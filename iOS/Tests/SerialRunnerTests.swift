import XCTest
@testable import GroqDictateIOS

@MainActor
final class SerialRunnerTests: XCTestCase {
    func testRequestDuringARunIsServedByAnotherRunBeforeItsCallerReturns() async {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?
        let runner = SerialRunner<Int> { _ in
            runs += 1
            if runs == 1 {
                await withCheckedContinuation { gate = $0 }
            }
        }

        let first = Task { await runner.run(1) }
        while gate == nil { await Task.yield() }

        // Both arrive while the first run is going; they share one more run.
        let second = Task { await runner.run(1) }
        let third = Task { await runner.run(1) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(runs, 1)

        gate?.resume()
        await second.value
        XCTAssertEqual(runs, 2, "the request made mid-run must not be skipped")
        await third.value
        await first.value
        XCTAssertEqual(runs, 2)
        XCTAssertFalse(runner.isRunning(1))
    }

    func testKeysRunIndependently() async {
        var seen: [Int] = []
        let runner = SerialRunner<Int> { seen.append($0) }
        await runner.run(1)
        await runner.run(2)
        XCTAssertEqual(seen, [1, 2])
    }
}
