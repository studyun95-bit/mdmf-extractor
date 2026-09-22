import AppKit
import UniformTypeIdentifiers

final class DropArea: NSView {
    var onFiles: (([URL]) -> Void)?
    var highlighted = false { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: NSRect) {
        let area = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: area, xRadius: 18, yRadius: 18)
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (highlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = highlighted ? 2 : 1
        path.stroke()
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = !urls(sender).isEmpty
        return highlighted ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        onFiles?(files)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var log: NSTextView!
    private var chooseButton: NSButton!
    private var folderButton: NSButton!
    private var revealButton: NSButton!
    private var openButton: NSButton!
    private var folderLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var outputFolder: URL?
    private var outputs: [URL] = []
    private var pdfOutputs: [URL] = []
    private var pending: [URL] = []
    private var running = false
    private var failureCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenu()
        makeWindow()
        if !pending.isEmpty { let files = pending; pending.removeAll(); process(files) }
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let files = filenames.map { URL(fileURLWithPath: $0) }
        if window == nil { pending.append(contentsOf: files) } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            process(files)
        }
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !running }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }
    private func makeMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "MDMF 파일 추출기 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
        bar.addItem(fileItem)
        let fileMenu = NSMenu(title: "파일")
        let openItem = fileMenu.addItem(withTitle: "MDMF 파일 선택…", action: #selector(chooseFiles), keyEquivalent: "o")
        openItem.target = self
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = bar
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 610), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MDMF 파일 추출기"
        window.isReleasedWhenClosed = false
        let root = NSView()
        window.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24)
        ])
        stack.addArrangedSubview(label("MDMF → 공문 + 모든 붙임파일", size: 29, weight: .bold))
        let subtitle = label("PDF · HWP · HWPX · ZIP · 엑셀 등 포함된 파일을 그대로 꺼냅니다.", size: 14)
        subtitle.textColor = .secondaryLabelColor
        stack.addArrangedSubview(subtitle)
        let drop = DropArea(frame: .zero)
        drop.translatesAutoresizingMaskIntoConstraints = false
        drop.onFiles = { [weak self] in self?.process($0) }
        stack.addArrangedSubview(drop)
        NSLayoutConstraint.activate([drop.widthAnchor.constraint(equalTo: stack.widthAnchor), drop.heightAnchor.constraint(equalToConstant: 180)])
        let dropStack = NSStackView()
        dropStack.orientation = .vertical
        dropStack.alignment = .centerX
        dropStack.spacing = 12
        dropStack.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        dropStack.addArrangedSubview(icon)
        dropStack.addArrangedSubview(label("MDMF 파일을 여기에 놓으세요", size: 16, weight: .semibold))
        chooseButton = NSButton(title: "파일 선택…", target: self, action: #selector(chooseFiles))
        chooseButton.bezelStyle = .rounded
        dropStack.addArrangedSubview(chooseButton)
        drop.addSubview(dropStack)
        NSLayoutConstraint.activate([dropStack.centerXAnchor.constraint(equalTo: drop.centerXAnchor), dropStack.centerYAnchor.constraint(equalTo: drop.centerYAnchor)])
        let folderRow = NSStackView()
        folderRow.orientation = .horizontal
        folderRow.spacing = 10
        folderLabel = label("저장 위치: 원본 파일과 같은 폴더", size: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderRow.addArrangedSubview(folderLabel)
        folderButton = NSButton(title: "변경…", target: self, action: #selector(chooseFolder))
        folderButton.bezelStyle = .rounded
        folderRow.addArrangedSubview(folderButton)
        stack.addArrangedSubview(folderRow)
        folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusRow.addArrangedSubview(progress)
        status = label("파일을 선택하면 추출을 시작합니다.", size: 13, weight: .medium)
        statusRow.addArrangedSubview(status)
        stack.addArrangedSubview(statusRow)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        log = NSTextView()
        log.isEditable = false
        log.isSelectable = true
        log.font = .systemFont(ofSize: 12)
        log.textContainerInset = NSSize(width: 10, height: 10)
        log.isHorizontallyResizable = false
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        scroll.documentView = log
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        openButton = NSButton(title: "PDF 열기", target: self, action: #selector(openPDF))
        revealButton = NSButton(title: "Finder에서 보기", target: self, action: #selector(revealPDF))
        for button in [openButton!, revealButton!] { button.bezelStyle = .rounded; button.isEnabled = false; actions.addArrangedSubview(button) }
        stack.addArrangedSubview(actions)
        let footer = label("여러 파일 선택 가능 · 인터넷 전송 없음 · 같은 이름은 번호를 붙여 저장", size: 11)
        footer.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(footer)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func chooseFiles() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.title = "공문과 붙임파일을 추출할 MDMF 파일 선택"
        panel.allowedContentTypes = [UTType(filenameExtension: "mdmf") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "추출"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.process(panel.urls) }
        }
    }
    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "추출한 파일을 저장할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "선택"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.outputFolder = url
            self?.folderLabel.stringValue = "저장 위치: \(url.path)"
            self?.folderLabel.toolTip = url.path
        }
    }
    private func process(_ urls: [URL], continuing: Bool = false) {
        guard !urls.isEmpty else { return }
        if running { pending.append(contentsOf: urls); return }
        running = true
        if !continuing {
            outputs = []
            pdfOutputs = []
            failureCount = 0
            log.string = ""
        }
        chooseButton.isEnabled = false
        folderButton.isEnabled = false
        openButton.isEnabled = false
        revealButton.isEnabled = false
        progress.startAnimation(nil)
        status.stringValue = "\(urls.count)개 MDMF에서 공문과 붙임파일을 추출하고 있습니다…"
        let destination = outputFolder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var results: [ExtractionResult] = []
            var messages: [String] = []
            for url in urls {
                do {
                    let result = try MDMFExtractor.extract(url, outputDirectory: destination)
                    results.append(result)
                    messages.append("✓ \(result.outputURL.lastPathComponent)  ·  \(result.pageCount)페이지")
                    for attachment in result.attachmentURLs {
                        messages.append("✓ \(attachment.lastPathComponent)  ·  붙임파일")
                    }
                } catch {
                    messages.append("실패 · \(url.lastPathComponent)\n\(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = false
                self.outputs.append(contentsOf: results.flatMap(\.outputURLs))
                self.pdfOutputs.append(contentsOf: results.map(\.outputURL))
                self.failureCount += urls.count - results.count
                self.log.string += (self.log.string.isEmpty ? "" : "\n\n") + messages.joined(separator: "\n\n")
                self.status.stringValue = "추출 완료 · PDF \(self.pdfOutputs.count)개 · 붙임 \(self.outputs.count - self.pdfOutputs.count)개" + (self.failureCount > 0 ? " · 실패 \(self.failureCount)개" : "")
                self.progress.stopAnimation(nil)
                self.chooseButton.isEnabled = true
                self.folderButton.isEnabled = true
                self.openButton.isEnabled = !self.pdfOutputs.isEmpty
                self.revealButton.isEnabled = !self.outputs.isEmpty
                if !self.pending.isEmpty {
                    let next = self.pending
                    self.pending.removeAll()
                    self.process(next, continuing: true)
                }
            }
        }
    }
    @objc private func openPDF() { for url in pdfOutputs { NSWorkspace.shared.open(url) } }
    @objc private func revealPDF() { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
}

func runCLI(_ args: [String]) -> Int32 {
    if args.contains("--help") || args.contains("-h") {
        print("""
        MDMF 파일 추출기 1.1 — PDF + 붙임파일
        사용법: mdmf-extract --extract 파일.mdmf [파일2.mdmf ...] [--output-dir 폴더]
        기본 저장 위치는 원본 폴더입니다. 기존 파일은 덮어쓰지 않습니다.
        지원: MarkAny MDMFILEFXC v11, 헤더 2227바이트인 PDF 본문 및 포함된 붙임파일.
        """)
        return 0
    }
    var files: [URL] = []
    var output: URL?
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--extract" { index += 1; continue }
        if arg == "--output-dir" {
            index += 1
            guard index < args.count else { fputs("오류: --output-dir 뒤에 폴더를 지정하세요.\n", stderr); return 2 }
            output = URL(fileURLWithPath: args[index], isDirectory: true)
        } else if arg.hasPrefix("--") {
            fputs("오류: 알 수 없는 옵션 \(arg)\n", stderr); return 2
        } else { files.append(URL(fileURLWithPath: arg)) }
        index += 1
    }
    guard !files.isEmpty else { fputs("오류: 추출할 MDMF 파일을 지정하세요.\n", stderr); return 2 }
    var failed = false
    for file in files {
        do {
            let result = try MDMFExtractor.extract(file, outputDirectory: output)
            print("\(result.outputURL.path) (\(result.pageCount)페이지)")
            for attachment in result.attachmentURLs {
                print("\(attachment.path) (붙임파일)")
            }
        } catch {
            fputs("오류 [\(file.lastPathComponent)]: \(error.localizedDescription)\n", stderr)
            failed = true
        }
    }
    return failed ? 1 : 0
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty && !arguments[0].hasPrefix("-psn_") {
    exit(runCLI(arguments))
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
