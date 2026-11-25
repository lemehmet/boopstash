import Foundation

/// What the user set up in Settings ▸ Model (ADR 0014): where their own
/// model is served, which model, and how a request is made. The API key is
/// not here: it lives in the Keychain and nowhere else.
public struct ModelEndpointSettings: Sendable, Hashable, Codable {
    /// The base URL as typed. Empty means the feature is off.
    public var baseURL: String
    /// The model's name, as the service lists it or as typed.
    public var model: String
    public var generation: ModelGenerationSettings

    public init(baseURL: String = "", model: String = "", generation: ModelGenerationSettings = .defaults) {
        self.baseURL = baseURL
        self.model = model
        self.generation = generation
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        generation = try values.decodeIfPresent(ModelGenerationSettings.self, forKey: .generation) ?? .defaults
    }

    /// What the settings amount to.
    public enum State: Sendable, Hashable {
        /// No base URL: the feature does not exist in the interface.
        case off
        /// A base URL is set, and something stops a request; why, in a
        /// sentence.
        case incomplete(String)
        case ready(ModelEndpointAddress)
    }

    public var state: State {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .off }
        let address: ModelEndpointAddress
        switch ModelEndpointAddress.parse(baseURL) {
        case .success(let parsed): address = parsed
        case .failure(let problem): return .incomplete(problem.message)
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .incomplete("No model is chosen in Settings ▸ Model.")
        }
        if let problem = ModelExtraFields.problem(in: generation.extraFields) {
            return .incomplete("The extra request fields in Settings ▸ Model cannot be used: \(problem)")
        }
        return .ready(address)
    }
}

/// How a request is made. Each has a default and a valid range; a value
/// out of range is clamped, never sent as it is.
public struct ModelGenerationSettings: Sendable, Hashable, Codable {
    /// Tokens the model accepts, which bounds the sample and the examples.
    public var contextLength: Int
    /// Tokens the reply may have.
    public var maxReplyTokens: Int
    public var temperature: Double
    public var topP: Double
    /// Seconds a request may take, the model's loading included.
    public var timeLimit: Double
    /// A JSON object merged into each request, as text; empty for none.
    public var extraFields: String

    public init(contextLength: Int, maxReplyTokens: Int, temperature: Double, topP: Double, timeLimit: Double, extraFields: String) {
        self.contextLength = contextLength
        self.maxReplyTokens = maxReplyTokens
        self.temperature = temperature
        self.topP = topP
        self.timeLimit = timeLimit
        self.extraFields = extraFields
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        contextLength = try values.decodeIfPresent(Int.self, forKey: .contextLength) ?? defaults.contextLength
        maxReplyTokens = try values.decodeIfPresent(Int.self, forKey: .maxReplyTokens) ?? defaults.maxReplyTokens
        temperature = try values.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        topP = try values.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
        timeLimit = try values.decodeIfPresent(Double.self, forKey: .timeLimit) ?? defaults.timeLimit
        extraFields = try values.decodeIfPresent(String.self, forKey: .extraFields) ?? defaults.extraFields
    }

    /// The defaults assume a model with its reasoning switched off and a
    /// long context, which is what ADR 0014's measurements favour.
    public static let defaults = ModelGenerationSettings(
        contextLength: 32_768, maxReplyTokens: 2_048, temperature: 0.2, topP: 1.0, timeLimit: 180, extraFields: "")

    public static let contextLengthRange = 2_048...2_000_000
    public static let maxReplyTokensRange = 64...65_536
    public static let temperatureRange = 0.0...2.0
    public static let topPRange = 0.0...1.0
    public static let timeLimitRange = 5.0...1_800.0
    /// Tokens of the context a reply may never take: the fixed prompt and
    /// the instruction need room whatever the reply limit is.
    public static let contextReserve = 1_024

