import Foundation

enum JournalInterfaceLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh", english = "en"
    var id: String { rawValue }
    var nativeName: String { self == .chinese ? "简体中文" : "English" }
    var locale: Locale { Locale(identifier: self == .chinese ? "zh_CN" : "en_US") }
    static var systemDefault: Self {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .chinese : .english
    }
}

enum JournalSummaryLanguage: String, CaseIterable, Identifiable {
    case chinese = "zh", english = "en", automatic = "auto"
    var id: String { rawValue }
    func label(_ language: JournalInterfaceLanguage) -> String {
        switch self {
        case .chinese: return "简体中文"
        case .english: return "English"
        case .automatic: return JournalText(language)("跟随讨论内容")
        }
    }
    func instruction(fallback: JournalInterfaceLanguage) -> String {
        switch self {
        case .chinese: return "Write every summary and nextStep in Simplified Chinese."
        case .english: return "Write every summary and nextStep in English."
        case .automatic:
            return """
            For each entry independently, choose Simplified Chinese or English based on the dominant natural language of the user's discussion in that entry. Prioritize human user messages, not code, tool output, quotations, or the language of these instructions. For mixed discussions use the predominant user language; if genuinely ambiguous, use \(fallback == .chinese ? "Simplified Chinese" : "English"). Write summary and nextStep in that chosen language. Different entries may use different languages.
            """
        }
    }
}

enum JournalDateStyle { case month, shortDay, dayWithWeekday, fullDay, calendarDay }

struct JournalWeekday: Identifiable {
    let id: String
    let label: String
}

