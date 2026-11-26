import BoopstashCore
import Foundation
import Observation

/// Settings ▸ Model and what the workbench's generator reads (ADR 0014):
/// the endpoint the user configured, the model list last fetched from it,
/// and the API key's place in the Keychain. What the settings mean, their
/// ranges and what a request holds are Core's (`ModelEndpointSettings`,
/// `ModelEndpointGenerator`); this keeps them and asks the helper.
///
/// Every request here is the user's: the model list is fetched when they
/// enter the base URL or press Refresh, and Test is a button. Nothing is
/// fetched when Settings opens, at launch or on a timer, and nothing at
/// all while no endpoint is configured.
@MainActor
@Observable
final class ModelEndpointStore {
    static let settingsKey = "modelEndpoint"
    /// The model list last fetched and the base URL it came from, so that
    /// opening Settings shows it without a request.
    static let listKey = "modelEndpointList"

    struct SavedList: Codable, Equatable {
        var baseURL: String
        var models: [String]
    }

    struct TestResult: Equatable {
        var passed: Bool
        var text: String
    }

    private(set) var settings: ModelEndpointSettings
    /// The service's models, nil when no list was fetched for this URL.
    private(set) var listed: [String]?
    /// Why there is no list, after a fetch that failed.
    private(set) var listProblem: String?
    private(set) var isListing = false
    private(set) var testResult: TestResult?
    private(set) var isTesting = false
    /// What the pane says under a generation setting it had to change.
    private(set) var notes: [ModelGenerationSettings.Field: String] = [:]
    /// Why the extra request fields last typed were refused.
    private(set) var extraFieldsProblem: String?
    /// Whether a key is saved for this endpoint, and why it could not be
    /// saved or read if not.
    private(set) var hasKey = false
    private(set) var keyProblem: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: any ModelKeyStore
    @ObservationIgnored private let transport: ModelEndpointGenerator.Transport
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var testing: Task<Void, Never>?

    /// The user's own: their settings, their Keychain and the model
    /// helper. `AppModel.live()` makes the one there is; nothing else
    /// does, so a test never reads the settings or the Keychain of
    /// whoever runs it (#283).
    static func live() -> ModelEndpointStore {
        ModelEndpointStore(defaults: .standard, keys: KeychainModelKeyStore(), transport: LiveModelService.send)
    }

