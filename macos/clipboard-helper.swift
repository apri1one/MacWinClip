import AppKit
import CryptoKit
import Darwin
import Foundation

enum ClipboardError: Error {
    case invalidArguments
    case invalidText
    case invalidImage
    case invalidManifest
    case unsupportedType
}

struct FileEntry: Codable {
    var index: Int
    var name: String
    var size: Int64
    var sha256: String
    var sourcePath: String?
}

struct FileManifest: Codable {
    var version: Int
    var id: String
    var totalBytes: Int64
    var files: [FileEntry]
}

func writePayload(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func readManifest(_ path: String) throws -> FileManifest {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let manifest = try JSONDecoder().decode(FileManifest.self, from: data)
    guard
        manifest.version == 1,
        !manifest.files.isEmpty,
        manifest.files.count <= 1000,
        manifest.id.isEmpty || manifest.id.range(
            of: "^[a-f0-9]{32}$",
            options: .regularExpression
        ) != nil
    else {
        throw ClipboardError.invalidManifest
    }

    var total: Int64 = 0
    var used = Set<String>()
    for (expectedIndex, entry) in manifest.files.enumerated() {
        let addition = total.addingReportingOverflow(entry.size)
        guard
            entry.index == expectedIndex,
            entry.size >= 0,
            !addition.overflow,
            addition.partialValue <= 10 * 1024 * 1024 * 1024,
            safeFileName(entry.name, used: &used) == entry.name,
            entry.sha256.isEmpty || entry.sha256.range(
                of: "^[a-f0-9]{64}$",
                options: .regularExpression
            ) != nil,
            entry.sourcePath == nil || entry.sourcePath?.hasPrefix("/") == true
        else {
            throw ClipboardError.invalidManifest
        }
        total = addition.partialValue
    }
    guard total > 0, total == manifest.totalBytes else {
        throw ClipboardError.invalidManifest
    }
    return manifest
}

func writeManifest(_ manifest: FileManifest, to path: String) throws {
    let data = try JSONEncoder().encode(manifest)
    try writePayload(data, to: path)
}

func safeFileName(_ original: String, used: inout Set<String>) -> String {
    let forbidden = CharacterSet.controlCharacters.union(
        CharacterSet(charactersIn: "<>:\"/\\|?*")
    )
    var scalars = String.UnicodeScalarView()
    for scalar in original.unicodeScalars {
        scalars.append(forbidden.contains(scalar) ? "_" : scalar)
    }
    var candidate = String(scalars)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    while candidate.hasSuffix(".") || candidate.hasSuffix(" ") {
        candidate.removeLast()
    }
    if candidate.isEmpty {
        candidate = "file"
    }

    let stemUpper = (candidate as NSString)
        .deletingPathExtension
        .uppercased()
    let reserved = ["CON", "PRN", "AUX", "NUL"] +
        (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
    if reserved.contains(stemUpper) {
        candidate = "_\(candidate)"
    }

    let base = (candidate as NSString).deletingPathExtension
    let extensionName = (candidate as NSString).pathExtension
    var unique = candidate
    var suffix = 2
    while used.contains(unique.lowercased()) {
        unique = extensionName.isEmpty
            ? "\(base) (\(suffix))"
            : "\(base) (\(suffix)).\(extensionName)"
        suffix += 1
    }
    used.insert(unique.lowercased())
    return unique
}

func sha256(of path: String) throws -> String {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw ClipboardError.invalidManifest
    }
    defer { Darwin.close(descriptor) }

    var information = Darwin.stat()
    guard
        Darwin.fstat(descriptor, &information) == 0,
        information.st_mode & S_IFMT == S_IFREG
    else {
        throw ClipboardError.invalidManifest
    }

    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            throw ClipboardError.invalidManifest
        }
        hasher.update(data: Data(buffer[0..<count]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func copyAndHash(source: String, destination: String, cancelPath: String) throws -> (String, Int64) {
    let sourceDescriptor = Darwin.open(source, O_RDONLY | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else {
        throw ClipboardError.invalidManifest
    }
    defer { Darwin.close(sourceDescriptor) }

    var information = Darwin.stat()
    guard
        Darwin.fstat(sourceDescriptor, &information) == 0,
        information.st_mode & S_IFMT == S_IFREG
    else {
        throw ClipboardError.invalidManifest
    }

    let destinationDescriptor = Darwin.open(
        destination,
        O_WRONLY | O_CREAT | O_EXCL,
        mode_t(S_IRUSR | S_IWUSR)
    )
    guard destinationDescriptor >= 0 else {
        throw ClipboardError.invalidManifest
    }
    var completed = false
    defer {
        Darwin.close(destinationDescriptor)
        if !completed {
            try? FileManager.default.removeItem(atPath: destination)
        }
    }

    var hasher = SHA256()
    var total: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
        if FileManager.default.fileExists(atPath: cancelPath) {
            throw ClipboardError.invalidManifest
        }
        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR {
                continue
            }
            throw ClipboardError.invalidManifest
        }

        var written = 0
        while written < count {
            let result = buffer.withUnsafeBytes {
                Darwin.write(
                    destinationDescriptor,
                    $0.baseAddress?.advanced(by: written),
                    count - written
                )
            }
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw ClipboardError.invalidManifest
            }
            written += result
        }
        hasher.update(data: Data(buffer[0..<count]))
        total += Int64(count)
    }

    completed = true
    let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (hash, total)
}

func exportFileClipboard(_ urls: [URL], changeCount: Int, to path: String) throws {
    var entries: [FileEntry] = []
    var total: Int64 = 0
    var used = Set<String>()

    for (index, url) in urls.enumerated() {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClipboardError.unsupportedType
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.size] as? NSNumber else {
            throw ClipboardError.invalidManifest
        }
        let size = number.int64Value
        let addition = total.addingReportingOverflow(size)
        guard !addition.overflow else {
            throw ClipboardError.invalidManifest
        }
        total = addition.partialValue
        entries.append(
            FileEntry(
                index: index,
                name: safeFileName(url.lastPathComponent, used: &used),
                size: size,
                sha256: "",
                sourcePath: url.path
            )
        )
    }

    guard total > 0 else {
        throw ClipboardError.unsupportedType
    }
    let manifest = FileManifest(
        version: 1,
        id: "",
        totalBytes: total,
        files: entries
    )
    try writeManifest(manifest, to: path)
    print("\(changeCount) FILES \(total)")
}