/// Stable Chinese data values are retained; only app-owned display text is translated.
/// User notes, titles, model identifiers and transcript excerpts never pass through this table.
struct JournalText {
    let language: JournalInterfaceLanguage
    init(_ language: JournalInterfaceLanguage) { self.language = language }
    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let format = language == .english ? Self.english[key] ?? key : key
        return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
    }
    func category(_ value: String) -> String { self(value) }
    func date(_ date: Date, clock: JournalClock, style: JournalDateStyle) -> String {
        let format: String
        switch style {
        case .month: format = language == .chinese ? "yyyy年 M月" : "MMMM yyyy"
        case .shortDay: format = language == .chinese ? "M月d日 EEE" : "MMM d, EEE"
        case .dayWithWeekday: format = language == .chinese ? "M月d日，EEEE" : "EEEE, MMMM d"
        case .fullDay: format = language == .chinese ? "yyyy年 M月d日 EEEE" : "EEEE, MMM d, yyyy"
        case .calendarDay: format = language == .chinese ? "M月d日" : "MMM d"
        }
        return clock.label(date, format, locale: language.locale)
    }
    var weekdays: [String] {
        language == .chinese ? ["一", "二", "三", "四", "五", "六", "日"] : ["M", "T", "W", "T", "F", "S", "S"]
    }
    var weekdayItems: [JournalWeekday] {
        // Weekday labels repeat in English; IDs must also not collide with day-cell Int IDs.
        weekdays.enumerated().map { JournalWeekday(id: "weekday-\($0.offset)", label: $0.element) }
    }
    // Also translate already-created app diagnostics after an immediate UI-language change.
    // This is deliberately used only for diagnostics/metadata, never for user content.
    func message(_ value: String) -> String {
        guard language == .english else { return value }
        if let translated = Self.english[value] { return translated }
        // These diagnostics contain an already-formatted provider name. Match
        // only known app-owned templates; never reinterpret arbitrary notes.
        for provider in JournalProvider.allCases {
            for template in ["%@ 摘要失败或超时，请检查 CLI 版本、登录和网络。",
                             "未找到 %@ CLI。请安装并登录，或在设置中切换摘要引擎。",
                             "%@ 目录无法读取，请检查权限。"] {
                if value == String(format: template, provider.label) { return self(template, provider.label) }
            }
        }
        var result = value
        for key in Self.english.keys.filter({ !$0.contains("%") }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: key, with: Self.english[key]!)
        }
        return result
    }

    static let english = legacyEnglish.merging(workflowEnglish) { _, latest in latest }
        .merging(onboardingEnglish) { _, latest in latest }
        .merging(progressEnglish) { _, latest in latest }
    private static let progressEnglish: [String: String] = [
        "固定目标": "Fixed goal", "开放式研究": "Open-ended research", "未开始": "Not started",
        "待确认完成": "Completion to confirm", "受阻": "Blocked", "已确认完成": "Confirmed complete",
        "模型草拟": "Model draft", "人工修改": "Manual edit", "记录今日快照": "Save today's snapshot",
        "恢复历史版本": "Historical version restored", "任务树草拟": "Task tree draft",
        "任务树格式无效，已有记录未修改。": "Invalid task tree. Existing records were not changed.",
        "任务树不能循环嵌套，最多支持五层。": "Task trees cannot contain cycles and support up to five levels.",
        "任务树历史版本不兼容或格式无效，原文件已保留。": "Unsupported or invalid task history. Original file retained.",
        "任务树已由另一个窗口或实例修改，请重新加载后再保存。": "Another window or instance changed this tree. Reload before saving.",
        "模型任务树缺少有效依据或试图直接确认完成，本次未保存。": "The model tree lacks valid evidence or tries to confirm completion. Nothing saved.",
        "模型返回的任务树字段不完整，本次未保存；可重试或手动建立。": "The model returned incomplete tree fields. Nothing saved; retry or create tasks manually.",
        "模型返回空任务树、重复编号或超过 80 项，本次未保存；可重试或手动建立。": "The model returned an empty tree, duplicate IDs or over 80 tasks. Nothing saved; retry or create tasks manually.",
        "模型遗漏了已有任务，本次未保存；已有任务与历史未修改。": "The model omitted existing tasks. Nothing saved; existing tasks and history are unchanged.",
        "模型引用了不存在的上级任务，本次未保存；可重试或手动调整层级。": "The model referenced a nonexistent parent task. Nothing saved; retry or edit the hierarchy manually.",
        "模型任务未附摘要依据或依据超过 8 条，本次未保存；可重试或手动建立。": "A model task has no summary evidence or over 8 references. Nothing saved; retry or create tasks manually.",
        "模型引用的摘要编号不在本次输入中，本次未保存；可重试或手动建立。": "A summary reference is not in this input. Nothing saved; retry or create tasks manually.",
        "模型的完成提议已改为待人工确认，不计入完成进度。": "Model completion proposals now require human confirmation and do not count as completed progress.",
        "部分完成提议仅引用过期摘要，已保守标为进行中，请核实后人工确认。": "Some completion proposals cite only outdated notes. They remain in progress; verify before confirming them.",
        "正在读取线程记录，读取完成后可编辑任务树。": "Reading thread records. The tree can be edited after scanning finishes.",
        "正在生成任务树，完成或停止后可编辑。": "Drafting the task tree. Edit after generation finishes or is stopped.",
        "后台正在生成每日摘要；手动编辑仍可用，自动草拟需等待或停止后台生成。": "Daily summaries are being generated. Manual editing is available; wait or stop the background job to draft a tree.",
        "后台正在生成推进建议；手动编辑仍可用，自动草拟需等待或停止后台生成。": "Advice is being generated. Manual editing is available; wait or stop the background job to draft a tree.",
        "后台正在生成回顾报告；手动编辑仍可用，自动草拟需等待或停止后台生成。": "A report is being generated. Manual editing is available; wait or stop the background job to draft a tree.",
        "停止后台生成": "Stop background generation",
        "梳理目标与已有成果": "Review the goal and existing outcomes", "推进已记录的下一步": "Advance the recorded next step",
        "方案与证据整理": "Planning and evidence review",
        "任务树历史读取失败，原文件已保留；请从完整备份恢复。": "Task history could not be read. Original retained; recover from a full backup.",
        "任务树暂时不能保存，请检查存储或等待读取结束。": "Cannot save the tree now. Check storage or wait for scanning to finish.",
        "先保存至少一条每日摘要，或手动建立任务树。": "Save at least one daily summary first, or create the tree manually.",
        "生成期间摘要已变化，本次任务树未保存，请重新生成。": "Notes changed during generation. Tree not saved; generate again.",
        "已确认完成 %d / %d 项": "%d / %d tasks confirmed complete", "范围待确认": "Scope to confirm",
        "仅统计末级子项；不是时间、工作量或成功概率。": "Counts leaf tasks only; not time, workload or probability of success.",
        "阶段未设置": "Stage not set", "开放式研究展示阶段，不计算总体百分比。": "Open-ended research shows stages, not an overall percentage.",
        "%d 项待确认完成": "%d completions to confirm", "线程任务树": "Thread task tree",
        "使用摘要模型：%@ · %@": "Summary model: %@ · %@", "自动草拟任务树": "Draft task tree", "更新模型草稿": "Update model draft",
        "仅点击生成时调用模型。完成项必须人工确认；模型不会覆盖人工修改的节点，也不会执行原线程。": "Model requests run only when you click Generate. Completion needs human confirmation; edited nodes are protected and the original thread is never acted on.",
        "任务树": "Task tree", "每日历史": "Daily history",
        "有未保存修改，保存后才计入线程进度。": "Unsaved changes count toward thread progress only after saving.",
        "修改会保存为今天的新版本；浏览历史不调用模型。": "Changes are saved as today's new version. Browsing history makes no model requests.",
        "重新加载": "Reload", "允许草拟线程任务树？": "Allow task tree generation?",
        "仅将这个线程的标题、现有任务树、最多 60 条已保存每日摘要与下一步交给 %@ CLI 的模型提供方并消耗额度。不发送原始聊天摘录；任务树及摘要仍可能含私人信息。": "Only this thread's title, existing tree and up to 60 saved daily summaries and next steps go to the model provider configured by the %@ CLI, consuming quota. No raw chat excerpts; trees and notes may still contain private information.",
        "放弃未保存修改？": "Discard unsaved changes?", "放弃修改": "Discard changes",
        "重新加载会放弃未保存修改，继续？": "Reload and discard unsaved changes?",
        "删除这项及所有子项？": "Delete this task and all its children?",
        "保存后改变目标范围；此前的任务树仍保留在每日历史中。": "Saving changes the goal scope. Earlier trees remain in daily history.",
        "恢复这个历史版本？": "Restore this historical version?",
        "会保存为今天的新版本，不会删除已有历史或调用模型。": "Saved as today's new version. No history is deleted and no model is called.",
        "任务树已有新版本，请先保存或重新加载。": "A new tree version is available. Save or reload first.",
        "线程目标": "Thread goal", "目标类型": "Goal type", "当前阶段": "Current stage",
        "确认这棵树代表当前目标范围": "Confirm this tree represents the current goal scope",
        "新增、删除、改名或调整层级后需重新确认范围。百分比仅反映已确认完成的子项数。": "Adding, removing, renaming or reparenting tasks requires renewed scope confirmation. Percentages count confirmed leaf tasks only.",
        "任务与子项": "Tasks & subtasks", "新增任务": "Add task",
        "可自动草拟，也可手动建立。没有已保存摘要时，不会凭聊天数量推算进度。": "Draft automatically or create manually. Without saved notes, progress is not guessed from chat counts.",
        "依据覆盖：共 %d 天记录 · 提供 %d 条摘要 · %d 天缺摘要 · %d 条已过时": "Coverage: %d recorded days · %d notes supplied · %d days without notes · %d outdated notes",
        "历史较长时使用最早 8 条和最新 52 条摘要，文字可能截断；不代表掌握完整对话或全部工作。": "Long histories use the earliest 8 and latest 52 notes, with bounded text. This does not cover the full conversation or all work.",
        "摘要有变化，可更新任务树；现有确认与历史不会自动改变。": "Notes changed; you can update the tree. Existing confirmations and history do not change automatically.",
        "父项不计入百分比": "Parent tasks are not counted", "确认完成": "Confirm complete", "新增子项": "Add subtask",
        "人工修改已保护": "Manual edit protected", "查看依据（%d 条）": "View evidence (%d notes)",
        "生成时有效": "Current at generation", "生成时已过时": "Outdated at generation", "恢复为当前版本": "Restore as current version",
        "尚无历史。保存修改或生成草稿后，会记录当天的版本。": "No history yet. Saving or generating a draft records a version for that day.",
        "编辑任务项": "Edit task", "任务名称": "Task name", "上级任务": "Parent task", "顶级任务": "Top-level task",
        "说明": "Description", "模型未报告": "Model not reported",
        "任务状态": "Task status", "选择已确认完成属于人工确认；保存主界面修改后才计入进度。": "Selecting Confirmed complete is a human confirmation. It counts only after saving the main editor.",
        "应用修改": "Apply changes", "任务树与每日进度": "Task tree & daily progress",
        "将替换现有日志、建议历史、线程状态与任务树历史，并自动保留恢复前原文件。旧备份不含任务树时保留本机任务树。保留当前来源目录与设置，关闭自动草稿；不会调用模型。": "Replaces notes, advice, thread states and task history, retaining original files. Legacy backups preserve local task trees. Keeps current source paths and settings, disables automatic drafts and makes no model requests.",
        "备份包含人工记录、线程状态、任务树与每日历史、建议与反馈、调用记录、周报／月报，以及线程标题和日期。不包含原始对话摘录、CLI 凭据文件或账号配置。": "Includes notes, thread states, task trees and daily history, advice and feedback, requests, reports, titles and dates. Excludes raw chat excerpts, CLI credentials and account configuration."
    ]
    private static let onboardingEnglish: [String: String] = [
        "两者都有": "Both tools", "仅 Codex": "Codex only", "仅 Claude Code": "Claude Code only",
        "读取哪些来源": "Sources to read", "你使用哪些工具？": "Which tools do you use?",
        "新手指引": "Getting started", "体验演示": "Explore the demo", "新手指引与安全演示": "Getting started & safe demo",
        "跳过指引": "Skip tour", "退出指引": "Exit tour", "上一步": "Back", "下一步": "Next",
        "开始使用": "Start using AgentJournal", "准备好了": "You're ready",
        "第 %d / %d 步": "Step %d of %d", "返回自己的日志": "Back to my journal",
        "仅合成示例 · 不调用模型 · 不写入真实日志": "Synthetic examples only · No model calls · No writes to your journal",
        "先看演示，再开始自己的日志": "Explore a demo, then start your own journal",
        "日历：今天都处理了什么？": "Calendar: what did you work on today?",
        "每日记录：把讨论变成可回看的进展": "Daily notes: turn discussions into reviewable progress",
        "线程时间线：同一个问题，连续看几天": "Thread timeline: one problem across several days",
        "模型选择：读取来源和总结模型分开选": "Models: choose sources and summarizers independently",
        "推进助手：下一步推进哪个线程？": "Progress advisor: which thread should move forward?",
        "分享图片：挑一段时间，展示自己的进展": "Share cards: show progress over a date range",
        "周报／月报：从记录提炼阶段成果": "Weekly & monthly reviews: connect your saved progress",
        "数据与设置：额度、隐私和历史都由你掌控": "Data & settings: control requests, privacy and history",
        "准备好了，开始自己的 AgentJournal": "You're ready to start your own AgentJournal",
        "先选择语言和本机记录来源。后面的高亮指引使用合成示例，不读取私人日志、不调用模型，也不会混入你的真实记录。": "Choose your languages and local sources first. The highlighted tour uses synthetic examples: no private logs, model calls, or additions to your real journal.",
        "点击日期，查看当天的线程。蓝点代表 Codex，橙点代表 Claude Code，绿点代表已保存的推进建议。可以切换月份，也可以从有记录的日子快速回看。": "Select a date to see that day's threads. Blue dots are Codex, orange dots are Claude Code, and green dots are saved advice. Switch months or jump to a day with records.",
        "中间列按天整理线程。摘要先作为草稿，你可以修改分类、下一步，再确认。确认笔记不会把整个线程标记为完成，也不会修改原会话。": "The middle column groups threads by day. Summaries are drafts: edit the category and next step, then confirm. Confirming a note does not complete the entire thread or change its original conversation.",
        "选中线程后，右侧串起它在不同日期的记录。可以编辑笔记、设置线程状态；回到原线程是定位现有会话，不会自动发消息，Claude 桌面跳转仍是实验性功能。": "Select a thread to connect its notes across days on the right. Edit notes and set thread states. Returning to a thread locates an existing conversation without sending a message; Claude Desktop navigation remains experimental.",
        "这里选择生成摘要的 CLI 和模型，不是原线程的模型。可以用 Codex 总结 CC，也可以反过来。真实生成需要对应 CLI 安装、登录和可用额度；允许前会说明发送少量摘录。": "Choose the summarizing CLI and model, independently of the original thread's model. Codex can summarize CC, or vice versa. Real generation needs the corresponding CLI, login and allowance; permission explains the small excerpts sent.",
        "绿色入口只根据已记录的线程进展建议下一步，不读取日程的 DDL 或重要度。建议按日期和版本保留，可标记已处理、等待或不采纳；它不会替你执行任务。": "The green advisor suggests next steps using recorded thread progress, not calendar deadlines or priority. Advice retains dates and versions, with handled, waiting or dismissed feedback. It does not execute tasks for you.",
        "选择日期范围，生成可保存的 PNG 进展卡片，也能导出 Markdown。不会自动上传到任何平台；示例不含私人对话，真实分享前仍需检查敏感内容。": "Choose a date range for saved PNG progress cards or Markdown exports. Nothing is uploaded automatically. Demo examples have no private conversations; check real exports for sensitive content before sharing.",
        "把已保存的笔记汇总成周报、月报或自定义期间回顾，保留依据和多个版本。它不会补造缺失成果；生成需要模型额度，浏览与导出历史不需要。": "Synthesize saved notes into weekly, monthly or custom-period reviews, retaining evidence and versions. Missing accomplishments are not invented. Generation uses model allowance; browsing and exporting history do not.",
        "仪表入口管理调用限额、自动暂停、建议反馈和完整备份。旁边的滑杆入口可改来源、排除项目和语言。归档也包含在备份里；备份未加密，请勿上传 GitHub。": "The gauge controls request limits, automatic pause, feedback and full backups. The sliders change sources, exclusions and languages. Backups include archives; they are unencrypted and must not be uploaded to GitHub.",
        "当前是 macOS 桌面 Beta，没有网页或手机端，也没有后台守护服务。自动扫描和自动草稿只在窗口打开时运行。仅整理本机可读取的 Codex／CC 日志，不能读取云端独有或其他电脑的线程。": "This is a macOS desktop Beta, with no web/mobile version or background service. Automatic scans and drafts run only while the window is open. Only locally readable Codex/CC logs are supported, not cloud-only threads or other computers.",
        "未选择的来源不会扫描；以后可以在设置里修改。读取来源与总结模型相互独立。": "Unselected sources are not scanned. Change this later in Settings. Sources and summarizing models are independent.",
        "macOS 桌面 Beta · 无网页／手机端 · 自动任务仅在窗口打开时运行": "macOS desktop Beta · No web/mobile app · Automatic tasks require an open window",
        "这是一段安全演示，不会开启自动草稿。生成真实总结时，仍会单独征求允许并说明额度使用。": "This safe demo does not enable automatic drafts. Real summaries still request permission and explain allowance usage separately.",
        "演示结束后，示例不会混入你的真实日志。": "Demo examples never become part of your real journal.",
        "从右上角的问号菜单可再次打开新手指引或体验演示。": "Reopen the tour or demo from the question-mark menu in the upper-right corner.",
        "现阶段安装包面向 Apple Silicon、macOS 14 及以上；仍是未公证的 Beta，其他系统与机器需要额外验证。": "Current packages target Apple Silicon and macOS 14+. This Beta is not notarized; other systems and machines need further verification."
    ]
    private static let workflowEnglish: [String: String] = [
        "这里计数的是 CLI 生成任务；CLI 内部可能有多轮模型请求，其他应用的调用不在统计中。": "Counts CLI generation jobs. A CLI job may make multiple model requests. Usage in other apps is not included.",
        "备份包含人工记录、线程状态、建议与反馈、调用记录、周报／月报，以及线程标题和日期。不包含原始对话摘录、CLI 凭据文件或账号配置。": "Includes notes, thread states, advice and feedback, request logs, reports, titles and dates. Excludes raw conversation excerpts, CLI authentication files and account configuration.",
        "图片页码无效。": "Invalid image page.",
        "检测到未完成的恢复，请重新打开以恢复原文件；不会继续写入或调用模型。": "An unfinished restore was detected. Reopen to recover originals. No further writes or model requests.",
        "恢复事务格式无效，所有文件已保留。": "Invalid restore transaction. All files retained.",
        "恢复备份目录不能使用符号链接。": "Restore backup directories cannot be symbolic links.",
        "恢复前原文件不完整，请保留 Restore Backups 并手动修复。": "Pre-restore originals are incomplete. Keep Restore Backups for manual repair.",
        "数据与调用": "Data & requests",
        "调用控制": "Request controls",
        "备份恢复": "Backup & restore",
        "今日 %d / %d 次 · 自动 %d / %d 次": "Today %d / %d requests · Automatic %d / %d",
        "一次摘要请求最多整理 4 条记录。失败、取消和已开始的请求也计入上限；这是本地请求次数，不是 token、费用或账号剩余额度。": "One summary request handles up to 4 records. Failed, cancelled and started requests count. These are local requests, not tokens, costs or account allowances.",
        "每日全部请求上限：%d": "Daily request limit: %d",
        "其中自动草稿上限：%d": "Automatic draft limit: %d",
        "暂停自动草稿": "Pause automatic drafts",
        "自动补齐选中线程的历史草稿": "Automatically fill selected thread history",
        "默认只处理选中日期的记录；浏览旧线程不会自动补齐整段历史。上限 0 表示禁用。额度按应用时区的自然日重置。": "Only the selected date is processed by default. Browsing old threads does not fill their history. Zero disables requests. Limits reset each calendar day in the app's time zone.",
        "保存设置": "Save settings",
        "立即暂停并停止": "Pause & stop now",
        "调用控制已保存。": "Request controls saved.",
        "待生成列表：%d 条": "Pending drafts: %d",
        "仅预览，不调用模型；仍会等待线程静置一分钟，并跳过已编辑或确认的记录。": "Preview only; no model requests. Generation waits for one minute of inactivity and skips edited or confirmed notes.",
        "仅显示前 30 条；不会自动扩大生成范围。": "First 30 shown. Generation scope is not expanded automatically.",
        "今日请求记录": "Today's requests",
        "手动摘要": "Manual summary",
        "自动草稿": "Automatic drafts",
        "推进分析": "Progress analysis",
        "已开始": "Started",
        "成功": "Succeeded",
        "失败": "Failed",
        "已取消": "Cancelled",
        "备份包含人工记录、线程状态、建议与反馈、调用记录、周报／月报，以及线程标题和日期。不包含原始对话摘录、CLI 凭据或模型账号。": "Includes notes, thread states, advice and feedback, request logs, reports, titles and dates. Excludes raw conversation excerpts, CLI credentials and model accounts.",
        "备份未加密，可能含私人文字和本地路径。请保存到安全位置，不要提交到 GitHub。": "Backups are unencrypted and may include private notes and local paths. Store securely; do not commit to GitHub.",
        "导出完整备份": "Export full backup",
        "选择备份恢复…": "Choose backup to restore…",
        "打开恢复前备份": "Open pre-restore backup",
        "恢复前会校验格式，并在本机保留原文件。恢复不会打开原线程、发送消息或启动模型；当前来源目录和设置不变。": "The format is validated and originals saved locally first. Restoration opens no threads, sends no messages and starts no models. Current source directories and settings stay unchanged.",
        "演示模式不读取或写入备份。": "Demo does not read or write backups.",
        "备份已保存，请妥善保管。": "Backup saved. Keep it secure.",
        "确认恢复备份？": "Restore this backup?",
        "恢复": "Restore",
        "%d 条日志 · %d 次建议 · %d 份期间回顾": "%d notes · %d advice snapshots · %d period reports",
        "将替换现有日志、建议历史和线程状态，并自动保留恢复前原文件。保留当前来源目录与设置，关闭自动草稿；不会调用模型。": "Replaces notes, advice history and thread states after saving original files. Retains current source directories and settings, and turns automatic drafts off. No model requests.",
        "恢复完成，原文件已备份。自动草稿已关闭。": "Restored. Originals backed up. Automatic drafts are off.",
        "线程状态": "Thread state",
        "线程已完成": "Thread completed",
        "暂时搁置": "Paused",
        "等待中": "Waiting",
        "建议反馈": "Advice feedback",
        "尚未处理": "Pending",
        "已处理": "Handled",
        "不采纳": "Dismissed",
        "已完成或暂时搁置的线程不进入推进分析；每日记录仍然保留。": "Completed and paused threads are excluded from analysis. Daily notes remain.",
        "推进助手可单独选择模型。已处理／不采纳的建议在出现新进展前不再重复推荐。": "Select an independent advisor model. Handled or dismissed advice is not repeated until progress changes.",
        "周报／月报": "Weekly / monthly reports",
        "周报": "Weekly report",
        "月报": "Monthly report",
        "自选期间": "Custom period",
        "期间": "Period",
        "上一期间": "Previous period",
        "当前期间": "Current period",
        "%d 条记录 · %d 条有摘要 · %d 条缺少摘要": "%d records · %d with notes · %d without notes",
        "生成期间回顾": "Generate report",
        "生成演示回顾": "Generate demo report",
        "只使用期间内已保存的摘要，不自动补齐缺失草稿。最多对比最近 120 条记录，结论可展开核对；历史回顾保留原始版本。": "Uses saved notes only; does not generate missing drafts. Compares up to 120 recent records. Expand claims to check evidence. Original report versions are retained.",
        "历史回顾": "Saved reports",
        "生成一份回顾，或选择已保存的版本。浏览历史不会调用模型。": "Generate a report or select a saved version. Browsing history never calls a model.",
        "本次回顾尚未保存，请重试保存。": "Report not saved yet. Retry saving.",
        "复制 Markdown": "Copy Markdown",
        "保存 Markdown": "Save Markdown",
        "已复制，请检查私人内容后分享。": "Copied. Review private content before sharing.",
        "回顾已保存，请检查私人内容后分享。": "Report saved. Review private content before sharing.",
        "回顾是模型草稿，不代表已核实的成果。分享前检查私人信息；不会自动上传。": "Reports are model drafts, not verified accomplishments. Review private content before sharing. Nothing uploads automatically.",
        "允许生成期间回顾？": "Allow period report?",
        "将选定期间最多 120 条已保存摘要、标题和后续事项发送到 %@ CLI 的模型提供方，消耗 1 次本地调用额度。可能包含私人文字；不发送原始对话，不使用工具。": "Up to 120 saved notes, titles and next steps go via the %@ CLI to its model provider, using one locally counted request. Notes may be private. No raw conversations or tools.",
        "使用 %d / %d 条记录；%d 条缺少摘要": "Based on %d / %d records; %d without notes",
        "已完成成果": "Completed outcomes",
        "仍在推进": "Ongoing work",
        "明确阻塞": "Explicit blockers",
        "下一期间": "Next steps",
        "期间综述": "Period overview",
        "依据：": "Evidence:",
        "没有足够记录支持此项。": "No sufficient recorded evidence.",
        "模型草稿 · 分享前请核对": "Model draft · Review before sharing",
        "演示期间回顾：对比多天进展，不调用模型。": "Demo review: compare multiple days without model requests.",
        "存储文件不能使用符号链接，原文件已保留。": "Storage file cannot be a symbolic link. Original retained.",
        "存储文件过大或格式无效，原文件已保留。": "Storage file too large or invalid. Original retained.",
        "存储目录不能使用符号链接。": "Storage directory cannot be a symbolic link.",
        "无法锁定日志存储，请检查目录权限。": "Cannot lock journal storage. Check permissions.",
        "无法锁定日志存储，请重试。": "Cannot lock journal storage. Retry.",
        "存储文件过大，请先备份。": "Storage file too large. Back up first.",
        "日志已由另一个实例修改，本次未覆盖；请导出备份后重新打开。": "Another instance changed the journal. Nothing overwritten. Export a backup and reopen.",
        "已达到今日模型调用上限；可在调用控制中调整。": "Daily request limit reached. Adjust in Request controls.",
        "自动草稿已暂停。": "Automatic drafts paused.",
        "已达到今日自动草稿上限，剩余内容不会继续调用模型。": "Automatic draft limit reached. No further automatic requests.",
        "状态或调用记录格式无效，原文件已保留。": "Invalid states or request logs. Original retained.",
        "备份文件过大。": "Backup too large.",
        "备份格式或版本不兼容。": "Incompatible backup format or version.",
        "备份日志版本不兼容。": "Incompatible backup journal version.",
        "恢复目标或文件大小无效。": "Invalid restore target or file size.",
        "恢复未完成，回滚失败；原文件已保存在 Restore Backups，请勿继续编辑。": "Restore and rollback failed. Originals retained in Restore Backups. Stop editing.",
        "状态与调用记录读取失败；模型调用已停止，原文件已保留，可从备份恢复。": "Cannot read states or request logs. Models stopped; originals retained. Restore a backup.",
        "状态与调用记录保存失败；后续模型调用已停止，请备份后重新打开。": "Cannot save states or request logs. Models stopped. Back up and reopen.",
        "调用控制设置无效。": "Invalid request controls.",
        "请等待读取或生成结束，再备份。": "Wait for reading or generation before backup.",
        "请等待读取或生成结束，再恢复。": "Wait for reading or generation before restoration.",
        "周报／月报缺少有效日期或来源依据，结果未采用。": "Report dates or source evidence invalid. Result not adopted.",
        "后续事项没有已记录的下一步依据，结果未采用。": "Next steps lack recorded evidence. Result not adopted.",
        "历史归档": "History archive",
        "推进建议历史或状态文件超过 32MB 时，最早的建议、周报／月报和 30 天前的调用记录会移到 Archive 文件夹，不会删除。历史建议和回顾仍可浏览，完整备份包含归档；恢复时合并归档并保留本机已有历史。": "When advice history or the state file exceeds 32 MB, the oldest advice, weekly/monthly reports and request logs older than 30 days move to Archive. Historical advice and reports remain browsable. Full backups include archives; restoring merges archives and retains existing local history.",
        "旧索引来源无法确认，已保留原索引副本；当前目录将重新扫描。": "The legacy index's source could not be verified. Its original copy was preserved; the current folders will be rescanned.",
        "历史归档读取失败，原文件已保留；无法导出完整备份，请检查归档文件。": "History archives could not be read. Originals retained; a complete backup cannot be exported until the archive files are checked.",
        "归档格式无效，原文件已保留。": "Invalid archive format. Originals retained.",
        "归档读取失败，原文件已保留。": "An archive could not be read. Originals retained.",
        "恢复目标已存在，原文件已保留。": "A restore destination already exists. Originals retained.",
        "已归档 %d 次建议 · %d 份期间回顾 · %d 条调用记录（%d 个文件）": "Archived: %d analyses · %d period reviews · %d request logs (%d files)",
        "打开归档文件夹": "Open archive folder",
        "暂无归档。": "Nothing archived.",
        "归档目录不能使用符号链接，原文件已保留。": "The archive folder cannot be a symbolic link. Originals retained.",
        "时区更改后，有 %d 条已编辑或确认的笔记未能自动对应到新日期。原笔记未删除，切回原时区即可看到。": "After the timezone change, %d edited or confirmed notes could not be matched to a new date. They were not deleted; switch back to the previous timezone to see them.",
    ]
    private static let legacyEnglish: [String: String] = [
        "环境检查": "Environment check", "重新检查": "Check again", "完成": "Done", "演示模式": "Demo mode",
        "本地记录": "Local history", "会话映射": "Session mapping", "登录、网络与额度": "Login, network & usage",
        "演示不检查真实环境，也不读取私人目录或调用模型。": "Demo mode does not check your environment, read private folders or call models.",
        "已找到可执行程序；尚未验证版本、登录或模型权限。": "Executable found. Version, login and model access have not been verified.",
        "未找到 CLI；仍可浏览本地记录。需要模型功能时，请在终端安装并登录，或切换摘要引擎。": "CLI not found. Local history is still available. For model features, install and sign in in Terminal, or select another summary engine.",
        "未启用桌面映射；自定义 CC 主目录不会自动读取默认桌面数据。可在设置中指定会话目录。": "Desktop mapping is disabled. A custom CC home does not automatically read default desktop data; set the session folder in Settings.",
        "这里只检查本地目录和 CLI 是否存在，不读取密钥，不验证账号，不发送模型请求。登录与额度请在对应 CLI 中自行确认。": "Only local folders and CLI availability are checked. No credentials are read, accounts verified or model requests sent. Check login and usage in the respective CLI.",
        "目录可访问；未检查日志内容，空目录也会显示为可访问。": "Folder is accessible. Log contents were not checked; empty folders also appear accessible.",
        "未发现目录；没有使用过该工具时这是正常的。请检查主目录设置，之后再刷新本地记录。": "Folder not found. This is normal if you have not used this tool. Check the home directory setting, then refresh local history.",
        "这里是文件而不是目录；请填写主目录，不要选择单个日志文件。": "This is a file, not a folder. Enter the home directory, not an individual log file.",
        "目录不可读取；请检查所选目录的权限和系统隐私设置，不需要关闭 Gatekeeper。": "Folder is not readable. Check folder permissions and system privacy settings; do not disable Gatekeeper.",
        "请填写以 / 开头的绝对目录路径；不要使用 ~ 或 sessions/projects 子目录。": "Enter an absolute directory path starting with /. Do not use ~ or the sessions/projects subfolder.",
        "不启动 CLI、不读取聊天或密钥、不联网；结果只在此窗口显示，不导出个人路径。": "No CLI launches, chat or credential reads, or network requests. Results stay in this window and do not export personal paths.",
        "兼容性说明：仅本地 Codex / CC 记录；Claude Desktop 原线程跳转仍是实验性功能。缺少 CLI 不影响浏览，生成内容需另行授权并消耗模型额度。": "Local Codex / CC history only. Claude Desktop original-thread navigation is experimental. Browsing works without a CLI; generation needs separate consent and consumes model usage.",
        "浏览记录不需要模型或 CLI 登录。新日志的自动草稿默认关闭；升级保留原有设置。生成内容会说明发送内容与额度使用。": "Browsing needs no model or CLI login. Auto drafts are off for new journals; upgrades preserve existing settings. Generation explains what is sent and how model usage is consumed.",
        "推进助手": "Progress advisor",
        "每日建议，保留进展的判断": "Daily advice, with a lasting record",
        "推进建议": "Progress advice", "当天推进建议": "Advice for this day",
        "每日建议": "Daily advice", "查看日期": "Date", "分析当前进展": "Analyze current progress",
        "较早的建议": "Earlier advice", "较新的建议": "Newer advice",
        "%d 天 · %d 次分析": "%d days · %d analyses", "%@，%d 次分析": "%@, %d analyses",
        "新分析始终使用当前进展，并保存到生成当天；选择历史日期只回看，不调用模型。": "New analyses use current progress and are saved on the day they are generated. Browsing history never calls a model.",
        "还没有保存的建议": "No saved advice yet",
        "历史快照：保留当时的判断，继续前请核对当前进展。": "Historical snapshot: the original judgment is preserved. Check current progress before continuing.",
        "尚未保存 · 退出后会丢失": "Not saved · lost on exit",
        "重试保存（不调用模型）": "Retry saving (no model call)",
        "当时的候选：%d / %d 个线程，每个最多 3 天的摘要。": "Snapshot scope: %d of %d threads, up to 3 days of notes each.",
        "这一天还没有推进建议": "No advice saved for this day",
        "选择左侧已保存的日期回看，或点击分析当前进展。不会为没有记录的过去日期补造建议。": "Choose a saved day on the left, or analyze current progress. Advice is never invented for past days without a record.",
        "查看当前候选范围": "Inspect current candidate scope",
        "原线程未在当前记录中，建议与依据仍保留": "Thread is not currently indexed; advice and evidence are retained",
        "演示历史仅在内存中，不读取私人记录，不调用模型。": "Demo history stays in memory. No private records or model calls.",
        "建议与依据保存在本机，退出后仍可回看，可能包含私人信息。建议不代表真实优先级；返回客户端不会发送下一步。": "Advice and evidence are saved locally and remain after exit; they may contain private information. Advice is not true priority. Opening a client never sends the next step.",
        "推进建议历史读取失败，原文件已保留；请备份并修复后重启。": "Advice history could not be read. The original file is preserved; back it up, repair it, then restart.",
        "本次建议尚未保存；已有历史未删除，请检查存储空间和权限后重试。": "This advice has not been saved. Existing history is intact; check storage and permissions, then retry saving.",
        "推进建议历史不能使用符号链接，原文件已保留。": "Advice history cannot be a symbolic link. The original file is preserved.",
        "推进建议历史文件过大或格式无效，原文件已保留。": "Advice history is too large or invalid. The original file is preserved.",
        "推进建议历史版本不兼容，原文件已保留。": "Advice history has an incompatible version. The original file is preserved.",
        "推进建议历史文件过大，请先备份；已有建议未删除。": "Advice history is too large. Back it up first; no existing advice was deleted.",
        "推进建议历史无法安全保存，原文件已保留。": "Advice history could not be saved safely. The original file is preserved.",
        "推进建议历史包含无效快照，原文件已保留。": "Advice history contains an invalid snapshot. The original file is preserved.",
        "只根据线程进展判断下一步，不读取日程计划": "Recommend next steps from thread progress only; no planner data",
        "只看线程进展 · 你决定是否继续": "Progress only · you decide what to continue",
        "对比已完成的进展、明确的下一步和阻塞。不会读取日程计划的 DDL、重要度，也不会自动发消息或执行任务。": "Compare actual progress, explicit next steps and blockers. No planner deadlines or importance, and no automatic messages or task execution.",
        "停止分析": "Stop analysis", "查看演示建议": "Show demo advice", "分析线程进展": "Analyze progress",
        "分析最近活跃的 %d / %d 个线程，每个最多 3 天的摘要；不受主界面的日期和分类筛选影响。": "Consider %d of %d most recently active threads, up to 3 days each; independent of the main view's date and category filters.",
        "线程记录已变化；以下是旧快照，请重新分析。": "Progress has changed. This is an older snapshot; analyze again.",
        "暂无有依据的推荐；可先补齐或核对最新进展。": "No evidence-backed recommendations yet. Add or check the latest progress notes.",
        "接下来，推进哪个线程？": "Which thread should move forward next?",
        "先生成或编辑线程的每日摘要，再点击分析。助手只使用这里保存的摘要与下一步，不发送原始对话、项目路径或日程数据。": "Generate or edit daily summaries first, then analyze. The advisor uses saved summaries and next steps only, not raw conversations, project path fields or planner data.",
        "有明确后续就建议推进；资料过期就先核对；条件未满足就等待。每条建议都能展开查看依据。": "A clear next step supports continuation. Outdated notes require review; explicit blockers call for waiting. Expand each suggestion to inspect its evidence.",
        "查看本次候选范围": "Inspect candidate scope", "摘要最新": "Current summary", "需补齐摘要": "Needs current notes",
        "允许分析线程进展？": "Allow progress analysis?",
        "将最多 40 个线程的标题、日期和最近 3 天的摘要与下一步交给 %@ CLI 的模型提供方并消耗额度。摘要也可能包含私人信息；不会使用工具或修改原线程。": "Titles, dates and up to 3 days of summaries and next steps for up to 40 threads will be sent through the %@ CLI to its model provider and consume usage. Notes may contain private information. No tools or original-thread changes.",
        "建议推进": "Continue", "先核对进展": "Review first", "等待条件": "Waiting",
        "判断把握：%@": "Confidence: %@", "较高": "High", "中等": "Medium", "较低": "Low",
        "进展依据": "Progress evidence", "无摘要": "No summary", "摘要已过期": "Outdated summary",
        "查看线程时间线": "View timeline", "复制下一步": "Copy next step",
        "推荐缺少有效进展依据，结果未采用；请刷新摘要后重试。": "Advice lacked valid progress evidence and was not accepted. Update summaries and try again.",
        "返回原线程": "Return to thread", "复制线程标题": "Copy thread title",
        "返回 Claude Code（实验性）": "Open in Claude Code (experimental)",
        "此记录没有有效的原线程 ID。": "This record has no valid original thread ID.",
        "无法打开客户端，请检查是否已安装。": "Could not open the client. Check that it is installed.",
        "已请求定位 Claude Code 原线程。此功能为实验性；若没有定位，请在 Claude Code 中搜索线程标题。不会导入新会话。": "Requested the original Claude Code session. This is experimental: if it did not navigate, search the thread title in Claude Code. No new session is imported.",
        "未找到可定位的桌面会话，已打开 Claude 并复制线程标题；请在 Code 中搜索。终端继续命令可在菜单中复制，不会自动执行。": "No navigable desktop session was found. Opened Claude and copied the thread title; search it in Code. You can copy a terminal resume command from the menu; it never runs automatically.",
        "部分 Claude 桌面会话元数据无法读取；日志仍可查看，原线程定位可能不可用。": "Some Claude desktop metadata could not be read. Journal history remains available; original-session navigation may be unavailable.",
        "Claude 桌面会话目录（留空自动）": "Claude desktop sessions folder (blank: automatic)",
        "两种工具 · 一份工作日志": "Two tools. One work journal.",
        "演示 · 不读取私人记录": "Demo · no private history",
        "自动草稿": "Auto drafts", "取消": "Cancel", "允许": "Allow", "关闭": "Close",
        "允许生成模型摘要？": "Allow model summaries?",
        "选中线程的少量对话摘录会交给 %@ CLI，发送到其配置的模型提供方并消耗额度。原始日志只读，生成任务不能使用工具。": "Short excerpts from the selected threads will be sent through the %@ CLI to its configured model provider and consume usage. Original logs are read-only; summarization cannot use tools.",
        "线程静置一分钟后生成草稿；不会覆盖你编辑或确认过的文字": "Generate after a thread has been idle for one minute; edited and confirmed notes are preserved.",
        "刷新本地记录": "Refresh local history", "来源目录、摘要引擎和模型设置": "Language, sources, engine and model settings",
        "分享图片": "Share image", "选择日期范围，生成可保存或分享的进展卡片": "Select a date range and create progress cards to save or share",
        "跟随 CLI 默认": "CLI default", "更多模型与自定义…": "More models / custom…",
        "选择写摘要的引擎与模型，不改变原线程使用的模型": "Choose the summarization engine and model; the original thread is unchanged",
        "日历": "Calendar", "今天": "Today", "有记录的日子": "Active days",
        "本地读取 · 摘要需模型额度": "Local history · summaries consume usage",
        "%@，%d 个线程": "%@, %d threads", "%d 个线程": "%d threads", "全部线程": "All threads",
        "今天处理了什么": "What happened that day", "找到一个线程，回看它的每一天": "Find a thread and follow its daily progress",
        "浏览方式": "View", "按天": "By day", "按线程": "By thread",
        "导出当前摘要为 Markdown": "Export current summaries as Markdown", "搜索线程或进展": "Search threads or progress",
        "分类": "Category", "全部": "All", "未分类": "Uncategorized", "课程": "Courses", "研究": "Research", "学工": "Student affairs", "生活": "Life",
        "来源": "Source", "全部来源": "All sources", "这一天，留一点空白": "A little space for today",
        "没有符合条件的线程。\n可以选择有记录的日期，或切换到“按线程”。": "No matching threads.\nChoose an active day or switch to By thread.",
        "停止生成": "Stop", "草稿可编辑 · 已确认文字不会被自动覆盖": "Edit drafts freely · confirmed notes are preserved",
        "生成草稿": "Generate drafts", "正在整理这一天的进展…": "Summarizing this day's progress…",
        "%d 条对话 · 等待生成草稿": "%d messages · awaiting a draft", "已确认": "Confirmed", "可编辑草稿": "Editable draft",
        "有新进展": "New activity", "编辑": "Edit", "复制继续命令": "Copy resume command",
        "打开 Codex 原线程": "Open thread in Codex", "重新生成模型草稿": "Regenerate model draft",
        "一个线程的每一天": "A thread, day by day", "打开原线程": "Open original thread", "导出此线程摘要": "Export thread summaries",
        "打开、继续或导出此线程": "Open, resume or export this thread", "%d 天的记录": "%d recorded days",
        "选择左侧的线程卡片": "Select a thread on the left", "进展，有迹可循": "Progress leaves a trail",
        "同一个线程在不同日期做的事，\n会在这里连成一条时间线。": "What a thread did on different days\ncomes together in this timeline.",
        "这一天有 %d 条对话，尚未生成草稿。": "%d messages that day; no draft yet.", "后续：%@": "Next: %@",
        "草稿": "Draft", "生成": "Generate", "导出失败：": "Export failed: ", "编辑当天记录": "Edit daily note",
        "后续事项（可留空）": "Next step (optional)", "确认这条记录": "Confirm this note",
        "保存后的文字会保留；线程有新进展时会提示，不会自动改写。": "Saved text is preserved. New activity is flagged without automatically rewriting your note.",
        "保存": "Save", "来源与摘要设置": "Language, sources & summaries",
        "只读本机日志，不修改会话，也不需要把 API 密钥交给本软件。": "Reads local logs without changing conversations or collecting your CLI credentials.",
        "Codex 主目录": "Codex home", "Claude Code 主目录": "Claude Code home", "时区": "Time zone",
        "摘要引擎": "Summary engine", "摘要模型": "Summary model", "自定义模型…": "Custom model…", "自定义模型名": "Custom model name",
        "刷新中…": "Refreshing…", "刷新模型列表": "Refresh model list",
        "Sonnet / Opus / Haiku 会由 Claude CLI 解析到对应模型；可选范围与账号、提供方有关。": "Claude CLI resolves Sonnet / Opus / Haiku aliases. Availability depends on your account and provider.",
        "应用语言": "App language", "生成内容语言": "Summary language", "跟随讨论内容": "Match discussion",
        "界面语言与摘要语言相互独立。自动模式逐条判断用户讨论的主要语言；修改设置不会翻译已有记录。": "App and summary languages are independent. Match discussion chooses each entry's main user language. Existing notes are not translated.",
        "读取来源与摘要引擎相互独立：可以用 Codex 总结 CC，也可以反过来。实际模型会记录在草稿旁。": "Transcript source and summary engine are independent. Either engine can summarize either source; drafts record the actual model.",
        "排除项目（每行一个路径片段）": "Exclude projects (one path fragment per line)",
        "Claude Code 原始日志可能定期清理；本软件保留已扫描的少量摘录与草稿。改时区或排除规则会重建索引，但保留原日志已清理的历史（被排除的项目除外）；已有笔记会对应到新日期，原笔记不删除。更换来源目录会重新建立索引。": "Claude Code may clean up transcripts. This app retains bounded excerpts and drafts. Changing the timezone or exclusions rebuilds the index but keeps history whose transcripts were cleaned up (except excluded projects); existing notes move to the new dates and originals are kept. Changing source folders starts a new index.",
        "设置…": "Settings…", "保存设置": "Save settings", "请输入自定义模型名，或选择“跟随 CLI 默认”。": "Enter a custom model name or choose CLI default.",
        "模型未报告": "model not reported", "旧草稿 · 模型未记录": "Legacy draft · model not recorded", "已保存": "saved",
        "没有本地目录，请刷新 Codex 列表或输入自定义模型。": "No cached models. Refresh the Codex list or enter a custom name.",
        "来自 Codex 本地模型目录；可刷新列表。": "From Codex's local model catalog; refresh to update.",
        "已通过 Codex model/list 更新；实际访问权限由 CLI 账号决定。": "Updated through Codex model/list. Access depends on the CLI account.",
        "未能刷新，仍可使用本地列表、CLI 默认或自定义模型。请检查 CLI 版本和登录。": "Refresh failed. Cached models, CLI default and custom names still work. Check your CLI version and login.",
        "这段时间，我做了什么": "What I worked on", "%d 个活跃日": "%d active days", "这段时间没有符合条件的记录。": "No matching records in this date range.",
        "线程 %@": "Thread %@", " · 续": " · continued", "当天有 %d 条对话，尚未生成摘要。": "%d messages that day; no summary yet.",
        "[本地路径]": "[local path]", "尚未生成摘要。": "No summary yet.", "AgentJournal · 两种工具，一份进展": "AgentJournal · Two tools. One story of progress.",
        "图片生成失败，请重试。": "Could not render the image. Please try again.", "分享这段时间的进展": "Share your progress",
        "按线程归并每日摘要 · 长内容自动分页，不丢记录": "Daily summaries grouped by thread · long content is paginated",
        "先选择要分享的线程，再预览图片": "Choose which threads to share, then preview the image",
        "1 · 选择内容": "1 · Choose content", "2 · 预览图片": "2 · Preview images",
        "关闭后使用线程编号，不显示原始名字。": "When off, use thread numbers instead of original names.",
        "生成所选线程草稿": "Generate selected drafts", "返回选择": "Back to selection",
        "%d / %d 个线程已选择": "%d / %d threads selected", "预览图片": "Preview image",
        "选择要分享的线程": "Choose threads to share", "全部选中": "Select all", "全部取消": "Deselect all",
        "默认全部包含；取消一个线程会排除它在所选期间的所有记录。这里只影响本次分享，不会删除日志。": "All threads are included by default. Deselecting a thread excludes all its notes in this date range. This affects this share only and never deletes your journal.",
        "所选日期没有符合条件的线程。": "No matching threads in this date range.",
        "%d 条每日记录": "%d daily records", "至少选择一个线程，才能预览图片。": "Select at least one thread to preview an image.",
        "来自 %@": "From %@",
        "开始": "From", "结束": "To", "当天": "This day", "最近 7 天": "Last 7 days", "本月": "This month",
        "显示线程标题": "Show thread titles", "仅已确认": "Confirmed only", "开始日期不能晚于结束日期。": "Start date must not be after end date.",
        "%d 个线程 · %d 条每日记录 · %d 条可生成／更新": "%d threads · %d daily records · %d ready to generate / update",
        "生成期间草稿": "Generate range drafts",
        "仅分享整理后的文字，不带原始对话、路径字段或账号信息。仍请检查摘要中的个人信息；不会自动上传。": "Shares notes only, without raw chats, path fields or account details. Review notes for private information. Nothing is uploaded automatically.",
        "第 %d / %d 张": "Image %d of %d", "复制图片": "Copy image", "保存 PNG": "Save PNG", "保存全部": "Save all",
        "图片无法读取": "Could not read the image", "生成所选日期的摘要？": "Generate summaries for this range?", "允许生成": "Generate",
        "将通过 %@ 生成／更新 %d 条每日草稿。少量对话摘录会发送给该 CLI 的模型提供方，并消耗额度；你编辑或确认过的文字不会被覆盖。": "Use %@ to generate / update %d daily drafts. Short excerpts will be sent to the CLI's configured provider and consume usage. Edited and confirmed notes are preserved.",
        "图片已复制，可粘贴到微信等应用。": "Image copied. Paste it into a messaging app.", "图片已保存。": "Image saved.", "保存图片": "Save images",
        "选择文件夹，将创建独立子文件夹保存所有分页图片。": "Choose a folder. All images will be saved in a new subfolder.", "已保存 %d 张图片。": "Saved %d images.",
        "部分图片可能已保存，请检查所选文件夹。": "Some images may have been saved. Check the selected folder. ",
        "正在读取 Codex 与 Claude Code…": "Reading Codex and Claude Code…", "正在生成草稿 %d/%d…": "Generating drafts %d/%d…",
        "工作日志读取失败，原文件已保留；请备份并修复后重启。": "Could not read the journal. The original file is preserved; back it up, repair it and restart.",
        "时区无效，例如 Asia/Shanghai 或 America/New_York。": "Invalid time zone. Try Asia/Shanghai or America/New_York.",
        "请等待读取或摘要结束，再修改设置。": "Wait for indexing or generation to finish before changing settings.",
        "日志目录请填写绝对路径。": "Use absolute paths for transcript directories.", "日志文件损坏，暂时不能保存设置。": "The journal file is damaged; settings cannot be saved.",
        "工作日志保存失败：": "Could not save the journal: ", "状态：": "Status: ", " · 分类：": " · Category: ", "按线程整理 · AgentJournal": "Organized by thread · AgentJournal",
        "已完成": "Completed", "进行中": "In progress", "待确认": "Needs review", "待整理": "Not summarized",
        "未发现 Codex 本地记录；可在设置中指定目录。": "No local Codex history found. Set its directory in settings.",
        "未发现 Claude Code 本地记录；可在设置中指定目录。": "No local Claude Code history found. Set its directory in settings.",
        "索引未能缓存，当前记录仍可查看。": "The index could not be cached; current records are still available.",
        "%@ 目录无法读取，请检查权限。": "Cannot read the %@ directory. Check its permissions.",
        "一个 %@ 日志暂时无法读取，刷新时会重试。": "A %@ log could not be read. The next refresh will retry.",
        "未命名线程": "Untitled thread", "示例数据 · 未调用模型": "Sample data · no model call", "演示": "Demo",
        "模型遗漏条目或返回了无效字段，这批草稿未保存，请重试。": "The model omitted entries or returned invalid fields. This batch was not saved; please try again.",
        "未找到 %@ CLI。请安装并登录，或在设置中切换摘要引擎。": "%@ CLI was not found. Install and sign in, or change the summary engine in settings.",
        "无法将资料交给摘要引擎，请重试。": "Could not send input to the summarizer. Please try again.",
        "Claude Code 达到摘要轮数限制，这批草稿未保存，请重试或切换引擎。": "Claude Code reached the turn limit. This batch was not saved; retry or change engines.",
        "Claude Code 返回执行错误，这批草稿未保存，请在终端检查 CLI 登录和网络。": "Claude Code returned an execution error. This batch was not saved. Check CLI login and network in Terminal.",
        "CLI 版本不支持摘要所需参数，请更新 CLI 或切换摘要引擎。": "This CLI version does not support the required options. Update it or change engines.",
        "摘要认证失败，请检查 CLI 的登录或模型提供方配置。": "Summary authentication failed. Check CLI login or provider settings.",
        "模型额度暂时不足；已有日志仍可查看，稍后可重试。": "Model usage is temporarily exhausted. Existing notes are available; retry later.",
        "摘要引擎未登录或登录已失效，请在终端登录后重试。": "The summary engine is not signed in or its login expired. Sign in in Terminal and retry.",
        "%@ 摘要失败或超时，请检查 CLI 版本、登录和网络。": "%@ summarization failed or timed out. Check CLI version, login and network.",
        "模型返回格式不完整，这批草稿未保存。": "The model returned an incomplete response. This batch was not saved.",
        "Claude Code 未返回结构化摘要，请更新 CLI 后重试。": "Claude Code did not return structured summaries. Update the CLI and retry."
    ]
}
