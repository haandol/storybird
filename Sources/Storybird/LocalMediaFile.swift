import Darwin
import Foundation

enum LocalMediaFile {
    /// Resolves MCP paths without opening a picker or interpreting URLs and shell
    /// syntax. Files remain subject to the app's actual operating-system access.
    static func url(path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw AgentEditError.invalidField("path")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Copies from one opened regular file into an exclusive destination. Checking
    /// the descriptor prevents path replacement from turning a file into a FIFO;
    /// bounded reads allow cancellation without loading a whole movie into memory.
    static func copy(
        from source: URL, to destination: URL,
        didCopyBytes: @Sendable (Int) -> Void = { _ in }
    ) throws {
        guard source.isFileURL, destination.isFileURL else {
            throw AgentEditError.invalidField("path")
        }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 0 else {
            throw AgentEditError.invalidField("path")
        }
        let outputDescriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard outputDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer { try? output.close() }
        do {
            while true {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: 1_048_576), !data.isEmpty else { break }
                try output.write(contentsOf: data)
                didCopyBytes(data.count)
            }
            try Task.checkCancellation()
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
