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

    func testCorruptBlobYieldsEmptyCache() {
        secrets.set("not-json", for: "all")
        let store = makeStore()
        XCTAssertEqual(store.snippets, [])
        XCTAssertNil(store.value(for: "a"))
    }

    func testValueForUnknownIdReturnsNil() {
        let store = makeStore()
        store.upsert(Snippet(id: "a", name: "A"), value: "va")
        XCTAssertNil(store.value(for: "missing"))
    }

    func testDeleteUnknownIdIsNoOp() {
        let store = makeStore()
        store.upsert(Snippet(id: "a", name: "A"), value: "va")
        store.delete(id: "missing")
        XCTAssertEqual(store.snippets.map(\.id), ["a"])
    }

    func testSnippetDisplayNameUsesPlaceholderForEmptyName() {
        XCTAssertEqual(Snippet(name: "").displayName, "—")
        XCTAssertEqual(Snippet(name: "  ").displayName, "—")
        XCTAssertEqual(Snippet(name: "Room").displayName, "Room")
    }

    func testMigrationUsesEmptyStringWhenLegacyValueMissing() {
        seedLegacy([(id: "a", name: "A", value: "va")])
        secrets.delete("a")
        let store = makeStore()
        store.prepare()
        XCTAssertEqual(store.value(for: "a"), "")
    }

    func testPrepareIsIdempotent() {
        let store = makeStore()
        store.upsert(Snippet(id: "a", name: "A"), value: "va")
        store.prepare()
        store.prepare()
        XCTAssertEqual(store.snippets.map(\.name), ["A"])
    }

    func testDeleteAllOnEmptyStoreClearsBlobAccount() {
        secrets.set("stale", for: "all")
        let store = makeStore()
        store.deleteAll()
        XCTAssertNil(secrets.storage["all"])
    }

    // MARK: Тип сниппета (kind)

    func testKindDefaultsToSecret() {
        XCTAssertEqual(Snippet(name: "A").kind, .secret)
    }

    func testKindIsSecretFlag() {
        XCTAssertTrue(SnippetKind.secret.isSecret)
        XCTAssertFalse(SnippetKind.text.isSecret)
        XCTAssertFalse(SnippetKind.link.isSecret)
    }

    func testKindRoundTripsThroughStore() {
        let store = makeStore()
        store.upsert(Snippet(id: "a", name: "Pass", kind: .secret), value: "p")
        store.upsert(Snippet(id: "b", name: "Mail", kind: .text), value: "me@x.io")
        store.upsert(Snippet(id: "c", name: "Room", kind: .link), value: "https://meet.example/abc")

        let reloaded = makeStore()
        reloaded.prepare()
        XCTAssertEqual(reloaded.snippets.map(\.kind), [.secret, .text, .link])
    }

    func testBlobWithoutKindDecodesAsSecret() {
        // Блоб, записанный до появления `kind` (ключа нет ни у одной записи).
        secrets.set(#"[{"id":"a","name":"A","value":"va"}]"#, for: "all")
        let store = makeStore()
        XCTAssertEqual(store.snippets, [Snippet(id: "a", name: "A", kind: .secret)])
    }

    func testLinkActionDefaultsToOpen() {
        XCTAssertEqual(Snippet(name: "Room", kind: .link).linkAction, .open)
    }

    func testLinkActionRoundTripsThroughStore() {
        let store = makeStore()
        store.upsert(Snippet(id: "a", name: "Open", kind: .link, linkAction: .open), value: "https://a.io")
        store.upsert(Snippet(id: "b", name: "Copy", kind: .link, linkAction: .copy), value: "https://b.io")

        let reloaded = makeStore()
        reloaded.prepare()
        XCTAssertEqual(reloaded.snippets.map(\.linkAction), [.open, .copy])
    }

    func testBlobWithoutLinkActionDecodesAsOpen() {
        // Блоб с типом link, но без ключа linkAction (формат до этой фичи).
        secrets.set(#"[{"id":"a","name":"A","value":"https://a.io","kind":"link"}]"#, for: "all")
        let store = makeStore()
        XCTAssertEqual(store.snippets.first?.linkAction, .open)
    }

    func testPrimaryActivation() {
        XCTAssertEqual(Snippet(name: "p", kind: .secret).primaryActivation, .paste)
        XCTAssertEqual(Snippet(name: "t", kind: .text).primaryActivation, .paste)
        XCTAssertEqual(Snippet(name: "v", kind: .link, linkAction: .paste).primaryActivation, .paste)
        XCTAssertEqual(Snippet(name: "o", kind: .link, linkAction: .open).primaryActivation, .open)
        XCTAssertEqual(Snippet(name: "c", kind: .link, linkAction: .copy).primaryActivation, .copy)
        // linkAction у не-ссылки на основное действие не влияет.
        XCTAssertEqual(Snippet(name: "s", kind: .secret, linkAction: .copy).primaryActivation, .paste)
    }

    func testAvailableActivations() {
        // Секрет/текст: вставить + скопировать. Ссылка: ещё и открыть. Кнопки в строке —
        // ровно эти действия (вне зависимости от того, какое из них основное).
        XCTAssertEqual(Snippet(name: "s", kind: .secret).availableActivations, [.paste, .copy])
        XCTAssertEqual(Snippet(name: "t", kind: .text).availableActivations, [.paste, .copy])
        XCTAssertEqual(Snippet(name: "l", kind: .link).availableActivations, [.paste, .open, .copy])
    }

    func testLegacyMigrationDefaultsToSecret() {
        seedLegacy([(id: "a", name: "A", value: "va")])
        let store = makeStore()
        store.prepare()
        XCTAssertEqual(store.snippets.first?.kind, .secret)
    }

    // MARK: Нормализация URL для открытия ссылок

    func testURLForValueAddsHttpsWhenSchemeMissing() {
        XCTAssertEqual(Snippet.url(forValue: "meet.example.com/abc"),
                       URL(string: "https://meet.example.com/abc"))
    }

    func testURLForValueKeepsExistingScheme() {
        XCTAssertEqual(Snippet.url(forValue: "http://example.com"),
                       URL(string: "http://example.com"))
    }

    func testURLForValueTrimsWhitespace() {
        XCTAssertEqual(Snippet.url(forValue: "  https://example.com  "),
                       URL(string: "https://example.com"))
    }

    func testURLForValueRejectsNonHTTPAndEmpty() {
        XCTAssertNil(Snippet.url(forValue: ""))
        XCTAssertNil(Snippet.url(forValue: "   "))
        XCTAssertNil(Snippet.url(forValue: "ftp://example.com"))
        XCTAssertNil(Snippet.url(forValue: "not a url"))
    }

    func testURLForValuePreservesPathAndQuery() {
        XCTAssertEqual(Snippet.url(forValue: "alfabank.ktalk.ru/ibazhenov"),
                       URL(string: "https://alfabank.ktalk.ru/ibazhenov"))
        XCTAssertEqual(Snippet.url(forValue: "https://x.io/room?id=1&t=2"),
                       URL(string: "https://x.io/room?id=1&t=2"))
    }

    func testURLForValueAcceptsUppercaseScheme() {
        // Схема сравнивается без учёта регистра — «HTTPS://…» должен открываться.
        XCTAssertEqual(Snippet.url(forValue: "HTTPS://example.com")?.host, "example.com")
    }
}