func exportClipboard(to path: String) throws {
    let pasteboard = NSPasteboard.general
    let changeCount = pasteboard.changeCount
    let options: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true
    ]
    let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    if
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL],
        !objects.isEmpty
    {
        try exportFileClipboard(
            objects.map { $0 as URL },
            changeCount: changeCount,
            to: path
        )
        return
    }
    if
        let filePaths = pasteboard.propertyList(forType: fileNamesType) as? [String],
        !filePaths.isEmpty
    {
        try exportFileClipboard(
            filePaths.map { URL(fileURLWithPath: $0) },
            changeCount: changeCount,
            to: path
        )
        return
    }

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

func setFileClipboard(manifestPath: String, directory: String) throws -> Int {
    let manifest = try readManifest(manifestPath)
    let urls = manifest.files.map {
        URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent($0.name, isDirectory: false)
    }
    guard !urls.isEmpty, urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
        throw ClipboardError.invalidManifest
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else {
        throw ClipboardError.unsupportedType
    }
    return pasteboard.changeCount
}

func importFiles(manifestPath: String, directory: String) throws {
    print(try setFileClipboard(manifestPath: manifestPath, directory: directory))
}

func ownFiles(manifestPath: String, directory: String, pidPath: String) throws {
    guard pidPath.hasPrefix("/") else {
        throw ClipboardError.invalidArguments
    }
    defer {
        try? FileManager.default.removeItem(atPath: pidPath)
    }
    let changeCount = try setFileClipboard(
        manifestPath: manifestPath,
        directory: directory
    )
    print(changeCount)
    fflush(stdout)
    while NSPasteboard.general.changeCount == changeCount {
        Thread.sleep(forTimeInterval: 0.25)
    }
}

func setManifestId(path: String, id: String) throws {
    guard id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
        throw ClipboardError.invalidManifest
    }
    var manifest = try readManifest(path)
    manifest.id = id
    try writeManifest(manifest, to: path)
}

func buildPublicManifest(privatePath: String, publicPath: String) throws {
    let privateManifest = try readManifest(privatePath)
    guard privateManifest.id.range(
        of: "^[a-f0-9]{32}$",
        options: .regularExpression
    ) != nil else {
        throw ClipboardError.invalidManifest
    }
    var publicEntries: [FileEntry] = []
    for entry in privateManifest.files {
        guard let sourcePath = entry.sourcePath else {
            throw ClipboardError.invalidManifest
        }
        publicEntries.append(
            FileEntry(
                index: entry.index,
                name: entry.name,
                size: entry.size,
                sha256: try sha256(of: sourcePath),
                sourcePath: nil
            )
        )
    }
    try writeManifest(
        FileManifest(
            version: 1,
            id: privateManifest.id,
            totalBytes: privateManifest.totalBytes,
            files: publicEntries
        ),
        to: publicPath
    )
}

func buildOfferManifest(privatePath: String, offerPath: String) throws {
    let privateManifest = try readManifest(privatePath)
    guard privateManifest.id.range(
        of: "^[a-f0-9]{32}$",
        options: .regularExpression
    ) != nil else {
        throw ClipboardError.invalidManifest
    }
    let offerEntries = privateManifest.files.map {
        FileEntry(
            index: $0.index,
            name: $0.name,
            size: $0.size,
            sha256: "",
            sourcePath: nil
        )
    }
    try writeManifest(
        FileManifest(
            version: 1,
            id: privateManifest.id,
            totalBytes: privateManifest.totalBytes,
            files: offerEntries
        ),
        to: offerPath
    )
}

