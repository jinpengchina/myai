import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';
import { latestSetup, downloadIpa, ensureSetupApp, pokiTeamOf } from '../src/install/setup-app.mjs';
import { releaseRepository } from '../src/release-repository.mjs';
import { startUpdateChecks, updateNotice } from '../src/update-check.mjs';

function environment(t, values) {
  for (const [name, value] of Object.entries(values)) {
    const previous = process.env[name];
    process.env[name] = value;
    t.after(() => previous === undefined ? delete process.env[name] : process.env[name] = previous);
  }
}

test('the source preview has no trusted publisher, network update, or installer download', async t => {
  environment(t, {
    AILOVE_LEGACY_RELEASE_REPO: '',
    AILOVE_LEGACY_SETUP_TEAM_IDS: '',
    POKI_RELEASE_REPO: 'upstream/poki',
    POKI_NO_UPDATE_CHECK: '',
  });
  const fetch = t.mock.method(globalThis, 'fetch', () => assert.fail('Unexpected network request'));

  assert.equal(releaseRepository(), undefined);
  assert.equal(pokiTeamOf('TeamIdentifier=TESTTEAM01'), null);
  assert.equal(await updateNotice(), undefined);
  startUpdateChecks()();

  await assert.rejects(latestSetup(), /No installer release repository is configured/);
  await assert.rejects(downloadIpa('app-beta', 'unused'), /No installer release repository is configured/);
  await assert.rejects(ensureSetupApp({}), /No installer signing team is configured/);
  assert.equal(fetch.mock.callCount(), 0);
});

test('an explicitly set release repository accepts only owner and repository path segments', t => {
  environment(t, { AILOVE_LEGACY_RELEASE_REPO: '' });
  for (const unsafe of ['example.com/u/repo', 'https://example.com/u/repo', 'example/../x', 'example/.', 'example/..', 'u/r?admin=true', 'u/%2Er', 'u//r']) {
    process.env.AILOVE_LEGACY_RELEASE_REPO = unsafe;
    assert.equal(releaseRepository(), undefined);
  }
  process.env.AILOVE_LEGACY_RELEASE_REPO = ' example-org/my.ailove_fork ';
  assert.equal(releaseRepository(), 'example-org/my.ailove_fork');
});

test('the legacy CLI asks for explicit configuration before launching a device helper', async () => {
  const cli = fileURLToPath(new URL('../bin/install-iphone.mjs', import.meta.url));
  const exec = promisify(execFile);
  for (const command of ['run', '--update-only']) {
    await assert.rejects(
      exec(process.execPath, [cli, command, '--json', '--bridge', '/fixture/nonexistent-helper'], {
        env: { ...process.env, AILOVE_LEGACY_RELEASE_REPO: '', POKI_INSTALL_ANY_NODE: '1' },
      }),
      error => {
        assert.equal(error.code, 2);
        assert.equal(JSON.parse(error.stdout).code, 'setup_download_failed');
        assert.match(error.stdout, /Install ailove from source with Xcode/);
        return true;
      },
    );
  }
});

test('GitHub Actions only runs read-only preview checks', async () => {
  const directory = new URL('../.github/workflows/', import.meta.url);
  const names = await readdir(directory);
  assert.deepEqual(names.filter(name => /\.ya?ml$/.test(name)), ['source-checks.yml']);
  const contents = await readFile(new URL('source-checks.yml', directory), 'utf8');
  assert.match(contents, /permissions:\n  contents: read\n/);
  assert.match(contents, /persist-credentials: false/);
  assert.doesNotMatch(contents, /pull_request_target|secrets\.|:\s+write\b|gh release|wrangler/);
});
