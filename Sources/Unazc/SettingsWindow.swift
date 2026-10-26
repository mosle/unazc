import AppKit
import SwiftUI

/// Every option in one window, opened from the menu bar or the call screen's right-click menu. It
/// writes `Options` directly and tells the app through `Actions`, which keeps the menu in step.
/// Main thread only.
final class SettingsWindow {
    struct Actions {
        /// The engine in use and the one loading, if any.
        var engines: () -> (active: Engine?, loading: Engine?)
        var selectEngine: (Engine) -> Void
        var optionsChanged: () -> Void
        var micPolicyChanged: () -> Void
        var isLoginEnabled: () -> Bool
        var setLogin: (Bool) -> Void
        var editVocabulary: () -> Void
        var editSnippets: () -> Void
        var openLog: () -> Void
    }

    private let model: SettingsModel
    private var window: NSWindow?

    init(actions: Actions) {
        model = SettingsModel(actions: actions)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
            window.title = "Unazc の設定"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.setFrameAutosaveName("UnazcSettings")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        // A menu-bar app is not active on its own; without this the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Redraws from the current settings, after something outside the window changed them.
    func refresh() { model.objectWillChange.send() }
}

private final class SettingsModel: ObservableObject {
    let actions: SettingsWindow.Actions
    /// Apps added in the アプリ別 tab that have no option of their own yet (not saved until they do).
    @Published var addedApps: [String] = []

    init(actions: SettingsWindow.Actions) {
        self.actions = actions
    }

    var listedApps: [String] {
        Set(Options.appsWithOverrides + addedApps).sorted { FrontApp.name(of: $0).localizedStandardCompare(FrontApp.name(of: $1)) == .orderedAscending }
    }

