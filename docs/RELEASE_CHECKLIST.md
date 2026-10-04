# Release acceptance checklist

Automation does not replace a clean-Mac installation test. Record the exact artifact digest, app version, OS/architecture and CLI versions used. Do not fill pending checks with assumptions.

## Source publication

- [ ] Review intended tracked/new files and `git diff --cached`; no unrelated workspace changes.
- [ ] Run privacy scanner self-tests, working/history check and exact staged check; manually inspect screenshots/prose too.
- [ ] Use synthetic fixtures/public screenshots only. No transcripts, journal/index files, credentials, signing keys or private paths.
- [ ] Default tests pass without any live-test flags. Edited/confirmed notes, migrations, cancellation and provider separation remain covered.
- [ ] App version/build, changelog, requirements and release notes agree. Latest code is committed before tagging.

## Locally automatable acceptance

| Scenario | Coverage / expected result |
|---|---|
| Missing CLIs / no history | Synthetic diagnostics tests: browsing remains possible; do not imply login readiness |
| Bad/custom directories and archived-only history | Synthetic metadata/parser tests: actionable hints, correct indexing, no credential paths |
| Demo / first-launch language choices | Tests plus demo UI check: no private reads, saves or model requests |
| Existing notes / legacy storage | Synthetic migration/corruption tests: preserve confirmed/edited text and original files |
| Summaries and advice | Tool-free/ephemeral arguments, bounded input, consent and cancellation tests; model calls remain opt-in |
| Advice follow-through / thread states | Persist feedback without rewriting advice; handled/dismissed progress and completed/paused threads are excluded; changed progress can return |
| Request controls | Shared-lock daily/automatic reservations, failed/cancelled attempts counted, explicit history scope, pause/cancel and zero-call cap; counts are CLI jobs, not provider billing |
| Backup / recovery | Validate before replacement, retain exact originals and importable safety backup when readable, preserve current settings/receipts, pause automation, roll back interrupted restoration |
| Weekly / monthly review | Bounded saved-note input, dated evidence IDs, explicit thread states not backdated, immutable versions, cancellation/save retry and bilingual multi-page PNG checks |
| CLI failures | Local stub processes simulate missing login, unsupported flags, authentication, usage and network failures; no real accounts/models |
| Packaging | Re-extracted ZIP and read-only mounted DMG: arm64, minimum macOS 14, intact signature and heuristic bundled-data privacy scan; separate SHA-256 and public metadata |
| Publish privacy | Heuristic working/staged/history checks; not proof of comprehensive security |

## Real-machine acceptance — pending until performed

- [ ] Download the final asset via a browser on a second/fresh Apple Silicon Mac; preserve quarantine, verify digest, drag to Applications and launch.
- [ ] Verify the advertised minimum OS on an actual macOS 14 machine (or explicitly narrow tested-version claims). Packaging an OS target is not runtime verification.
- [ ] No CLIs, no provider history: choose language, see empty states and diagnostics; no model call or surprise login.
- [ ] One provider only, both providers, custom home directories and denied folder access behave correctly.
- [ ] Unauthenticated/expired CLI, offline network, unavailable model and exhausted usage produce useful errors while old notes stay available. Never run real model tests without the tester's consent.
- [ ] Confirm CLI versions and actual selected/reported model using a tiny synthetic prompt. Do not send private history just to test readiness.
- [ ] Test English/Chinese layout, smaller display, long notes and multi-page PNG sharing with synthetic data. Review exported images before posting.
- [ ] Codex original-thread navigation opens the existing thread with no sent message; Claude experimental route either opens the original Code session or has a usable title-search fallback. No import or automatic command execution.
- [ ] Upgrade a synthetic prior-version journal and verify storage identity, notes and settings; preserve a backup before testing real data.
- [ ] Export/import a synthetic backup on a second Mac, inspect safety copies, and verify restored notes without source transcripts; keep plaintext private backups off public hosting.
- [ ] Review one synthetic real-model period report for accurate cross-day reconciliation/citations and no revival of superseded or completed work; confirm the selected model and CLI-job count with explicit consent.

## Public binary release gate

- [ ] Real Developer ID Application signature, Hardened Runtime, secure timestamp and successful Apple notarization.
- [ ] Tickets stapled/validated; `verify_artifact.sh ZIP --require-notarized` and `verify_dmg.sh DMG --require-notarized` succeed after re-download.
- [ ] Artifact metadata says `notarized: true`, clean source state and the exact reviewed tag's commit.
- [ ] Clean-Mac/browser download test passes without disabling Gatekeeper globally.
- [ ] Release asset filenames, checksums, metadata and signing statements all refer to the same build.
- [ ] Review the draft manually before publishing. Unsigned test artifacts remain unmistakably labeled Beta/unnotarized.

Intel/universal packages, automatic updates, App Store distribution and cloud sync are not requirements for the initial source Beta. Do not advertise them as supported.
