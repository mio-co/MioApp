// Mac 更新辅助脚本（MioUpdateCore.macInstallScript）：语法、参数只走位置变量、失败时恢复旧版本
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { extractMacInstallScript } from './mac-install-script.mjs';

const script = extractMacInstallScript();

test('script is extracted with a shebang and no Swift indentation', () => {
  assert.ok(script.startsWith('#!/bin/sh\n'), script.slice(0, 40));
  assert.ok(script.split('\n')[1].startsWith('PID='), 'top-level lines are not indented');
  assert.ok(!script.includes('\\('), 'no Swift interpolation inside the raw string');
});

test('sh -n accepts the script', () => {
  const d = mkdtempSync(join(tmpdir(), 'mio-sh-'));
  const f = join(d, 'install.sh');
  writeFileSync(f, script);
  execFileSync('sh', ['-n', f]);
});

test('paths only come from positional parameters and are always quoted', () => {
  assert.match(script, /PID="\$1"; ZIP="\$2"; TARGET="\$3"; WORK="\$4"; LOG="\$5"; BUNDLE_ID="\$6"/);
  for (const v of ['ZIP', 'TARGET', 'WORK', 'NEW', 'LOG']) {
    const unquoted = new RegExp(`[^"]\\$${v}\\b|[^"]\\$\\{${v}\\}`);
    for (const line of script.split('\n')) {
      if (line.includes(`$${v}`)) assert.ok(!unquoted.test(line.replace(/"[^"]*"/g, '""')), `unquoted $${v}: ${line}`);
    }
  }
});

test('checks bundle id, strips quarantine, restores the old app on failure, supports no-relaunch', () => {
  assert.match(script, /PlistBuddy -c 'Print :CFBundleIdentifier'/);
  assert.match(script, /"\$ID" != "\$BUNDLE_ID"/);
  assert.match(script, /xattr -dr com\.apple\.quarantine "\$TARGET"/);
  assert.match(script, /\/bin\/mv "\$WORK\/old\.app" "\$TARGET"/);
  assert.match(script, /MIO_UPDATE_NO_RELAUNCH/);
  assert.match(script, /kill -0 "\$PID"/);
});
