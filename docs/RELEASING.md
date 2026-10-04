# Release preparation

Source publication does not need Apple membership. A trusted public macOS download should use Developer ID signing and Apple notarization. The default build remains an explicitly labeled ad-hoc Beta, not a substitute for either.

## 1. Review source before pushing

```sh
git status --short
git diff --check
ruby scripts/privacy_check.rb --self-test
ruby scripts/test_privacy_check.rb
ruby scripts/privacy_check.rb --history
zsh scripts/test.sh
zsh scripts/build_app.sh
```

Review the complete intended file list, then stage only those files yourself. Inspect `git diff --cached` and run `ruby scripts/privacy_check.rb --staged` before committing. No script here stages, commits, tags or pushes source automatically.

The scanner covers tracked/non-ignored working-tree candidates and, with `--history`, reachable blobs in local refs. `--staged` scans the exact staged bytes. `--artifact APP` scans bundled filenames and bytes; ZIP verification runs this automatically. It detects configured token/private-key shapes, common personal-data/signing filenames and non-demo absolute macOS home paths. It does not inspect ignored personal data or print matched values. It can miss unknown secrets, image contents, inaccessible/unfetched refs and arbitrary sensitive prose. Review everything manually; use `--demo` for public screenshots. If a secret has already been published, revoke it before addressing history.

Keep the source-only release usable without Apple credentials. The current package is arm64/macOS 14+; do not advertise Intel/universal or untested OS versions.

## 2. Ad-hoc Beta artifacts

`build_app.sh` builds an explicit arm64 target without debug information and remaps source paths, signs in a temporary staging folder, verifies the app and then re-extracts/verifies/scans its ZIP. It writes:

- `dist/AgentJournal-VERSION-macOS-arm64-adhoc.zip`
- the matching `.zip.sha256` and `.json` metadata
- local shortcuts `dist/AgentJournal.app` and `dist/AgentJournal.zip`

Only publish the versioned asset and its matching sidecars. Metadata includes app/build version, architecture, minimum OS, signing mode, source commit, dirty-tree flag and digest; no home paths or account/certificate names. A dirty-tree build is suitable for local testing, not a reproducible tagged release. Checksums detect corruption; they do not establish publisher identity.

Desktop/iCloud file providers can reattach Finder metadata to the development `.app` copy and cause strict verification there to fail. The release ZIP is created from clean temporary staging, not that copy; verify a freshly extracted ZIP outside a synced folder. Do not re-zip the development `.app` as a public asset.

Verify after downloading/copying, from the project root:

```sh
(cd dist && shasum -a 256 -c AgentJournal-0.5.0-macOS-arm64-adhoc.zip.sha256)
zsh scripts/verify_artifact.sh dist/AgentJournal-0.5.0-macOS-arm64-adhoc.zip
```

Pass the actual ZIP path to the second command. This verifier checks the packaging structure, architecture, minimum OS and signature without launching the app. It is intended for this project's assets, not as a general malicious-archive scanner. Default verification does **not** claim notarization or clean-Mac acceptance.

## 3. Optional Developer ID signing and notarization

### Drag-to-Applications disk images

`zsh scripts/build_dmg.sh` builds/verifies the ZIP, creates a compressed read-only disk image containing the signed app, an Applications shortcut and bilingual install notes, then mounts it read-only without opening Finder or launching the app for verification. The image is detached after checking. Disk-image services must be available; a restricted execution sandbox may need explicit permission to create/mount this local virtual image.

It produces `AgentJournal-VERSION-macOS-arm64-adhoc.dmg`, the matching `.dmg.sha256` and `.dmg.json`. ZIP metadata retains its original `-adhoc.json` filename; DMG metadata is separate and must not overwrite it. Open the DMG, quit the older app, drag into Applications, eject, and launch the installed copy. Export a private backup before upgrading. Do not rebuild a disk image from the Desktop/iCloud development app copy.

