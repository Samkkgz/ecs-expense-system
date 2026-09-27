const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const test = require('node:test');

test('NAS 断连探测间隔最长不超过 2 分钟', () => {
  const sourcePath = path.resolve(
    __dirname,
    '../scripts/auto_upload_invoices.py'
  );
  const script = String.raw`
import importlib.util
import sys
import time

source_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("ecs_auto_upload", source_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def delay_after(seconds):
    module._nas_down_since = time.time() - seconds
    return module._get_backoff_delay()


assert delay_after(0) == 30
assert delay_after(120) == 60
assert delay_after(240) == 120
assert delay_after(3600) == 120
assert module.BACKOFF_MAX == 120
print("ok")
`;

  const output = execFileSync('python3', ['-c', script, sourcePath], {
    encoding: 'utf8'
  });

  assert.equal(output.trim(), 'ok');
});
