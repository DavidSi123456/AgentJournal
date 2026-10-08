# Local release-preparation verification

## macOS first-summary workflow — 2026-10-08

Candidate: **0.6.2, build 13**, Apple Silicon/macOS 15.7.9. Only macOS UI/store, macOS tests, version metadata and documentation changed; Windows and portable core are unchanged.

- English and Chinese system-default test processes each passed **93 checks**, with **4 optional live checks skipped**. Six new synthetic regressions cover zero-summary request prevention, manual-note freshness, the 40-thread candidate bound, preparation scope/budgets/protected notes, cancellation phases and bilingual consent.
- Native, isolated synthetic UI checks verified opaque welcome/read-consent pages and the one-entry manual-edit/save/return path. With no notes, task trees and period reviews show preparation actions and advice is disabled. Saving the first unconfirmed manual note unlocks advice and task-tree drafting with current evidence; the account/model consent dialog was inspected and cancelled. No real models or personal journals were used.
- Release ZIP and read-only mounted DMG passed layout, arm64/minimum-macOS-14, strict ad-hoc signature and bundled privacy checks; SHA-256 sidecars verified. These checks are not Apple notarization or broad machine/OS acceptance.
- Parent/fork metadata integration remains pending. Same-name or numbered threads are not merged by inference.

## External installation report — 2026-10-08

The maintainer reported that AgentJournal was successfully installed and used on another person's Mac. This records the maintainer's report, not an independently observed test. The tested app version/digest, macOS version, architecture, download method/quarantine state and exact feature coverage were not supplied. Do not attribute this report specifically to 0.6.2 or mark the complete fresh-Mac acceptance checklist as passed. Developer ID signing and Apple notarization remain unverified.

项目维护者反馈：AgentJournal 已在另一位用户的 Mac 上成功安装并使用。这里只记录维护者反馈，非独立现场验收；具体版本／校验值、系统版本、芯片、下载及隔离属性、功能测试范围未提供，不能据此宣称 0.6.2 已完成全新 Mac 全流程验收，也不代表苹果签名或公证已通过。

## Original preparation snapshot

Date: 2026-10-01. Environment: Apple Silicon, macOS 15.7.9. Candidate: 0.4.1, build 6, local working tree (not a clean tagged release).

- `zsh scripts/test.sh`: **36 passed, 4 opt-in live checks skipped**. The CLI-failure test launches synthetic local stubs only; no real model/account request is needed.
- Privacy guard: **14 rule checks and 13 end-to-end checks passed**. End-to-end tests cover staged/working isolation, retained historical secret-shaped fixtures, ignored versus force-added private files, symlinks and bundled artifact bytes. Temporary repositories contain synthetic data only and are removed afterward.
- Working publish candidates and 22 locally reachable historical blobs: no configured heuristic matched. This is not a full audit and does not cover unfetched remote refs, sensitive prose or screenshot contents. The exact staged check still belongs to the eventual staging/commit step; this run did not stage source.
- Release build succeeded. The re-extracted ZIP passed plist/arm64/minimum-OS/signature checks and its four bundled files passed the privacy guard. The matching SHA-256 sidecar verified successfully. Metadata explicitly says `adhoc`, `notarized: false` and `source_dirty: true`.
- Missing signing configuration and missing notarization configuration both failed before building/uploading. Requiring notarization for the ad-hoc ZIP correctly failed the Developer ID requirement; no Apple submission was made.
- Synthetic demo UI: English Settings/environment check, first-launch language selection, switching to Chinese, Chinese environment check and continuing into the Chinese interface were visually checked. No screenshot was added to the public repository.
- PlanDesk's release build passed with the updated shared library. This was a compilation check only; no PlanDesk app was installed or launched.
- Workflow/issue YAML and workflow/packaging shell syntax were checked locally. GitHub Actions and Release publication were **not** run remotely.

Pending at that snapshot: Developer ID credentials and the successful signed/notarized path; browser-download installation on a second/fresh Mac; actual macOS 14 runtime acceptance; real-client/CLI compatibility checks on those machines; source staging/commit/tag/push and remote CI. See [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md). No current installed app was replaced during this preparation.

## CI language regression follow-up — 2026-10-01

