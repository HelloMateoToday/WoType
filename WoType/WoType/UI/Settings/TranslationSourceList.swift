//
//  TranslationSourceList.swift
//  WoType
//
//  设置 › 翻译设置 › 翻译源（docs/16）：翻译并显示的窗口问哪些翻译源、按什么顺序排。
//  每行：名字、开关、拖动手柄（≡）。按住手柄上下拖改顺序，拖的时候画一条插入线，松手存进设置
//  （selectionSourceOrder 存全部的顺序，selectionSourcesOn 存开着的）。设置一变设置页整页重画，列表跟着更新。
//  自己是一张透明的卡片（设置页按卡片给它定宽），里面套一张真的卡片。
//

import Cocoa

final class TranslationSourceList: CardView {

    private let sources = SelectionTranslator.orderedSources()
    private var rows: [NSView] = []
    private let indicator = NSView()
    private var card: NSView!

    init() {
        super.init(frame: .zero)
        transparent = true
        let on = Set(Settings.shared.config.selectionSourcesOn)
        rows = sources.enumerated().map { index, source in
            let toggle = SettingSwitch(isOn: on.contains(source.id)) { [weak self] enabled in
                self?.setEnabled(source.id, enabled)
            }
            let handle = DragHandle()
            handle.onDrag = { [weak self] point in self?.dragged(index, to: point) }
            handle.onDrop = { [weak self] point in self?.dropped(index, at: point) }
            let accessory = NSStackView(views: [toggle, handle])
            accessory.spacing = 12
            return SettingsKit.row(title: source.name, detail: Self.detail(source), accessory: accessory)
        }
        card = SettingsKit.card(rows)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        addSubview(indicator)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func detail(_ source: SelectionTranslator.Source) -> String? {
        switch source.kind {
        case .machine: nil
        case .apple: "离线翻译。要先在「系统设置 › 通用 › 语言与地区 › 翻译语言」里下载用到的语言。"
        case .ai: "AI 模型（「模型管理」里添加的），用你自己的 API 密钥。"
        }
    }

    private func setEnabled(_ id: String, _ enabled: Bool) {
        Settings.shared.update { config in
            config.selectionSourcesOn.removeAll { $0 == id }
            if enabled { config.selectionSourcesOn.append(id) }
        }
    }

    // MARK: - 拖动

    /// 鼠标（窗口坐标）在第几行之前：0…行数
    private func slot(at windowPoint: NSPoint) -> Int {
        let y = convert(windowPoint, from: nil).y
        for (index, row) in rows.enumerated() {
            let frame = convert(row.bounds, from: row)
            if y > frame.midY { return index }
        }
        return rows.count
    }

    private func dragged(_ index: Int, to point: NSPoint) {
        let slot = slot(at: point)
        let y: CGFloat
        if slot < rows.count {
            y = convert(rows[slot].bounds, from: rows[slot]).maxY
        } else {
            y = convert(rows[rows.count - 1].bounds, from: rows[rows.count - 1]).minY
        }
        indicator.frame = NSRect(x: 12, y: y - 1, width: bounds.width - 24, height: 2)
        indicator.isHidden = slot == index || slot == index + 1
    }

    private func dropped(_ index: Int, at point: NSPoint) {
        indicator.isHidden = true
        var slot = slot(at: point)
        guard slot != index, slot != index + 1 else { return }
        var ids = sources.map(\.id)
        let moved = ids.remove(at: index)
        if slot > index { slot -= 1 }
        ids.insert(moved, at: slot)
        Settings.shared.update { $0.selectionSourceOrder = ids }
    }
}

/// ≡：按住上下拖。拖的过程和松手的位置（窗口坐标）交给列表
private final class DragHandle: NSView {
    var onDrag: ((NSPoint) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    private let image = NSImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "拖动排序")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image.contentTintColor = .tertiaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        toolTip = "按住上下拖动，改变顺序"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 22),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDrop?(event.locationInWindow)
    }
}
