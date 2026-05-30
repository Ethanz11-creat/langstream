import XCTest
@testable import FlowType

final class ConfigurationTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = Configuration.default
        XCTAssertEqual(config.triggerKey, .command)
        XCTAssertEqual(config.interactionMode, .tapToStart)
        XCTAssertEqual(config.maxRecordingDuration, 600)
        XCTAssertEqual(config.temperature, 0.3)
        XCTAssertEqual(config.maxTokens, 2048)
        XCTAssertTrue(config.enableFillerStrip)
        XCTAssertTrue(config.enableTermCorrection)
        XCTAssertFalse(config.hasCompletedOnboarding)
        XCTAssertNil(config.microphoneDeviceID)
    }

    func testCodableRoundTrip() throws {
        var config = Configuration.default
        config.maxRecordingDuration = 300
        config.hasCompletedOnboarding = true
        config.microphoneDeviceID = "test-device"

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Configuration.self, from: data)

        XCTAssertEqual(decoded.maxRecordingDuration, 300)
        XCTAssertTrue(decoded.hasCompletedOnboarding)
        XCTAssertEqual(decoded.microphoneDeviceID, "test-device")
    }

    func testMaxRecordingDurationClamping() throws {
        // Test that too-large values are clamped
        let json = """
        {
            "maxRecordingDuration": 99999,
            "triggerKey": "command",
            "interactionMode": "tapToStart"
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.maxRecordingDuration, 600)
    }

    func testMaxRecordingDurationMinimum() throws {
        // Test that too-small values are clamped
        let json = """
        {
            "maxRecordingDuration": 1,
            "triggerKey": "command",
            "interactionMode": "tapToStart"
        }
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(config.maxRecordingDuration, 10)
    }

    func testBackwardCompatibilityMigration() throws {
        // Old single-provider format should migrate to multi-provider
        let oldJson = """
        {
            "llmProvider": "SiliconFlow",
            "llmBaseURL": "https://api.siliconflow.cn/v1",
            "llmModel": "deepseek-ai/DeepSeek-V3",
            "triggerKey": "command"
        }
        """
        let data = oldJson.data(using: .utf8)!
        let config = try JSONDecoder().decode(Configuration.self, from: data)

        XCTAssertEqual(config.llmProviders.count, 1)
        XCTAssertEqual(config.llmProviders.first?.provider, "SiliconFlow")
        XCTAssertEqual(config.llmProviders.first?.baseURL, "https://api.siliconflow.cn/v1")
        XCTAssertEqual(config.llmProviders.first?.model, "deepseek-ai/DeepSeek-V3")
        XCTAssertTrue(config.llmProviders.first?.isActive ?? false)
    }
}