    /// Where the settings are kept, where the key is, and what makes a
    /// request: all three are said, never assumed.
    init(defaults: UserDefaults, keys: any ModelKeyStore, transport: @escaping ModelEndpointGenerator.Transport) {
        self.defaults = defaults
        self.keys = keys
        self.transport = transport
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(ModelEndpointSettings.self, from: $0) } ?? ModelEndpointSettings()
        if let saved = defaults.data(forKey: Self.listKey).flatMap({ try? JSONDecoder().decode(SavedList.self, from: $0) }),
           saved.baseURL == settings.baseURL {
            listed = saved.models
        }
    }

    // MARK: What the pane shows

    var state: ModelEndpointSettings.State { settings.state }

    /// The checked address, when the base URL is one.
    var address: ModelEndpointAddress? {
        try? ModelEndpointAddress.parse(settings.baseURL).get()
    }

    /// What is wrong with the base URL, when something is typed and it
    /// is not an address.
    var addressProblem: String? {
        guard !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if case .failure(let problem) = ModelEndpointAddress.parse(settings.baseURL) { return problem.message }
        return nil
    }

    /// The mark beside the endpoint, once there is one.
    var indicator: ModelEndpointIndicator? {
        address.map { ModelEndpointIndicator(address: $0, place: .settings) }
    }

    /// The model field's rows, or nil when it takes a typed name: no
    /// list was fetched, or the service lists nothing.
    var modelOptions: [ModelList.Option]? {
        guard let listed, !listed.isEmpty else { return nil }
        return ModelList.options(listed: listed, chosen: settings.model)
    }

    /// Why the model field takes a typed name, when it does.
    var listNote: String? {
        if let listProblem { return "The model list could not be fetched, so type the model's name. \(listProblem)" }
        if listed?.isEmpty == true { return "The service lists no models, so type the model's name." }
        if listed == nil, address != nil { return "Press Refresh to fetch the service's model list, or type the model's name." }
        return nil
    }

    // MARK: The workbench's generator

    /// The generator the workbench asks. It reads the settings and the
    /// key when a request is made, so a change in Settings counts at once.
    nonisolated var generator: ModelEndpointGenerator {
        ModelEndpointGenerator(
            settings: { [weak self] in await self?.settings ?? ModelEndpointSettings() },
            apiKey: { [keys] address in try keys.read(account: address.keyAccount) },
            transport: transport)
    }

    /// The key saved for the endpoint in the settings, read from the
    /// Keychain now.
    func key() throws -> String? {
        guard let address else { return nil }
        return try keys.read(account: address.keyAccount)
    }

    // MARK: Changes

    /// The base URL as entered. A new address has no list yet, and its
    /// own key or none. Returns whether it changed.
    @discardableResult
    func setBaseURL(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != settings.baseURL else { return false }
        listing?.cancel()
        isListing = false
        forgetTest()
        settings.baseURL = text
        listed = nil
        listProblem = nil
        defaults.removeObject(forKey: Self.listKey)
        save()
        refreshKeyState()
        return true
    }

    func setModel(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != settings.model else { return }
        settings.model = name
        forgetTest()
        save()
    }

    /// A test is of the settings it was made with: when any of them
    /// changes, a test in flight is cancelled and a result shown is taken
    /// away, so the pane never shows a verdict on settings it no longer
    /// shows.
    private func forgetTest() {
        testing?.cancel()
        testing = nil
        isTesting = false
        testResult = nil
    }

    /// Saves `key` in the Keychain for this endpoint; an empty key
    /// removes it. The key goes nowhere else.
    func setKey(_ key: String) {
        guard let address else {
            keyProblem = "Enter the base URL first: a key is kept for the endpoint it belongs to."
            return
        }
        do {
            try keys.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: address.keyAccount)
            keyProblem = nil
        } catch {
            keyProblem = "The key could not be saved in the Keychain. \(error.localizedDescription)"
        }
        forgetTest()
        refreshKeyState(keepingProblem: true)
    }

    /// Whether the Keychain holds a key for this endpoint. Reads the
    /// Keychain; called when the pane appears and when the address or the
    /// key changes.
    func refreshKeyState(keepingProblem: Bool = false) {
        if !keepingProblem { keyProblem = nil }
        guard address != nil else {
            hasKey = false
            return
        }
        do {
            hasKey = try key() != nil
        } catch {
            hasKey = false
            if !keepingProblem { keyProblem = "The Keychain could not be read. \(error.localizedDescription)" }
        }
    }

    /// A generation setting as typed: kept in range, with a note when it
    /// is not what was typed.
    func enter(_ text: String, in field: ModelGenerationSettings.Field) {
        // Another field may have moved with it (the reply limit follows
        // the context length), and then has a note of its own.
        let (settled, said) = settings.generation.entering(text, in: field)
        if settled != settings.generation { forgetTest() }
        settings.generation = settled
        notes = said
        save()
    }

    /// The extra request fields as typed. Text that is not a JSON object
    /// is refused, with the reason, and the fields stay as they were.
    @discardableResult
    func setExtraFields(_ text: String) -> Bool {
        if let problem = ModelExtraFields.problem(in: text) {
            extraFieldsProblem = problem
            return false
        }
        extraFieldsProblem = nil
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if fields != settings.generation.extraFields { forgetTest() }
        settings.generation.extraFields = fields
        save()
        return true
    }

    func resetGeneration() {
        if settings.generation != .defaults { forgetTest() }
        settings.generation = .defaults
        notes = [:]
        extraFieldsProblem = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Requests, each on the user's action

    /// Fetches the service's model list: when the base URL was entered,
    /// and on Refresh. Sends the key and nothing else.
    @discardableResult
    func refreshModels() -> Task<Void, Never>? {
        guard address != nil else { return nil }
        listing?.cancel()
        let asked = settings
        isListing = true
        let task = Task { [weak self, transport, keys] in
            // The key is read for the address asked, whatever the
            // settings have become since.
            let result = await ModelEndpointGenerator.models(
                settings: asked, apiKey: { address in try keys.read(account: address.keyAccount) }, transport: transport)
            guard let self, !Task.isCancelled, self.settings.baseURL == asked.baseURL else { return }
            self.isListing = false
            switch result {
            case .success(let models):
                self.listed = models
                self.listProblem = nil
                let saved = SavedList(baseURL: asked.baseURL, models: models)
                if let data = try? JSONEncoder().encode(saved) { self.defaults.set(data, forKey: Self.listKey) }
            case .failure(let failure):
                self.listed = nil
                self.listProblem = failure.reason
                self.defaults.removeObject(forKey: Self.listKey)
            }
        }
        listing = task
        return task
    }

    /// Settings ▸ Model ▸ Test: one request like Generate's, with a
    /// built-in instruction and sample, and what came of it.
    @discardableResult
    func test() -> Task<Void, Never>? {
        guard case .ready = state, !isTesting else {
            if case .incomplete(let reason) = state { testResult = TestResult(passed: false, text: reason) }
            return nil
        }
        isTesting = true
        testResult = nil
        let generator = generator
        let task = Task { [weak self] in
            let result = await generator.generate(ModelEndpointGenerator.testRequest)
            // Cancelled: the settings changed, and whoever changed them
            // already took this test away.
            guard let self, !Task.isCancelled else { return }
            self.isTesting = false
            let verdict = ModelEndpointGenerator.testVerdict(result)
            self.testResult = TestResult(passed: verdict.passed, text: verdict.text)
        }
        testing = task
        return task
    }
}
