import Foundation
import StorybirdMCPKit

@main
struct StorybirdMCPMain {
    /// Starts the stdio server without writing protocol diagnostics to stdout.
    static func main() async {
        do {
            try await StorybirdMCPService().run()
            Foundation.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("StorybirdMCP failed: \(error.localizedDescription)\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
    }
}
