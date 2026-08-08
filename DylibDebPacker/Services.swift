import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published var plugins: [PluginFile] = []
    @Published var sources: [RepoSource] = []
    @Published var repoPackages: [RepoPackage] = []
    @Published var sourceMessages: [UUID: String] = [:]
    @Published var selectedPluginIDs: Set<UUID> = []
    @Published var settings = PackageSettings()
    @Published var status = "就绪"
    @Published var generatedDebURL: URL?
    @Published var isBusy = false

    private let fileManager = FileManager.default

    init() {
        load()
    }

    var selectedPlugins: [PluginFile] {
        plugins.filter { selectedPluginIDs.contains($0.id) }
    }

    func documentsURL() throws -> URL {
        try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    func pluginsURL() throws -> URL {
        let url = try documentsURL().appendingPathComponent("Plugins", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func stateURL() throws -> URL {
        try documentsURL().appendingPathComponent("state.json")
    }

    func load() {
        do {
            let url = try stateURL()
            guard fileManager.fileExists(atPath: url.path) else { return }
            let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
            plugins = state.plugins
            sources = state.sources
            settings = state.settings
            selectedPluginIDs = Set(state.plugins.map(\.id))
        } catch {
            status = error.localizedDescription
        }
    }

    func save() {
        do {
            let state = PersistedState(plugins: plugins, sources: sources, settings: settings)
            let data = try JSONEncoder.pretty.encode(state)
            try data.write(to: try stateURL(), options: .atomic)
        } catch {
            status = error.localizedDescription
        }
    }

    func importFiles(_ urls: [URL]) {
        Task {
            await runBusy("导入文件") {
                for url in urls {
                    try await self.importFile(url)
                }
                self.save()
                self.status = "已导入 \(urls.count) 个文件"
            }
        }
    }

    func importFile(_ url: URL) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let lower = url.pathExtension.lowercased()
        if lower == "dylib" {
            try copyDylib(from: url, source: "Imported")
        } else if lower == "deb" {
            let extracted = try DebExtractor.extractDylibs(from: url)
            for item in extracted {
                try addDylibData(item.data, fileName: item.name, source: url.lastPathComponent)
            }
        } else {
            throw AppError.unsupportedArchive(url.lastPathComponent)
        }
    }

    func addSource(urlText: String) {
        let count = addSources(from: urlText, refresh: true)
        if count == 0 {
            status = AppError.invalidURL.localizedDescription
        }
    }

    @discardableResult
    func addSources(from text: String, refresh: Bool) -> Int {
        let urls = RepoURLParser.extractRepoURLs(from: text)
        var added = 0
        for normalized in urls where !sources.contains(where: { $0.url == normalized }) {
            let name = URL(string: normalized)?.host ?? "Source"
            sources.append(RepoSource(name: name, url: normalized))
            added += 1
        }
        if added > 0 {
            save()
            status = "已添加 \(added) 个源"
            if refresh { refreshSources() }
        }
        return added
    }

    func removeSource(_ source: RepoSource) {
        sources.removeAll { $0.id == source.id }
        repoPackages.removeAll { $0.sourceID == source.id }
        sourceMessages.removeValue(forKey: source.id)
        save()
    }

    func refreshSources() {
        Task {
            await runBusy("刷新源") {
                var packages: [RepoPackage] = []
                for source in self.sources {
                    do {
                        let found = try await RepoClient.fetchPackages(from: source)
                        packages.append(contentsOf: found)
                        self.sourceMessages[source.id] = found.isEmpty ? "索引为空" : "已读取 \(found.count) 个插件包"
                    } catch {
                        self.sourceMessages[source.id] = error.localizedDescription
                    }
                }
                self.repoPackages = packages.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.status = "已读取 \(packages.count) 个插件包"
            }
        }
    }

    func download(_ package: RepoPackage) {
        Task {
            await runBusy("下载 \(package.name)") {
                guard let url = package.downloadURL else { throw AppError.invalidURL }
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let extracted = try DebExtractor.extractDylibs(from: tempURL)
                for item in extracted {
                    try self.addDylibData(item.data, fileName: item.name, source: package.name)
                }
                self.save()
                self.status = "已从 \(package.name) 提取 \(extracted.count) 个 dylib"
            }
        }
    }

    func buildDeb() {
        Task {
            await runBusy("打包 deb") {
                let output = try DebBuilder.build(plugins: self.selectedPlugins, baseURL: try self.documentsURL(), settings: self.settings)
                self.generatedDebURL = output
                self.save()
                self.status = "已生成 \(output.lastPathComponent)"
            }
        }
    }

    func toggleSelection(_ plugin: PluginFile) {
        if selectedPluginIDs.contains(plugin.id) {
            selectedPluginIDs.remove(plugin.id)
        } else {
            selectedPluginIDs.insert(plugin.id)
        }
    }

    func deletePlugins(at offsets: IndexSet) {
        for index in offsets {
            let plugin = plugins[index]
            if let url = try? documentsURL().appendingPathComponent(plugin.relativePath) {
                try? fileManager.removeItem(at: url)
            }
            selectedPluginIDs.remove(plugin.id)
        }
        plugins.remove(atOffsets: offsets)
        save()
    }

    func update(plugin: PluginFile) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[index] = plugin
        save()
    }

    private func copyDylib(from url: URL, source: String) throws {
        try addDylibData(Data(contentsOf: url), fileName: url.lastPathComponent, source: source)
    }

    private func addDylibData(_ data: Data, fileName: String, source: String) throws {
        let cleanName = fileName.hasSuffix(".dylib") ? fileName.sanitizedFileComponent : "\(fileName).dylib".sanitizedFileComponent
        let unique = uniqueFileName(cleanName, in: try pluginsURL())
        let destination = try pluginsURL().appendingPathComponent(unique)
        try data.write(to: destination, options: .atomic)
        var plugin = PluginFile(displayName: String(unique.dropLast(6)), fileName: unique, relativePath: "Plugins/\(unique)", source: source)
        inferFilter(for: &plugin)
        plugins.append(plugin)
        selectedPluginIDs.insert(plugin.id)
    }

    private func uniqueFileName(_ name: String, in directory: URL) -> String {
        var candidate = name
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        var index = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    private func inferFilter(for plugin: inout PluginFile) {
        let key = plugin.debName.lowercased()
        let bundles: [String: String] = [
            "fengchao": "com.fcbox.hiveconsumer",
            "cainiao": "com.cainiao.cnwireless",
            "lolmobile": "com.tencent.ied.app.lolbible",
            "chinamobilecloud": "com.chinamobile.mcloud",
            "chinaradio": "com.cbn.app",
            "qqmusic": "com.tencent.QQMusic",
            "xiaohongshu": "com.xingin.discover",
            "douyin": "com.ss.iphone.ugc.Aweme",
            "wcallrecorder": "com.tencent.xin",
            "weapphelper": "com.tencent.xin"
        ]
        if key == "zhiyuanhui" {
            plugin.filterKind = .executable
            plugin.filterValue = "Volunteer"
            return
        }
        if let value = bundles[key] {
            plugin.filterKind = .bundle
            plugin.filterValue = value
        }
    }

    private func runBusy(_ label: String, _ work: @escaping () async throws -> Void) async {
        isBusy = true
        status = label
        do {
            try await work()
        } catch {
            status = error.localizedDescription
        }
        isBusy = false
    }
}

enum RepoURLParser {
    static func extractRepoURLs(from text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var seen = Set<String>()
        var result: [String] = []

        for match in matches {
            let raw = nsText.substring(with: match.range)
            if let normalized = normalize(raw), !seen.contains(normalized) {
                seen.insert(normalized)
                result.append(normalized)
            }
        }
        return result
    }

    private static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\r\t,;，；。)]}"))
        guard var components = URLComponents(string: trimmed),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else {
            return nil
        }

        var path = components.path
        if path.hasSuffix("/Packages.gz") {
            path = String(path.dropLast("/Packages.gz".count))
        } else if path.hasSuffix("/Packages") {
            path = String(path.dropLast("/Packages".count))
        } else if path.hasSuffix("/Release") {
            path = String(path.dropLast("/Release".count))
        }
        if path.isEmpty { path = "/" }
        components.path = path.ensureTrailingSlash()
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString.ensureTrailingSlash()
    }
}

