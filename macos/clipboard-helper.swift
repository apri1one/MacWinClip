import AppKit
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

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
    var kind: String
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
        manifest.version == 2,
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
    var entryKinds: [String: String] = [:]
    for (expectedIndex, entry) in manifest.files.enumerated() {
        guard
            entry.index == expectedIndex,
            entry.kind == "file" || entry.kind == "directory",
            isSafeRelativePath(entry.name)
        else {
            throw ClipboardError.invalidManifest
        }
        let key = entry.name.lowercased()
        guard entryKinds[key] == nil else {
            throw ClipboardError.invalidManifest
        }
        let components = entry.name.split(separator: "/").map(String.init)
        if components.count > 1 {
            let parent = components.dropLast().joined(separator: "/").lowercased()
            guard entryKinds[parent] == "directory" else {
                throw ClipboardError.invalidManifest
            }
        }

        if entry.kind == "directory" {
            guard
                entry.size == 0,
                entry.sha256.isEmpty,
                entry.sourcePath == nil
            else {
                throw ClipboardError.invalidManifest
            }
        } else {
            let addition = total.addingReportingOverflow(entry.size)
            guard
                entry.size >= 0,
                !addition.overflow,
                addition.partialValue <= 10 * 1024 * 1024 * 1024,
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
        entryKinds[key] = entry.kind
    }
    guard total == manifest.totalBytes else {
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

    let reservedPattern =
        "^(CON|PRN|AUX|NUL|COM[1-9\\u00B9\\u00B2\\u00B3]|" +
        "LPT[1-9\\u00B9\\u00B2\\u00B3])(?:\\.|$)"
    if candidate.range(
        of: reservedPattern,
        options: [.regularExpression, .caseInsensitive]
    ) != nil {
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

func isSafeRelativePath(_ path: String) -> Bool {
    guard
        !path.isEmpty,
        !path.hasPrefix("/"),
        !path.contains("\\"),
        path.utf16.count <= 259
    else {
        return false
    }
    let components = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    ).map(String.init)
    guard !components.isEmpty else {
        return false
    }
    for component in components {
        if component == "." || component == ".." {
            return false
        }
        if component.lengthOfBytes(using: .utf8) > 255 {
            return false
        }
        var used = Set<String>()
        if safeFileName(component, used: &used) != component {
            return false
        }
    }
    return true
}

func fileTypeAndSize(_ path: String) throws -> (String, Int64) {
    var information = Darwin.stat()
    guard Darwin.lstat(path, &information) == 0 else {
        throw ClipboardError.invalidManifest
    }
    switch information.st_mode & S_IFMT {
    case S_IFREG:
        return ("file", Int64(information.st_size))
    case S_IFDIR:
        return ("directory", 0)
    case S_IFLNK:
        throw ClipboardError.unsupportedType
    default:
        throw ClipboardError.unsupportedType
    }
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

func appendClipboardEntry(
    url: URL,
    relativePath: String,
    entries: inout [FileEntry],
    total: inout Int64
) throws {
    guard entries.count < 1000, isSafeRelativePath(relativePath) else {
        throw ClipboardError.invalidManifest
    }
    let (kind, size) = try fileTypeAndSize(url.path)
    if kind == "file" {
        let addition = total.addingReportingOverflow(size)
        guard
            size >= 0,
            !addition.overflow,
            addition.partialValue <= 10 * 1024 * 1024 * 1024
        else {
            throw ClipboardError.invalidManifest
        }
        entries.append(
            FileEntry(
                index: entries.count,
                name: relativePath,
                kind: "file",
                size: size,
                sha256: "",
                sourcePath: url.path
            )
        )
        total = addition.partialValue
        return
    }

    entries.append(
        FileEntry(
            index: entries.count,
            name: relativePath,
            kind: "directory",
            size: 0,
            sha256: "",
            sourcePath: nil
        )
    )
    let children = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: []
    ).sorted {
        $0.lastPathComponent.compare(
            $1.lastPathComponent,
            options: [.literal],
            locale: Locale(identifier: "en_US_POSIX")
        ) == .orderedAscending
    }
    var used = Set<String>()
    for child in children {
        let safeName = safeFileName(child.lastPathComponent, used: &used)
        try appendClipboardEntry(
            url: child,
            relativePath: "\(relativePath)/\(safeName)",
            entries: &entries,
            total: &total
        )
    }
}

func exportFileClipboard(_ urls: [URL], changeCount: Int, to path: String) throws {
    var entries: [FileEntry] = []
    var total: Int64 = 0
    var used = Set<String>()

    for url in urls {
        let safeName = safeFileName(url.lastPathComponent, used: &used)
        try appendClipboardEntry(
            url: url,
            relativePath: safeName,
            entries: &entries,
            total: &total
        )
    }

    guard !entries.isEmpty else {
        throw ClipboardError.unsupportedType
    }
    let manifest = FileManifest(
        version: 2,
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
        do {
            try exportFileClipboard(
                objects.map { $0 as URL },
                changeCount: changeCount,
                to: path
            )
        } catch ClipboardError.unsupportedType {
            try? FileManager.default.removeItem(atPath: path)
            print("\(changeCount) EMPTY 0")
        }
        return
    }
    if
        let filePaths = pasteboard.propertyList(forType: fileNamesType) as? [String],
        !filePaths.isEmpty
    {
        do {
            try exportFileClipboard(
                filePaths.map { URL(fileURLWithPath: $0) },
                changeCount: changeCount,
                to: path
            )
        } catch ClipboardError.unsupportedType {
            try? FileManager.default.removeItem(atPath: path)
            print("\(changeCount) EMPTY 0")
        }
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

final class RemoteFilePromiseOwner: NSObject,
    NSFilePromiseProviderDelegate,
    NSPasteboardItemDataProvider
{
    private let manifest: FileManifest
    private let cacheDirectory: String
    private let demandPath: String
    private let readyPath: String
    private let failedPath: String
    private let pasteboard: NSPasteboard
    private let requestLock = NSLock()
    private var requested = false
    private var publishedChangeCount: Int?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MacWinClip.file-promises"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    var providers: [NSFilePromiseProvider] = []

    private static let indexType = NSPasteboard.PasteboardType(
        "com.macwinclip.remote-file-index"
    )

    init(
        manifest: FileManifest,
        cacheDirectory: String,
        demandPath: String,
        readyPath: String,
        failedPath: String,
        pasteboard: NSPasteboard = .general
    ) {
        self.manifest = manifest
        self.cacheDirectory = cacheDirectory
        self.demandPath = demandPath
        self.readyPath = readyPath
        self.failedPath = failedPath
        self.pasteboard = pasteboard
    }

    private func topLevelEntry(at index: Int) throws -> FileEntry {
        let topLevel = manifest.files.filter { !$0.name.contains("/") }
        guard index >= 0 && index < topLevel.count else {
            throw ClipboardError.invalidManifest
        }
        return topLevel[index]
    }

    private func ensureReady() throws {
        requestLock.lock()
        if !requested {
            try? FileManager.default.removeItem(atPath: failedPath)
            do {
                try writePayload(Data("fetch".utf8), to: demandPath)
                requested = true
            } catch {
                requestLock.unlock()
                throw error
            }
        }
        requestLock.unlock()

        let deadline = Date(timeIntervalSinceNow: 30 * 60)
        while Date() < deadline {
            requestLock.lock()
            let expected = publishedChangeCount
            requestLock.unlock()
            if let expected,
               pasteboard.changeCount != expected {
                throw NSError(
                    domain: "MacWinClip",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The file offer was replaced on the clipboard."
                    ]
                )
            }
            if FileManager.default.fileExists(atPath: readyPath) {
                return
            }
            if FileManager.default.fileExists(atPath: failedPath) {
                throw NSError(
                    domain: "MacWinClip",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The Windows file transfer failed."
                    ]
                )
            }
            if Thread.isMainThread {
                _ = RunLoop.current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.05)
                )
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        throw NSError(
            domain: "MacWinClip",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for the Windows file transfer."
            ]
        )
    }

    private func cachedURL(for entry: FileEntry) throws -> URL {
        let root = URL(fileURLWithPath: cacheDirectory, isDirectory: true)
        let url = root.appendingPathComponent(
            entry.name,
            isDirectory: entry.kind == "directory"
        )
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue == (entry.kind == "directory")
        else {
            throw NSError(
                domain: "MacWinClip",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "A received file is missing from the private cache."
                ]
            )
        }
        return url
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        guard
            let index = filePromiseProvider.userInfo as? Int,
            let entry = try? topLevelEntry(at: index)
        else {
            return "MacWinClip"
        }
        return (entry.name as NSString).lastPathComponent
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            guard let index = filePromiseProvider.userInfo as? Int else {
                throw ClipboardError.invalidManifest
            }
            let entry = try topLevelEntry(at: index)
            try ensureReady()
            let source = try cachedURL(for: entry)
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(
        for filePromiseProvider: NSFilePromiseProvider
    ) -> OperationQueue {
        promiseQueue
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard
            type == .fileURL,
            let value = item.string(forType: Self.indexType),
            let index = Int(value),
            let entry = try? topLevelEntry(at: index)
        else {
            return
        }
        do {
            try ensureReady()
            let source = try cachedURL(for: entry)
            item.setString(source.absoluteString, forType: .fileURL)
        } catch {
            item.setData(Data(), forType: .fileURL)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
    }

    func publish() throws -> Int {
        let topLevel = manifest.files.filter { !$0.name.contains("/") }
        guard !topLevel.isEmpty else {
            throw ClipboardError.invalidManifest
        }

        let transient = NSPasteboard.PasteboardType(
            "org.nspasteboard.TransientType"
        )
        let concealed = NSPasteboard.PasteboardType(
            "org.nspasteboard.ConcealedType"
        )
        let autoGenerated = NSPasteboard.PasteboardType(
            "org.nspasteboard.AutoGeneratedType"
        )
        let sourceType = NSPasteboard.PasteboardType(
            "org.nspasteboard.source"
        )
        let sourceData = Data("com.macwinclip.bridge".utf8)
        var writings: [NSPasteboardWriting] = []
        var promiseWritings: [NSPasteboardWriting] = []

        for (index, entry) in topLevel.enumerated() {
            let item = NSPasteboardItem()
            item.setString(String(index), forType: Self.indexType)
            item.setDataProvider(self, forTypes: [.fileURL])
            item.setData(Data(), forType: transient)
            item.setData(Data(), forType: concealed)
            item.setData(Data(), forType: autoGenerated)
            item.setData(sourceData, forType: sourceType)
            writings.append(item)

            let fileType: String
            if entry.kind == "directory" {
                fileType = UTType.folder.identifier
            } else {
                let extensionName = (entry.name as NSString).pathExtension
                fileType = UTType(filenameExtension: extensionName)?
                    .identifier ?? UTType.data.identifier
            }
            let provider = NSFilePromiseProvider(
                fileType: fileType,
                delegate: self
            )
            provider.userInfo = index
            providers.append(provider)
            promiseWritings.append(provider)
        }
        writings.append(contentsOf: promiseWritings)

        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard pasteboard.writeObjects(writings) else {
            throw ClipboardError.unsupportedType
        }
        let changeCount = pasteboard.changeCount
        requestLock.lock()
        publishedChangeCount = changeCount
        requestLock.unlock()
        return changeCount
    }
}

func ownPromisedFiles(
    manifestPath: String,
    cacheDirectory: String,
    demandPath: String,
    readyPath: String,
    failedPath: String,
    dismissedPath: String,
    pidPath: String
) throws {
    guard
        cacheDirectory.hasPrefix("/"),
        demandPath.hasPrefix("/"),
        readyPath.hasPrefix("/"),
        failedPath.hasPrefix("/"),
        dismissedPath.hasPrefix("/"),
        pidPath.hasPrefix("/")
    else {
        throw ClipboardError.invalidArguments
    }
    defer {
        try? FileManager.default.removeItem(atPath: pidPath)
    }
    let manifest = try readManifest(manifestPath)
    guard manifest.files.allSatisfy({ $0.sha256.isEmpty }) else {
        throw ClipboardError.invalidManifest
    }
    let owner = RemoteFilePromiseOwner(
        manifest: manifest,
        cacheDirectory: cacheDirectory,
        demandPath: demandPath,
        readyPath: readyPath,
        failedPath: failedPath
    )
    let changeCount = try owner.publish()
    print(changeCount)
    fflush(stdout)
    while NSPasteboard.general.changeCount == changeCount {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.1)
        )
    }
    try? writePayload(Data("dismiss".utf8), to: dismissedPath)
}