    /// The numeric settings, for the pane's fields and what it says of a
    /// value it had to change.
    public enum Field: String, Sendable, CaseIterable, Identifiable {
        case contextLength, maxReplyTokens, temperature, topP, timeLimit

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .contextLength: "Context length (tokens)"
            case .maxReplyTokens: "Maximum reply (tokens)"
            case .temperature: "Temperature"
            case .topP: "Top-p"
            case .timeLimit: "Time limit (seconds)"
            }
        }

        var isWhole: Bool { self == .contextLength || self == .maxReplyTokens || self == .timeLimit }

        var range: ClosedRange<Double> {
            switch self {
            case .contextLength: Double(contextLengthRange.lowerBound)...Double(contextLengthRange.upperBound)
            case .maxReplyTokens: Double(maxReplyTokensRange.lowerBound)...Double(maxReplyTokensRange.upperBound)
            case .temperature: temperatureRange
            case .topP: topPRange
            case .timeLimit: timeLimitRange
            }
        }
    }

    public subscript(field: Field) -> Double {
        get {
            switch field {
            case .contextLength: Double(contextLength)
            case .maxReplyTokens: Double(maxReplyTokens)
            case .temperature: temperature
            case .topP: topP
            case .timeLimit: timeLimit
            }
        }
        set {
            switch field {
            case .contextLength: contextLength = Self.whole(newValue)
            case .maxReplyTokens: maxReplyTokens = Self.whole(newValue)
            case .temperature: temperature = newValue
            case .topP: topP = newValue
            case .timeLimit: timeLimit = newValue
            }
        }
    }

    /// A value as the pane's field shows it: whole numbers without a
    /// fraction, the others as short as they read back.
    public func text(_ field: Field) -> String {
        Self.text(self[field], whole: field.isWhole)
    }

    /// What typing `text` into `field` gives: the settings with every
    /// value in range, and a note for each value that is not what it was:
    /// the field typed into, and the reply limit when a smaller context
    /// moved it. Text that is not a number puts the default back.
    public func entering(_ text: String, in field: Field) -> (settings: ModelGenerationSettings, notes: [Field: String]) {
        var changed = self
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        var said: String?
        if let typed = Double(trimmed), typed.isFinite {
            changed[field] = field.isWhole ? typed.rounded() : typed
        } else {
            changed[field] = Self.defaults[field]
            said = "\"\(text)\" is not a number; the default, \(Self.defaults.text(field)), is back."
        }
        var (settled, notes) = changed.clamped()
        if let said { notes[field] = said }
        return (settled, notes)
    }

    /// The settings with every value in its range, and for each value that
    /// had to change, what to say. The reply limit also leaves
    /// `contextReserve` tokens of the context free.
    public func clamped() -> (settings: ModelGenerationSettings, notes: [Field: String]) {
        var settled = self
        var notes: [Field: String] = [:]
        for field in Field.allCases {
            let value = self[field]
            let range = field.range
            let inRange = value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : Self.defaults[field]
            if inRange != value || !value.isFinite {
                settled[field] = inRange
                let low = Self.text(range.lowerBound, whole: field.isWhole)
                let high = Self.text(range.upperBound, whole: field.isWhole)
                notes[field] = "Must be between \(low) and \(high); set to \(Self.text(inRange, whole: field.isWhole))."
            }
        }
        let most = settled.contextLength - Self.contextReserve
        if settled.maxReplyTokens > most {
            settled.maxReplyTokens = most
            notes[.maxReplyTokens] = "The reply must leave \(Self.contextReserve) tokens of the context free; set to \(most)."
        }
        return (settled, notes)
    }

    private static func whole(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(value.rounded(), -1e15), 1e15))
    }

    private static func text(_ value: Double, whole: Bool) -> String {
        if whole || value == value.rounded() && abs(value) < 1e15 {
            return whole ? String(Self.whole(value)) : String(format: "%.1f", value)
        }
        // Up to four decimals, without trailing zeros.
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}

/// The extra request fields: a JSON object merged into each request, for
/// what the server at hand needs (mostly: reasoning off).
public enum ModelExtraFields {
    /// Fields a request sets itself and the extra fields may not replace:
    /// the conversation is the instruction and the sample the workbench
    /// showed, the model is the one chosen, and the reply is not streamed.
    public static let reserved: Set<String> = ["messages", "model", "stream"]

    /// Why `text` cannot be used, or nil when it can. Empty text is no
    /// extra fields.
    public static func problem(in text: String) -> String? {
        switch parse(text) {
        case .success: nil
        case .failure(let refusal): refusal.reason
        }
    }

    public struct Refusal: Error, Sendable, Hashable {
        public var reason: String
    }

