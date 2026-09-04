import SwiftTerm
import SwiftUI
import UIKit

struct TerminalView: UIViewRepresentable {
    func makeUIView(context _: Context) -> TerminalScrollContainer {
        TerminalScrollContainer(frame: .zero)
    }

    func updateUIView(_: TerminalScrollContainer, context _: Context) {}

    static func dismantleUIView(_ view: TerminalScrollContainer, coordinator _: Void) {
        view.terminalView.updateUiClosed()
    }
}

@MainActor
final class TerminalScrollContainer: UIView, UIScrollViewDelegate {
    let terminalView = LinuxTerminalView(frame: .zero)
    private let scrollView = UIScrollView(frame: .zero)
    private var applyingTerminalPosition = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1)

        scrollView.delegate = self
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = true
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.showsVerticalScrollIndicator = true
        addSubview(scrollView)

        terminalView.isScrollEnabled = false
        terminalView.showsVerticalScrollIndicator = false
        terminalView.scrollContainer = self
        scrollView.addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        pinTerminalToViewport()
        terminalContentSizeDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pinTerminalToViewport()
        guard !applyingTerminalPosition else { return }

        let maximumOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let position = maximumOffset > 0 ? scrollView.contentOffset.y / maximumOffset : 1
        terminalView.scroll(toPosition: Double(min(max(position, 0), 1)))
    }

    func terminalContentSizeDidChange() {
        let position = terminalView.scrollPosition
        let userOwnsScroll = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        scrollView.contentSize = CGSize(
            width: bounds.width,
            height: max(terminalView.contentSize.height, bounds.height)
        )
        if userOwnsScroll {
            pinTerminalToViewport()
            return
        }
        applyTerminalPosition(position)
    }

    func scheduleContentSizeUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.terminalContentSizeDidChange()
        }
    }

    func terminalDidScroll(to position: Double) {
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
        applyTerminalPosition(position)
    }

    private func applyTerminalPosition(_ position: Double) {
        let maximumOffset = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
        let target = CGPoint(x: 0, y: maximumOffset * min(max(position, 0), 1))
        guard abs(scrollView.contentOffset.y - target.y) > 0.5 else { return }

        applyingTerminalPosition = true
        scrollView.setContentOffset(target, animated: false)
        pinTerminalToViewport()
        applyingTerminalPosition = false
    }

    private func pinTerminalToViewport() {
        terminalView.frame = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
    }
}

@MainActor
final class LinuxTerminalView: SwiftTerm.TerminalView, TerminalViewDelegate {
    private static let oneDarkBackground = UIColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1)
    private let backend = QEMUTerminalBackend.shared
    private var foregroundObserver: NSObjectProtocol?
    weak var scrollContainer: TerminalScrollContainer?

    override var contentSize: CGSize {
        didSet {
            scrollContainer?.scheduleContentSizeUpdate()
        }
    }

    override init(frame: CGRect) {
        var options = TerminalOptions.default
        options.scrollback = 10_000
        options.cursorStyle = .steadyBlock
        super.init(
            frame: frame,
            font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            options: options
        )
        terminalDelegate = self
        nativeBackgroundColor = Self.oneDarkBackground
        nativeForegroundColor = UIColor(red: 0.671, green: 0.698, blue: 0.749, alpha: 1)
        caretColor = UIColor(red: 0.322, green: 0.545, blue: 1, alpha: 1)
        installColors([
            SwiftTerm.Color(red8: 0x1E, green8: 0x21, blue8: 0x27),
            SwiftTerm.Color(red8: 0xE0, green8: 0x6C, blue8: 0x75),
            SwiftTerm.Color(red8: 0x98, green8: 0xC3, blue8: 0x79),
            SwiftTerm.Color(red8: 0xE5, green8: 0xC0, blue8: 0x7B),
            SwiftTerm.Color(red8: 0x61, green8: 0xAF, blue8: 0xEF),
            SwiftTerm.Color(red8: 0xC6, green8: 0x78, blue8: 0xDD),
            SwiftTerm.Color(red8: 0x56, green8: 0xB6, blue8: 0xC2),
            SwiftTerm.Color(red8: 0xAB, green8: 0xB2, blue8: 0xBF),
            SwiftTerm.Color(red8: 0x5C, green8: 0x63, blue8: 0x70),
            SwiftTerm.Color(red8: 0xE0, green8: 0x6C, blue8: 0x75),
            SwiftTerm.Color(red8: 0x98, green8: 0xC3, blue8: 0x79),
            SwiftTerm.Color(red8: 0xE5, green8: 0xC0, blue8: 0x7B),
            SwiftTerm.Color(red8: 0x61, green8: 0xAF, blue8: 0xEF),
            SwiftTerm.Color(red8: 0xC6, green8: 0x78, blue8: 0xDD),
            SwiftTerm.Color(red8: 0x56, green8: 0xB6, blue8: 0xC2),
            SwiftTerm.Color(red8: 0xFF, green8: 0xFF, blue8: 0xFF),
        ])
        optionAsMetaKey = true
        keyboardAppearance = .dark
        inputAccessoryView = TerminalKeyboardAccessory(container: self)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.backend.resume()
                _ = self.becomeFirstResponder()
            }
        }
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

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
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

    func scrolled(source _: SwiftTerm.TerminalView, position: Double) {
        scrollContainer?.terminalDidScroll(to: position)
    }

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

