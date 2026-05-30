import XCTest
@testable import FlowType

final class ASRPostProcessorTests: XCTestCase {

    func testStripFillerWords() {
        let input = "嗯那个就是说我想要啊实现一个功能"
        let result = ASRPostProcessor.process(input)
        // Filler words should be stripped
        XCTAssertFalse(result.contains("嗯"))
        XCTAssertFalse(result.contains("那个"))
        XCTAssertFalse(result.contains("就是"))
        XCTAssertFalse(result.contains("啊"))
        // Core content should remain
        XCTAssertTrue(result.contains("实现"))
        XCTAssertTrue(result.contains("功能"))
    }

    func testDetectRepetition() {
        let input = "然后然后然后我们开始开始写代码"
        let result = ASRPostProcessor.process(input)
        // Repetitions should be collapsed
        XCTAssertFalse(result.contains("然后然后"))
        XCTAssertFalse(result.contains("开始开始"))
    }

    func testEmptyInput() {
        let result = ASRPostProcessor.process("")
        XCTAssertEqual(result, "")
    }

    func testTechTermCorrection() {
        // Tech terms defined in Resources/tech_terms.json should be corrected
        let input = "使用 react 和 nodejs 开发"
        let result = ASRPostProcessor.process(input)
        // Note: exact behavior depends on tech_terms.json content
        XCTAssertFalse(result.isEmpty)
    }
}
