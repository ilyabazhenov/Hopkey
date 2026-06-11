import XCTest
@testable import HopkeyCore

final class SnippetStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    /// In-memory секрет-хранилище — чтобы тесты не трогали настоящий Keychain.
    private final class MemorySecretStore: SnippetSecretStore {
        private(set) var storage: [String: String] = [:]
        func set(_ value: String, for account: String) { storage[account] = value }
        func value(for account: String) -> String? { storage[account] }
        func delete(_ account: String) { storage[account] = nil }
    }

    private var secrets: MemorySecretStore!

    override func setUpWithError() throws {
        suiteName = "SnippetStoreTests-\(name)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        secrets = MemorySecretStore()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> SnippetStore {
        SnippetStore(defaults: defaults, keychain: secrets)
    }

    func testEmptyByDefault() {
        let store = makeStore()
        store.prepare()
        XCTAssertEqual(store.snippets, [])
    }

    func testUpsertReadsBackAndSurvivesReload() {
        let store = makeStore()
        store.prepare()
        let snippet = Snippet(id: "a", name: "Room")
        store.upsert(snippet, value: "secret-value")

        XCTAssertEqual(store.snippets, [snippet])
        XCTAssertEqual(store.value(for: "a"), "secret-value")

        // Всё лежит ОДНОЙ записью-блобом, а не пер-сниппет.
        XCTAssertNotNil(secrets.storage["all"])
        XCTAssertNil(secrets.storage["a"])

        // Новый объект на том же хранилище читает блоб и видит то же.
        let reloaded = makeStore()
        reloaded.prepare()
        XCTAssertEqual(reloaded.snippets, [snippet])
        XCTAssertEqual(reloaded.value(for: "a"), "secret-value")
    }

    func testUpsertUpdatesExistingInPlace() {
        let store = makeStore()
        store.prepare()
        store.upsert(Snippet(id: "a", name: "Old"), value: "v1")
        store.upsert(Snippet(id: "b", name: "Other"), value: "x")
        store.upsert(Snippet(id: "a", name: "New"), value: "v2")

        XCTAssertEqual(store.snippets.map(\.name), ["New", "Other"])
        XCTAssertEqual(store.value(for: "a"), "v2")
    }

    func testDeleteRemovesFromBlob() {
        let store = makeStore()
        store.prepare()
        store.upsert(Snippet(id: "a", name: "Room"), value: "v")
        store.delete(id: "a")

        XCTAssertEqual(store.snippets, [])
        XCTAssertNil(store.value(for: "a"))
        let reloaded = makeStore()
        reloaded.prepare()
        XCTAssertEqual(reloaded.snippets, [])
    }

    func testDeleteAllClearsKeychain() {
        let store = makeStore()
        store.prepare()
        store.upsert(Snippet(id: "a", name: "A"), value: "va")
        store.deleteAll()

        XCTAssertEqual(store.snippets, [])
        XCTAssertNil(secrets.storage["all"])
    }

    // MARK: Миграция со старого формата (метаданные в UserDefaults + значение на сниппет)

    private func seedLegacy(_ items: [(id: String, name: String, value: String)]) {
        let metas = items.map { Snippet(id: $0.id, name: $0.name) }
        defaults.set(try! JSONEncoder().encode(metas), forKey: "snippets")
        items.forEach { secrets.set($0.value, for: $0.id) }
    }

    func testMigrationFoldsLegacyIntoBlob() {
        seedLegacy([(id: "a", name: "A", value: "va"), (id: "b", name: "B", value: "vb")])

        let store = makeStore()
        store.prepare()  // выполняет миграцию

        XCTAssertEqual(store.snippets.map(\.name), ["A", "B"])
        XCTAssertEqual(store.value(for: "a"), "va")
        XCTAssertEqual(store.value(for: "b"), "vb")
        // Всё переехало в единый блоб; старые пер-ключевые записи и legacy-метаданные убраны.
        XCTAssertNotNil(secrets.storage["all"])
        XCTAssertNil(secrets.storage["a"])
        XCTAssertNil(secrets.storage["b"])
        XCTAssertNil(defaults.data(forKey: "snippets"))
    }

    func testMigrationRunsOnce() {
        seedLegacy([(id: "a", name: "A", value: "va")])
        makeStore().prepare()  // мигрировали и поставили флаг

        // Заново «подкинутые» legacy-данные больше не подхватываются.
        seedLegacy([(id: "z", name: "Z", value: "vz")])
        let store = makeStore()
        store.prepare()
        XCTAssertFalse(store.snippets.contains { $0.name == "Z" })
    }

    func testNoMigrationWhenNoLegacy() {
        let store = makeStore()
        store.prepare()
        XCTAssertEqual(store.snippets, [])
        XCTAssertNil(secrets.storage["all"])
    }

    // MARK: Ленивая загрузка (без явного prepare())

    func testSnippetsAccessLazilyLoadsAndMigrates() {
        seedLegacy([(id: "a", name: "A", value: "va")])
        let store = makeStore()
        // prepare() НЕ вызываем — само обращение к списку должно загрузить и мигрировать.
        XCTAssertEqual(store.snippets.map(\.name), ["A"])
        XCTAssertEqual(store.value(for: "a"), "va")
        XCTAssertNotNil(secrets.storage["all"])  // переехало в блоб
    }

    func testValueAccessLazilyLoads() {
        let writer = makeStore()
        writer.upsert(Snippet(id: "a", name: "A"), value: "va")
        // Свежий объект: первое обращение — value(for:), без prepare() — должно подхватить блоб.
        let reader = makeStore()
        XCTAssertEqual(reader.value(for: "a"), "va")
    }
}