    /// The object `text` holds, as a dictionary of JSON values; empty for
    /// empty text.
    public static func parse(_ text: String) -> Result<[String: Any], Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success([:]) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) else {
            return .failure(Refusal(reason: "This is not valid JSON. It must be a JSON object, like {\"name\": value}."))
        }
        guard let object = value as? [String: Any] else {
            return .failure(Refusal(reason: "This is JSON but not an object. It must be a JSON object, like {\"name\": value}."))
        }
        if let taken = object.keys.sorted().first(where: reserved.contains) {
            return .failure(Refusal(reason: "\"\(taken)\" is set by BoopStash and cannot be replaced here."))
        }
        return .success(object)
    }
}

/// How a kind of server spells "do not reason first", for the help beside
/// the extra request fields. Each entry was checked against the server's
/// own documentation or measured (ADR 0014), and says where it is known
/// to work.
public struct ModelDialect: Sendable, Hashable, Identifiable {
    /// The servers, as the menu names them.
    public var name: String
    /// The extra request fields, ready to use.
    public var fields: String
    /// What it is known to do, and where it does not.
    public var note: String

    public var id: String { name }

    public static let all: [ModelDialect] = [
        ModelDialect(
            name: "llama.cpp, llama-swap, vLLM",
            fields: #"{"chat_template_kwargs":{"enable_thinking":false}}"#,
            note: "For models whose chat template has an enable_thinking switch, such as Qwen3. Measured for ADR 0014; documented by vLLM."),
        ModelDialect(
            name: "Ollama",
            fields: #"{"reasoning_effort":"none"}"#,
            note: "Asks for no thinking. A model that cannot switch thinking off uses its lowest level instead."),
        ModelDialect(
            name: "Servers that take OpenAI's reasoning_effort",
            fields: #"{"reasoning_effort":"none"}"#,
            note: "The values depend on the model. Where \"none\" is refused, use \"minimal\" or \"low\"."),
    ]

    /// The mark beside the extra request fields: its hover text and its
    /// accessibility label.
    public static let mark = "ⓘ"

    public static var help: String {
        let entries = all.map { "\($0.name):\n\($0.fields)\n\($0.note)" }
        return "Fields that switch a model's reasoning off, by kind of server. Click to fill the field.\n\n"
            + entries.joined(separator: "\n\n")
    }
}

/// Where a host is, as far as its name or address says.
public enum ModelHostLocality: Sendable, Hashable, Codable {
    case thisMac
    case localNetwork
    case elsewhere

    /// Classifies a URL's host: loopback addresses and `localhost` are
    /// this Mac; private and link-local addresses, `.local` names and bare
    /// host names are the local network; everything else, and everything
    /// that cannot be told, is elsewhere. Numbers in other spellings
    /// (`2130706433`, `0x7f.1`, `010.0.0.1`) are elsewhere: they reach
    /// whatever address the resolver reads them as.
    public static func of(host: String) -> ModelHostLocality {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            // An IPv6 address; a zone (`%en0`) names an interface here.
            let address = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? host
            return ipv6(address)
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return .elsewhere }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.contains(where: \.isEmpty) { return .elsewhere }
        if let octets = dottedQuad(labels) { return ipv4(octets) }
        // A last label that reads as a number is an address in another
        // spelling, not a name.
        if let last = labels.last, looksNumeric(last) { return .elsewhere }
        if host == "localhost" { return .thisMac }
        if labels.count == 1 || labels.last == "local" { return .localNetwork }
        return .elsewhere
    }

    private static func looksNumeric(_ label: Substring) -> Bool {
        if label.hasPrefix("0x") { return true }
        return label.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Four decimal octets, each written without a leading zero.
    private static func dottedQuad(_ labels: [Substring]) -> [UInt8]? {
        guard labels.count == 4 else { return nil }
        var octets: [UInt8] = []
        for label in labels {
            guard !label.isEmpty, label.count <= 3, label.allSatisfy({ $0.isASCII && $0.isNumber }),
                  label.count == 1 || !label.hasPrefix("0"), let octet = UInt8(label)
            else { return nil }
            octets.append(octet)
        }
        return octets
    }

    private static func ipv4(_ octets: [UInt8]) -> ModelHostLocality {
        switch (octets[0], octets[1]) {
        case (127, _): .thisMac
        case (10, _), (192, 168), (169, 254): .localNetwork
        case (172, 16...31): .localNetwork
        default: .elsewhere
        }
    }

    private static func ipv6(_ text: String) -> ModelHostLocality {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return .elsewhere }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes[15] == 1 { return .thisMac }
        // An IPv4 address mapped into IPv6 is where that address is.
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            return ipv4(Array(bytes[12..<16]))
        }
        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { return .localNetwork }
        if bytes[0] & 0xfe == 0xfc { return .localNetwork }
        return .elsewhere
    }
}

