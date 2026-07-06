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

    func testOutOfRangeIndexIsSafe() {
        let store = NotesStore(directory: directory)
        store.update("ignored", at: NotesStore.count)   // за пределами — без эффекта, без краша
        store.update("ignored", at: -1)
        XCTAssertEqual(store.text(at: NotesStore.count), "")
        XCTAssertEqual(store.text(at: -1), "")
        XCTAssertFalse(store.persist(at: NotesStore.count))
    }
}
