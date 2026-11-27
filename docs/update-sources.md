# Release sources

myai is a source preview. Build, sign, and update it with Xcode using the [build guide](../README.md#build-for-your-iphone).

The iOS app uses its installed development profile and manages its version through Xcode. It connects to an external relay only when you choose an address in Settings.

## Legacy release tools

The retained Poki release tools require explicit configuration. The preview ships with an empty [signed catalog configuration](../config/release-source.json).

| Setting | Purpose |
| --- | --- |
| `MYAI_LEGACY_RELEASE_REPO` | GitHub `owner/repo` to query for releases or developer artifacts. An empty value keeps GitHub release lookups and MCP update notices disabled. |
| `MYAI_LEGACY_SETUP_TEAM_IDS` | Comma-separated Apple Developer ID teams that the legacy Mac installer may trust. The installer checks the code signature and notarization. |
| `MYAI_LEGACY_GITHUB_CLIENT_ID` | GitHub device sign-in client ID for an operator's own developer artifact integration. |

A signed release catalog uses explicit `url` and `public_key` settings. Rust embeds these values at build time, and Node reads them from the checkout. Use an HTTPS address and the publisher's 32-byte Ed25519 verification key encoded as hexadecimal. Keep the private key outside the repository.

The clients verify the signed payload, approved origin, asset path, size, and SHA-256. When an authenticated catalog asset is unavailable and a GitHub mirror is configured, the same tag and filename must satisfy the catalog's integrity data. Invalid signatures, redirects, and integrity failures stop the download.

The legacy scripts in `scripts/release` document Poki's historical publication flow. myai's GitHub workflow runs local-source checks with read-only permissions.
