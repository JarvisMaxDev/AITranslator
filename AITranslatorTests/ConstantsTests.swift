import XCTest
@testable import AI_Translator

final class ConstantsTests: XCTestCase {

    func testMaxTextLengthIsPositive() {
        XCTAssertGreaterThan(Constants.maxTextLength, 0)
    }

    func testDoublePressIntervalIsReasonable() {
        XCTAssertGreaterThan(Constants.doublePressInterval, 0.1)
        XCTAssertLessThan(Constants.doublePressInterval, 2.0)
    }

    func testUserDefaultsKeysNotEmpty() {
        XCTAssertFalse(Constants.UserDefaultsKeys.providerConfigs.isEmpty)
        XCTAssertFalse(Constants.UserDefaultsKeys.selectedProviderId.isEmpty)
        XCTAssertFalse(Constants.UserDefaultsKeys.sourceLanguageCode.isEmpty)
        XCTAssertFalse(Constants.UserDefaultsKeys.targetLanguageCode.isEmpty)
    }
}
