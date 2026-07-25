import AppKit
import Foundation

private struct TransferState: Decodable {
    let direction: String?
    let name: String?
    let stage: String?
    let transferred: Int64?
    let total: Int64?
    let message: String?
}

private struct Arguments {
    let stateFile: String
    let cancelFile: String

    static func parse(_ values: [String]) -> Arguments? {
        if values.count == 3 {
            return Arguments(stateFile: values[1], cancelFile: values[2])
        }

        var stateFile: String?
        var cancelFile: String?
        var index = 1
        while index + 1 < values.count {
            switch values[index] {
            case "--state-file", "-StateFile":
                stateFile = values[index + 1]
            case "--cancel-file", "-CancelFile":
                cancelFile = values[index + 1]
            default:
                break
            }
            index += 2
        }

        guard let stateFile, let cancelFile else {
            return nil
        }
        return Arguments(stateFile: stateFile, cancelFile: cancelFile)
    }
}

private struct SpeedSample {
    let at: Date
    let bytes: Int64
}

private final class ProgressController: NSObject, NSWindowDelegate {
    private let stateURL: URL
    private let cancelURL: URL
    private let window: NSWindow
    private let directionLabel = NSTextField(labelWithString: "文件传输")
    private let stageLabel = NSTextField(labelWithString: "等待传输状态…")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let nameLabel = NSTextField(labelWithString: "正在准备文件…")
    private let progress = NSProgressIndicator()
    private let amountLabel = NSTextField(labelWithString: "0 B")
    private let rateLabel = NSTextField(labelWithString: "正在计算速度")
    private let statusBox = NSBox()
    private let statusTitle = NSTextField(labelWithString: "等待传输状态…")
    private let messageLabel = NSTextField(labelWithString: "等待传输状态…")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var timer: Timer?
    private var samples: [SpeedSample] = []
    private var lastName = ""
    private var lastTransferred: Int64 = -1
    private var terminalAt: Date?
    private var isTerminal = false

    init(stateFile: String, cancelFile: String) {
        stateURL = URL(fileURLWithPath: stateFile)
        cancelURL = URL(fileURLWithPath: cancelFile)

        let rect = NSRect(x: 0, y: 0, width: 520, height: 318)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        super.init()
        configureWindow()
        configureControls()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        poll()

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func configureWindow() {
        window.title = "MacWinClip"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor
    }

    private func configureControls() {
        guard let content = window.contentView else {
            return
        }

        directionLabel.frame = NSRect(x: 24, y: 266, width: 350, height: 28)
        directionLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        directionLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(directionLabel)

        percentLabel.frame = NSRect(x: 398, y: 262, width: 98, height: 34)
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .medium)
        percentLabel.textColor = .controlAccentColor
        percentLabel.alignment = .right
        content.addSubview(percentLabel)

        stageLabel.frame = NSRect(x: 24, y: 245, width: 472, height: 18)
        stageLabel.font = .systemFont(ofSize: 12)
        stageLabel.textColor = .secondaryLabelColor
        stageLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(stageLabel)

        nameLabel.frame = NSRect(x: 24, y: 210, width: 472, height: 22)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        content.addSubview(nameLabel)

        progress.frame = NSRect(x: 24, y: 186, width: 472, height: 12)
        progress.style = .bar
        progress.controlSize = .regular
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.setAccessibilityLabel("文件传输进度")
        progress.startAnimation(nil)
        content.addSubview(progress)

        amountLabel.frame = NSRect(x: 24, y: 158, width: 230, height: 18)
        amountLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        amountLabel.textColor = .secondaryLabelColor
        content.addSubview(amountLabel)

        rateLabel.frame = NSRect(x: 254, y: 158, width: 242, height: 18)
        rateLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .right
        rateLabel.lineBreakMode = .byTruncatingHead
        content.addSubview(rateLabel)

        statusBox.frame = NSRect(x: 24, y: 78, width: 472, height: 66)
        statusBox.boxType = .custom
        statusBox.borderColor = .separatorColor
        statusBox.borderWidth = 1
        statusBox.cornerRadius = 8
        statusBox.fillColor = .controlBackgroundColor
        content.addSubview(statusBox)

        statusTitle.frame = NSRect(x: 13, y: 35, width: 444, height: 19)
        statusTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        statusTitle.lineBreakMode = .byTruncatingTail
        statusBox.contentView?.addSubview(statusTitle)

        messageLabel.frame = NSRect(x: 13, y: 10, width: 444, height: 18)
        messageLabel.font = .systemFont(ofSize: 11.5)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        statusBox.contentView?.addSubview(messageLabel)

        cancelButton.frame = NSRect(x: 388, y: 20, width: 108, height: 40)
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .large
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("取消文件传输")
        content.addSubview(cancelButton)
    }

    @objc private func cancelPressed() {
        if isTerminal {
            window.close()
            return
        }

        do {
            try Data("cancel".utf8).write(to: cancelURL, options: .atomic)
            cancelButton.isEnabled = false
            cancelButton.title = "正在取消…"
            statusTitle.stringValue = "正在取消…"
        } catch {
            statusTitle.stringValue = "无法取消传输"
            statusTitle.textColor = .systemRed
            messageLabel.stringValue = error.localizedDescription
        }
    }

    private func poll() {
        let now = Date()
        if let terminalAt, now.timeIntervalSince(terminalAt) >= 4 {
            window.close()
            return
        }

        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(TransferState.self, from: data) else {
            return
        }

        render(state, now: now)
    }

