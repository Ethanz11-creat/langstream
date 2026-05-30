/// Lightweight sanity tests that run inline without XCTest.
/// These are executed in debug builds via the `@main` entry point.
/// In a full Xcode environment, use the XCTest-based tests instead.

import Foundation

enum InlineSanityTests {

    static func runAll() {
        #if DEBUG
        print("=== InlineSanityTests ===")
        testConfigurationClamping()
        testSessionStateProperties()
        print("=== All inline tests passed ===")
        #endif
    }

    private static func testConfigurationClamping() {
        // Test that out-of-range maxRecordingDuration values are clamped
        let jsonHigh = """
        {"maxRecordingDuration":99999,"triggerKey":"command","interactionMode":"tapToStart"}
        """.data(using: .utf8)!
        let configHigh = try! JSONDecoder().decode(Configuration.self, from: jsonHigh)
        assert(configHigh.maxRecordingDuration == 600, "Max duration should clamp to 600")

        let jsonLow = """
        {"maxRecordingDuration":1,"triggerKey":"command","interactionMode":"tapToStart"}
        """.data(using: .utf8)!
        let configLow = try! JSONDecoder().decode(Configuration.self, from: jsonLow)
        assert(configLow.maxRecordingDuration == 10, "Min duration should clamp to 10")

        print("✓ Configuration clamping")
    }

    private static func testSessionStateProperties() {
        assert(SessionState.idle.iconName == "mic")
        assert(SessionState.recording(elapsedSeconds: 0).iconName == "waveform")
        assert(SessionState.processing(provider: "Test").showSpinner == true)
        assert(SessionState.idle.showSpinner == false)
        assert(SessionState.recording(elapsedSeconds: 5).isRecordingIndicator == true)
        assert(SessionState.injecting.isRecordingIndicator == false)
        print("✓ SessionState properties")
    }
}