func stageManifest(
    privatePath: String,
    publicPath: String,
    stagingDirectory: String,
    cancelPath: String
) throws {
    let privateManifest = try readManifest(privatePath)
    guard privateManifest.id.range(
        of: "^[a-f0-9]{32}$",
        options: .regularExpression
    ) != nil else {
        throw ClipboardError.invalidManifest
    }

    try FileManager.default.createDirectory(
        atPath: stagingDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    do {
        var publicEntries: [FileEntry] = []
        for entry in privateManifest.files {
            guard let sourcePath = entry.sourcePath else {
                throw ClipboardError.invalidManifest
            }
            let stagedPath = URL(
                fileURLWithPath: stagingDirectory,
                isDirectory: true
            ).appendingPathComponent(
                String(format: "%06d.payload", entry.index),
                isDirectory: false
            ).path
            let (hash, copiedBytes) = try copyAndHash(
                source: sourcePath,
                destination: stagedPath,
                cancelPath: cancelPath
            )
            guard copiedBytes == entry.size else {
                throw ClipboardError.invalidManifest
            }
            publicEntries.append(
                FileEntry(
                    index: entry.index,
                    name: entry.name,
                    size: entry.size,
                    sha256: hash,
                    sourcePath: nil
                )
            )
        }
        try writeManifest(
            FileManifest(
                version: 1,
                id: privateManifest.id,
                totalBytes: privateManifest.totalBytes,
                files: publicEntries
            ),
            to: publicPath
        )
    } catch {
        try? FileManager.default.removeItem(atPath: stagingDirectory)
        throw error
    }
}

func printPlan(_ path: String) throws {
    let manifest = try readManifest(path)
    for entry in manifest.files {
        let name = Data(entry.name.utf8).base64EncodedString()
        let source = entry.sourcePath.map {
            Data($0.utf8).base64EncodedString()
        } ?? "-"
        let hash = entry.sha256.isEmpty ? "-" : entry.sha256
        print("\(entry.index)\t\(name)\t\(entry.size)\t\(hash)\t\(source)")
    }
}

func writeProgress(
    path: String,
    stage: String,
    transferred: Int64,
    total: Int64,
    name: String,
    message: String,
    direction: String
) throws {
    let object: [String: Any] = [
        "stage": stage,
        "direction": direction,
        "transferred": transferred,
        "total": total,
        "name": name,
        "message": message,
        "updatedUtc": ISO8601DateFormatter().string(from: Date())
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    try writePayload(data, to: path)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else {
        throw ClipboardError.invalidArguments
    }

    switch arguments[1] {
    case "change-count":
        guard arguments.count == 2 else { throw ClipboardError.invalidArguments }
        print(NSPasteboard.general.changeCount)

    case "export":
        guard arguments.count == 3 else { throw ClipboardError.invalidArguments }
        try exportClipboard(to: arguments[2])

    case "import":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        try importClipboard(type: arguments[2], from: arguments[3])

    case "import-files":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        try importFiles(manifestPath: arguments[2], directory: arguments[3])

    case "own-files":
        guard arguments.count == 5 else { throw ClipboardError.invalidArguments }
        try ownFiles(
            manifestPath: arguments[2],
            directory: arguments[3],
            pidPath: arguments[4]
        )

    case "set-id":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        try setManifestId(path: arguments[2], id: arguments[3])

    case "public-manifest":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        try buildPublicManifest(privatePath: arguments[2], publicPath: arguments[3])

    case "offer-manifest":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        try buildOfferManifest(privatePath: arguments[2], offerPath: arguments[3])

    case "stage-manifest":
        guard arguments.count == 6 else { throw ClipboardError.invalidArguments }
        try stageManifest(
            privatePath: arguments[2],
            publicPath: arguments[3],
            stagingDirectory: arguments[4],
            cancelPath: arguments[5]
        )

    case "manifest-total":
        guard arguments.count == 3 else { throw ClipboardError.invalidArguments }
        print(try readManifest(arguments[2]).totalBytes)

    case "manifest-id":
        guard arguments.count == 3 else { throw ClipboardError.invalidArguments }
        print(try readManifest(arguments[2]).id)

    case "manifest-plan":
        guard arguments.count == 3 else { throw ClipboardError.invalidArguments }
        try printPlan(arguments[2])

    case "verify-file":
        guard arguments.count == 4 else { throw ClipboardError.invalidArguments }
        guard try sha256(of: arguments[2]) == arguments[3] else {
            throw ClipboardError.invalidManifest
        }

    case "progress-write":
        guard arguments.count == 9 else { throw ClipboardError.invalidArguments }
        guard
            let transferred = Int64(arguments[4]),
            let total = Int64(arguments[5])
        else {
            throw ClipboardError.invalidArguments
        }
        try writeProgress(
            path: arguments[2],
            stage: arguments[3],
            transferred: transferred,
            total: total,
            name: arguments[6],
            message: arguments[7],
            direction: arguments[8]
        )

    default:
        throw ClipboardError.invalidArguments
    }
} catch {
    fputs("clipboard-helper failed\n", stderr)
    exit(1)
}
