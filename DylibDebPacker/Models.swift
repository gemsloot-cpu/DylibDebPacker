import Foundation

enum FilterKind: String, Codable, CaseIterable, Identifiable, Equatable {
    case bundle
    case executable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bundle: return "Bundle ID"
        case .executable: return "可执行名"
        }
    }
}

struct PluginFile: Identifiable, Codable, Hashable {
    var id = UUID()
    var displayName: String
    var fileName: String
    var relativePath: String
    var source: String
    var filterKind: FilterKind = .bundle
    var filterValue: String = ""
    var addedAt = Date()

    var debName: String {
        fileName.hasSuffix(".dylib") ? String(fileName.dropLast(6)) : displayName
    }
}

struct RepoSource: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var addedAt = Date()
}

struct RepoPackage: Identifiable, Codable, Hashable {
    var id = UUID()
    var sourceID: UUID
    var sourceName: String
    var baseURL: String
    var package: String
    var name: String
    var version: String
    var architecture: String
    var filename: String
    var description: String

    var downloadURL: URL? {
        if let absolute = URL(string: filename), absolute.scheme != nil {
            return absolute
        }
        guard let base = URL(string: baseURL.ensureTrailingSlash()) else { return nil }
        return URL(string: filename, relativeTo: base)?.absoluteURL
    }
}

struct PackageSettings: Codable, Equatable {
    var packageID = "com.local.custom-dylibs"
    var name = "自选 dylib 插件包"
    var version = "1.0.0"
    var architecture = "iphoneos-arm64"
    var rootless = true
    var maintainer = "local"
}

struct PersistedState: Codable {
    var plugins: [PluginFile] = []
    var sources: [RepoSource] = []
    var settings = PackageSettings()
}

enum AppError: LocalizedError {
    case invalidURL
    case unsupportedArchive(String)
    case missingPayload
    case noDylibsFound
    case noPluginsSelected
    case missingFilter(String)
    case zlibFailed(Int32)
    case sourceUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL 无效"
        case .unsupportedArchive(let detail):
            return "暂不支持这个压缩格式：\(detail)"
        case .missingPayload:
            return "deb 里没有找到 data.tar/data.tar.gz"
        case .noDylibsFound:
            return "没有提取到 dylib"
        case .noPluginsSelected:
            return "请选择至少一个 dylib"
        case .missingFilter(let name):
            return "\(name) 缺少注入目标"
        case .zlibFailed(let code):
            return "gzip 处理失败：\(code)"
        case .sourceUnavailable(let detail):
            return "源索引不可用：\(detail)"
        }
    }
}

extension String {
    func ensureTrailingSlash() -> String {
        hasSuffix("/") ? self : self + "/"
    }

    var sanitizedFileComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { $0 + String($1) }
    }
}
