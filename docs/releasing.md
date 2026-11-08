# Releasing Agora

Agora comes in three separate apps, so they install side by side with their own settings and saved logins:

| | Agora (stable) | Agora Nightly | Agora Dev |
|---|---|---|---|
| Bundle ID | `io.github.willyrl.agora` | `io.github.willyrl.agora.nightly` | `io.github.willyrl.agora.dev` |
| Made by | pushing a `v*` tag (`release.yml`) | every night at 19:00 UTC when `main` changed, or **Actions → Nightly → Run workflow** (`nightly.yml`) | `scripts/build-app.sh` on your Mac |
| Version | from the tag: `0.2.0` | the next patch + date: `0.2.1-nightly.20261109` | Info.plist's |
| On GitHub | a release, marked latest (a tag with a dash, `v0.2.0-beta.1`, is a pre-release) | one rolling pre-release tagged `nightly`, replaced each night | — |
| Updates from | `releases/latest/download/appcast.xml` | `releases/download/nightly/appcast-nightly.xml` | doesn't update |
| Icon | plain | dark NIGHTLY band | orange DEV band |

`scripts/build-app.sh [dev|stable|nightly]` sets the bundle ID, name and icon; `scripts/package-release.sh` (with `AGORA_FLAVOR=stable|nightly`) adds the update feed and packages it.

## Make a stable release

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The workflow tests, builds a universal app (Apple Silicon + Intel) with the version stamped in, packages `Agora-<version>.dmg` and `.zip` with `SHA256SUMS`, publishes the release with generated notes, then signs the `.zip` and attaches the update feed. **Actions → Release → Run workflow** makes a draft instead, to look over first.

Build numbers (`CFBundleVersion`) are UTC timestamps (`YYYYMMDDHHMM`), so every build is newer than the one before it.

Locally, `scripts/package-release.sh <version>` does the same packaging into `dist/`, and `scripts/make-appcast.sh` writes a feed.

**Fixing a released version** while `main` has moved on: branch from the tag (`git switch -c release/0.2 v0.2.0`), fix it there, tag `v0.2.1` on that branch, and bring the fix to `main` too.

## Secrets

| Secret | For | Without it |
|---|---|---|
| `SPARKLE_PRIVATE_KEY` | signing updates (EdDSA, from Sparkle's `generate_keys`) | no update feed is published |
| `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` | a "Developer ID Application" certificate (.p12, base64) | signed ad hoc; the notes explain the first launch |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization (needs the certificate too) | not notarized; macOS warns on first open |

### The update signing key

Every update is checked against the public key built into Agora (`AGORA_UPDATE_PUBLIC_KEY` in `scripts/package-release.sh`). **Keep the private key backed up**, for example in a password manager: if it's lost, installed copies can't accept new updates and everyone has to reinstall by hand; if it leaks, someone could sign fake updates.

- It was generated on the maintainer's Mac and lives in that login Keychain under the account `agora-updates`. Export it with Sparkle's tools: `generate_keys --account agora-updates -x key.txt` (then delete `key.txt`).
- GitHub secrets can't be read back. To set it again: `gh secret set SPARKLE_PRIVATE_KEY < key.txt`.
- Sparkle's tools come from `scripts/get-sparkle-tools.sh`, pinned to a version and checksum. When Sparkle is updated in `Package.resolved`, update that script's `VERSION` and `SHA256` too.

## Signing locally

`scripts/build-app.sh` signs with `AGORA_SIGN_IDENTITY` when set (e.g. `"Developer ID Application: Name (TEAMID)"`), else the local certificate from `scripts/make-signing-cert.sh`, else ad hoc. Only a Developer ID gets the hardened runtime and a secure timestamp, which notarization needs; ad-hoc and self-signed builds can't load Sparkle under the hardened runtime.

Only release builds update themselves: `package-release.sh` puts the feed and public key into Info.plist. Agora Dev and the demo have neither, so they never replace themselves with a release.
