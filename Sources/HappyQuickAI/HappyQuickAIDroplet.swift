//
//  HappyQuickAIDroplet.swift
//  HappyQuickAI
//
//  The droplet object: preferences, lifecycle, the chat + model-list REST
//  clients, and the state the views render.
//

import Combine
import DroppyKit
import Foundation

/// One successful model fetch, kept so switching provider or reopening the
/// settings pane does not re-hit the network for the same configuration.
private struct ModelsCacheEntry {
    let provider: AIProvider
    let apiKey: String
    let baseURL: String
    let models: [String]
    let date: Date

    /// Whether this entry still describes the current configuration and is
    /// fresh enough to serve.
    func isCurrent(provider: AIProvider, apiKey: String, baseURL: String, ttl: TimeInterval) -> Bool {
        self.provider == provider
            && self.apiKey == apiKey
            && self.baseURL == baseURL
            && Date().timeIntervalSince(date) < ttl
    }
}

/// Where an OpenAI-compatible server lives and what a request to it looks like.
private struct CustomEndpoints {
    let chat: URL
    let models: URL

    /// Derives the two endpoints from whatever the user pasted: a base URL
    /// (`https://host:port` or `https://host:port/v1`), or a full chat
    /// completions path. The `/v1` prefix is assumed, matching LM Studio,
    /// Ollama, vLLM, llama.cpp and the usual OpenAI clones.
    init?(baseURL: String) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let chatString: String
        if trimmed.contains("/chat/completions") {
            chatString = trimmed
        } else if trimmed.hasSuffix("/v1") {
            chatString = trimmed + "/chat/completions"
        } else {
            chatString = trimmed + "/v1/chat/completions"
        }

        guard let chatURL = URL(string: chatString) else { return nil }
        let modelsString = chatString.replacingOccurrences(of: "/chat/completions", with: "/models")
        guard let modelsURL = URL(string: modelsString) else { return nil }

        self.chat = chatURL
        self.models = modelsURL
    }
}

