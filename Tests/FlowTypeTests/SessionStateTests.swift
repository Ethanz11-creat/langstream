import XCTest
@testable import FlowType

final class SessionStateTests: XCTestCase {

    func testStateEquatable() {
        let a: SessionState = .idle
        let b: SessionState = .idle
        XCTAssertEqual(a, b)

        let c: SessionState = .recording(elapsedSeconds: 5)
        let d: SessionState = .recording(elapsedSeconds: 5)
        XCTAssertEqual(c, d)

        let e: SessionState = .recording(elapsedSeconds: 5)
        let f: SessionState = .recording(elapsedSeconds: 10)
        XCTAssertNotEqual(e, f)
    }

    func testStateIconNames() {
        XCTAssertEqual(SessionState.idle.iconName, "mic")
        XCTAssertEqual(SessionState.recording(elapsedSeconds: 0).iconName, "waveform")
        XCTAssertEqual(SessionState.processing(provider: "Test").iconName, "brain.head.profile")
        XCTAssertEqual(SessionState.polishing(preview: "").iconName, "sparkles")
        XCTAssertEqual(SessionState.injecting.iconName, "keyboard")
        XCTAssertEqual(SessionState.error("msg").iconName, "exclamationmark.triangle")
    }

    func testStateIsRecordingIndicator() {
        XCTAssertFalse(SessionState.idle.isRecordingIndicator)
        XCTAssertTrue(SessionState.recording(elapsedSeconds: 5).isRecordingIndicator)
        XCTAssertFalse(SessionState.processing(provider: "Test").isRecordingIndicator)
        XCTAssertFalse(SessionState.injecting.isRecordingIndicator)
    }

    func testStateShowSpinner() {
        XCTAssertFalse(SessionState.idle.showSpinner)
        XCTAssertFalse(SessionState.recording(elapsedSeconds: 0).showSpinner)
        XCTAssertTrue(SessionState.processing(provider: "Test").showSpinner)
        XCTAssertTrue(SessionState.polishing(preview: "").showSpinner)
        XCTAssertFalse(SessionState.injecting.showSpinner)
    }
}
