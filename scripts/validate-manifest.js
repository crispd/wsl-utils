const path = require('path');
const fs = require('fs');

// Use AJV 2020 entrypoint if available
let Ajv2020;
try {
  Ajv2020 = require('ajv/dist/2020');
} catch (e) {
  Ajv2020 = null;
}

if (!Ajv2020) {
  console.error('AJV 2020 entrypoint not found. Please install dev deps: npm i -D ajv@8 ajv-formats');
  process.exit(2);
}

const addFormats = require('ajv-formats');

const schemaPath = path.resolve(__dirname, '..', 'schema', 'manifest.schema.json');
const dataPath = path.resolve(__dirname, '..', 'manifest.json');

const schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

// Don't automatically add the default meta-schemas to AJV (meta:false).
// This prevents AJV from attempting to fetch/resolve the draft meta-schema
// fragments (like "meta/core") which aren't available as separate files locally.
const ajv = new Ajv2020({ allErrors: true, strict: false, loadSchema: loadSchema, meta: false });
addFormats(ajv);
 

function loadSchema(uri) {
  // Resolve file: URIs relative to schema folder. Handles two cases:
  //  - file:someFile.json  -> loads schema file at schema/someFile.json
  //  - file:meta/core       -> the official meta-schema references sub-schemas by path
  //                         which may exist only inside the downloaded draft file.
  if (uri.startsWith('file:')) {
    const full = uri.slice('file:'.length);
    // split off fragment if present
    const [p, hash] = full.split('#', 2);
    const candidate = path.resolve(path.dirname(schemaPath), p || '');
    if (p && fs.existsSync(candidate)) {
      const loaded = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      // avoid duplicate registration of $id
      try { if (loaded && loaded.$id && ajv && ajv.getSchema(loaded.$id)) delete loaded.$id } catch (e) {}
      // if a fragment was supplied, resolve it as a simple JSON pointer (rough support)
      if (hash) {
        // strip leading '/' if present
        const pointer = hash.replace(/^\//, '');
        const parts = pointer.split('/').map(decodeURIComponent).filter(Boolean);
        let cur = loaded;
        for (const part of parts) { cur = cur && cur[part] }
        return Promise.resolve(cur || loaded);
      }
      return Promise.resolve(loaded);
    }

    // If candidate file doesn't exist, attempt to resolve the path inside the local draft file
    // e.g., uri 'file:meta/core' should return the object at draft['meta']['core'] if present.
    const draftPath = path.resolve(path.dirname(schemaPath), 'draft2020-12.json');
    if (fs.existsSync(draftPath)) {
      const draft = JSON.parse(fs.readFileSync(draftPath, 'utf8'));
      const parts = full.split('#', 1)[0].split('/').filter(Boolean);
      let cur = draft;
      for (const part of parts) {
        if (cur && Object.prototype.hasOwnProperty.call(cur, part)) {
          cur = cur[part];
        } else {
          cur = null;
          break;
        }
      }
      if (cur) {
        // If AJV expects the ref under the meta-schema namespace, register this sub-schema
        // under a composed id so subsequent refs can resolve (e.g. 'https://json-schema.org/draft/2020-12/schema/meta/core').
        try {
          const composedId = 'https://json-schema.org/draft/2020-12/schema/' + parts.join('/');
          if (cur && cur.$id) delete cur.$id;
          // register only if not already present
          if (!ajv.getSchema(composedId)) {
            ajv.addSchema(cur, composedId);
          }
        } catch (e) {
          // ignore registration errors
        }
        return Promise.resolve(cur);
      }
    }
  }
  // Fallback to network fetch is omitted for security
  return Promise.reject(new Error('Unable to load schema: ' + uri));
}

(async () => {
  try {
    // Prevent AJV from attempting to load the meta-schema referenced by the schema
    // (e.g. file:./draft2020-12.json) since resolving the draft's internal 'meta/*'
    // references requires many additional files. Removing $schema is safe for
    // validation with AJV where we control the runtime.
    if (schema && schema.$schema) delete schema.$schema;

    const validate = await ajv.compileAsync(schema);
    const valid = validate(data);
    if (!valid) {
      console.error('manifest.json is INVALID');
      console.error(validate.errors);
      process.exit(1);
    }
    console.log('manifest.json is valid');
    process.exit(0);
  } catch (err) {
    console.error('Validation failed unexpectedly:', err.message);
    process.exit(2);
  }
})();
