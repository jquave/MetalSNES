import Foundation

@main
struct TestCLI {
    static func main() {
        let testDir = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "\(FileManager.default.currentDirectoryPath)/TestROMs/PeterLemon/CPUTest/CPU"

        if FileManager.default.fileExists(atPath: testDir) {
            CPUTestRunner.runAllTests(directory: testDir)
        } else {
            print("Test ROM directory not found: \(testDir)")
            print("Usage: run_tests [path/to/CPUTest/CPU]")
        }
    }
}
