import XCTest
@testable import HopkeyCore

final class ClipboardHistoryTests: XCTestCase {

    /// In-memory ключ-хранилище — чтобы тесты не трогали настоящий Keychain.
    private final class MemorySecretStore: SnippetSecretStore {
        private(set) var storage: [String: String] = [:]
        func set(_ value: String, for account: String) { storage[account] = value }
        func value(for account: String) -> String? { storage[account] }
        func delete(_ account: String) { storage[account] = nil }
    }

    private var dir: URL!
    private var secrets: MemorySecretStore!
    /// Управляемое «сейчас» для детерминизма «даты добавления».
    private var now = Date(timeIntervalSince1970: 1_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)", isDirectory: true)
        secrets = MemorySecretStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeHistory(capacity: Int = 100, maxImageBytes: Int = 16 * 1024 * 1024) -> ClipboardHistory {
        ClipboardHistory(capacity: capacity, maxImageBytes: maxImageBytes, directory: dir,
                         keyStore: secrets, clock: { [unowned self] in self.now })
    }

    /// Тексты записей по порядку (картинки — как nil), для лаконичных ассертов.
    private func texts(_ h: ClipboardHistory) -> [String?] {
        h.entries.map { if case .text(let t) = $0.content { return t } else { return nil } }
    }

    // Небольшой валидный PNG (1×1) — генерируем через Data, чтобы не тянуть AppKit в core-тесты.
    // Здесь важен не рендер, а уникальность байтов для dedup/шифрования, поэтому используем
    // произвольные, но детерминированные данные.
    private func pngBytes(_ seed: UInt8) -> Data {
        Data((0..<64).map { _ in seed })
    }

    // MARK: - Текст (поведение прежнего кольца сохранено)

    func testRecordAddsToFront() {
        let h = makeHistory()
        h.record("a"); h.record("b")
        XCTAssertEqual(texts(h), ["b", "a"])
    }

    func testDuplicateMovesToFrontWithoutGrowing() {
        let h = makeHistory()
        h.record("a"); h.record("b"); h.record("a")
        XCTAssertEqual(texts(h), ["a", "b"])
    }

    func testCapacityEnforced() {
        let h = makeHistory(capacity: 3)
        ["1", "2", "3", "4"].forEach { h.record($0) }
        XCTAssertEqual(texts(h), ["4", "3", "2"])
    }

    func testEmptyOrWhitespaceIgnored() {
        let h = makeHistory()
        h.record(""); h.record("   \n")
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testClear() {
        let h = makeHistory()
        h.record("a"); h.clear()
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testDeleteByIdRemovesOnlyThatEntry() {
        let h = makeHistory()
        h.record("a"); h.record("b"); h.record("c")
        let idB = h.entries.first { if case .text("b") = $0.content { return true } else { return false } }!.id
        h.delete(id: idB)
        XCTAssertEqual(texts(h), ["c", "a"])
    }

    func testDeleteUnknownIdIsNoop() {
        let h = makeHistory()
        h.record("a")
        h.delete(id: "does-not-exist")
        XCTAssertEqual(texts(h), ["a"])
    }

    func testDeleteImageRemovesFileAndSurvivesReload() {
        let h = makeHistory()
        h.record(imagePNG: pngBytes(9), pixelWidth: 1, pixelHeight: 1)
        let entry = h.entries.first!
        guard case .image(let ref) = entry.content else { return XCTFail() }
        h.delete(id: entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ref.file).path))
        XCTAssertTrue(makeHistory().entries.isEmpty)                      // удаление персистентно
    }

    // MARK: - Картинки

