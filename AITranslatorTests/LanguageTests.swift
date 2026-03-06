import XCTest
@testable import AI_Translator

final class LanguageTests: XCTestCase {

    // MARK: - Language.autoDetect

    func testAutoDetectHasCorrectCode() {
        XCTAssertEqual(Language.autoDetect.code, "auto")
    }

    func testAutoDetectHasFlag() {
        XCTAssertFalse(Language.autoDetect.flag.isEmpty)
    }

    // MARK: - LanguageList

    func testLanguageListNotEmpty() {
        XCTAssertFalse(LanguageList.all.isEmpty)
    }

    func testFindByCodeEnglish() {
        let lang = LanguageList.find(byCode: "en")
        XCTAssertNotNil(lang)
        XCTAssertEqual(lang?.name, "English")
    }

    func testFindByCodeRussian() {
        let lang = LanguageList.find(byCode: "ru")
        XCTAssertNotNil(lang)
        XCTAssertEqual(lang?.name, "Russian")
    }

    func testFindByCodeUnknown() {
        let lang = LanguageList.find(byCode: "xyz")
        XCTAssertNil(lang)
    }

    func testAllLanguagesHaveUniqueCode() {
        let codes = LanguageList.all.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count, "Duplicate language codes found")
    }

    func testAllLanguagesHaveFlag() {
        for lang in LanguageList.all {
            XCTAssertFalse(lang.flag.isEmpty, "\(lang.name) missing flag")
        }
    }

    // MARK: - Language Hashable/Equatable

    func testLanguageEquality() {
        let a = Language(code: "en", name: "English", localizedName: "English", flag: "🇬🇧")
        let b = Language(code: "en", name: "English", localizedName: "English", flag: "🇬🇧")
        XCTAssertEqual(a, b)
    }

    func testLanguageInequality() {
        let en = LanguageList.find(byCode: "en")!
        let ru = LanguageList.find(byCode: "ru")!
        XCTAssertNotEqual(en, ru)
    }
}
