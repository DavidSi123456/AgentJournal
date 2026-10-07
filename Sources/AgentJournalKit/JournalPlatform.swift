import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum JournalPlatform {
    // Windows inherits the current user's LocalAppData ACL; POSIX permissions
    // must not be applied through Foundation on Windows.
    static func attributes(_ permissions: Int) -> [FileAttributeKey: Any]? {
        #if os(Windows)
        return nil
        #else
        return [.posixPermissions: permissions]
        #endif
    }
    static func restrict(_ url: URL, permissions: Int = 0o600) throws {
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        #endif
    }
    static func drainPool<T>(_ operation: () throws -> T) rethrows -> T {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: operation)
        #else
        return try operation()
        #endif
    }
    static func withLock<T>(_ url: URL, _ operation: () throws -> T) throws -> T {
        #if os(Windows)
        // Opening with no sharing gives an OS-owned, crash-released exclusive
        // lock. Fail closed on contention rather than risking a lost update.
        let path = Array(url.path.utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW($0.baseAddress, DWORD(GENERIC_READ | GENERIC_WRITE), 0, nil,
                        DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw JournalError.message("日志正在被另一个实例使用，或存储目录无法写入。")
        }
        defer { _ = CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info),
              info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
            throw JournalError.message("存储文件不能使用符号链接，原文件已保留。")
        }
        return try operation()
        #else
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw JournalError.message("无法锁定日志存储，请检查目录权限。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw JournalError.message("无法锁定日志存储，请重试。") }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
        #endif
    }
}
