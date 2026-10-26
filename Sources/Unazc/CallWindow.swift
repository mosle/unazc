import AppKit
import SwiftUI

/// The call screen: dictating looks like being on a call with "unazc", who listens while Fn is
/// held and nods at the pauses. Purely a picture; dictation works the same without it.
///
/// It never takes focus (a non-activating panel that cannot become key), so the text still goes to
/// the app the user is typing in. Dragged anywhere; the position is remembered. Main thread only.
final class CallWindow {
    private let panel: NSPanel
    private let model = CallModel()
    var onHangUp: () -> Void = {}
    /// From the right-click menu.
    var onOpenSettings: () -> Void = {}
    var onSetOnTop: (Bool) -> Void = { _ in }
    var onSetOpacity: (Double) -> Void = { _ in }
    var onSetCompact: (Bool) -> Void = { _ in }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        let host = FirstMouseHostingView(rootView: CallView(model: model, actions: CallActions(
            hangUp: { [weak self] in self?.onHangUp() },
            openSettings: { [weak self] in self?.onOpenSettings() },
            setOnTop: { [weak self] in self?.onSetOnTop($0) },
            setOpacity: { [weak self] in self?.onSetOpacity($0) },
            setCompact: { [weak self] in self?.onSetCompact($0) })))
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host
        if !panel.setFrameUsingName("UnazcCall"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 220 - 24, y: screen.maxY - 24))
        }
        panel.setFrameAutosaveName("UnazcCall")
    }

    var isVisible: Bool { panel.isVisible }

    func apply(visible: Bool, onTop: Bool, opacity: Double, compact: Bool) {
        panel.level = onTop ? .floating : .normal
        panel.collectionBehavior = onTop ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.managed]
        panel.alphaValue = opacity
        model.onTop = onTop
        model.opacity = opacity
        model.compact = compact
        // Resized about the top-left corner, so switching keeps the window where it was put.
        let size = CallView.size(compact: compact)
        if panel.frame.size != size {
            let frame = panel.frame
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        if visible, !panel.isVisible {
            model.since = Date()
            panel.orderFrontRegardless()
        } else if !visible, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    func setListening(_ on: Bool) { model.listening = on }

    func nod() { model.nods += 1 }
}

private final class CallModel: ObservableObject {
    @Published var since = Date()
    @Published var listening = false
    @Published var nods = 0
    @Published var onTop = true
    @Published var opacity = 1.0
    @Published var compact = false
}

private struct CallActions {
    var hangUp: () -> Void
    var openSettings: () -> Void
    var setOnTop: (Bool) -> Void
    var setOpacity: (Double) -> Void
    var setCompact: (Bool) -> Void
}

/// Clicks reach the hang-up button even though the panel is never the key window.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct CallView: View {
    @ObservedObject var model: CallModel
    let actions: CallActions

    static func size(compact: Bool) -> NSSize {
        compact ? NSSize(width: 220, height: 60) : NSSize(width: 220, height: 300)
    }

    var body: some View {
        let size = Self.size(compact: model.compact)
        let radius: CGFloat = model.compact ? 16 : 22
        Group {
            if model.compact { compactBody } else { fullBody }
        }
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: radius).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: radius))
        .contextMenu {
            Button("設定…", action: actions.openSettings)
            Divider()
            Toggle("コンパクト表示", isOn: Binding(get: { model.compact }, set: actions.setCompact))
            Toggle("常に前面に", isOn: Binding(get: { model.onTop }, set: actions.setOnTop))
            Picker("不透明度", selection: Binding(get: { model.opacity }, set: actions.setOpacity)) {
                // The current value is listed too when it is not one of the choices (set by the slider).
                ForEach(Options.callOpacityChoices.contains(model.opacity) ? Options.callOpacityChoices
                        : (Options.callOpacityChoices + [model.opacity]).sorted(by: >), id: \.self) { value in
                    Text("\(Int((value * 100).rounded()))%").tag(value)
                }
            }
            Divider()
            Button("電話を切る", action: actions.hangUp)
        }
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            elapsed
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 18)
            Spacer(minLength: 12)
            Avatar(size: 88, listening: model.listening, nods: model.nods)
            Text("unazc")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 14)
            status
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 4)
            Spacer(minLength: 12)
            hangUpButton(size: 52)
                .padding(.bottom, 20)
        }
    }

    /// One line: avatar, name with status or time, hang-up.
    private var compactBody: some View {
        HStack(spacing: 10) {
            Avatar(size: 36, listening: model.listening, nods: model.nods)
            VStack(alignment: .leading, spacing: 1) {
                Text("unazc")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Group {
                    if model.listening { status } else { elapsed }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
            hangUpButton(size: 30)
        }
        .padding(.horizontal, 12)
    }

    private var elapsed: some View {
        TimelineView(.periodic(from: model.since, by: 1)) { context in
            Text(Self.elapsed(from: model.since, to: context.date))
        }
    }

    private var status: some View {
        Text(model.listening ? "聞いています…" : "Fn を押して話す")
    }

    private func hangUpButton(size: CGFloat) -> some View {
        Button(action: actions.hangUp) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.red))
        }
        .buttonStyle(.plain)
        .help("電話画面を閉じる")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// unazc's face: the app icon in a circle that nods when `nods` changes, with a slow pulsing ring
/// while listening, the way a call app shows the other side listening.
private struct Avatar: View {
    let size: CGFloat
    let listening: Bool
    let nods: Int
    /// Driven from `listening` on appear as well as on change: switching between full and compact
    /// makes a new avatar mid-recording, which would otherwise never see `listening` change.
    @State private var pulsing = false

    var body: some View {
        // The nod is in points; scaled so the small avatar nods as visibly as the large one.
        let unit = size / 88
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(listening ? 0.55 : 0), lineWidth: max(2, 3 * unit))
                .frame(width: size * 1.18, height: size * 1.18)
                .scaleEffect(pulsing ? 1.08 : 1)
                .onAppear { pulse(listening) }
                .onChange(of: listening) { _, on in pulse(on) }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: size, height: size)
                // The icon's rounded square has a transparent margin; enlarged, its face fills the circle.
                .scaleEffect(1.3)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .keyframeAnimator(initialValue: Nod(), trigger: nods) { content, nod in
                    content
                        .rotationEffect(.degrees(nod.tilt), anchor: .bottom)
                        .offset(y: nod.drop * unit)
                } keyframes: { _ in
                    KeyframeTrack(\.drop) {
                        CubicKeyframe(5, duration: 0.12)
                        CubicKeyframe(0, duration: 0.16)
                        CubicKeyframe(3, duration: 0.12)
                        CubicKeyframe(0, duration: 0.2)
                    }
                    KeyframeTrack(\.tilt) {
                        CubicKeyframe(4, duration: 0.12)
                        CubicKeyframe(0, duration: 0.16)
                        CubicKeyframe(2, duration: 0.12)
                        CubicKeyframe(0, duration: 0.2)
                    }
                }
        }
    }

    private func pulse(_ on: Bool) {
        withAnimation(on ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.2)) {
            pulsing = on
        }
    }

    private struct Nod {
        var drop: Double = 0
        var tilt: Double = 0
    }
}
