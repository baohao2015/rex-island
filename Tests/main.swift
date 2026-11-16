import Foundation

// A small assert-based runner: `swift test` needs a working SwiftPM, which Command Line Tools
// installs don't always have. scripts/build.sh test compiles this with Sources/Core and runs it.

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(file):\(line) \(message)")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", file: String = #fileID, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL \(file):\(line) \(message)\n  expected: \(expected)\n  actual:   \(actual)")
    }
}

func json(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
}

/// Compares two JSON values by their sorted serialization.
func sameJSON(_ a: Any, _ b: Any) -> Bool {
    let options: JSONSerialization.WritingOptions = [.sortedKeys]
    return (try? JSONSerialization.data(withJSONObject: a, options: options)) == (try? JSONSerialization.data(withJSONObject: b, options: options))
}

let suites: [(String, () -> Void)] = [
    ("rex parsing", rexParsingTests),
    ("board", boardTests),
    ("decisions", decisionTests),
    ("risk", riskTests),
    ("installer", installerTests),
    ("usage", usageTests),
    ("format", formatTests),
    ("markdown", markdownTests),
    ("terminal menu", terminalMenuTests),
]

for (name, run) in suites {
    let before = failures
    run()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}
print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