@MainActor
private final class TerminalKeyboardAccessory: UIView {
    private weak var terminal: LinuxTerminalView?
    private weak var controlButton: UIButton?
    private var controlResetObserver: NSObjectProtocol?

    init(container: LinuxTerminalView) {
        terminal = container
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = UIColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillProportionally
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(makeButton(title: "esc") { [weak self] in self?.send([0x1B]) })
        let control = makeButton(title: "ctrl") { [weak self] in
            guard let self, let terminal else { return }
            terminal.controlModifier.toggle()
            updateControlButton()
        }
        controlButton = control
        stack.addArrangedSubview(control)
        stack.addArrangedSubview(makeButton(symbol: "arrow.right.to.line.compact") { [weak self] in self?.send([0x09]) })
        for symbol in ["~", "|", "/", "-"] {
            stack.addArrangedSubview(makeButton(title: symbol) { [weak self] in self?.terminal?.insertText(symbol) })
        }
        stack.addArrangedSubview(makeButton(symbol: "arrow.left") { [weak self] in self?.send([0x1B, 0x5B, 0x44]) })
        stack.addArrangedSubview(makeButton(symbol: "arrow.down") { [weak self] in self?.send([0x1B, 0x5B, 0x42]) })
        stack.addArrangedSubview(makeButton(symbol: "arrow.up") { [weak self] in self?.send([0x1B, 0x5B, 0x41]) })
        stack.addArrangedSubview(makeButton(symbol: "arrow.right") { [weak self] in self?.send([0x1B, 0x5B, 0x43]) })
        stack.addArrangedSubview(makeButton(symbol: "keyboard.chevron.compact.down") { [weak self] in
            self?.terminal?.resignFirstResponder()
        })

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        controlResetObserver = NotificationCenter.default.addObserver(
            forName: .terminalViewControlModifierReset,
            object: container,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateControlButton() }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let controlResetObserver {
            NotificationCenter.default.removeObserver(controlResetObserver)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private func makeButton(title: String? = nil, symbol: String? = nil, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        if let symbol {
            button.setImage(UIImage(systemName: symbol), for: .normal)
        }
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        button.tintColor = UIColor.white.withAlphaComponent(0.88)
        button.setTitleColor(UIColor.white.withAlphaComponent(0.88), for: .normal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func send(_ bytes: [UInt8]) {
        UIDevice.current.playInputClick()
        terminal?.send(bytes)
    }

    private func updateControlButton() {
        let selected = terminal?.controlModifier == true
        controlButton?.backgroundColor = selected ? UIColor.systemBlue.withAlphaComponent(0.35) : .clear
        controlButton?.layer.cornerRadius = 9
    }
}