- Source was published in `1aab570`. Its [first CI run](https://github.com/DavidSi123456/AgentJournal/actions/runs/36827113351) passed privacy, shell-syntax and fail-closed signing checks, then failed at `DiagnosticsTests.swift:82`. Build/upload steps were skipped, not verified.
- The simulated CLI-failure test expected Chinese text while inheriting the system's default interface language. Launching it locally with English `AppleLanguages` reproduced the same assertion/exit code 133. The offline fallback had correctly returned an English diagnostic.
- The corrected test explicitly exercises both interface languages and checks the same translated diagnostic that the UI displays. Legacy compatibility fixtures still keep their intentionally unset language preference.
- `zsh scripts/test.sh --all-locales` passed locally: **36 passed and 4 opt-in checks skipped in each language**. It compiles once, then launches separate English and Chinese processes and asserts their effective system language. No persistent system preferences, real accounts, model requests or user journals are used.
- CI and the optional Beta draft workflow use this two-language check. Per-test progress is unbuffered, and checkout/upload actions use Node.js 24-compatible versions. No installed app was replaced; application source behavior is unchanged by this fix.

Follow-up remote results are recorded in [GitHub Actions](https://github.com/DavidSi123456/AgentJournal/actions); local success alone is not proof of a successful remote build or binary acceptance. Developer ID/notarization, clean-Mac/macOS 14 acceptance and a tagged public Release remain separate steps.

## Daily advice history — 2026-10-01

Local candidate: **0.4.2, build 7**, Apple Silicon/macOS 15.7.9, uncommitted working tree.

- `zsh scripts/test.sh --all-locales`: **42 passed, 4 opt-in live checks skipped in each language**. New coverage includes restart persistence, multiple days and same-day runs, original evidence/model/language/timezone, stale-writer retention, corrupted/future/invalid archives, symlinks, directories, oversized files, cancellation and save retry without another model call. Fixtures are synthetic and do not use personal journals or real model accounts.
- Release build and re-extracted ZIP verification passed: arm64, minimum macOS 14, strict ad-hoc signature and bundled privacy heuristics. This does not verify notarization, Gatekeeper acceptance or clean-Mac installation.
- Synthetic English UI checked daily history, selecting yesterday's advice, expanding its dated evidence and retaining two analyses on the same day. Green/teal advisor accents and green main-calendar indicators were visually checked; Codex and Claude source colors remain blue/orange.
- Final UI checks confirmed earlier/newer version buttons switch between the two same-day snapshots. PlanDesk's release compilation with the updated shared library also passed; its installed app was not replaced or launched.
- GUI initialization from a restricted command environment aborted in macOS `_RegisterApplication` before the advisor UI. The same build launched successfully with ordinary desktop permissions. GUI smoke checks must use explicit demo arguments; do not re-query a terminated app path with a tool that may relaunch it without those arguments.
- No installed app was replaced or personal preferences deliberately changed for this verification. No GitHub push, new remote CI run, tag or Release was performed for this feature.

Advice storage is independent of daily notes; old memory-only results are not recoverable. Developer ID/notarization and macOS 14/clean-Mac runtime acceptance remain pending.

## Follow-through, controls, recovery and period reviews — 2026-10-02–03

Local candidate: **0.5.0, build 8**, Apple Silicon/macOS 15.7.9, uncommitted working tree. This is a local Beta candidate, not a tagged reproducible release.

- `zsh scripts/test.sh --all-locales`: **57 passed, 4 opt-in live checks skipped in each language**. Fifteen new tests cover feedback/thread states and changed progress; independent advice-model preferences; shared-instance/concurrent daily reservations; failed/cancelled attempts and day rollover; zero-call limits and automatic scope/pause; stale journal writers; evidence/date/size/state validation and cancellation/persistence of period reports; bilingual multi-page PNG rendering; backup round trips, corrupt-state recovery, importable pre-restore safety copies and interrupted-restore rollback. Fixtures are synthetic; no personal journals or real model calls were used.
- Feedback is retained separately from immutable advice snapshots. Demo UI verified that marking one thread completed and a second thread's suggestion handled reduces a new analysis from three candidates to one without deleting daily notes/history. Waiting advice does not authorize advancing a thread. Fingerprint tests retain handled/dismissed decisions for the matching progress while allowing genuinely changed progress to return.
- Synthetic English UI checked the thread-state picker, green/teal feedback controls, request/backup tabs, saved weekly review and expandable dated evidence. Final report header layout was checked after repairing overlapping/wrapped English controls. The preview was a temporary copy with a separate bundle ID and an explicit demo-only plist flag, so tool relaunches could not load real journal data; the preview was quit afterward. Shipping bundles do not contain that flag. No public screenshot was added.
- Restore tests validate all components before replacement, retain exact originals, keep current settings and already-recorded CLI jobs, turn auto-drafts off, and recover an interrupted transaction before models/writes resume. Readable originals also produce an importable `AgentJournal-PreRestore.json`. Backups are plaintext private files, not transcript exports or credential-file backups; user-written notes/settings may still contain sensitive content.
- Period-review tests reject nonexistent evidence IDs, invalid dates, next steps without saved evidence and completed/paused-thread next steps. Explicit user states set after a period end are not backdated. Reports are synthesized model drafts; citation validation does not prove semantic correctness, and the real-provider report path remains opt-in/unexercised.
- Privacy guard: **14 rule checks and 13 end-to-end checks passed**; **50 working publish candidates and 75 locally reachable historical blobs** had no configured heuristic matches. ZIP and mounted DMG app contents also passed bundled-data heuristics. This does not replace manual sensitive-prose/image review or exact staging-time checks.
- Release build, re-extracted ZIP and read-only mounted DMG passed arm64/minimum-macOS-14/layout/intact-ad-hoc-signature checks. DMG verification did not launch an app and detached its temporary mount. Matching SHA-256 sidecars and distinct ZIP/DMG metadata verified; both say `adhoc`, `notarized: false`, `source_dirty: true`.
- Final ZIP SHA-256: `c3662c83ff124d54025455f4a0bda0a6685c8521a05c415ac23dc22ae2f066db`. Final DMG SHA-256: `f5287eeb2596ac534eb13d633264b310452288ea92198f3ba4514f8172c070bc`.
- Both app/DMG builders reject missing signing or notarization configuration before building/uploading. The ad-hoc ZIP correctly fails `--require-notarized`. No usable Developer ID Application identity was available; no Apple submission, signing-key creation, payment or credential configuration was performed. Local DMG creation/mounting needed ordinary desktop permissions; a restricted sandbox refused those disk-image services.
- Workflow YAML, packaging shell syntax and `git diff --check` passed locally. CI now includes ZIP/DMG verification and uploads separate sidecars; GitHub Actions/Release publication were not run remotely for this candidate.
- PlanDesk's final release compilation with the updated shared library passed. A default command first failed on the sandbox-denied user module-cache path; rerunning with writable temporary Swift/Clang caches and scratch directory succeeded. No PlanDesk source was edited and its installed app was not replaced or launched.

Installed AgentJournal remains **0.4.2**. No installed app replacement, personal-journal migration, source staging/commit/push, tag, repository-visibility change or Release publication was performed in this turn. Developer ID/notarization, browser-download/quarantine acceptance on a fresh Mac, macOS 14 runtime acceptance and consented real-CLI report validation remain pending; see [RELEASING.md](RELEASING.md) and [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md).

## Built-in demo, onboarding and launch materials — 2026-10-04

Local candidate: **0.5.1, build 9**, Apple Silicon/macOS 15.7.9, uncommitted working tree based on `383461e`. Not a tagged release.

- `zsh scripts/test.sh --all-locales`: **70 passed, 4 opt-in checks skipped in each language**, after compiling the complete UI. New synthetic coverage verifies that unselected providers are not scanned, retained indexed history survives re-enabling a provider, first-run onboarding blocks private scans and all three model-generation paths, and upgrades preserve notes/model/language/explicit opt-in settings. No live account/model checks were requested.
- Native synthetic preview checked the welcome language/source pickers, Chinese calendar highlighting, English welcome/completion layout and all ten navigation steps. Fixed a stale right-side selection when replacing the demo store; the rebuilt preview verified that selecting Claude Code only updates the calendar, daily list and timeline to Claude examples. The preview used a separate bundle ID and a forced demo-only plist flag, not the installed app or real data. Both temporary preview processes were quit via their own menus afterward.
- The rebuilt versioned ZIP passed arm64/macOS-14 minimum/intact ad-hoc signature checks and the artifact privacy scan. A 0.5.1 DMG, Developer ID signing, notarization, Gatekeeper approval, fresh-Mac installation and macOS 14 runtime acceptance were not verified in this turn. The shipping bundle does not contain the temporary demo-only flag.
- Built-in imagegen created two 1024×1536 portrait posters and one 1254×1254 square poster using the synthetic preview as structure reference. Manual review checked primary Chinese copy, purple/blue/orange/green mapping, synthetic/illustrative labels and platform/window-open footers; the images are not exact application screenshots. Saved final prompts and captions explain model allowance, private repository availability and Beta limitations.
- Working privacy heuristics passed for **57 publish candidates**; manual illustration/caption review and `git diff --check` also passed. Historical/staged scanning belongs to a later explicit publication step; no source was staged or committed here.
- Read-only repository metadata confirmed a personal-account private repository on main. Official GitHub documentation was checked for personal collaborator write access, organization roles, ruleset plan availability and PR/fork workflow controls. No GitHub permission, visibility, invite, ruleset, PR, push, tag or Release change was performed.

The installed/Launchpad app was not replaced. Promotional posts were not published. Real-provider onboarding/summary/report use remains opt-in; user-created notes and backups still require their own sensitive-data review before sharing.
