import AppKit
import Foundation

enum ClipboardError: Error {
    case invalidArguments
    case invalidText
    case invalidImage
    case unsupportedType
}

func writePayload(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func exportClipboard(to path: String) throws {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount

    if let png = pasteboard.data(forType: .png) {
        try writePayload(png, to: path)
        print("\(changeCount) PNG \(png.count)")
        return
    }

    if
        let tiff = pasteboard.data(forType: .tiff),
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    {
        try writePayload(png, to: path)
        print("\(changeCount) PNG \(png.count)")
        return
    }

    if let text = pasteboard.string(forType: .string) {
        let data = Data(text.utf8)
        try writePayload(data, to: path)
        print("\(changeCount) TEXT \(data.count)")
        return
    }

    try? FileManager.default.removeItem(atPath: path)
    print("\(changeCount) EMPTY 0")
}

func importClipboard(type: String, from path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()

    switch type {
    case "TEXT":
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClipboardError.invalidText
        }
        guard pasteboard.setString(text, forType: .string) else {
            throw ClipboardError.invalidText
        }

    case "PNG":
        guard
            let image = NSImage(data: data),
            let tiff = image.tiffRepresentation
        else {
            throw ClipboardError.invalidImage
        }
        guard
            pasteboard.setData(data, forType: .png),
            pasteboard.setData(tiff, forType: .tiff)
        else {
            throw ClipboardError.invalidImage
        }

    default:
        throw ClipboardError.unsupportedType
    }

    print(pasteboard.changeCount)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw ClipboardError.invalidArguments
    }

    switch arguments[1] {
    case "change-count":
        guard arguments.count == 2 else {
            throw ClipboardError.invalidArguments
        }
        print(NSPasteboard.general.changeCount)

    case "export":
        guard arguments.count == 3 else {
            throw ClipboardError.invalidArguments
        }
        try exportClipboard(to: arguments[2])

    case "import":
        guard arguments.count == 4 else {
            throw ClipboardError.invalidArguments
        }
        try importClipboard(type: arguments[2], from: arguments[3])

    default:
        throw ClipboardError.invalidArguments
    }
} catch {
    fputs("clipboard-helper failed\n", stderr)
    exit(1)
}
