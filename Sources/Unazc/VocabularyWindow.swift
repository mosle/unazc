import AppKit
import SwiftUI

/// A small window for adding one entry to the replacement dictionary, opened with Fn+D or from the
/// menu with the last dictation filled in, to be trimmed down to the misrecognized part. Main thread.
final class VocabularyWindow {
    private let model = VocabularyModel()
    private var window: NSWindow?

    func show(from text: String) {
        model.from = text
        model.to = ""
        model.error = nil
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.title = "置き換え辞書に登録"
            window.isReleasedWhenClosed = false
            window.level = .floating
            model.close = { [weak window] in window?.close() }
            window.contentView = NSHostingView(rootView: VocabularyView(model: model))
            window.center()
            self.window = window
        }
        // A menu-bar app is not active on its own; without this the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        model.focus += 1
    }
}

private final class VocabularyModel: ObservableObject {
    // An error is about what was typed, so it goes once the text changes.
    @Published var from = "" { didSet { error = nil } }
    @Published var to = "" { didSet { error = nil } }
    @Published var error: String?
    /// Bumped on every show, so the first field takes focus again.
    @Published var focus = 0
    var close: () -> Void = {}

    var existing: String? { Vocabulary.existing(from) }

    func register() {
        do {
            try Vocabulary.register(from, to)
            close()
        } catch let error as Vocabulary.RegisterError {
            self.error = error.message
        } catch {
            self.error = "書き込めませんでした: \(error.localizedDescription)"
        }
    }
}

private struct VocabularyView: View {
    @ObservedObject var model: VocabularyModel
    @FocusState private var fromFocused: Bool

    var body: some View {
        Form {
            TextField("認識された文字", text: $model.from)
                .focused($fromFocused)
            // Return is the default button's.
            TextField("入れたい文字", text: $model.to)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let existing = model.existing {
                Text("いまは「\(existing)」に置き換えています。登録すると上書きします。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("認識された文字は、間違えた部分だけに縮めてください。次の発話から効きます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("キャンセル", action: model.close).keyboardShortcut(.cancelAction)
                Button("登録", action: model.register).keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420)
        .onChange(of: model.focus) { fromFocused = true }
        .onAppear { fromFocused = true }
    }
}
