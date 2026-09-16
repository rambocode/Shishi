import Foundation
import Darwin

/// 对同一数据库的进程持有排他锁，防止两个窗口进程覆盖各自的内存快照。
final class LibraryLock {
    private let descriptor: Int32
    init(dataURL: URL) throws {
        try FileManager.default.createDirectory(at: dataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = dataURL.appendingPathExtension("lock")
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LockError.unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw LockError.inUse
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    enum LockError: LocalizedError {
        case unavailable, inUse
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法访问数据库目录。请检查目录权限。"
            case .inUse: return "这个数据库已由另一个拾事进程打开，请使用已有窗口。"
            }
        }
    }
}
