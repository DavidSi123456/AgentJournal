# Changelog

## 0.5.1 — built-in demo and guided onboarding (not yet tagged)

- Add a first-launch, bilingual highlighted walkthrough of the real interface using synthetic-only demo data. Choose app/content languages and Codex / Claude Code / both; completing or skipping the tour is not model consent. Reopen the tour or interactive demo from the help menu.
- Persist tour completion, preserve upgrade preferences and notes, and defer private scans/model jobs until first-run onboarding completes. Demo examples never enter the real journal or trigger model calls.
- Apply source selection at scan time, not only as a display filter; skip unselected transcript folders/desktop metadata while keeping previously indexed retained history available when re-enabled.
- Explain desktop-only/window-open behavior, local transcript coverage, Apple Silicon/macOS 14+ packaging and ad-hoc, non-notarized Beta limitations in onboarding and documentation. Add synthetic bilingual regressions and type-check the complete UI in the check runner.
- Add two portrait launch illustrations, a square Moments poster, copyable Chinese launch captions and a source-linked maintainer permissions/PR guide. Artwork is marked synthetic/illustrative; no private logs, public-download claims or GitHub permission changes are included.

## 0.5.0 — progress follow-through and period reviews (not yet tagged)

- Add persistent user-selected active/waiting/paused/completed thread states and append-only advice feedback. Completed/paused threads are excluded from analysis; handled/dismissed recommendations stay suppressed until their recorded progress changes. Daily confirmation still does not imply whole-thread completion.
- Give the advisor an independent model preference. Add a preview queue, automatic pause/stop, optional historical auto-fill, and shared persisted limits for local CLI generation jobs (default 20 total / 5 automatic per day). Failed/cancelled/started jobs count; these are not provider token, cost or account allowances.
- Add private JSON backup/import with validated notes, advice/evidence, states/feedback, request logs, period reports and excerpt-free thread metadata. Restoration keeps local source/model settings, turns auto-drafts off, retains existing request receipts, saves exact originals, and recovers an interrupted transaction before permitting writes/model jobs.
- Generate actual weekly/monthly/custom reviews from bounded saved notes: synthesized outcomes, ongoing work, explicit blockers and recorded next steps, with per-item evidence, missing/bounded coverage disclosure, immutable versions, Markdown and paginated PNG export. No raw transcripts are sent for period reviews and no missing drafts are generated implicitly.
- Protect new-version persistent writers with a shared file lock and reject stale daily-journal overwrites. Preserve invalid/newer state files and stop model jobs rather than resetting limits.
- Keep history whose transcripts were cleaned up when a timezone or exclusion change rebuilds the index (newly excluded projects are still dropped), including legacy v2 indexes without `sourceSignature`. Verify original roots or preserve unverifiable cache bytes with an explicit warning.
- Migrate timezone notes by message membership, not disappearing day IDs. Handle consecutive dates, retain per-timezone originals and pending migrations across restart/backup, avoid overwriting confirmed destination notes, and disclose ambiguous split/merged days.
- Move the oldest advice snapshots, period reviews and request receipts older than 30 days to an `Archive` folder once a live file passes 32 MiB, instead of blocking saves or model requests at the 64 MiB ceiling. Nothing is deleted; Data & requests shows archived counts.
- Include archives in version-2 portable backups (v1 imports remain supported) and history browsing; deduplicate repeated restores, retain local archives/receipt limits, and roll back newly imported archives after an interrupted restore. Invalid archives fail full export rather than producing a partial backup.
- Reduce background work: load/write the index off the main thread and skip unchanged writes. Changed scans persist immediately, so source cleanup followed by restart cannot discard the last five minutes. Keep the one-minute refresh from restarting on view updates and cache date formatters/advisor input fingerprints.
- Add drag-to-Applications DMG packaging, read-only verification, separate asset checksums/metadata, and fail-closed Developer ID / notarization options. Default artifacts remain clearly labeled ad-hoc Beta; no real certificate or Apple submission is implied.

## 0.4.2 — daily advice history (not yet tagged)

- Save progress-advisor results locally as dated snapshots, including original evidence, model, generation timezone and language setting. Preserve multiple analyses per day and revisit them after restarting without model calls.
- Add a daily history sidebar, same-day version menu, green calendar indicators and a coordinated green/teal advisor accent. Codex stays blue, Claude Code stays orange, and the main journal stays purple.
- Label historical/stale advice and unsaved results clearly. New analyses always use current progress; missing past-day advice is not backfilled. Retain advice even if its source thread is no longer indexed.
- Keep advice separate from daily notes for downgrade safety, validate snapshots on load, and preserve corrupt/incompatible files. Save retry does not call a model. Cancelled/failed analyses do not append history; archive limits never prune older advice.
- Add bilingual regression checks for persistence, multiple versions, timezone boundaries, invalid archives, unsafe paths and save retries; demo histories never read private records, write files or call models.

## 0.4.1 — release preparation (not yet tagged)

- Add bilingual, local-only environment checks to first launch and Settings. Missing CLIs do not prevent browsing; detected executables do not imply valid login or model access.
- Make Settings scrollable on smaller displays and clarify model consent on first launch.
- Explicitly package Apple Silicon/macOS 14+ test builds with versioned filenames, SHA-256 checksums and non-personal source/signing metadata.
- Re-extract and verify packaged app signatures, and scan bundled bytes for common privacy hazards. Omit debug info and remap source paths in packaged builds. Add explicit, fail-closed Developer ID signing and Keychain-backed notarization options; neither runs by default.
- Fix provider-formatted failure diagnostics remaining Chinese after switching to English.
- Add a privacy guard for publish candidates, exact staged blobs and reachable Git history, with synthetic self-tests and no matched-value output.
- Add CI privacy checks, a manually dispatched unsigned Beta draft workflow, issue-report privacy guidance and a release acceptance checklist.
- Make CLI diagnostic tests independent of system language, verify simulated failures in both app languages, and run CI checks under English and Chinese system defaults. Flush per-test progress for useful failure logs and update GitHub Actions to Node.js 24-compatible versions.

This builds on the local 0.4.0 preview: a progress-only thread advisor, dated evidence/confidence, original Codex-thread links, and experimental Claude Desktop Code session mapping/navigation. No planner deadlines or importance are used. These features are not autonomous execution.

Signing credentials, Apple notarization, a tagged Release and clean-Mac acceptance remain separate release steps. No such completion is implied by this changelog.
