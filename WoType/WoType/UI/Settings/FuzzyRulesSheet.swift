//
//  FuzzyRulesSheet.swift
//  WoType
//
//  模糊音设置面板：标题和一句说明，声母、韵母两组，按当前拼音引擎显示，每组分左右两列（窗口高度跟着内容走，不用滚），
//  每条是「z = zh  资 · 知」加一个小开关；底下恢复默认、全部关闭、已开启几项、完成。
//  开关一拨立即生效；一条都不开就是不用模糊音。
//

import Cocoa

final class FuzzyRulesSheet: NSWindowController {

    private static var current: FuzzyRulesSheet?

    private let stack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private let inset: CGFloat = 20
    private let columnGap: CGFloat = 12

    /// 在设置窗口上弹出。
    static func present(on parent: NSWindow) {
        let sheet = FuzzyRulesSheet()
        current = sheet
        parent.beginSheet(sheet.window!) { _ in current = nil }
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "模糊音"
        super.init(window: window)
        let content = makeContent()
        window.contentView = content
        reload()
        // 高度按内容算：两个引擎的规则条数不一样（水杉 11 条、万象 10 条）
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.width, height: content.fittingSize.height))
    }

    private static let width: CGFloat = 600

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent() -> NSView {
        let root = SettingsBackgroundView()

        // 标题和说明固定在上面
        let title = NSTextField(labelWithString: "模糊音")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = SettingsKit.wrappingLabel("分不清的两个音当成一样的：开了 z = zh，打 zidao 也能出「知道」。",
                                                 size: 12, color: .secondaryLabelColor)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: inset, bottom: 14, right: inset)

        // 底栏：左边恢复默认、全部关闭，中间开了几项，右边完成
        let bar = NSView()
        let line = SeparatorLine()
        let reset = SettingButton(title: "恢复默认") { [weak self] in
            Settings.shared.update { config in
                // 默认那几条里只留当前引擎有的（万象没有 an=ang 这类）
                let known = Set(FuzzyRule.groups(for: config.pinyinEngine).flatMap(\.1).map(\.id))
                config[keyPath: Self.rulesKey] = FuzzyRule.defaults.filter(known.contains)
            }
            self?.reload()
        }
        let clear = SettingButton(title: "全部关闭") { [weak self] in
            Settings.shared.update { $0[keyPath: Self.rulesKey] = [] }
            self?.reload()
        }
        let done = SettingButton(title: "完成") { [weak self] in
            guard let window = self?.window else { return }
            window.sheetParent?.endSheet(window)
        }
        done.keyEquivalent = "\r"
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        for view in [line, reset, clear, countLabel, done] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }

        for view in [title, subtitle, stack, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            subtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),

            root.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 52),
            line.topAnchor.constraint(equalTo: bar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            reset.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: inset),
            reset.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clear.leadingAnchor.constraint(equalTo: reset.trailingAnchor, constant: 8),
            clear.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            countLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -inset),
            done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return root
    }

    /// 按当前设置重画三组开关。
    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let enabled = Set(Settings.shared.config[keyPath: Self.rulesKey])
        for (i, (group, rules)) in FuzzyRule.groups(for: Settings.shared.config.pinyinEngine).enumerated() {
            let title = SettingsKit.sectionTitle(group.rawValue)
            if i > 0, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(14, after: last)
            }
            stack.addArrangedSubview(title)

            // 左右两列：左边多放一条
            let half = (rules.count + 1) / 2
            let columns = [Array(rules[..<half]), Array(rules[half...])].map { column in
                SettingsKit.card(column.map { row(for: $0, isOn: enabled.contains($0.id)) },
                                 separatorInset: SettingsKit.rowInset)
            }
            let pair = NSStackView(views: columns)
            pair.spacing = columnGap
            pair.alignment = .top
            pair.distribution = .fillEqually
            stack.addArrangedSubview(pair)
            pair.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2).isActive = true
        }
        updateCount()
    }

    /// 一条规则：「z = zh」、一对例字、开关。点这一行的任何地方都切换。
    private func row(for rule: FuzzyRule, isOn: Bool) -> NSView {
        let toggle = SettingSwitch(isOn: isOn) { [weak self] on in
            Self.set(rule, on: on)
            self?.updateCount()
        }
        let row = SettingRowView()
        row.toggle = toggle
        let formula = NSTextField(labelWithString: rule.title)
        formula.font = .systemFont(ofSize: 13)
        let example = NSTextField(labelWithString: rule.example)
        example.font = .systemFont(ofSize: 12)
        example.textColor = .secondaryLabelColor
        for view in [formula, example, toggle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),
            formula.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsKit.rowInset),
            formula.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            // 例字都从同一列开始，上下对齐
            example.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsKit.rowInset + 102),
            example.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SettingsKit.rowInset),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// 改的是当前引擎的那份（两个引擎的规则分开存，docs/15）
    private static var rulesKey: WritableKeyPath<Config, [String]> {
        Config.fuzzyRulesKey(for: Settings.shared.config.pinyinEngine)
    }

    private func updateCount() {
        let count = Settings.shared.config[keyPath: Self.rulesKey].count
        countLabel.stringValue = count == 0 ? "没有开启" : "已开启 \(count) 项"
    }

    /// 开或关一条规则，保持设置面板里的顺序。
    private static func set(_ rule: FuzzyRule, on: Bool) {
        Settings.shared.update { config in
            var enabled = Set(config[keyPath: rulesKey])
            if on { enabled.insert(rule.id) } else { enabled.remove(rule.id) }
            config[keyPath: rulesKey] = FuzzyRule.groups(for: config.pinyinEngine).flatMap(\.1).map(\.id)
                .filter(enabled.contains)
        }
    }
}
