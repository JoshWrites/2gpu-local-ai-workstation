// Smoke test for the tool.execute.before hook. Run with: node test-hook.js

import { PermissionClassifier } from './index.js';

let failures = 0;
let passes = 0;

function assertPass(label, fn) {
  try {
    fn();
    passes++;
  } catch (e) {
    failures++;
    console.error(`FAIL: ${label}: ${e.message}`);
  }
}

async function assertNoThrow(hook, input, output, label) {
  try {
    await hook(input, output);
    passes++;
  } catch (e) {
    failures++;
    console.error(`FAIL: ${label}: should not throw, but threw: ${e.message}`);
  }
}

async function assertThrows(hook, input, output, label, expectedInMessage) {
  try {
    await hook(input, output);
    failures++;
    console.error(`FAIL: ${label}: should throw, but didn't`);
  } catch (e) {
    if (expectedInMessage && !e.message.includes(expectedInMessage)) {
      failures++;
      console.error(`FAIL: ${label}: threw but message missing "${expectedInMessage}": ${e.message}`);
    } else {
      passes++;
    }
  }
}

async function main() {
  const hooks = await PermissionClassifier({});
  const hook = hooks['tool.execute.before'];

  // Non-bash tool: should do nothing
  await assertNoThrow(hook, { tool: 'edit' }, { args: { path: '/tmp/x' } }, 'non-bash tool');

  // Read tier: should not throw
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'ls /tmp' } }, 'read: ls');
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'docker ps' } }, 'read: docker ps');
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'ssh laptop -- ls /home/anny' } }, 'read: ssh ls');

  // Write tier: should not throw
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'mkdir /tmp/foo' } }, 'write: mkdir');
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'git commit -m x' } }, 'write: git commit');
  await assertNoThrow(hook, { tool: 'bash' }, { args: { command: 'ssh laptop -- npm install' } }, 'write: ssh npm install');

  // Remove tier: should throw with a helpful message
  await assertThrows(
    hook,
    { tool: 'bash' },
    { args: { command: 'rm -rf /tmp/foo' } },
    'remove: rm -rf',
    'yes rm foo'
  );
  await assertThrows(
    hook,
    { tool: 'bash' },
    { args: { command: 'ssh laptop -- rm -rf /home/anny/junk' } },
    'remove: ssh rm',
    'yes rm junk'
  );
  await assertThrows(
    hook,
    { tool: 'bash' },
    { args: { command: 'docker rm jellyfin' } },
    'remove: docker rm',
    'yes rm jellyfin'
  );
  await assertThrows(
    hook,
    { tool: 'bash' },
    { args: { command: 'sudo pct destroy 100' } },
    'remove: pct destroy',
    'yes destroy 100'
  );

  // Missing command: should not throw
  await assertNoThrow(hook, { tool: 'bash' }, { args: {} }, 'missing command');
  await assertNoThrow(hook, { tool: 'bash' }, {}, 'missing args entirely');

  console.log('');
  if (failures > 0) {
    console.error(`FAILED: ${passes} passed, ${failures} failed`);
    process.exit(1);
  }
  console.log(`PASSED: ${passes} tests`);
}

main().catch((e) => {
  console.error('Unexpected:', e);
  process.exit(1);
});
