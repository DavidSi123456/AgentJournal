# AgentJournal 0.5.0 Beta

A native, bilingual macOS journal for local Codex and Claude Code history: daily notes, thread timelines, progress follow-through, bounded optional model drafts, real weekly/monthly reviews and local sharing.

## Download requirements

- Apple Silicon (arm64), macOS 14+. Intel/universal and other platforms are not included.
- This draft's `adhoc` ZIP and drag-to-Applications DMG are **unsigned developer test builds**: they have an app integrity signature, but no Developer ID identity or Apple notarization. Gatekeeper may block them. Do not disable Gatekeeper globally; experienced testers can build from reviewed source, or wait for a notarized download.
- A CLI is not needed to browse local history. Model features require an installed/authenticated Codex or Claude Code CLI and separate consent; they consume provider/account usage.

## Changes

- Saved thread lifecycle states and advice feedback; no repeated handled/dismissed advice until progress changes. Paused/completed threads are excluded from analysis without hiding daily notes.
- Independent advisor model, preview queue, immediate auto-draft pause, optional historical fill, and persisted daily limits for local CLI generation jobs. Counts are not provider billing or account usage.
- Private backup/restore with original-file safety copies, validation, conservative request-receipt retention and interrupted-restore recovery. Current local settings remain unchanged and automatic drafts turn off.
- Synthesized weekly/monthly/custom reports with expandable evidence, bounded/missing coverage disclosure, saved versions, Markdown and paginated PNG export.
- ZIP and DMG verification, checksums and matching non-personal metadata. Developer ID signing/notarization remain explicit, fail-closed opt-ins.

- Progress-only advisor with dated evidence, explicit review/waiting states and manual navigation. It never sends thread messages or executes next steps.
- Codex original-thread links and experimental Claude Desktop Code mapping/navigation, with title-search fallback.
- First-launch and Settings environment checks without model calls, credential reads or network requests.
- Versioned packages, SHA-256 checksums, source/signing metadata and release/privacy checks.

## Limitations and privacy

Only locally available transcripts are indexed; metadata alone cannot recover cloud-only conversations. Claude Desktop navigation uses an undocumented route observed in Desktop 2.16120.0 and may stop working. CLI formats/flags are version-sensitive. The deployment target is not a full OS compatibility guarantee.

Browsing/indexing and image rendering stay local. After consent, summaries send bounded conversation excerpts, and advice sends bounded saved titles/notes/next steps to the selected CLI's configured model provider. Model judgments can be wrong. Review notes and previews before sharing. Use synthetic/demo material in public bug reports; never attach real transcripts, journals, credentials or personal screenshots.

Release acceptance, including a fresh-Mac download/install and signed/notarized distribution, must be reviewed before publishing this draft. See `docs/RELEASE_CHECKLIST.md` and `CHANGELOG.md` in the source.
