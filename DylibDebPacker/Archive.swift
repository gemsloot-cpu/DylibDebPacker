import Foundation

enum GzipCodec {
    static func compress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { input in
            var output: UnsafeMutablePointer<UInt8>?
            var outputLen = 0
            let result = gzip_compress(input.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &outputLen)
            guard result == 0, let output else { throw AppError.zlibFailed(result) }
            defer { gzip_free(output) }
            return Data(bytes: output, count: outputLen)
        }
    }

    static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { input in
            var output: UnsafeMutablePointer<UInt8>?
            var outputLen = 0
            let result = gzip_decompress(input.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &outputLen)
            guard result == 0, let output else { throw AppError.zlibFailed(result) }
            defer { gzip_free(output) }
            return Data(bytes: output, count: outputLen)
        }
    }
}

enum Bzip2Codec {
    static func decompress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { input in
            var output: UnsafeMutablePointer<UInt8>?
            var outputLen = 0
            let result = bzip2_decompress(input.bindMemory(to: UInt8.self).baseAddress, data.count, &output, &outputLen)
            guard result == 0, let output else { throw AppError.zlibFailed(Int32(result)) }
            defer { bzip2_free(output) }
            return Data(bytes: output, count: outputLen)
        }
    }
}

struct ArEntry {
    let name: String
    let data: Data
}

enum ArArchive {
    static func read(_ data: Data) throws -> [ArEntry] {
        guard data.count >= 8, String(data: data.prefix(8), encoding: .ascii) == "!<arch>\n" else {
            throw AppError.unsupportedArchive("不是 ar/deb 文件")
        }

        var offset = 8
        var entries: [ArEntry] = []
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            guard let headerString = String(data: header, encoding: .ascii) else { break }
            let rawName = String(headerString.prefix(16)).trimmingCharacters(in: .whitespaces)
            let sizeText = String(headerString.dropFirst(48).prefix(10)).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText), offset + 60 + size <= data.count else { break }
            var name = rawName
            if name.hasSuffix("/") { name.removeLast() }
            let bodyStart = offset + 60
            let body = data.subdata(in: bodyStart..<(bodyStart + size))
            entries.append(ArEntry(name: name, data: body))
            offset = bodyStart + size + (size % 2)
        }
        guard !entries.isEmpty else {
            throw AppError.unsupportedArchive("deb ar 内容为空或损坏")
        }
        return entries
    }

    static func write(entries: [ArEntry]) -> Data {
        var out = Data("!<arch>\n".utf8)
        let timestamp = Int(Date().timeIntervalSince1970)
        for entry in entries {
            let size = entry.data.count
            let name = entry.name.hasSuffix("/") ? entry.name : entry.name + "/"
            let header = field(name, 16) +
                field(String(timestamp), 12) +
                field("0", 6) +
                field("0", 6) +
                field("100644", 8) +
                field(String(size), 10) +
                "`\n"
            out.append(Data(header.utf8))
            out.append(entry.data)
            if size % 2 == 1 { out.append(0x0A) }
        }
        return out
    }

    private static func field(_ value: String, _ width: Int) -> String {
        let truncated = String(value.prefix(width))
        return truncated + String(repeating: " ", count: max(0, width - truncated.count))
    }
}

struct TarEntry {
    var path: String
    var data: Data?
    var mode: Int
    var isDirectory: Bool
}

enum TarArchive {
    static func write(entries: [TarEntry]) -> Data {
        var out = Data()
        for entry in entries {
            out.append(header(for: entry))
            if let body = entry.data {
                out.append(body)
                out.append(Data(repeating: 0, count: padding(for: body.count)))
            }
        }
        out.append(Data(repeating: 0, count: 1024))
        return out
    }

    static func files(from data: Data) -> [(path: String, data: Data)] {
        var offset = 0
        var files: [(String, Data)] = []
        while offset + 512 <= data.count {
            let block = data.subdata(in: offset..<(offset + 512))
            if block.allSatisfy({ $0 == 0 }) { break }
            let name = ascii(block, 0, 100)
            let prefix = ascii(block, 345, 155)
            let fullName = [prefix, name].filter { !$0.isEmpty }.joined(separator: "/")
            let size = Int(octal(block, 124, 12))
            let typeflag = block[156]
            offset += 512
            if size > 0, offset + size <= data.count, typeflag != 53 {
                files.append((fullName, data.subdata(in: offset..<(offset + size))))
            }
            offset += size + padding(for: size)
        }
        return files
    }

    private static func header(for entry: TarEntry) -> Data {
        var block = Data(repeating: 0, count: 512)
        let normalized = entry.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        writeString(normalized, into: &block, offset: 0, length: 100)
        writeOctal(entry.mode, into: &block, offset: 100, length: 8)
        writeOctal(0, into: &block, offset: 108, length: 8)
        writeOctal(0, into: &block, offset: 116, length: 8)
        writeOctal(entry.data?.count ?? 0, into: &block, offset: 124, length: 12)
        writeOctal(Int(Date().timeIntervalSince1970), into: &block, offset: 136, length: 12)
        for index in 148..<156 { block[index] = 0x20 }
        block[156] = entry.isDirectory ? 53 : 48
        writeString("ustar", into: &block, offset: 257, length: 6)
        writeString("00", into: &block, offset: 263, length: 2)
        writeString("root", into: &block, offset: 265, length: 32)
        writeString("wheel", into: &block, offset: 297, length: 32)
        let checksum = block.reduce(0) { $0 + Int($1) }
        writeChecksum(checksum, into: &block)
        return block
    }

    private static func padding(for count: Int) -> Int {
        (512 - (count % 512)) % 512
    }

