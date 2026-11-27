// Source previews have no hosted release publisher. Legacy tooling can opt in to a particular repo.
export function legacyReleaseSetting(name) {
  return process.env[`MYAI_LEGACY_${name}`] ?? process.env[`AILOVE_LEGACY_${name}`];
}

export function releaseRepository() {
  const repo = legacyReleaseSetting('RELEASE_REPO')?.trim();
  return repo && /^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_.-]+$/.test(repo) && !repo.endsWith('/.') && !repo.endsWith('/..')
    ? repo
    : undefined;
}
