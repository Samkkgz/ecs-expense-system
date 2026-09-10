const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const nasRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(nasRoot, '..');

const indexHtml = fs.readFileSync(path.join(nasRoot, 'index.html'), 'utf8');
const initSql = fs.readFileSync(path.join(nasRoot, 'sql', 'init.sql'), 'utf8');
const migrationSql = fs.readFileSync(
  path.join(nasRoot, 'sql', 'migration-v4.20.0-admin-reset-user-password.sql'),
  'utf8'
);
const versions = fs.readFileSync(path.join(repoRoot, 'VERSIONS.md'), 'utf8');

test('version markers remain consistent', () => {
  assert.match(indexHtml, /ECS v4\.20\.0/);
  assert.match(indexHtml, />v4\.20\.0<\/span>/);
  assert.match(versions, /## v4\.20\.0 \(2026-09-10\)/);
});

test('user management renders password reset only in the super admin branch', () => {
  const rowRenderer = indexHtml.match(/profiles_data\.map\(function\(u\)[\s\S]*?\}\)\.join\(''\)\+/);
  assert.ok(rowRenderer, 'user management row renderer should exist');

  const rowHtml = rowRenderer[0];
  const superAdminBranch = rowHtml.indexOf("isSuperAdmin?'");
  const resetButton = rowHtml.indexOf('openAdminResetPassword');

  assert.ok(superAdminBranch >= 0, 'super admin conditional branch should exist');
  assert.ok(resetButton > superAdminBranch, 'password reset button must be inside the super admin branch');
  assert.match(rowHtml, /title="修改登录密码"/);
});

test('password modal contains secure confirmation inputs and error target', () => {
  assert.match(indexHtml, /data-password-overlay/);
  assert.match(indexHtml, /id="adminNewPassword"[^>]*type="password"|type="password"[^>]*id="adminNewPassword"/);
  assert.match(indexHtml, /id="adminConfirmPassword"[^>]*type="password"|type="password"[^>]*id="adminConfirmPassword"/);
  assert.match(indexHtml, /minlength="6"/);
  assert.match(indexHtml, /maxlength="72"/);
  assert.match(indexHtml, /id="adminPasswordError"/);
  assert.match(indexHtml, /password !== confirmPassword/);
});

test('frontend submits the reset request with the expected RPC parameters', () => {
  assert.match(indexHtml, /sb\.rpc\('admin_reset_user_password'/);
  assert.match(indexHtml, /p_user_id:\s*uid/);
  assert.match(indexHtml, /p_new_password:\s*password/);
  assert.doesNotMatch(indexHtml, /console\.log\([^\n]*password/i);
});

test('database function is super-admin-only and stores a bcrypt hash', () => {
  const functionPattern = /CREATE OR REPLACE FUNCTION public\.admin_reset_user_password\([\s\S]*?\$fn\$;/;
  const initFunction = initSql.match(functionPattern);
  const migrationFunction = migrationSql.match(functionPattern);

  assert.ok(initFunction, 'init.sql should define admin_reset_user_password');
  assert.ok(migrationFunction, 'migration should define admin_reset_user_password');
  assert.equal(initFunction[0], migrationFunction[0], 'init.sql and migration function bodies should match');

  assert.match(initFunction[0], /role = 'super_admin'/);
  assert.doesNotMatch(initFunction[0], /role IN \('admin','super_admin'\)/);
  assert.match(initFunction[0], /extensions\.crypt/);
  assert.match(initFunction[0], /extensions\.gen_salt\('bf', 10\)/);
  assert.match(initFunction[0], /auth\.users/);
  assert.match(initFunction[0], /octet_length\(p_new_password\) > 72/);
});