    private static func writeString(_ value: String, into data: inout Data, offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length - 1))
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func writeOctal(_ value: Int, into data: inout Data, offset: Int, length: Int) {
        let text = String(format: "%0*o", length - 1, value)
        let bytes = Array(text.utf8.suffix(length - 1)) + [0]
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }

    private static func writeChecksum(_ value: Int, into data: inout Data) {
        let text = String(format: "%06o", value)
        let bytes = Array(text.utf8) + [0, 0x20]
        data.replaceSubrange(148..<(148 + bytes.count), with: bytes)
    }

    private static func ascii(_ data: Data, _ offset: Int, _ length: Int) -> String {
        let raw = data.subdata(in: offset..<(offset + length))
        return String(data: raw.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private static func octal(_ data: Data, _ offset: Int, _ length: Int) -> Int64 {
        let text = ascii(data, offset, length).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int64(text, radix: 8) ?? 0
    }
}

enum DebBuilder {
    static func build(plugins: [PluginFile], baseURL: URL, settings: PackageSettings) throws -> URL {
        guard !plugins.isEmpty else { throw AppError.noPluginsSelected }

        var dataEntries = directoryEntries(settings: settings)
        let installRoot = settings.rootless ? "var/jb/Library/MobileSubstrate/DynamicLibraries" : "Library/MobileSubstrate/DynamicLibraries"
        for plugin in plugins {
            guard !plugin.filterValue.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AppError.missingFilter(plugin.displayName)
            }
            let sourceURL = baseURL.appendingPathComponent(plugin.relativePath)
            let dylibData = try Data(contentsOf: sourceURL)
            dataEntries.append(TarEntry(path: "\(installRoot)/\(plugin.fileName)", data: dylibData, mode: 0o755, isDirectory: false))
            let plist = plistText(for: plugin)
            dataEntries.append(TarEntry(path: "\(installRoot)/\(plugin.debName).plist", data: Data(plist.utf8), mode: 0o644, isDirectory: false))
        }

        let control = controlText(settings: settings, installedSizeKB: dataEntries.reduce(0) { $0 + ($1.data?.count ?? 0) } / 1024 + 1)
        let controlTar = TarArchive.write(entries: [TarEntry(path: "control", data: Data(control.utf8), mode: 0o644, isDirectory: false)])
        let dataTar = TarArchive.write(entries: dataEntries)
        let deb = ArArchive.write(entries: [
            ArEntry(name: "debian-binary", data: Data("2.0\n".utf8)),
            ArEntry(name: "control.tar.gz", data: try GzipCodec.compress(controlTar)),
            ArEntry(name: "data.tar.gz", data: try GzipCodec.compress(dataTar))
        ])

        let fileName = "\(settings.packageID)_\(settings.version)_\(settings.architecture).deb".sanitizedFileComponent
        let output = baseURL.appendingPathComponent("Builds", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let debURL = output.appendingPathComponent(fileName)
        try deb.write(to: debURL, options: .atomic)
        return debURL
    }

    private static func directoryEntries(settings: PackageSettings) -> [TarEntry] {
        if settings.rootless {
            return ["var", "var/jb", "var/jb/Library", "var/jb/Library/MobileSubstrate", "var/jb/Library/MobileSubstrate/DynamicLibraries"].map {
                TarEntry(path: $0, data: nil, mode: 0o755, isDirectory: true)
            }
        }
        return ["Library", "Library/MobileSubstrate", "Library/MobileSubstrate/DynamicLibraries"].map {
            TarEntry(path: $0, data: nil, mode: 0o755, isDirectory: true)
        }
    }

    private static func plistText(for plugin: PluginFile) -> String {
        switch plugin.filterKind {
        case .bundle:
            return "{ Filter = { Bundles = ( \"\(plugin.filterValue)\" ); }; }\n"
        case .executable:
            return "{ Filter = { Executables = ( \"\(plugin.filterValue)\" ); }; }\n"
        }
    }

    private static func controlText(settings: PackageSettings, installedSizeKB: Int) -> String {
        """
        Package: \(settings.packageID)
        Name: \(settings.name)
        Version: \(settings.version)
        Architecture: \(settings.architecture)
        Depends: firmware (>= 13.0), mobilesubstrate | ellekit
        Maintainer: \(settings.maintainer)
        Author: \(settings.maintainer)
        Section: Tweaks
        Description: Custom on-device dylib bundle built by Dylib Deb Packer.
        Installed-Size: \(installedSizeKB)

        """
    }
}

enum DebExtractor {
    static func extractDylibs(from debURL: URL) throws -> [(name: String, data: Data)] {
        let entries = try ArArchive.read(Data(contentsOf: debURL))
        guard let payload = entries.first(where: {
            let name = $0.name.lowercased()
            return name == "data.tar.gz" || name == "data.tar"
        }) else {
            let names = entries.map(\.name).joined(separator: ", ")
            if names.lowercased().contains("data.tar.xz") { throw AppError.unsupportedArchive("data.tar.xz") }
            if names.lowercased().contains("data.tar.zst") { throw AppError.unsupportedArchive("data.tar.zst") }
            throw AppError.missingPayload
        }

        let tarData = payload.name.lowercased().hasSuffix(".gz") ? try GzipCodec.decompress(payload.data) : payload.data
        let dylibs = TarArchive.files(from: tarData)
            .filter { $0.path.hasSuffix(".dylib") }
            .map { (URL(fileURLWithPath: $0.path).lastPathComponent, $0.data) }
        guard !dylibs.isEmpty else { throw AppError.noDylibsFound }
        return dylibs
    }
}
