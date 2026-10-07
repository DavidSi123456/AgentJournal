# AgentJournal — Swift Windows prototype

This is an experimental source/developer build, **not a verified standalone
Windows installer**. The existing macOS app and its installation are unchanged.

## First-version scope

- Native desktop UI in Swift, using pinned SwiftCrossUI 0.10.0 / WinUIBackend.
- The existing Swift history reader, date grouping, prompt and model-response validation.
- Daily and cross-day thread views; Codex blue, Claude Code orange, purple branding.
- Synthetic demo on launch; reading actual histories requires an explicit click.
- Editable, locally saved notes; confirmation, stale-summary indicators and human-edit protection.
- Manual, consent-gated summaries through native Windows CLIs or standard npm/Node entry points.
- Independent Chinese/English interface and Chinese/English/automatic summary language.
- Durable call receipts, default 20 calls/day, atomic writes and conflicting-instance protection.

Not included yet: calendar grid, task-tree editor/history, advisor, weekly/monthly
review UI, PNG sharing, backup/restore UI, source-thread deep links, model-catalog
discovery, WSL invocation, standalone DLL packaging, signing and auto-update.
Shared task-tree/report/backup **logic** is compiled by the core; the Windows UI
for those features is not implemented. Core tests on macOS do not prove Windows compatibility.

## Windows developer prerequisites

1. Install Swift and Visual Studio C++/Windows SDK components using the
   [official Swift Windows guide](https://www.swift.org/install/windows/).
2. Use a Visual Studio developer PowerShell with `swift --version` working.
3. For the desktop UI, also follow the pinned backend's
   [WinUIBackend requirements](https://github.com/moreSwift/swift-cross-ui/blob/v0.10.0/Sources/SwiftCrossUI/SwiftCrossUI.docc/Backends/WinUIBackend.md).
   Its documentation specifies Windows SDK 10.0.17763 and a particular Windows
   App SDK runtime. These are additional prerequisites; this project does not
   silently install them. Runtime packaging/version compatibility still requires
   testing on an actual Windows machine.

From the repository root:

```powershell
# No GUI dependency, real conversations or model calls needed.
./scripts/build_windows.ps1 -CoreOnly

# Test the core, then compile the experimental desktop UI.
./scripts/build_windows.ps1
```

Run `AgentJournalWindows.exe` from the build output directory, not by copying the
exe alone. The script prints its path. The required Swift and WinUI runtimes must
be installed. Windows 10/11 x64 is the initial validation target; ARM64 is not yet
tested by this project's workflow.

The new **Windows Swift prototype (manual)** GitHub Actions workflow is deliberately
manual-only. It will become available only after these changes are pushed. Its
core tests use synthetic fixtures and its GUI step checks compilation, not a
successful desktop launch. No workflow has been run for this local prototype yet.

## Storage and safeguards

Windows data lives in `%LOCALAPPDATA%\AgentJournal\WindowsPrototype\`, separately
from the macOS app's `ThreadJournal` directory. Raw `.codex` / `.claude` transcripts
are read-only. The private index retains bounded excerpts; notes/settings do not
store full transcripts. Do not commit/share the storage directory or index.

Changing transcript roots or timezone creates a separate note namespace. The
prototype does **not** migrate notes between timezones; switching back restores
the original namespace. Filtering providers does not delete their existing notes.

The Windows lock uses an exclusive OS file handle and fails closed on contention;
macOS continues to use `flock`. Windows storage inherits the current user's
LocalAppData ACL, rather than applying Unix permissions. Summary invocation never
uses `cmd.exe` or PowerShell: `.exe` files run directly, known npm packages use
`node.exe` plus a script argument. Nonstandard npm prefixes can use a native CLI
override; `.cmd` and `.bat` overrides are rejected.

Generation does not happen on startup, refresh or navigation. An explicit consent
screen explains that bounded historical text is sent to the chosen CLI/model and
may consume quota. The same no-tools restrictions as the macOS app are passed to
the CLI; support depends on the installed CLI version and errors fail closed.
Windows process cancellation, login, pipe handling and child-process cleanup
still need real-machine acceptance testing before distribution.

## macOS development preview

The portable package has a separate staging manifest/cache identity on macOS;
a normal `swift build` still builds the existing native macOS app without
downloading SwiftCrossUI. Staged source copies are build artifacts only; the
canonical reader/model files remain shared with the macOS target.

```sh
zsh scripts/test_portable.sh
# Compile and open a demo-only preview; no real history reads/writes/model calls.
zsh scripts/preview_windows.sh
```

`AGENTJOURNAL_PROTOTYPE_DATA_DIR` optionally selects a separate prototype data
directory for synthetic QA. Do not set it to the main app's data folder.

## Verification status

Checked locally on macOS arm64 with Swift 6.1.2:

- All 16 portable checks passed, using synthetic data and fake summarizers.
- The existing native macOS release target compiled successfully; its English
  and Chinese suites each passed 87 tests (4 optional live tests skipped).
- The shared desktop UI compiled and opened as a demo-only macOS preview.
  Thread navigation, note editing/saving and interface-language switching were
  exercised through the actual UI.

The Windows-specific compiler branches, PowerShell script, WinUI launch and real
CLI integration have **not** been validated on Windows. No Windows executable or
installer has been produced on this Mac. The manual workflow is prepared for that
next validation step, not evidence that it has already passed.

---

# AgentJournal — Swift Windows 原型

这是开发测试原型，**不是已验证、可直接分发的 Windows 安装包**；现有 Mac
软件和启动台版本没有被替换。

第一版已有：启动演示、按天／按线程浏览 Codex 与 Claude Code、本地笔记编辑与
确认、中英文界面、独立的摘要语言设置、手动确认后调用 CLI 摘要，以及调用上限
和笔记保护。紫色整体、Codex 蓝色、Claude Code 橙色。

暂不包含月历网格、任务树界面、推进助手、周月报界面、图片分享、备份恢复界面、
原线程跳转、模型列表自动发现、WSL 模型调用、正式安装包和签名。

Windows 测试需要先安装 Swift、Visual Studio 所需组件；图形界面还需要上述
WinUIBackend 对应的 SDK／运行库。在仓库根目录的开发者 PowerShell 中运行：

```powershell
./scripts/build_windows.ps1 -CoreOnly  # 先测共享核心，不调用模型
./scripts/build_windows.ps1           # 再编译图形界面
```

数据独立保存在 `%LOCALAPPDATA%\AgentJournal\WindowsPrototype\`。首次显示的是
内置模拟数据；点击“读取本地记录”才扫描真实来源，点击生成并确认才使用模型。
原始聊天只读；原型索引会保存有限片段，不能作为公开分享材料。

切换目录或时区使用独立笔记空间，不会把原笔记错误附到另一天；切回原设置仍可
看到原笔记。手工编辑或确认的笔记不会被模型覆盖。第一版不是 Mac 数据迁移工具。

本地测试与 Mac 界面预览通过，也不能替代 Windows 实机验证。需要完成 Windows
编译／启动、CLI 登录与取消、中文输入、运行库打包等验证后，再发布正式 Windows 版。

当前验证结果：16 项共享核心测试通过；Mac 原有中英文测试各 87 项通过，4 项
可选在线测试跳过；Mac 发布目标重新编译通过。原型预览中的线程切换、笔记编辑／
保存和语言切换已实际点击验证。测试只用模拟数据，没有读取真实聊天或调用真实模型。
尚未在 Windows 上编译和运行，也没有生成可分发的 Windows exe／安装包。