@MainActor
public final class HappyQuickAIDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "happy-quick-ai"

    public static let defaultSystemPrompt = """
        You are an ultra-minimalist answer engine for Happy Quick-AI. Your goal is to deliver immediate value using the fewest characters possible.

        Response rules:
        1. ZERO pleasantries, introductions, or sign-offs (do not use "Sure," "Here you go," "Hello," or "Hope this helps").
        2. If asked for code: respond ONLY with the optimized code block. Include brief explanations only as comments within the code itself.
        3. If asked a technical or conceptual question: answer in a maximum of 2 sentences or use short bullet points. Get straight to the point.
        4. If asked to translate, summarize, or correct text: return the final result directly, without quotation marks or explanatory text.
        5. Use clean Markdown formatting, prioritizing code and lists over dense paragraphs.
        """

    /// How many messages the persisted history keeps at most. Sending is
    /// always capped to the last 20; this bounds the stored blob itself.
    private static let maxMessages = 200
    /// How long a fetched model list is reused before the API is asked again.
    private static let modelsCacheTTL: TimeInterval = 180
    /// Debounce for re-fetching the model list while an API key is typed.
    private static let modelRefreshDelay: UInt64 = 600_000_000

    @Published public var messages: [ChatMessage] = []
    @Published public var isGenerating: Bool = false
    @Published public var isFetchingModels: Bool = false
    @Published public var availableModels: [String] = []
    @Published public var errorMessage: String? = nil
    @Published public var modelsFetchError: String? = nil
    @Published public var isTestingConnection: Bool = false
    @Published public var connectionStatus: String? = nil

    private var host: DropletHost?
    private var cancellables = Set<AnyCancellable>()

    /// Guards every asynchronous continuation: while false (between
    /// `deactivate()` and the next `activate(host:)`) in-flight work must not
    /// touch `@Published` state or the host.
    private var isActive = false
    /// Every task the droplet started, cancelled wholesale on deactivation.
    private var inFlightTasks: [Task<Void, Never>] = []
    /// The debounced model-list refresh scheduled after an API key edit.
    private var modelRefreshTask: Task<Void, Never>?

    /// Bumped on every provider switch or fetch; only the newest fetch may
    /// apply its result, so a slow response never overwrites a newer one.
    private var modelFetchGeneration = 0
    /// Which provider owns the currently displayed list.
    private var modelsProvider: AIProvider?
    /// The last successful fetch, for the TTL cache.
    private var modelsCacheEntry: ModelsCacheEntry?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        isActive = true
        host.log.info("Happy Quick-AI activated")
        loadMessages()
        updateAvailableModelsList()

        host.preferences.didChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    public func deactivate() {
        isActive = false
        modelRefreshTask?.cancel()
        modelRefreshTask = nil
        // A fetch already on the wire must not win its generation guard after
        // reactivation either.
        modelFetchGeneration += 1
        for task in inFlightTasks { task.cancel() }
        inFlightTasks.removeAll()
        cancellables.removeAll()
        host = nil
    }

    /// Remembers a task so `deactivate()` can cancel it.
    private func track(_ task: Task<Void, Never>) {
        inFlightTasks.append(task)
    }

    // MARK: Preferences

    public var selectedProvider: AIProvider {
        get {
            let raw = host?.preferences.value(forKey: "provider", default: AIProvider.chatGPT.rawValue) ?? AIProvider.chatGPT.rawValue
            return AIProvider(rawValue: raw) ?? .chatGPT
        }
        set {
            host?.preferences.setValue(newValue.rawValue, forKey: "provider")
            connectionStatus = nil
            updateAvailableModelsList()
        }
    }

    public var chatgptApiKey: String {
        get { host?.preferences.value(forKey: "chatgptApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "chatgptApiKey")
            scheduleModelRefresh()
        }
    }

    public var geminiApiKey: String {
        get { host?.preferences.value(forKey: "geminiApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "geminiApiKey")
            scheduleModelRefresh()
        }
    }

    public var claudeApiKey: String {
        get { host?.preferences.value(forKey: "claudeApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "claudeApiKey")
            scheduleModelRefresh()
        }
    }

    public var deepseekApiKey: String {
        get { host?.preferences.value(forKey: "deepseekApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "deepseekApiKey")
            scheduleModelRefresh()
        }
    }

    public var openRouterApiKey: String {
        get { host?.preferences.value(forKey: "openRouterApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "openRouterApiKey")
            scheduleModelRefresh()
        }
    }

    public var customApiKey: String {
        get { host?.preferences.value(forKey: "customApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "customApiKey")
            scheduleModelRefresh()
        }
    }

    /// Base address of the custom OpenAI-compatible server, for example
    /// `http://localhost:8080/v1`.
    public var customBaseURL: String {
        get { host?.preferences.value(forKey: "customBaseURL", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "customBaseURL")
            scheduleModelRefresh()
        }
    }

    public var selectedModel: String {
        get {
            let defaultM = selectedProvider.defaultModel
            return host?.preferences.value(forKey: "selectedModel_\(selectedProvider.rawValue)", default: defaultM) ?? defaultM
        }
        set {
            host?.preferences.setValue(newValue, forKey: "selectedModel_\(selectedProvider.rawValue)")
        }
    }

    public var systemPrompt: String {
        get { host?.preferences.value(forKey: "systemPrompt", default: Self.defaultSystemPrompt) ?? Self.defaultSystemPrompt }
        set {
            host?.preferences.setValue(newValue, forKey: "systemPrompt")
        }
    }

    /// The language the AI answers in, taken from Droppy's own interface so
    /// the chat always replies in the language the app is showing. There is no
    /// setting for it; the terminator instruction is built from this.
    public var selectedLanguage: String {
        let appLanguage = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? "en"
        switch appLanguage.prefix(2).lowercased() {
        case "es": return "Español"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "it": return "Italiano"
        case "pt": return "Português"
        case "ja": return "日本語"
        case "zh": return "中文"
        default: return "English"
        }
    }

    public var activeApiKey: String {
        switch selectedProvider {
        case .chatGPT: return chatgptApiKey
        case .gemini: return geminiApiKey
        case .claude: return claudeApiKey
        case .deepseek: return deepseekApiKey
        case .openRouter: return openRouterApiKey
        case .custom: return customApiKey
        }
    }

    /// Whether the selected provider has everything it needs to send: a key
    /// for the hosted providers, a base URL for a custom server.
    public var isConfigured: Bool {
        switch selectedProvider {
        case .custom:
            return !customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return !activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public var setupHintTitle: String {
        selectedProvider == .custom ? "No AI server configured" : "No API key configured"
    }

    public var setupHintDetail: String {
        if selectedProvider == .custom {
            return "Paste your OpenAI-compatible server address in settings."
        }
        return "Set up your \(selectedProvider.displayName) API key in settings."
    }

    private var configurationErrorText: String {
        if selectedProvider == .custom {
            return "No API base URL configured. Paste your server address in Settings."
        }
        return "No API key provided for \(selectedProvider.displayName)."
    }

    public func openSettings() {
        host?.workspace.openSettings()
    }

    // MARK: Chat Storage & API Calls

    public func clearMessages() {
        messages.removeAll()
        saveMessages()
        errorMessage = nil
    }

    private func loadMessages() {
        if let data = host?.preferences.value(forKey: "chatHistory", as: Data.self),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            self.messages = Array(decoded.suffix(Self.maxMessages))
        }
    }

    private func saveMessages() {
        let capped = Array(messages.suffix(Self.maxMessages))
        if let encoded = try? JSONEncoder().encode(capped) {
            host?.preferences.setValue(encoded, forKey: "chatHistory")
        }
    }

    private func capMessages() {
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    // MARK: Dynamic Model Fetching

    /// Debounced re-fetch after an API key or base URL is edited, so pasting
    /// or typing a key does not fire a request per keystroke.
    private func scheduleModelRefresh() {
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.modelRefreshDelay)
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.updateAvailableModelsList()
        }
    }

    public func updateAvailableModelsList() {
        let provider = selectedProvider
        modelFetchGeneration += 1
        let generation = modelFetchGeneration

        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = provider.usesBaseURL
            ? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        guard isConfigured else {
            isFetchingModels = false
            modelsFetchError = nil
            applyModelList(provider.fallbackModels, for: provider)
            return
        }

        // A fresh cached list is exact — no network call just because the pane
        // reopened or the provider was switched once.
        if let cache = modelsCacheEntry, cache.isCurrent(provider: provider, apiKey: apiKey, baseURL: baseURL, ttl: Self.modelsCacheTTL) {
            applyModelList(cache.models, for: provider)
            return
        }

        isFetchingModels = true
        modelsFetchError = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let fetched: [String]
            do {
                fetched = try await self.listModels(provider: provider, apiKey: apiKey, baseURL: baseURL)
            } catch {
                guard generation == self.modelFetchGeneration, self.isActive else { return }
                self.modelsFetchError = error.localizedDescription
                // Keep the previous list only when it belongs to this provider;
                // otherwise fall back to this provider's defaults.
                if self.modelsProvider != provider {
                    self.applyModelList(provider.fallbackModels, for: provider)
                } else {
                    self.isFetchingModels = false
                }
                return
            }

            guard generation == self.modelFetchGeneration, self.isActive else { return }

            // A successful fetch always wins: show exactly what this provider
            // returned (deduped), never a leftover from another provider.
            var seen = Set<String>()
            let models = fetched.filter { seen.insert($0).inserted }
            self.modelsCacheEntry = ModelsCacheEntry(
                provider: provider,
                apiKey: apiKey,
                baseURL: baseURL,
                models: models,
                date: Date()
            )
            self.applyModelList(models, for: provider)
        }
        track(task)
    }

    /// Applies a model list to the state, staying on the typed choice for the
    /// custom provider, where the model name is the user's to decide.
    private func applyModelList(_ models: [String], for provider: AIProvider) {
        availableModels = models.isEmpty ? provider.fallbackModels : models
        modelsProvider = provider
        modelsFetchError = nil
        if !availableModels.contains(selectedModel), provider != .custom {
            selectedModel = availableModels.first ?? provider.defaultModel
        }
        isFetchingModels = false
    }

    private func listModels(provider: AIProvider, apiKey: String, baseURL: String) async throws -> [String] {
        switch provider {
        case .chatGPT: return try await fetchOpenAIModels(apiKey: apiKey)
        case .gemini: return try await fetchGeminiModels(apiKey: apiKey)
        case .claude: return try await fetchClaudeModels(apiKey: apiKey)
        case .deepseek: return try await fetchDeepSeekModels(apiKey: apiKey)
        case .openRouter: return try await fetchOpenRouterModels(apiKey: apiKey)
        case .custom: return try await fetchOpenAICompatibleModels(apiKey: apiKey, baseURL: baseURL)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count >= 8 else { return "too short (\(key.count) chars)" }
        return "\(key.prefix(4))…\(key.suffix(4)) (length \(key.count))"
    }

    /// Sends the stored configuration to the chosen provider's models endpoint
    /// so the user can see, with the server's own answer, whether it works.
    public func testConnection() async {
        let provider = selectedProvider
        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = provider.usesBaseURL
            ? customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        isTestingConnection = true
        connectionStatus = nil
        defer { isTestingConnection = false }

        guard isConfigured else {
            connectionStatus = "Configure \(provider.displayName) in Settings first."
            return
        }

        let credential: String
        if provider.usesBaseURL {
            credential = baseURL
        } else {
            credential = "key \(maskedKey(apiKey))"
        }

        do {
            let models = try await listModels(provider: provider, apiKey: apiKey, baseURL: baseURL)
            guard isActive else { return }
            connectionStatus = "OK — \(provider.displayName) accepted \(credential) (\(models.count) models)."
        } catch {
            guard isActive else { return }
            connectionStatus = "Rejected (\(provider.displayName)): \(error.localizedDescription) — \(credential)."
        }
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "OpenAI")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "OpenAI")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        let modelIds = dataArray.compactMap { $0["id"] as? String }
            .filter { (id: String) -> Bool in
                let id = id.lowercased()
                // Chat model families: gpt-*, o1/o2/o3/o4/o5/oA, chatgpt-*.
                let isChatFamily = id.hasPrefix("gpt-")
                    || id.hasPrefix("o1") || id.hasPrefix("o2") || id.hasPrefix("o3")
                    || id.hasPrefix("o4") || id.hasPrefix("o5")
                    || id.hasPrefix("oa") || id.hasPrefix("chatgpt-")
                guard isChatFamily else { return false }
                // Never offer the non-chat endpoints as a reply model.
                return !id.contains("realtime")
                    && !id.contains("audio")
                    && !id.contains("embedding")
                    && !id.contains("image")
                    && !id.contains("tts")
                    && !id.contains("whisper")
                    && !id.contains("transcribe")
                    && !id.contains("moderation")
                    && !id.contains("-instruct")
            }
            .sorted()

        return modelIds
    }

    private func fetchGeminiModels(apiKey: String) async throws -> [String] {
        // The key travels in the x-goog-api-key header, never in the URL.
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Gemini")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Gemini")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            return []
        }

        let modelNames = modelsArray.compactMap { item -> String? in
            guard let name = item["name"] as? String,
                  let methods = item["supportedGenerationMethods"] as? [String],
                  methods.contains("generateContent") else {
                return nil
            }
            return name.replacingOccurrences(of: "models/", with: "")
        }
        .filter { name in
            guard name.hasPrefix("gemini-") else { return false }
            let lowered = name.lowercased()
            return !lowered.contains("-live")
                && !lowered.contains("-tts")
                && !lowered.contains("-silent")
                && !lowered.contains("embedding")
                && !lowered.contains("trms")
                && !lowered.contains("-flow")
        }
        .sorted()

        return modelNames
    }

    private func fetchClaudeModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://api.anthropic.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Claude")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Claude")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        let modelIds = dataArray.compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("claude-") }
            .sorted()

        return modelIds
    }

    private func fetchDeepSeekModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://api.deepseek.com/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "DeepSeek")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "DeepSeek")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        let modelIds = dataArray.compactMap { $0["id"] as? String }
            .filter { $0.hasPrefix("deepseek-") }
            .sorted()

        return modelIds
    }

    private func fetchOpenRouterModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "OpenRouter")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "OpenRouter")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        // OpenRouter lists every hosted model: language models, image
        // generators, rerankers, embeddings, TTS. Keep only text chat models,
        // prefer currently available (`supported_parameters.max_tokens`).
        let modelIds = dataArray.compactMap { item -> String? in
            guard let id = item["id"] as? String else { return nil }
            let lowered = id.lowercased()
            guard lowered.contains("/") else { return nil }
            var excluded = id.contains("embedding")
                || id.contains("rerank")
                || id.contains("image")
                || id.contains("sdxl")
                || id.contains("flux")
                || id.contains("dall-e")
                || id.contains("whisper")
                || id.contains("tts")
                || id.contains("audio")
                || id.contains("video")
                || id.contains("transcribe")
            if !excluded, let params = item["supported_parameters"] as? [String: Any] {
                // Presence of max_tokens marks a chat model in this API.
                excluded = !(params["max_tokens"] as? Bool ?? false)
            }
            return excluded ? nil : id
        }
        .sorted()

        return modelIds
    }

    /// The custom provider's model list: OpenAI-compatible `/models`.
    private func fetchOpenAICompatibleModels(apiKey: String, baseURL: String) async throws -> [String] {
        guard let endpoints = CustomEndpoints(baseURL: baseURL) else {
            throw APIError.invalidURL(domain: "Custom")
        }

        var request = URLRequest(url: endpoints.models)
        request.httpMethod = "GET"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Custom")
        }
        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Custom")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return []
        }

        return dataArray.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: Send Message

    @discardableResult
    public func sendMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isGenerating else { return false }
        guard isConfigured else {
            errorMessage = configurationErrorText
            return false
        }

        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        let userMsg = ChatMessage(role: .user, content: trimmed)
        messages.append(userMsg)
        capMessages()
        saveMessages()
        errorMessage = nil
        isGenerating = true

        let currentProvider = selectedProvider
        let currentModel = selectedModel
        let currentSystemPrompt = systemPrompt
        let currentLanguage = selectedLanguage
        let history = Array(messages.suffix(20))

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let responseText: String
                switch currentProvider {
                case .chatGPT:
                    responseText = try await self.callChatGPTAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .gemini:
                    responseText = try await self.callGeminiAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .claude:
                    responseText = try await self.callClaudeAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .deepseek:
                    responseText = try await self.callDeepSeekAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .openRouter:
                    responseText = try await self.callOpenRouterAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .custom:
                    responseText = try await self.callCustomAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                }

                guard self.isActive else { return }
                let assistantMsg = ChatMessage(role: .assistant, content: responseText)
                self.messages.append(assistantMsg)
                self.capMessages()
                self.saveMessages()
                self.isGenerating = false
            } catch {
                guard self.isActive else { return }
                let masked = self.maskedKey(apiKey)
                self.host?.log.error("\(currentProvider.displayName) request failed, key \(masked): \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                self.isGenerating = false
            }
        }
        track(task)
        return true
    }

    // MARK: REST Integrations

    private func callChatGPTAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [[String: String]] = []
        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."
        apiMessages.append(["role": "system", "content": fullSystemInstruction])

        for msg in history {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "OpenAI")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "OpenAI")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError.parsing(domain: "OpenAI")
        }

        return content
    }

    private func callGeminiAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL(domain: "Gemini")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let contents = history.map { msg -> [String: Any] in
            [
                "role": msg.role == .user ? "user" : "model",
                "parts": [["text": msg.content]]
            ]
        }

        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."
        let body: [String: Any] = [
            "contents": contents,
            "systemInstruction": [
                "parts": [["text": fullSystemInstruction]]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Gemini")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Gemini")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let contentObj = firstCandidate["content"] as? [String: Any],
              let parts = contentObj["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw APIError.parsing(domain: "Gemini")
        }

        return text
    }

    private func callClaudeAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."

        let apiMessages = history.map { msg -> [String: String] in
            [
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.content
            ]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": fullSystemInstruction,
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Claude")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Claude")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw APIError.parsing(domain: "Claude")
        }

        return text
    }

    private func callDeepSeekAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let url = URL(string: "https://api.deepseek.com/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var apiMessages: [[String: String]] = []
        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."
        apiMessages.append(["role": "system", "content": fullSystemInstruction])

        for msg in history {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "DeepSeek")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "DeepSeek")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError.parsing(domain: "DeepSeek")
        }

        return content
    }

    private func callOpenRouterAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://getdroppy.app", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Happy Quick-AI", forHTTPHeaderField: "X-Title")

        var apiMessages: [[String: String]] = []
        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."
        apiMessages.append(["role": "system", "content": fullSystemInstruction])

        for msg in history {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "OpenRouter")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "OpenRouter")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw APIError.parsing(domain: "OpenRouter")
        }

        // content is a String for text, or an array of text/image parts.
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        throw APIError.parsing(domain: "OpenRouter")
    }

    /// The custom provider's chat call: an OpenAI-compatible
    /// `/chat/completions` request, with the Bearer key only when one is set.
    private func callCustomAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        guard let endpoints = CustomEndpoints(baseURL: customBaseURL) else {
            throw APIError.invalidURL(domain: "Custom")
        }

        var request = URLRequest(url: endpoints.chat)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        var apiMessages: [[String: String]] = []
        let fullSystemInstruction = "\(systemPrompt)\nPlease respond in \(language)."
        apiMessages.append(["role": "system", "content": fullSystemInstruction])

        for msg in history {
            apiMessages.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": apiMessages
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidURL(domain: "Custom")
        }

        guard httpResponse.statusCode == 200 else {
            throw APIClient.httpError(data: data, response: httpResponse, domain: "Custom")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw APIError.parsing(domain: "Custom")
        }

        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        throw APIError.parsing(domain: "Custom")
    }
}