import SwiftTerm
import SwiftUI
import UIKit

struct TerminalView: UIViewRepresentable {
    func makeUIView(context _: Context) -> LinuxTerminalView {
        LinuxTerminalView(frame: .zero)
    }

    func updateUIView(_: LinuxTerminalView, context _: Context) {}

    static func dismantleUIView(_ view: LinuxTerminalView, coordinator _: Void) {
        view.stop()
        view.updateUiClosed()
    }
}

@MainActor
final class LinuxTerminalView: SwiftTerm.TerminalView, TerminalViewDelegate {
    private let backend = QEMUTerminalBackend()

    override init(frame: CGRect) {
        super.init(frame: frame, font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        terminalDelegate = self
        nativeBackgroundColor = UIColor(red: 0.035, green: 0.047, blue: 0.055, alpha: 1)
        nativeForegroundColor = UIColor(red: 0.78, green: 0.9, blue: 0.8, alpha: 1)
        caretColor = UIColor(red: 0.55, green: 1, blue: 0.65, alpha: 1)
        optionAsMetaKey = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            backend.start { [weak self] data in
                let bytes = [UInt8](data)
                Task { @MainActor [weak self] in
                    self?.feedSender.feed(byteArray: bytes[...])
                }
            }
            _ = becomeFirstResponder()
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func send(source _: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        backend.send(Data(data))
    }

    func sizeChanged(source _: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        backend.resize(columns: newCols, rows: newRows)
    }

    func stop() {
        backend.stop()
    }

    func setTerminalTitle(source _: SwiftTerm.TerminalView, title _: String) {}

    func hostCurrentDirectoryUpdate(source _: SwiftTerm.TerminalView, directory _: String?) {}

    func scrolled(source _: SwiftTerm.TerminalView, position _: Double) {}

    func requestOpenLink(source _: SwiftTerm.TerminalView, link: String, params _: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func bell(source _: SwiftTerm.TerminalView) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func clipboardCopy(source _: SwiftTerm.TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }

    func rangeChanged(source _: SwiftTerm.TerminalView, startY _: Int, endY _: Int) {}
}