The default image is a **test installer, not a trusted public release**. It does not get Developer ID or notarization merely by using `.dmg`. For a signed/notarized image, use the same non-secret environment references below with `zsh scripts/build_dmg.sh --sign --notarize`. This explicit command submits/staples the app first and then signs/submits/staples its enclosing DMG, checks both tickets and Gatekeeper assessments, and generates matching checksums/metadata. It makes two Apple submissions and uploads packaged software only, never local journals or backups. Missing configuration fails before building/uploading; no ad-hoc fallback is permitted. `zsh scripts/verify_dmg.sh ASSET.dmg --require-notarized` checks the finished downloaded-equivalent container/app without launching either.

Use Developer ID **Application** signing for app and DMG; this workflow does not use a `.pkg` or require an Installer certificate. Local CI/test builds make no Apple submission. A reviewed clean tag, certificate-backed success, fresh-Mac browser-download acceptance and a maintainer-reviewed Release remain mandatory for calling a download notarized/public-ready. See Apple's [packaging instructions](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

The maintainer must enroll, pay/accept terms and verify identity themselves. Create a **Developer ID Application** certificate and keep its private key in Keychain; never commit/export it into this repo. `.pkg` installers use a separate Developer ID Installer certificate; this ZIP workflow does not need one.

Store notarization credentials interactively, outside the repository:

```sh
xcrun notarytool store-credentials AgentJournal-notary
```

Use Apple's secure prompts. Do not paste passwords/API private keys into shell history, issues or chat. Then set non-secret references and explicitly request signing/upload:

```sh
export AGENTJOURNAL_SIGNING_IDENTITY='Developer ID Application: YOUR LEGAL NAME (TEAMID)'
export AGENTJOURNAL_NOTARY_PROFILE='AgentJournal-notary'
zsh scripts/build_app.sh --sign --notarize
```

`--sign` adds Hardened Runtime and a secure timestamp, verifies the Apple Developer ID certificate requirement, and never falls back to ad-hoc. `--notarize` additionally uploads only the packaged application, waits for `Accepted`, staples/validates the app's ticket, repackages the ZIP, and checks the downloaded-equivalent extraction with Gatekeeper. It requires `--sign` and a Keychain profile. ZIPs cannot be stapled directly. Submission results remain private under ignored `.build/notary-results/`; if timed out, the service may still be processing. Inspect the saved submission ID and Apple's `notarytool info/log` before resubmitting. No journal/transcripts are bundled or uploaded.

The notarized output ends in `-notarized.zip`, with its own checksum/metadata. A `-developer-id.zip` produced by `--sign` alone is **not notarized**. Signing/notarization is not a privacy or code-quality endorsement, and normal first-launch/permission prompts can remain. This path cannot be verified without a real certificate and successful Apple submission.

Prefer local signing for the first release. CI currently receives no Apple credentials. If signing is moved into CI later, use protected environments, encrypted Secrets and an isolated temporary Keychain; do not expose signing secrets to pull-request jobs.

## 4. Release draft, not automatic publication

After reviewing/committing source and updating app version, build number, changelog and notes, create and push a reviewed Beta tag yourself, for example `v0.5.0-beta.1`. This is a separate authorized Git operation, not done by these scripts.

Run **Prepare unsigned Beta release draft** manually on `main` with that existing tag. It verifies tag/version consistency, main ancestry, a clean checkout, privacy checks, synthetic tests and ZIP/DMG validation. It creates an unsigned **draft prerelease**, refuses to replace an existing Release, and never publishes automatically. Review notes and [acceptance checks](RELEASE_CHECKLIST.md) before deciding whether to publish.

For a notarized public download, build locally from the same clean tag with `--sign --notarize`. Replace the unsigned draft assets with the matching notarized ZIP/DMG and their checksums/metadata, and update the notes to reflect their actual signing status before publication. Do not mix checksum/metadata from different builds. GitHub CI artifacts are test outputs, not automatically approved public releases.

Official references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [GitHub runner architectures](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