/// The base URL the user typed, checked.
public struct ModelEndpointAddress: Sendable, Hashable {
    public var url: URL
    /// The host, with its port when the URL names one: what the interface
    /// calls the destination.
    public var host: String
    public var locality: ModelHostLocality

    public enum Problem: Error, Sendable, Hashable {
        case notAURL
        case scheme
        case noHost
        case credentials
        case query
        case plainHTTP(host: String)

        public var message: String {
            switch self {
            case .notAURL: "The base URL is not a URL. It looks like http://localhost:8080 or https://models.example."
            case .scheme: "The base URL must start with http:// or https://."
            case .noHost: "The base URL names no host."
            case .credentials: "The base URL must not hold a user name or password. Put the key in the API key field, which keeps it in the Keychain."
            case .query: "The base URL must not have a query or a fragment."
            case .plainHTTP(let host):
                "\(host) is not on this Mac or the local network, so the base URL must start with https://. Plain http:// is for local addresses only."
            }
        }
    }

    /// The address `text` names. Plain HTTP is accepted for this Mac and
    /// the local network only; a URL with a user name, a password, a query
    /// or a fragment is refused, as each would be kept outside the
    /// Keychain or sent on every request.
    public static func parse(_ text: String) -> Result<ModelEndpointAddress, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.notAURL)
        }
        guard scheme == "http" || scheme == "https" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.noHost) }
        guard components.user == nil, components.password == nil else { return .failure(.credentials) }
        guard components.query == nil, components.fragment == nil else { return .failure(.query) }
        guard let url = components.url else { return .failure(.notAURL) }
        let locality = ModelHostLocality.of(host: host)
        let shown = components.port.map { "\(host):\($0)" } ?? host
        if scheme == "http", locality == .elsewhere { return .failure(.plainHTTP(host: shown)) }
        return .success(ModelEndpointAddress(url: url, host: shown, locality: locality))
    }

    /// `<base>/v1/chat/completions`, also when the base already ends in `/v1`.
    public var chatURL: URL { root.appendingPathComponent("chat/completions") }

    /// `<base>/v1/models`.
    public var modelsURL: URL { root.appendingPathComponent("models") }

    private var root: URL {
        let path = url.path
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.hasSuffix("/v1") ? url : url.appendingPathComponent("v1")
    }
}

/// The warning mark beside Generate and beside the endpoint in Settings
/// (ADR 0014): a Unicode symbol whose details say what is sent and where.
/// The details are also its help text and accessibility label.
public struct ModelEndpointIndicator: Sendable, Hashable {
    public enum Place: Sendable, Hashable {
        /// Beside Generate: the sample is the one shown below.
        case workbench
        /// Beside the endpoint in Settings.
        case settings
    }

    /// The mark for a host on this Mac or the local network.
    public static let mark = "△"
    /// The stronger mark, for a host that is neither.
    public static let strongMark = "⚠︎"

    public var symbol: String
    /// The text leaves the local network.
    public var isStrong: Bool
    public var details: String

    public init(host: String, locality: ModelHostLocality, place: Place) {
        isStrong = locality == .elsewhere
        symbol = isStrong ? Self.strongMark : Self.mark
        let sample = place == .workbench ? "the sample shown below" : "the sample the script workbench shows"
        let sent = "Generate sends your instruction, \(sample) and any lines you marked as examples"
        let rest = "Nothing else of the note, and no other note, is sent."
        switch locality {
        case .thisMac:
            details = "\(sent) to the model at \(host), on this Mac. \(rest)"
        case .localNetwork:
            details = "\(sent) to the model at \(host), on your local network. \(rest)"
        case .elsewhere:
            details = "\(sent) to \(host), which is not this Mac or your local network: that text leaves the local network. \(rest)"
        }
    }

    public init(address: ModelEndpointAddress, place: Place) {
        self.init(host: address.host, locality: address.locality, place: place)
    }
}
