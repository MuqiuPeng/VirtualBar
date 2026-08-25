import Foundation

/// `open`-launched apps don't inherit the launching terminal's stdout, so
/// mirror debug prints to a fixed file too.
func debugLog(_ message: String) {
    print(message)
    let line = message + "\n"
    let path = "/tmp/virtualbar.log"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path), let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
