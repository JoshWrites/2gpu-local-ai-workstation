// Smoke test for the classifier. Run with: node test.js
//
// Not using a test framework — simple asserts with diff output.

import { PermissionClassifier } from './index.js';

let failures = 0;
let passes = 0;

function assertEqual(actual, expected, label) {
  if (actual === expected) {
    passes++;
    return;
  }
  failures++;
  console.error(`FAIL: ${label}`);
  console.error(`  expected: ${expected}`);
  console.error(`  actual:   ${actual}`);
}

// Helper: invoke the plugin with a bash command, return the output status
// (or the default 'ask' if the plugin leaves it alone).
async function callPlugin(command) {
  const hooks = await PermissionClassifier({});
  const input = {
    type: 'bash',
    pattern: command,
    metadata: {},
    id: 'test',
    sessionID: 'test',
    messageID: 'test',
    title: command,
    time: { created: Date.now() },
  };
  const output = { status: 'ask' }; // default
  await hooks['permission.ask'](input, output);
  return { status: output.status, metadata: input.metadata };
}

// ── Test cases ──────────────────────────────────────────────────────────

async function runTests() {
  // Read-tier commands should be allowed
  const readCases = [
    'ls /tmp',
    'cat /etc/hostname',
    'grep foo bar.txt',
    'rg pattern src/',
    'docker ps',
    'docker logs jellyfin',
    'git status',
    'git log --oneline',
    'systemctl status ssh',
    'ss -tlnp',
    'curl -s http://localhost:11434/v1/models',
    'pct list',
    'dig @1.1.1.1 example.com',
    'ssh laptop -- ls /home/anny',      // SSH prefix stripped
    'ssh levinelabsserver1 -- pct list',
    'sudo pct exec 100 -- docker ps',   // pct exec + sudo stripped
  ];
  for (const cmd of readCases) {
    const result = await callPlugin(cmd);
    assertEqual(result.status, 'allow', `read tier: "${cmd}"`);
  }

  // Write-tier commands should remain 'ask'
  const writeCases = [
    'mkdir /tmp/foo',
    'cp a b',
    'mv a b',
    'chmod 600 ~/.ssh/authorized_keys',
    'git add .',
    'git commit -m "foo"',
    'git push origin main',
    'systemctl restart ssh',
    'docker run -d nginx',
    'apt install curl',
    'pip install requests',
    'echo "hello" > /tmp/foo.txt',
    'sed -i "s/a/b/" file.txt',
    'kill 12345',
    'curl -X POST http://example.com',
    'ssh laptop -- git add .',          // SSH stripped, write-tier inside
    'ssh laptop -- npm install',
    'sudo systemctl restart nginx',
  ];
  for (const cmd of writeCases) {
    const result = await callPlugin(cmd);
    assertEqual(result.status, 'ask', `write tier: "${cmd}"`);
  }

  // Remove-tier commands should be denied with a hint
  const removeCases = [
    'rm -rf /tmp/foo',
    'rm file.txt',
    'docker rm jellyfin',
    'docker rmi nginx:latest',
    'docker volume rm my_volume',
    'docker system prune',
    'apt purge nvidia-container-runtime',
    'apt remove nginx',
    'pip uninstall requests',
    'npm uninstall lodash',
    'git reset --hard HEAD~5',
    'git clean -fd',
    'git push --force',
    'git push -f origin main',
    'git branch -D feature-x',
    'git stash drop',
    'kill -9 12345',
    'killall node',
    'pkill -f chrome',
    'pct destroy 100',
    'dd if=/dev/zero of=/dev/sda',
    'mkfs.ext4 /dev/sdb1',
    'reboot',
    'shutdown now',
    'sudo rm -rf /tmp/foo',             // sudo stripped
    'ssh laptop -- rm -rf /foo',        // SSH stripped
    'ssh levinelabsserver1 -- sudo pct exec 100 -- docker rm jellyfin', // all strips
  ];
  for (const cmd of removeCases) {
    const result = await callPlugin(cmd);
    assertEqual(result.status, 'deny', `remove tier: "${cmd}"`);
    if (!result.metadata.classifier_hint) {
      failures++;
      console.error(`FAIL: "${cmd}" denied but no classifier_hint set`);
    }
  }

  // Unclassified should default to 'ask' (safe fallback)
  const unclassifiedCases = [
    'some-random-binary --flag',
    'pytest tests/',
    'cargo run',
    'python3 -m some_module',
  ];
  for (const cmd of unclassifiedCases) {
    const result = await callPlugin(cmd);
    assertEqual(result.status, 'ask', `unclassified: "${cmd}"`);
  }

  // Edge cases: non-bash permissions should be untouched
  {
    const hooks = await PermissionClassifier({});
    const input = { type: 'edit', pattern: '/some/file', metadata: {}, id: 't', sessionID: 't', messageID: 't', title: 't', time: { created: 0 } };
    const output = { status: 'ask' };
    await hooks['permission.ask'](input, output);
    assertEqual(output.status, 'ask', 'edit permission: unchanged');
  }

  // ── Summary ──
  console.log('');
  if (failures > 0) {
    console.error(`FAILED: ${passes} passed, ${failures} failed`);
    process.exit(1);
  } else {
    console.log(`PASSED: ${passes} tests`);
  }
}

runTests().catch((err) => {
  console.error('Unexpected error:', err);
  process.exit(1);
});
