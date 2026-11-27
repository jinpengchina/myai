// Ported from GitHub CLI v2.83.0, internal/update/update.go (MIT).
// https://github.com/cli/cli/blob/152d328db80d4d4d7318c7700b6644ee827618a7/internal/update/update.go
// Copyright (c) 2019 GitHub Inc. See third_party/LICENSE.github-cli.
// Poki uses JSON, anonymous requests, cached notices, and silent failures for MCP clients.
import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { stateDir } from './config.mjs';
import { version } from './build-info.mjs';
import { releaseRepository } from './release-repository.mjs';

const day = 24 * 60 * 60 * 1000;
const stateFile = join(stateDir, 'update-check.json');
const pending = new Map();
let state;

function versionParts(value) {
  const match = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([\w.-]+))?(?:\+[\w.-]+)?$/.exec(value ?? '');
  return match && { numbers: match.slice(1, 4).map(Number), prerelease: match[4] };
}

function notice(repo, release) {
  const latest = versionParts(release?.tag_name), current = versionParts(version);
  if (!latest || !current || latest.prerelease || release.draft || release.prerelease) return;
  const difference = latest.numbers.map((n, i) => n - current.numbers[i]).find(n => n !== 0) ?? 0;
  if (difference < 0 || (difference === 0 && !current.prerelease)) return;
  const firstLine = String(release.body ?? '').split(/\r?\n/).map(line => line.trim()).find(line => line && !/^#{1,6}\s/.test(line)) ?? '';
  const summary = firstLine.replace(/^[-*+]\s+/, '').replace(/[\x00-\x1f\x7f-\x9f]/g, '').match(/^.*?[.!?](?:\s|$)|^.+$/)?.[0].trim() ?? '';
  return { version: latest.numbers.join('.'), summary: summary.slice(0, 300), url: `https://github.com/${repo}/releases/tag/${encodeURIComponent(release.tag_name)}`, command: 'poki update' };
}

async function github(repo, path) {
  const response = await fetch(`https://api.github.com/repos/${repo}${path}`, {
    headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'poki-update-check' },
    signal: AbortSignal.timeout(1500), redirect: 'error',
  });
  if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
  return response.json();
}

async function checkForUpdate(repo) {
  state ??= await readFile(stateFile, 'utf8').then(JSON.parse).catch(() => null);
  const age = Date.now() - state?.checkedAt;
  if (state?.repo === repo && Number.isFinite(age) && age >= 0 && age < day) return notice(repo, state.release);
  let release = null;
  try {
    const tags = (await github(repo, '/git/matching-refs/tags/v')).map(ref => ref.ref?.replace(/^refs\/tags\//, '')).filter(tag => versionParts(tag) && !versionParts(tag).prerelease);
    const newest = tags.sort((a, b) => versionParts(a).numbers.map((n, i) => n - versionParts(b).numbers[i]).find(n => n !== 0) ?? 0).at(-1);
    if (newest) release = notice(repo, { tag_name: newest }) ? await github(repo, `/releases/tags/${encodeURIComponent(newest)}`) : { tag_name: newest, draft: false, prerelease: false };
  } catch {}
  state = { repo, checkedAt: Date.now(), release };
  try {
    await mkdir(stateDir, { recursive: true, mode: 0o700 });
    const temporary = `${stateFile}.${process.pid}.tmp`;
    await writeFile(temporary, JSON.stringify(state), { mode: 0o600 });
    await rename(temporary, stateFile);
  } catch {}
  return notice(repo, release);
}

export async function updateNotice() {
  const repo = releaseRepository();
  if (!repo || process.env.POKI_NO_UPDATE_CHECK === '1') return;
  if (!pending.has(repo)) {
    pending.set(repo, checkForUpdate(repo).catch(() => undefined).finally(() => pending.delete(repo)));
  }
  return pending.get(repo);
}

export function startUpdateChecks() {
  if (!releaseRepository()) return () => {};
  void updateNotice();
  const timer = setInterval(() => { void updateNotice(); }, day);
  timer.unref();
  return () => clearInterval(timer);
}