    func testRecordImageAddsEntryAndFile() {
        let h = makeHistory()
        h.record(imagePNG: pngBytes(1), pixelWidth: 10, pixelHeight: 20)
        guard case .image(let ref) = h.entries.first?.content else { return XCTFail("ожидалась картинка") }
        XCTAssertEqual(ref.pixelWidth, 10)
        XCTAssertEqual(ref.pixelHeight, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ref.file).path))
        XCTAssertEqual(h.imageData(for: ref), pngBytes(1))
    }

    func testImageDedupByContentWithoutSecondFile() {
        let h = makeHistory()
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1)
        h.record("between")
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1)   // тот же контент
        XCTAssertEqual(h.entries.count, 2)                                // картинка всплыла, не задвоилась
        let imgFiles = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasPrefix("img-") } ?? []
        XCTAssertEqual(imgFiles.count, 1)                                 // второго файла нет
        guard case .image = h.entries.first?.content else { return XCTFail("картинка должна быть сверху") }
    }

    func testEvictionDeletesImageFile() {
        let h = makeHistory(capacity: 1)
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1)
        guard case .image(let ref) = h.entries.first?.content else { return XCTFail() }
        h.record("push out")                                             // вытесняет картинку
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(ref.file).path))
    }

    func testImageOverSizeLimitIgnored() {
        let h = makeHistory(maxImageBytes: 32)
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1)   // 64 байта > 32
        XCTAssertTrue(h.entries.isEmpty)
    }

    // MARK: - Персистентность и шифрование

    func testSurvivesReload() {
        let h = makeHistory()
        h.record("a")
        h.record(imagePNG: pngBytes(7), pixelWidth: 3, pixelHeight: 4)

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.count, 2)
        guard case .image(let ref) = reloaded.entries.first?.content else { return XCTFail("картинка сверху") }
        XCTAssertEqual(reloaded.imageData(for: ref), pngBytes(7))
        XCTAssertEqual(texts(reloaded), [nil, "a"])
    }

    func testManifestOnDiskIsEncrypted() throws {
        let h = makeHistory()
        h.record("PLAINTEXT-MARKER")
        let raw = try Data(contentsOf: dir.appendingPathComponent("manifest.enc"))
        XCTAssertNil(raw.range(of: Data("PLAINTEXT-MARKER".utf8)))       // на диске не плейнтекст
    }

    func testOrphanImageFileCollectedOnLoad() throws {
        makeHistory().record("seed")                                     // создаёт каталог + манифест
        let orphan = dir.appendingPathComponent("img-orphan.enc")
        try Data("junk".utf8).write(to: orphan)
        _ = makeHistory().entries                                        // prepare/ensureLoaded → GC
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testCorruptManifestYieldsEmptyHistory() throws {
        makeHistory().record("seed")                                     // ключ + каталог + манифест
        try Data("not a valid sealed box".utf8)
            .write(to: dir.appendingPathComponent("manifest.enc"))
        XCTAssertTrue(makeHistory().entries.isEmpty)                     // не падаем, пустая история
    }

    // MARK: - Дата добавления и приложение-источник

    func testRecordStoresCreatedAtAndSource() {
        let h = makeHistory()
        now = Date(timeIntervalSince1970: 5_000)
        h.record("a", source: ClipboardSource(appName: "Safari", bundleID: "com.apple.Safari"))
        let entry = h.entries.first
        XCTAssertEqual(entry?.createdAt, Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(entry?.source?.appName, "Safari")
        XCTAssertEqual(entry?.source?.bundleID, "com.apple.Safari")
    }

    func testRecordWithoutSourceHasNilSource() {
        let h = makeHistory()
        h.record("a")
        XCTAssertNil(h.entries.first?.source)
    }

    func testDuplicateTextUpdatesDateAndSource() {
        let h = makeHistory()
        now = Date(timeIntervalSince1970: 1_000)
        h.record("a", source: ClipboardSource(appName: "Safari", bundleID: "s"))
        now = Date(timeIntervalSince1970: 2_000)
        h.record("a", source: ClipboardSource(appName: "Notes", bundleID: "n"))
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertEqual(h.entries.first?.createdAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(h.entries.first?.source?.appName, "Notes")
    }

    func testDuplicateImageUpdatesDateAndSource() {
        let h = makeHistory()
        now = Date(timeIntervalSince1970: 1_000)
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1,
                 source: ClipboardSource(appName: "Preview", bundleID: "p"))
        now = Date(timeIntervalSince1970: 2_000)
        h.record(imagePNG: pngBytes(1), pixelWidth: 1, pixelHeight: 1,
                 source: ClipboardSource(appName: "Photos", bundleID: "ph"))
        XCTAssertEqual(h.entries.count, 1)
        XCTAssertEqual(h.entries.first?.createdAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(h.entries.first?.source?.appName, "Photos")
    }

    func testDateAndSourceSurviveReload() {
        let h = makeHistory()
        now = Date(timeIntervalSince1970: 7_777)
        h.record("a", source: ClipboardSource(appName: "Xcode", bundleID: "com.apple.dt.Xcode"))

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.entries.first?.createdAt, Date(timeIntervalSince1970: 7_777))
        XCTAssertEqual(reloaded.entries.first?.source?.appName, "Xcode")
        XCTAssertEqual(reloaded.entries.first?.source?.bundleID, "com.apple.dt.Xcode")
    }
}
