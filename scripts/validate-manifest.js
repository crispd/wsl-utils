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

const ajv = new Ajv2020({ allErrors: true, strict: false, loadSchema: loadSchema });
addFormats(ajv);

function loadSchema(uri) {
  // Resolve file: URIs relative to schema folder
  if (uri.startsWith('file:')) {
    const p = uri.slice('file:'.length);
    const candidate = path.resolve(path.dirname(schemaPath), p);
    if (fs.existsSync(candidate)) {
      return Promise.resolve(JSON.parse(fs.readFileSync(candidate, 'utf8')));
    }
  }
  // Fallback to network fetch is omitted for security
  return Promise.reject(new Error('Unable to load schema: ' + uri));
}

(async () => {
  try {
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