func validatePromiseLayout(
    manifestPath: String,
    cacheDirectory: String,
    workDirectory: String
) throws {
    let fileManager = FileManager.default
    let manifest = try readManifest(manifestPath)
    let topLevel = manifest.files.filter { !$0.name.contains("/") }
    guard
        !topLevel.isEmpty,
        manifest.files.allSatisfy({ $0.sha256.isEmpty })
    else {
        throw ClipboardError.invalidManifest
    }
    try fileManager.createDirectory(
        atPath: workDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let demandPath = "\(workDirectory)/demand"
    let readyPath = "\(workDirectory)/ready"
    let failedPath = "\(workDirectory)/failed"
    let destination = "\(workDirectory)/destination"
    try fileManager.createDirectory(
        atPath: destination,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    try writePayload(Data("ready".utf8), to: readyPath)

    let urlPasteboard = NSPasteboard.withUniqueName()
    let urlOwner = RemoteFilePromiseOwner(
        manifest: manifest,
        cacheDirectory: cacheDirectory,
        demandPath: demandPath,
        readyPath: readyPath,
        failedPath: failedPath,
        pasteboard: urlPasteboard
    )
    let urlChangeCount = try urlOwner.publish()
    let leadingFileURLItems = Array(
        (urlPasteboard.pasteboardItems ?? []).prefix(topLevel.count)
    ).filter { $0.types.contains(.fileURL) }.count
    guard leadingFileURLItems == topLevel.count else {
        throw ClipboardError.unsupportedType
    }
    let urls = urlPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    guard urls.count == topLevel.count else {
        throw ClipboardError.unsupportedType
    }
    let urlChangeStable = urlPasteboard.changeCount == urlChangeCount
    fputs(
        "promise-test fileURLs=\(urls.count) " +
        "changeStable=\(urlChangeStable)\n",
        stderr
    )

    let directPasteboard = NSPasteboard.withUniqueName()
    let directOwner = RemoteFilePromiseOwner(
        manifest: manifest,
        cacheDirectory: cacheDirectory,
        demandPath: "\(workDirectory)/direct-demand",
        readyPath: readyPath,
        failedPath: failedPath,
        pasteboard: directPasteboard
    )
    _ = try directOwner.publish()
    var promiseSuccesses = 0
    for (index, provider) in directOwner.providers.enumerated() {
        let entry = topLevel[index]
        let target = URL(
            fileURLWithPath: destination,
            isDirectory: true
        ).appendingPathComponent(
            entry.name,
            isDirectory: entry.kind == "directory"
        )
        var completionError: Error?
        directOwner.filePromiseProvider(
            provider,
            writePromiseTo: target
        ) { error in
            completionError = error
        }
        guard completionError == nil else {
            throw completionError!
        }
        let (kind, size) = try fileTypeAndSize(target.path)
        guard
            kind == entry.kind,
            entry.kind == "directory" || size == entry.size
        else {
            throw ClipboardError.invalidManifest
        }
        promiseSuccesses += 1
    }

    print(
        "topLevel=\(topLevel.count) " +
        "fileURLs=\(urls.count) promises=\(promiseSuccesses) " +
        "leadingFileURLs=\(leadingFileURLItems) " +
        "urlChangeStable=\(urlChangeStable)"
    )
}

func setFileClipboard(manifestPath: String, directory: String) throws -> Int {
    let manifest = try readManifest(manifestPath)
    let topLevel = manifest.files.filter { !$0.name.contains("/") }
    let urls = try topLevel.map { entry -> URL in
        let url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(
                entry.name,
                isDirectory: entry.kind == "directory"
            )
        let (kind, size) = try fileTypeAndSize(url.path)
        guard
            kind == entry.kind,
            entry.kind == "directory" || size == entry.size
        else {
            throw ClipboardError.invalidManifest
        }
        return url
    }
    guard !urls.isEmpty else {
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

func clearClipboardIfCount(_ expected: Int) {
    let pasteboard = NSPasteboard.general
    if pasteboard.changeCount == expected {
        pasteboard.clearContents()
    }
    print(pasteboard.changeCount)
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
        let hash: String
        if entry.kind == "directory" {
            hash = ""
        } else {
            guard let sourcePath = entry.sourcePath else {
                throw ClipboardError.invalidManifest
            }
            hash = try sha256(of: sourcePath)
        }
        publicEntries.append(
            FileEntry(
                index: entry.index,
                name: entry.name,
                kind: entry.kind,
                size: entry.size,
                sha256: hash,
                sourcePath: nil
            )
        )
    }
    try writeManifest(
        FileManifest(
            version: 2,
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
            kind: $0.kind,
            size: $0.size,
            sha256: "",
            sourcePath: nil
        )
    }
    try writeManifest(
        FileManifest(
            version: 2,
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
            if entry.kind == "directory" {
                publicEntries.append(
                    FileEntry(
                        index: entry.index,
                        name: entry.name,
                        kind: "directory",
                        size: 0,
                        sha256: "",
                        sourcePath: nil
                    )
                )
                continue
            }
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
                    kind: "file",
                    size: entry.size,
                    sha256: hash,
                    sourcePath: nil
                )
            )
        }
        try writeManifest(
            FileManifest(
                version: 2,
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
        print(
            "\(entry.index)\t\(entry.kind)\t\(name)\t\(entry.size)\t\(hash)\t\(source)"
        )
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

    case "clear-if-count":
        guard
            arguments.count == 3,
            let expected = Int(arguments[2])
        else {
            throw ClipboardError.invalidArguments
        }
        clearClipboardIfCount(expected)

    case "export":
        guard arguments.count == 3 else { throw ClipboardError.invalidArguments }
        try exportClipboard(to: arguments[2])

    case "file-manifest":
        guard arguments.count >= 4 else { throw ClipboardError.invalidArguments }
        try exportFileClipboard(
            Array(arguments.dropFirst(3)).map {
                URL(fileURLWithPath: $0)
            },
            changeCount: 0,
            to: arguments[2]
        )

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

    case "own-promised-files":
        guard arguments.count == 9 else { throw ClipboardError.invalidArguments }
        try ownPromisedFiles(
            manifestPath: arguments[2],
            cacheDirectory: arguments[3],
            demandPath: arguments[4],
            readyPath: arguments[5],
            failedPath: arguments[6],
            dismissedPath: arguments[7],
            pidPath: arguments[8]
        )

    case "validate-promise-layout":
        guard arguments.count == 5 else { throw ClipboardError.invalidArguments }
        try validatePromiseLayout(
            manifestPath: arguments[2],
            cacheDirectory: arguments[3],
            workDirectory: arguments[4]
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
