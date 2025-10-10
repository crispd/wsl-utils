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
  // Resolve file: URIs relative to schema folder. Handles file:someFile.json and
  // file:meta/core style references by extracting sub-objects from the local draft file.
  if (uri.startsWith('file:')) {
    const full = uri.slice('file:'.length);
    const [p, hash] = full.split('#', 2);
    const candidate = path.resolve(path.dirname(schemaPath), p || '');
    if (p && fs.existsSync(candidate)) {
      const loaded = JSON.parse(fs.readFileSync(candidate, 'utf8'));
      if (loaded && loaded.$id && ajv && ajv.getSchema(loaded.$id)) delete loaded.$id;
      if (hash) {
        const pointer = hash.replace(/^\//, '');
        const parts = pointer.split('/').map(decodeURIComponent).filter(Boolean);
        let cur = loaded;
        for (const part of parts) { cur = cur && cur[part]; }
        return Promise.resolve(cur || loaded);
      }
      return Promise.resolve(loaded);
    }

    // Fall back: try to extract sub-schema from local draft2020-12.json (if present)
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
        if (cur && cur.$id && ajv && ajv.getSchema(cur.$id)) delete cur.$id;
        return Promise.resolve(cur);
      }
    }
  }
  return Promise.reject(new Error('Unable to load schema: ' + uri));
}

function collectMissingScriptPaths(manifest, rootDir) {
  const missing = [];
  if (!manifest || typeof manifest !== 'object' || !manifest.scripts) {
    return missing;
  }

  for (const [lang, entries] of Object.entries(manifest.scripts)) {
    if (!entries || typeof entries !== 'object') continue;
    for (const [name, def] of Object.entries(entries)) {
      if (!def || typeof def.path !== 'string') continue;
      const relPath = def.path;
      const absPath = path.resolve(rootDir, relPath);
      if (!fs.existsSync(absPath)) {
        missing.push({ lang, name, relativePath: relPath, fullPath: absPath });
      }
    }
  }

  return missing;
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
    const schemaErrors = (!valid && Array.isArray(validate.errors)) ? validate.errors : [];
    const missingScripts = collectMissingScriptPaths(data, path.resolve(__dirname, '..'));

    if (schemaErrors.length || missingScripts.length) {
      console.error('\nmanifest.json is INVALID - see details below:');

      const reportLines = [];
      reportLines.push('# manifest.json validation report');
      reportLines.push('');
      reportLines.push('The manifest failed validation. See the issues listed below.');
      reportLines.push('');

      let issueIndex = 0;

      schemaErrors.forEach((err) => {
        issueIndex += 1;
        const instancePath = err.instancePath || err.dataPath || '/';
        const schemaPath = err.schemaPath || '';
        const keyword = err.keyword || '';
        const message = err.message || '';
        console.error(`\n[${issueIndex}] ${keyword} ${message}`);
        console.error(`  instancePath: ${instancePath}`);
        if (schemaPath) console.error(`  schemaPath: ${schemaPath}`);
        if (err.params) console.error(`  params: ${JSON.stringify(err.params)}`);

        let preview = '';
        try {
          const snippet = getDataAtPointer(data, instancePath);
          const printed = JSON.stringify(snippet, null, 2);
          preview = printed.length > 300 ? printed.slice(0, 300) + '...' : printed;
          console.error(`  data: ${preview}`);
        } catch (e) {
          // ignore
        }

        reportLines.push(`## Issue ${issueIndex}`);
        reportLines.push('');
        reportLines.push('- **type**: schema');
        reportLines.push(`- **keyword**: ${keyword}`);
        reportLines.push(`- **message**: ${message}`);
        reportLines.push(`- **instancePath**: \`${instancePath}\``);
        if (schemaPath) reportLines.push(`- **schemaPath**: \`${schemaPath}\``);
        if (err.params) {
          reportLines.push('- **params**:');
          reportLines.push('');
          reportLines.push('```json');
          reportLines.push(JSON.stringify(err.params, null, 2));
          reportLines.push('```');
        }
        if (preview) {
          reportLines.push('');
          reportLines.push('**data**:');
          reportLines.push('');
          reportLines.push('```json');
          reportLines.push(preview);
          reportLines.push('```');
        }
        reportLines.push('');
      });

      missingScripts.forEach((entry) => {
        issueIndex += 1;
        console.error(`\n[${issueIndex}] missing-script ${entry.relativePath}`);
        console.error(`  instancePath: /scripts/${entry.lang}/${entry.name}`);
        console.error(`  expectedPath: ${entry.relativePath}`);
        console.error(`  resolvedPath: ${entry.fullPath}`);

        reportLines.push(`## Issue ${issueIndex}`);
        reportLines.push('');
        reportLines.push('- **type**: missing-script');
        reportLines.push(`- **script**: \`${entry.lang}:${entry.name}\``);
        reportLines.push(`- **path**: \`${entry.relativePath}\``);
        reportLines.push(`- **resolvedPath**: \`${entry.fullPath}\``);
        reportLines.push('');
      });

      try {
        const reportDir = path.resolve(__dirname, '..', 'reports');
        if (!fs.existsSync(reportDir)) fs.mkdirSync(reportDir, { recursive: true });
        const reportPath = path.resolve(reportDir, 'manifest-validation.md');
        fs.writeFileSync(reportPath, reportLines.join('\n'), 'utf8');
        console.error('\nWrote validation report to ' + reportPath);
      } catch (e) {
        console.error('Failed to write validation report:', e && e.message ? e.message : String(e));
      }

      process.exit(1);
    }
    console.log('manifest.json is valid');
    process.exit(0);
  } catch (err) {
    console.error('Validation failed unexpectedly:');
    console.error(err && err.stack ? err.stack : String(err));
    process.exit(2);
  }
})();

// Helper: resolve a JSON Pointer-like instancePath (e.g. '/tasks/backup/steps/0')
function getDataAtPointer(root, pointer) {
  if (!pointer || pointer === '/') return root;
  // AJV instancePath is a JSON Pointer without the '#'
  const parts = pointer.replace(/^\//, '').split('/').map(unescapePointer);
  let cur = root;
  for (const p of parts) {
    if (cur === undefined || cur === null) return undefined;
    if (Array.isArray(cur)) {
      const idx = parseInt(p, 10);
      cur = cur[idx];
    } else {
      cur = cur[p];
    }
  }
  return cur;
}

function unescapePointer(str) {
  return str.replace(/~1/g, '/').replace(/~0/g, '~');
}



