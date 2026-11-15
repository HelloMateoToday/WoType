//
//  OnboardingPage.swift
//  WoType
//
//  设置里的「新手引导」（docs/18）：点「打开」才打开引导窗口（在侧边栏点这一项不自动打开）。
//  Debug 编译多一组调试工具：从某一步开始、不检查条件、重置完成标记、每一步现在能不能继续。
//

import Cocoa

final class OnboardingPage: SettingsPage {
    override var pageTitle: String { "新手引导" }
    override var pageSubtitle: String { "启用输入法、选引擎、试打字和翻译、开语音，一步步带你设置好。" }

    #if DEBUG
    /// 只用来读状态（每一步能不能继续），不开定时器
    private let model = OnboardingModel()
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 引导窗口里的状态（启用、权限、下载）变了，这里的状态表跟着刷新
        observer = NotificationCenter.default.addObserver(forName: OnboardingModel.didChange, object: nil,
                                                          queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, notification.object as AnyObject? !== self.model else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
    #endif

    override func build() -> [NSView] {
        var views: [NSView] = [
            SettingsKit.sectionTitle("引导"),
            SettingsKit.card([
                SettingsKit.row(title: "打开新手引导",
                                detail: OnboardingWindowController.isCompleted ? "已经完成过，可以再看一遍。" : "还没有完成。",
                                icon: SettingsIcon(symbol: "figure.wave", color: .systemPurple),
                                accessory: SettingButton(title: "打开") { OnboardingWindowController.shared.open() }),
            ]),
        ]
        #if DEBUG
        views += debugViews()
        #endif
        return views
    }

    #if DEBUG
    private func debugViews() -> [NSView] {
        model.ignoresChecks = OnboardingWindowController.ignoresChecks
        model.refresh()
        let state = model.state
        let steps = OnboardingStep.allCases
        let titles = steps.enumerated().map { i, step in
            "\(i + 1). \(OnboardingStepView.copy(step, engine: config.pinyinEngine).0)"
        }
        let start = ActionPopUp()
        start.add("选一步…") {}
        for (title, step) in zip(titles, steps) {
            start.add(title) { OnboardingWindowController.shared.open(from: step) }
        }
        let status = zip(titles, steps).map { title, step in
            let mark = OnboardingFlow.skipped(step, state) ? "－ 跳过" : OnboardingFlow.ready(step, state) ? "✓ 能继续" : "✗ 不能继续"
            return "\(mark)　\(title)"
        }.joined(separator: "\n")
        return [
            SettingsKit.sectionTitle("调试（只在 Debug 编译里显示）"),
            SettingsKit.card([
                SettingsKit.row(title: "从某一步开始", detail: "直接跳到那一步，不用从头点。", accessory: start),
                SettingsKit.row(title: "不检查条件", detail: "每一步都能继续，看界面和动画用。",
                                accessory: SettingSwitch(isOn: OnboardingWindowController.ignoresChecks) { [weak self] on in
                                    OnboardingWindowController.setIgnoresChecks(on)
                                    self?.reload()
                                }),
                SettingsKit.row(title: "首次弹出标记",
                                detail: (OnboardingWindowController.wasShown ? "已弹出过" : "还没弹出过")
                                    + "，" + (OnboardingWindowController.isCompleted ? "点过完成" : "没点过完成")
                                    + "。重置后下次启动输入法会再弹一次。",
                                accessory: SettingButton(title: "重置") { [weak self] in
                                    OnboardingWindowController.isCompleted = false
                                    OnboardingWindowController.wasShown = false
                                    self?.reload()
                                }),
            ]),
            SettingsKit.sectionTitle("每一步现在能不能继续"),
            SettingsKit.card([SettingsKit.row(title: "状态", detail: status)]),
        ]
    }
    #endif
}
