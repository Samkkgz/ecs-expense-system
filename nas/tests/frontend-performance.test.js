const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const nasRoot = path.resolve(__dirname, '..');
const indexHtml = fs.readFileSync(path.join(nasRoot, 'index.html'), 'utf8');
const nginxConf = fs.readFileSync(path.join(nasRoot, 'nginx.conf'), 'utf8');
const head = indexHtml.slice(0, indexHtml.indexOf('</head>'));

test('heavy parser libraries do not block initial document parsing', () => {
  assert.doesNotMatch(indexHtml, /<script[^>]+src="[^"]*tesseract\.min\.js"/);
  assert.doesNotMatch(indexHtml, /<script[^>]+src="[^"]*jszip\.min\.js"/);
  assert.doesNotMatch(indexHtml, /<script[^>]+src="[^"]*xlsx\.full\.min\.js"/);
  assert.match(indexHtml, /function ensureJsZip\(\)/);
  assert.match(indexHtml, /function ensureXlsx\(\)/);
  assert.match(indexHtml, /await ensureJsZip\(\)/);
  assert.match(indexHtml, /await ensureXlsx\(\)/);
  assert.doesNotMatch(indexHtml, /<script src="[^"]*pdf\.min\.js"/);
  assert.match(indexHtml, /function ensurePdfJs\(\)/);
  assert.match(indexHtml, /await ensurePdfJs\(\)/);
  assert.doesNotMatch(head, /supabase-js/);
});

test('nginx enables compression and index revalidation', () => {
  assert.match(nginxConf, /gzip on;/);
  assert.match(nginxConf, /gzip_types[^;]*application\/javascript/);
  assert.match(nginxConf, /add_header Cache-Control "no-cache, must-revalidate" always/);
});
