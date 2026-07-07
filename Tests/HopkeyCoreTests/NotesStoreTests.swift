import XCTest
@testable import HopkeyCore

final class NotesStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        // Своя временная директория на тест — настоящую Application Support не трогаем.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEmptyByDefault() {
        let store = NotesStore(directory: directory)
        for index in 0..<NotesStore.count {
            XCTAssertEqual(store.text(at: index), "")
            XCTAssertTrue(store.isEmpty(at: index))
        }
    }

    func testUpdateIsInMemoryUntilPersist() {
        let store = NotesStore(directory: directory)
        store.update("draft", at: 2)
        XCTAssertEqual(store.text(at: 2), "draft")
        // Новый экземпляр без persist ничего не видит — правка жила только в памяти.
        let reopened = NotesStore(directory: directory)
        XCTAssertEqual(reopened.text(at: 2), "")
    }

    func testPersistRoundTrip() {
        let store = NotesStore(directory: directory)
        store.update("# Дежурство\n— логи", at: 0)
        store.update("second dot", at: 6)
        store.persist(at: 0)
        store.persist(at: 6)

        let reopened = NotesStore(directory: directory)
        XCTAssertEqual(reopened.text(at: 0), "# Дежурство\n— логи")
        XCTAssertEqual(reopened.text(at: 6), "second dot")
        XCTAssertFalse(reopened.isEmpty(at: 0))
        XCTAssertTrue(reopened.isEmpty(at: 1))
    }

    func testPreviewIsFirstNonEmptyLineTrimmed() {
        let store = NotesStore(directory: directory)
        store.update("  # Title  \nbody line\nmore", at: 3)
        XCTAssertEqual(store.preview(at: 3), "# Title")
    }

    func testPreviewTruncatesToMaxLength() {
        let store = NotesStore(directory: directory)
        store.update(String(repeating: "x", count: 100), at: 1)
        let preview = store.preview(at: 1, maxLength: 10)
        XCTAssertEqual(preview, String(repeating: "x", count: 10) + "…")
    }

    func testIsEmptyForWhitespaceOnly() {
        let store = NotesStore(directory: directory)
        store.update("   \n\t  ", at: 4)
        XCTAssertTrue(store.isEmpty(at: 4))
    }

    func testNameAndFormatDefaultsAndRoundTrip() {
        let store = NotesStore(directory: directory)
        XCTAssertEqual(store.name(at: 0), "")
        XCTAssertFalse(store.isFormatted(at: 0))

        store.setName("Дежурство", at: 0)
        store.setFormatted(true, at: 2)

        // Метаданные читаются новым экземпляром из meta.json (persist немедленный).
        let reopened = NotesStore(directory: directory)
        XCTAssertEqual(reopened.name(at: 0), "Дежурство")
        XCTAssertTrue(reopened.isFormatted(at: 2))
        XCTAssertFalse(reopened.isFormatted(at: 0))
    }

    func testDisplayTitlePrefersNameThenPreview() {
        let store = NotesStore(directory: directory)
        store.update("# Дежурство\nбла", at: 0)
        XCTAssertEqual(store.displayTitle(at: 0), "# Дежурство")  // имени нет — превью
        store.setName("Смена", at: 0)
        XCTAssertEqual(store.displayTitle(at: 0), "Смена")        // имя перекрывает превью
    }

    func testClearResetsTextNameAndFormat() {
        let store = NotesStore(directory: directory)
        store.update("текст", at: 3)
        store.setName("имя", at: 3)
        store.setFormatted(true, at: 3)
        store.persist(at: 3)

        store.clear(at: 3)
        XCTAssertEqual(store.text(at: 3), "")
        XCTAssertEqual(store.name(at: 3), "")
        XCTAssertFalse(store.isFormatted(at: 3))

        let reopened = NotesStore(directory: directory)  // очистка сохранена на диск
        XCTAssertTrue(reopened.isEmpty(at: 3))
        XCTAssertEqual(reopened.name(at: 3), "")
    }

    // MARK: - NotesListItem

    func testListItemUnorderedContinues() {
        let item = NotesListItem.parse("- пункт")
        XCTAssertEqual(item?.nextMarker, "- ")
        XCTAssertEqual(item?.prefixLength, 2)
        XCTAssertEqual(item?.contentEmpty, false)
    }

    func testListItemBulletAndIndentPreserved() {
        let item = NotesListItem.parse("  • пункт")
        XCTAssertEqual(item?.nextMarker, "  • ")  // отступ сохраняется
        XCTAssertEqual(item?.prefixLength, 4)
    }

    func testListItemOrderedIncrements() {
        let item = NotesListItem.parse("3. пункт")
        XCTAssertEqual(item?.nextMarker, "4. ")
        XCTAssertEqual(item?.prefixLength, 3)
    }

    func testListItemEmptyDetected() {
        XCTAssertEqual(NotesListItem.parse("- ")?.contentEmpty, true)
        XCTAssertEqual(NotesListItem.parse("1. \n")?.contentEmpty, true)  // хвостовой \n игнорируется
    }

    func testNonListLinesReturnNil() {
        XCTAssertNil(NotesListItem.parse("обычный текст"))
        XCTAssertNil(NotesListItem.parse("-нет пробела"))
        XCTAssertNil(NotesListItem.parse("# заголовок"))
    }

    func testOutOfRangeIndexIsSafe() {
        let store = NotesStore(directory: directory)
        store.update("ignored", at: NotesStore.count)   // за пределами — без эффекта, без краша
        store.update("ignored", at: -1)
        XCTAssertEqual(store.text(at: NotesStore.count), "")
        XCTAssertEqual(store.text(at: -1), "")
        XCTAssertFalse(store.persist(at: NotesStore.count))
    }
}