enum RepoClient {
    static func fetchPackages(from source: RepoSource) async throws -> [RepoPackage] {
        guard let baseURL = URL(string: source.url.ensureTrailingSlash()) else { throw AppError.invalidURL }
        let packageLists = candidatePackagePaths(baseURL: baseURL)
        var sawUnsupportedArchive = false

        for path in packageLists {
            let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(path)
            guard let data = try? await fetch(url), !data.isEmpty else { continue }

            if path.hasSuffix(".xz") || path.hasSuffix(".zst") {
                sawUnsupportedArchive = true
                continue
            }

            let textData: Data
            if path.hasSuffix(".gz") {
                guard let decompressed = try? GzipCodec.decompress(data) else { continue }
                textData = decompressed
            } else if path.hasSuffix(".bz2") {
                guard let decompressed = try? Bzip2Codec.decompress(data) else { continue }
                textData = decompressed
            } else {
                textData = data
            }
            if let text = String(data: textData, encoding: .utf8) {
                let packages = parsePackages(text, source: source)
                if !packages.isEmpty { return packages }
            }
        }

        if sawUnsupportedArchive {
            throw AppError.sourceUnavailable("找到 Packages.xz/zst，但当前版本暂不支持这些压缩格式")
        }
        throw AppError.sourceUnavailable("没有找到可解析的 Packages 索引")
    }

    private static func candidatePackagePaths(baseURL: URL) -> [String] {
        var paths = [
            "Packages",
            "Packages.gz",
            "Packages.bz2",
            "Packages.xz",
            "Packages.zst"
        ]
        let distributions = ["iphoneos-arm64", "stable", "current", "release"]
        let components = ["main", "extras"]
        let architectures = ["iphoneos-arm64", "iphoneos-arm", "arm64", "all"]

        for distribution in distributions {
            for component in components {
                for architecture in architectures {
                    let prefix = "dists/\(distribution)/\(component)/binary-\(architecture)/Packages"
                    paths.append(prefix)
                    paths.append(prefix + ".gz")
                    paths.append(prefix + ".bz2")
                    paths.append(prefix + ".xz")
                    paths.append(prefix + ".zst")
                }
            }
        }
        return paths
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return Data()
        }
        return data
    }

    private static func parsePackages(_ text: String, source: RepoSource) -> [RepoPackage] {
        text.components(separatedBy: "\n\n").compactMap { stanza in
            var fields: [String: String] = [:]
            var currentKey: String?
            for line in stanza.components(separatedBy: .newlines) {
                if line.hasPrefix(" "), let key = currentKey {
                    fields[key, default: ""] += "\n" + line.trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon])
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                fields[key] = value
                currentKey = key
            }
            guard let package = fields["Package"], let filename = fields["Filename"] else { return nil }
            return RepoPackage(
                sourceID: source.id,
                sourceName: source.name,
                baseURL: source.url,
                package: package,
                name: fields["Name"] ?? package,
                version: fields["Version"] ?? "",
                architecture: fields["Architecture"] ?? "",
                filename: filename,
                description: fields["Description"] ?? ""
            )
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
