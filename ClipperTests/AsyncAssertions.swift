import Foundation
import XCTest

// XCTest's assertions take non-async autoclosures, so `XCTAssertEqual(await store.count(), 3)`
// does not compile: the `await` lands inside a closure that cannot suspend. Hoisting every
// such value into a local would triple the length of the suite and bury what each test is
// actually asserting, so instead these overloads accept async autoclosures. The call site
// then reads `await XCTAssertEqual(await store.count(), 3)`.
//
// Each one is written against `XCTFail` rather than by delegating to the synchronous
// assertion of the same name: in an async context Swift prefers the async overload, so
// delegating would call straight back into these functions forever.

func XCTAssertEqual<T: Equatable>(_ expression1: @autoclosure () async throws -> T,
                                  _ expression2: @autoclosure () async throws -> T,
                                  _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath,
                                  line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if lhs != rhs {
        XCTFail(describe(message(), "XCTAssertEqual failed: (\"\(lhs)\") is not equal to (\"\(rhs)\")"),
                file: file, line: line)
    }
}

func XCTAssertNotEqual<T: Equatable>(_ expression1: @autoclosure () async throws -> T,
                                     _ expression2: @autoclosure () async throws -> T,
                                     _ message: @autoclosure () -> String = "",
                                     file: StaticString = #filePath,
                                     line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if lhs == rhs {
        XCTFail(describe(message(), "XCTAssertNotEqual failed: (\"\(lhs)\") is equal to (\"\(rhs)\")"),
                file: file, line: line)
    }
}

func XCTAssertTrue(_ expression: @autoclosure () async throws -> Bool,
                   _ message: @autoclosure () -> String = "",
                   file: StaticString = #filePath,
                   line: UInt = #line) async rethrows {
    if try await !expression() {
        XCTFail(describe(message(), "XCTAssertTrue failed"), file: file, line: line)
    }
}

func XCTAssertFalse(_ expression: @autoclosure () async throws -> Bool,
                    _ message: @autoclosure () -> String = "",
                    file: StaticString = #filePath,
                    line: UInt = #line) async rethrows {
    if try await expression() {
        XCTFail(describe(message(), "XCTAssertFalse failed"), file: file, line: line)
    }
}

func XCTAssertNil<T>(_ expression: @autoclosure () async throws -> T?,
                     _ message: @autoclosure () -> String = "",
                     file: StaticString = #filePath,
                     line: UInt = #line) async rethrows {
    if let value = try await expression() {
        XCTFail(describe(message(), "XCTAssertNil failed: \"\(value)\""), file: file, line: line)
    }
}

func XCTAssertNotNil<T>(_ expression: @autoclosure () async throws -> T?,
                        _ message: @autoclosure () -> String = "",
                        file: StaticString = #filePath,
                        line: UInt = #line) async rethrows {
    if try await expression() == nil {
        XCTFail(describe(message(), "XCTAssertNotNil failed"), file: file, line: line)
    }
}

func XCTAssertGreaterThan<T: Comparable>(_ expression1: @autoclosure () async throws -> T,
                                         _ expression2: @autoclosure () async throws -> T,
                                         _ message: @autoclosure () -> String = "",
                                         file: StaticString = #filePath,
                                         line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if !(lhs > rhs) {
        XCTFail(describe(message(), "XCTAssertGreaterThan failed: (\"\(lhs)\") is not greater than (\"\(rhs)\")"),
                file: file, line: line)
    }
}

func XCTAssertGreaterThanOrEqual<T: Comparable>(_ expression1: @autoclosure () async throws -> T,
                                                _ expression2: @autoclosure () async throws -> T,
                                                _ message: @autoclosure () -> String = "",
                                                file: StaticString = #filePath,
                                                line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if !(lhs >= rhs) {
        XCTFail(describe(message(), "XCTAssertGreaterThanOrEqual failed: (\"\(lhs)\") is less than (\"\(rhs)\")"),
                file: file, line: line)
    }
}

func XCTAssertLessThan<T: Comparable>(_ expression1: @autoclosure () async throws -> T,
                                      _ expression2: @autoclosure () async throws -> T,
                                      _ message: @autoclosure () -> String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if !(lhs < rhs) {
        XCTFail(describe(message(), "XCTAssertLessThan failed: (\"\(lhs)\") is not less than (\"\(rhs)\")"),
                file: file, line: line)
    }
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: @autoclosure () async throws -> T,
                                             _ expression2: @autoclosure () async throws -> T,
                                             _ message: @autoclosure () -> String = "",
                                             file: StaticString = #filePath,
                                             line: UInt = #line) async rethrows {
    let lhs = try await expression1()
    let rhs = try await expression2()
    if !(lhs <= rhs) {
        XCTFail(describe(message(), "XCTAssertLessThanOrEqual failed: (\"\(lhs)\") is greater than (\"\(rhs)\")"),
                file: file, line: line)
    }
}

/// Mirrors `XCTUnwrap` for a value that has to be awaited first.
func XCTUnwrap<T>(_ expression: @autoclosure () async throws -> T?,
                  _ message: @autoclosure () -> String = "",
                  file: StaticString = #filePath,
                  line: UInt = #line) async throws -> T {
    guard let value = try await expression() else {
        XCTFail(describe(message(), "XCTUnwrap failed: expected a non-nil value"), file: file, line: line)
        throw AsyncUnwrapFailure(description: message())
    }
    return value
}

struct AsyncUnwrapFailure: Error {
    let description: String
}

private func describe(_ message: String, _ fallback: String) -> String {
    message.isEmpty ? fallback : "\(fallback) — \(message)"
}
