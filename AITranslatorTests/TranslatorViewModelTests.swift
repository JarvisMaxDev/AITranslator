import XCTest
@testable import AI_Translator

@MainActor
final class TranslatorViewModelTests: XCTestCase {

    private var settingsVM: SettingsViewModel!
    private var vm: TranslatorViewModel!

    override func setUp() {
        super.setUp()
        settingsVM = SettingsViewModel()
        vm = TranslatorViewModel(settingsViewModel: settingsVM)
    }

    override func tearDown() {
        vm = nil
        settingsVM = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStateIsEmpty() {
        XCTAssertTrue(vm.sourceText.isEmpty)
        XCTAssertTrue(vm.translatedText.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isTranslating)
    }

    func testDefaultSourceLanguageIsAutoDetect() {
        XCTAssertEqual(vm.sourceLanguage.code, "auto")
    }

    // MARK: - Clear

    func testClearAllResetsTexts() {
        vm.sourceText = "Hello"
        vm.translatedText = "Привет"
        vm.clearAll()
        XCTAssertTrue(vm.sourceText.isEmpty)
        XCTAssertTrue(vm.translatedText.isEmpty)
        XCTAssertNil(vm.error)
    }

    // MARK: - Undo / Redo

    func testUndoRestoresPreviousState() {
        vm.sourceText = "First"
        vm.translatedText = "Первый"
        vm.saveState()
        vm.sourceText = "Second"
        vm.translatedText = "Второй"

        vm.undo()
        XCTAssertEqual(vm.sourceText, "First")
        XCTAssertEqual(vm.translatedText, "Первый")
    }

    func testRedoAfterUndo() {
        vm.sourceText = "First"
        vm.translatedText = "Первый"
        vm.saveState()
        vm.sourceText = "Second"
        vm.translatedText = "Второй"

        vm.undo()
        vm.redo()
        XCTAssertEqual(vm.sourceText, "Second")
        XCTAssertEqual(vm.translatedText, "Второй")
    }

    func testUndoWithNoHistoryDoesNothing() {
        vm.sourceText = "Hello"
        vm.undo()
        XCTAssertEqual(vm.sourceText, "Hello")
    }

    func testCanUndoAndCanRedo() {
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)

        vm.saveState()
        vm.sourceText = "Changed"
        XCTAssertTrue(vm.canUndo)

        vm.undo()
        XCTAssertTrue(vm.canRedo)
    }

    // MARK: - Swap Languages

    func testSwapWithExplicitLanguages() {
        vm.sourceLanguage = LanguageList.find(byCode: "en")!
        vm.targetLanguage = LanguageList.find(byCode: "ru")!
        vm.sourceText = "Hello"
        vm.translatedText = "Привет"

        vm.swapLanguages()

        XCTAssertEqual(vm.sourceLanguage.code, "ru")
        XCTAssertEqual(vm.targetLanguage.code, "en")
        XCTAssertEqual(vm.sourceText, "Привет")
        XCTAssertEqual(vm.translatedText, "Hello")
    }

    func testSwapWithAutoDetectAndNoDetectedLanguageDoesNothing() {
        vm.sourceLanguage = .autoDetect
        vm.sourceText = "Hello"
        vm.translatedText = "Привет"
        let originalTarget = vm.targetLanguage

        vm.swapLanguages()

        // Should not swap because no detected language
        XCTAssertEqual(vm.sourceLanguage.code, "auto")
        XCTAssertEqual(vm.targetLanguage, originalTarget)
    }

    // MARK: - MaxTextLength

    func testTranslateRejectsOversizedText() async {
        vm.sourceText = String(repeating: "a", count: Constants.maxTextLength + 1)
        settingsVM.selectedProviderId = "test"

        await vm.translate()

        XCTAssertNotNil(vm.error, "Should set error for oversized text")
        XCTAssertFalse(vm.isTranslating)
    }

    func testTranslateRejectsEmptyText() async {
        vm.sourceText = "   "
        await vm.translate()
        XCTAssertNil(vm.error, "Empty text should silently return, not error")
        XCTAssertFalse(vm.isTranslating)
    }
}