    private func render(_ state: TransferState, now: Date) {
        let stage = state.stage ?? ""
        let stageKey = stage.lowercased()
        let transferred = max(0, state.transferred ?? 0)
        let total = max(0, state.total ?? 0)
        let name = nonempty(state.name) ?? "正在准备文件…"
        let terminal = ["done", "error", "canceled", "cancelled"].contains(stageKey)
        let speed = updateSpeed(transferred: transferred, name: name, now: now)
        var ratio = total > 0 ? min(1, max(0, Double(transferred) / Double(total))) : 0

        if stageKey == "done" {
            ratio = 1
        }

        directionLabel.stringValue = nonempty(state.direction) ?? "文件传输"
        stageLabel.stringValue = stageText(stage)
        nameLabel.stringValue = name
        statusTitle.stringValue = stageText(stage)
        messageLabel.stringValue = nonempty(state.message) ?? stageText(stage)
        percentLabel.stringValue = "\(Int(floor(ratio * 100)))%"
        amountLabel.stringValue = total > 0
            ? "\(formatBytes(transferred)) / \(formatBytes(total))"
            : formatBytes(transferred)

        let indeterminate = !terminal && (total <= 0 || ["preparing", "verifying"].contains(stageKey))
        if progress.isIndeterminate != indeterminate {
            progress.isIndeterminate = indeterminate
            if indeterminate {
                progress.startAnimation(nil)
            } else {
                progress.stopAnimation(nil)
            }
        }
        if !indeterminate {
            progress.doubleValue = ratio
        }

        if speed > 0, !terminal, transferred < total {
            let remaining = Double(total - transferred) / speed
            rateLabel.stringValue = "\(formatBytes(Int64(speed)))/s  预计剩余 \(formatDuration(remaining))"
        } else if terminal {
            rateLabel.stringValue = stageText(stage)
        } else if stageKey == "waiting" {
            rateLabel.stringValue = "等待另一台电脑"
        } else {
            rateLabel.stringValue = "正在计算速度"
        }

        if terminal {
            isTerminal = true
            cancelButton.isEnabled = true
            cancelButton.title = "关闭"
            cancelButton.setAccessibilityLabel("关闭文件传输窗口")
            if terminalAt == nil {
                terminalAt = now
            }

            switch stageKey {
            case "done":
                statusTitle.textColor = .systemGreen
                if nonempty(state.message) == nil {
                    messageLabel.stringValue = "文件已保存并写入剪贴板"
                }
            case "canceled", "cancelled":
                statusTitle.textColor = .secondaryLabelColor
                if nonempty(state.message) == nil {
                    messageLabel.stringValue = "传输已取消"
                }
            default:
                statusTitle.textColor = .systemRed
            }
        } else {
            isTerminal = false
            terminalAt = nil
            statusTitle.textColor = .labelColor
            cancelButton.setAccessibilityLabel("取消文件传输")
        }
    }

    private func updateSpeed(transferred: Int64, name: String, now: Date) -> Double {
        if name != lastName || transferred < lastTransferred {
            samples = [SpeedSample(at: now, bytes: transferred)]
            lastName = name
            lastTransferred = transferred
            return 0
        }

        if samples.isEmpty {
            samples = [SpeedSample(at: now, bytes: transferred)]
            lastName = name
            lastTransferred = transferred
        } else if transferred != lastTransferred {
            samples.append(SpeedSample(at: now, bytes: transferred))
            lastTransferred = transferred
        }

        while samples.count > 1, now.timeIntervalSince(samples[0].at) > 5 {
            samples.removeFirst()
        }

        guard let first = samples.first,
              let last = samples.last,
              last.at > first.at,
              last.bytes >= first.bytes else {
            return 0
        }
        return Double(last.bytes - first.bytes) / last.at.timeIntervalSince(first.at)
    }

    private func stageText(_ stage: String) -> String {
        switch stage.lowercased() {
        case "preparing":
            return "正在准备文件"
        case "transferring", "sending", "receiving":
            return "正在传输文件"
        case "verifying":
            return "正在校验文件"
        case "waiting":
            return "等待另一台电脑"
        case "done":
            return "已完成"
        case "error":
            return "传输失败"
        case "canceled", "cancelled":
            return "已取消"
        default:
            return stage.isEmpty ? "等待传输状态…" : stage
        }
    }

    private func formatBytes(_ value: Int64) -> String {
        let amount = Double(max(0, value))
        if amount >= 1_073_741_824 {
            return String(format: "%.2f GiB", amount / 1_073_741_824)
        }
        if amount >= 1_048_576 {
            return String(format: "%.1f MiB", amount / 1_048_576)
        }
        if amount >= 1_024 {
            return String(format: "%.1f KiB", amount / 1_024)
        }
        return "\(Int64(amount)) B"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let whole = max(0, Int(ceil(seconds)))
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secondsPart = whole % 60
        if hours > 0 {
            return "\(hours) 小时 \(minutes) 分"
        }
        if minutes > 0 {
            return "\(minutes) 分 \(secondsPart) 秒"
        }
        return "\(secondsPart) 秒"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let arguments: Arguments
    private var controller: ProgressController?

    init(arguments: Arguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ProgressController(
            stateFile: arguments.stateFile,
            cancelFile: arguments.cancelFile
        )
        self.controller = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

guard let arguments = Arguments.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(
        Data("Usage: progress-ui <state-file> <cancel-file>\n".utf8)
    )
    exit(2)
}

let application = NSApplication.shared
private let delegate = ApplicationDelegate(arguments: arguments)
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