    var addableApps: [(id: String, name: String)] {
        let listed = Set(listedApps)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let candidates = apps.compactMap { app -> (id: String, name: String)? in
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !listed.contains(id) else { return nil }
            return (id, app.localizedName ?? FrontApp.name(of: id))
        }
        return Dictionary(candidates, uniquingKeysWith: { a, _ in a }).map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A control bound to a setting: writes it, then lets the app react. `menu: false` is for a
    /// setting the menu and the call screen do not show, so a slider does not rebuild them on every step.
    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void, menu: Bool = true,
                    then: (() -> Void)? = nil) -> Binding<T> {
        Binding(get: get) { [self] value in
            set(value)
            then?()
            // optionsChanged ends in refresh(), which redraws this window.
            if menu { actions.optionsChanged() } else { objectWillChange.send() }
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let engines = model.actions.engines()
        TabView {
            Form {
                Section("認識") {
                    Picker("認識モデル", selection: Binding(get: { engines.loading ?? engines.active ?? Engine.selected }) { engine in
                        model.actions.selectEngine(engine)
                    }) {
                        ForEach(Engine.allCases.filter(\.isInstalled), id: \.self) { Text($0.title).tag($0) }
                    }
                    .disabled(engines.loading != nil)
                    if let loading = engines.loading {
                        Text("\(loading.title) を読み込み中…").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("入力") {
                    Toggle("話している途中の文字を表示する", isOn: model.binding({ Options.liveText }, { Options.liveText = $0 }))
                    Toggle("間で読点「、」を入れる", isOn: model.binding({ Options.pauseComma }, { Options.pauseComma = $0 }))
                    Toggle("語尾が上がったら「？」を付ける", isOn: model.binding({ Options.questionMark }, { Options.questionMark = $0 }))
                    Toggle("「改行」「次の行」とだけ言うと改行", isOn: model.binding({ Options.spokenNewline }, { Options.spokenNewline = $0 }))
                    Toggle("Shiftを押しながら録音を終えると送信（Enter）", isOn: model.binding({ Options.autoSend }, { Options.autoSend = $0 }))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("入力", systemImage: "character.cursor.ibeam") }
            Form {
                Section("録音") {
                    Picker("Fn キーの使い方", selection: model.binding({ Options.recordKeyMode }, { Options.recordKeyMode = $0 })) {
                        ForEach(Options.RecordKeyMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("使った後もマイクを開いておく", selection: model.binding({ Options.micKeepOpenSeconds }, { Options.micKeepOpenSeconds = $0 },
                                                                        then: model.actions.micPolicyChanged)) {
                        ForEach(Self.withCurrent(Options.micKeepOpenChoices, Options.micKeepOpenSeconds), id: \.self) { seconds in
                            Text(Options.micKeepOpenTitle(seconds)).tag(seconds)
                        }
                    }
                    Picker("録音を終えた後も続ける時間", selection: model.binding({ Options.postRollMs }, { Options.postRollMs = $0 })) {
                        ForEach(Self.withCurrent(Options.postRollChoices, Options.postRollMs).sorted(), id: \.self) { ms in
                            Text(Options.postRollTitle(ms)).tag(ms)
                        }
                    }
                    Toggle("話し終えてから録音を終えたときは待たない",
                           isOn: model.binding({ Options.skipPostRollWhenDone }, { Options.skipPostRollWhenDone = $0 }))
                    Toggle("録音中は音楽や動画を一時停止する", isOn: model.binding({ Options.pauseMedia }, { Options.pauseMedia = $0 }))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("録音", systemImage: "mic") }
            Form {
                Section {
                    Menu("アプリを追加") {
                        ForEach(model.addableApps, id: \.id) { app in
                            Button(app.name) { model.addedApps.append(app.id) }
                        }
                    }
                } footer: {
                    Text("録音を始めたとき前面にあったアプリの設定で文字を作ります。メニューバーの「（アプリ名）での設定」からも変えられます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.listedApps, id: \.self) { app in
                    Section {
                        ForEach(Options.TextOption.allCases, id: \.self) { option in
                            Picker(option.title, selection: model.binding({ Options.override(option, app: app) },
                                                                          { Options.setOverride(option, app: app, $0) })) {
                                ForEach([nil, true, false] as [Bool?], id: \.self) { value in
                                    Text(AppController.overrideTitle(value, global: option.global)).tag(value)
                                }
                            }
                        }
                        Button("このアプリの設定を消す") {
                            Options.removeOverrides(app: app)
                            model.addedApps.removeAll { $0 == app }
                            model.actions.optionsChanged()
                        }
                    } header: {
                        Text(FrontApp.name(of: app))
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("アプリ別", systemImage: "app.badge") }
            Form {
                Section {
                    Toggle("間で相槌を返す（イヤホンのときだけ）", isOn: model.binding({ Options.backchannel }, { Options.backchannel = $0 }))
                    LabeledContent("相槌の音量") {
                        Slider(value: model.binding({ Options.backchannelVolume }, { Options.backchannelVolume = $0 }, menu: false), in: 0.1...1)
                    }
                    .disabled(!Options.backchannel)
                    Toggle("電話画面を出す（相手は unazc）", isOn: model.binding({ Options.callWindow }, { Options.callWindow = $0 }))
                    Toggle("電話画面をコンパクトに", isOn: model.binding({ Options.callCompact }, { Options.callCompact = $0 }))
                        .disabled(!Options.callWindow)
                    Toggle("電話画面を常に前面に", isOn: model.binding({ Options.callOnTop }, { Options.callOnTop = $0 }))
                        .disabled(!Options.callWindow)
                    LabeledContent("電話画面の不透明度") {
                        Slider(value: model.binding({ Options.callOpacity }, { Options.callOpacity = $0 }), in: 0.3...1)
                        Text("\(Int((Options.callOpacity * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    .disabled(!Options.callWindow)
                } header: {
                    Text("おまけ（実験的）")
                } footer: {
                    Text("使わなくても音声入力はそのまま使えます。相槌のタイミングはまだ粗めです（黙ってから約0.25秒で鳴ります）。電話画面を右クリックしても、この設定を開けます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("おまけ", systemImage: "phone.bubble") }
            Form {
                Section("その他") {
                    Toggle("ログイン時に起動・落ちたら自動で再起動", isOn: Binding(get: model.actions.isLoginEnabled) { on in
                        model.actions.setLogin(on)
                        model.objectWillChange.send()
                    })
                    HStack {
                        Button("置き換え辞書を編集…", action: model.actions.editVocabulary)
                        Button("定型文を編集…", action: model.actions.editSnippets)
                        Button("ログを開く", action: model.actions.openLog)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("その他", systemImage: "gearshape") }
        }
        .padding(.top, 8)
        .frame(minWidth: 460, minHeight: 360)
    }

    /// A value set outside the app (defaults write) is listed too, so the picker tells the truth.
    static func withCurrent(_ choices: [Double], _ current: Double) -> [Double] {
        choices.contains(current) ? choices : choices + [current]
    }
}
