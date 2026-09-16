import Foundation

public enum DataError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// 独立 JSON 数据库；任何解码、版本或引用错误均由调用方显式处理。
public struct SnapshotFile {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Snapshot {
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
        try Domain.validate(value)
        return value
    }
    public func write(_ value: Snapshot) throws {
        try Domain.validate(value)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    /// 替换前保留原始字节，包含无法解析的旧数据库。
    @discardableResult public func backup() throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let destination = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".backup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }
}
