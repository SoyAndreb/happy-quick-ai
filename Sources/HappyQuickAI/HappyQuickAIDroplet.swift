//
//  HappyQuickAIDroplet.swift
//  HappyQuickAI
//

import Combine
import DroppyKit
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's `NSPrincipalClass`.
@objc(HappyQuickAIPrincipal)
public final class HappyQuickAIPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { HappyQuickAIDroplet() }
}

// MARK: - Models

public enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case claude = "Claude"
    case deepseek = "DeepSeek"
    case openRouter = "OpenRouter"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        }
    }

    public var defaultModel: String {
        switch self {
        case .chatGPT: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .claude: return "claude-sonnet-4-5"
        case .deepseek: return "deepseek-chat"
        case .openRouter: return "openrouter/auto"
        }
    }

    public var fallbackModels: [String] {
        switch self {
        case .chatGPT: return ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo", "o1-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-1.5-flash", "gemini-1.5-pro"]
        case .claude: return ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter: return ["openrouter/auto", "openrouter/auto:free", "meta-llama/llama-3.3-70b-instruct:free"]
        }
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var timestamp: Date

    public enum MessageRole: String, Codable {
        case user
        case assistant
    }

    public init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Main Droplet Class

@MainActor
public final class HappyQuickAIDroplet: NSObject, ObservableObject, Droplet {
    public nonisolated static let id: DropletID = "happy-quick-ai"

    public static let defaultSystemPrompt = """
        You are an ultra-minimalist answer engine for Quick AI. Your goal is to deliver immediate value using the fewest characters possible.

        Response rules:
        1. ZERO pleasantries, introductions, or sign-offs (do not use "Sure," "Here you go," "Hello," or "Hope this helps").
        2. If asked for code: respond ONLY with the optimized code block. Include brief explanations only as comments within the code itself.
        3. If asked a technical or conceptual question: answer in a maximum of 2 sentences or use short bullet points. Get straight to the point.
        4. If asked to translate, summarize, or correct text: return the final result directly, without quotation marks or explanatory text.
        5. Use clean Markdown formatting, prioritizing code and lists over dense paragraphs.
        """

    @Published public var messages: [ChatMessage] = []
    @Published public var isGenerating: Bool = false
    @Published public var isFetchingModels: Bool = false
    @Published public var availableModels: [String] = []
    @Published public var errorMessage: String? = nil
    @Published public var modelsFetchError: String? = nil
    @Published public var isTestingConnection: Bool = false
    @Published public var connectionStatus: String? = nil

    public static let supportedLanguages: [String] = [
        "English", "Español", "Français", "Deutsch",
        "Italiano", "Português", "日本語", "中文"
    ]

    private var host: DropletHost?
    private var cancellables = Set<AnyCancellable>()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    public func activate(host: DropletHost) throws {
        self.host = host
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
        modelRefreshTask?.cancel()
        modelRefreshTask = nil
        modelFetchGeneration += 1
        cancellables.removeAll()
        host = nil
    }

    // MARK: Preferences

    public var selectedProvider: AIProvider {
        get {
            let raw = host?.preferences.value(forKey: "provider", default: AIProvider.chatGPT.rawValue) ?? AIProvider.chatGPT.rawValue
            return AIProvider(rawValue: raw) ?? .chatGPT
        }
        set {
            host?.preferences.setValue(newValue.rawValue, forKey: "provider")
            objectWillChange.send()
            connectionStatus = nil
            updateAvailableModelsList()
        }
    }

    public var chatgptApiKey: String {
        get { host?.preferences.value(forKey: "chatgptApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "chatgptApiKey")
            objectWillChange.send()
            scheduleModelRefresh()
        }
    }

    public var geminiApiKey: String {
        get { host?.preferences.value(forKey: "geminiApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "geminiApiKey")
            objectWillChange.send()
            scheduleModelRefresh()
        }
    }

    public var claudeApiKey: String {
        get { host?.preferences.value(forKey: "claudeApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "claudeApiKey")
            objectWillChange.send()
            scheduleModelRefresh()
        }
    }

    public var deepseekApiKey: String {
        get { host?.preferences.value(forKey: "deepseekApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "deepseekApiKey")
            objectWillChange.send()
            scheduleModelRefresh()
        }
    }

    public var openRouterApiKey: String {
        get { host?.preferences.value(forKey: "openRouterApiKey", default: "") ?? "" }
        set {
            host?.preferences.setValue(newValue, forKey: "openRouterApiKey")
            objectWillChange.send()
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
            objectWillChange.send()
        }
    }

    public var systemPrompt: String {
        get { host?.preferences.value(forKey: "systemPrompt", default: Self.defaultSystemPrompt) ?? Self.defaultSystemPrompt }
        set {
            host?.preferences.setValue(newValue, forKey: "systemPrompt")
            objectWillChange.send()
        }
    }

    public var selectedLanguage: String {
        get { host?.preferences.value(forKey: "selectedLanguage", default: "English") ?? "English" }
        set {
            host?.preferences.setValue(newValue, forKey: "selectedLanguage")
            objectWillChange.send()
        }
    }

    public var activeApiKey: String {
        switch selectedProvider {
        case .chatGPT: return chatgptApiKey
        case .gemini: return geminiApiKey
        case .claude: return claudeApiKey
        case .deepseek: return deepseekApiKey
        case .openRouter: return openRouterApiKey
        }
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
            self.messages = decoded
        }
    }

    private func saveMessages() {
        if let encoded = try? JSONEncoder().encode(messages) {
            host?.preferences.setValue(encoded, forKey: "chatHistory")
        }
    }

    // MARK: Dynamic Model Fetching

    private var modelRefreshTask: Task<Void, Never>?

    /// Bumped on every provider switch or fetch; only the newest fetch may apply
    /// its result, so a slow response can never overwrite a newer provider's list.
    private var modelFetchGeneration = 0
    /// Which provider owns the currently displayed list.
    private var modelsProvider: AIProvider?

    /// Debounced re-fetch after an API key is edited, so pasting or typing a key
    /// does not fire a request per keystroke.
    private func scheduleModelRefresh() {
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.updateAvailableModelsList()
        }
    }

    public func updateAvailableModelsList() {
        let provider = selectedProvider
        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        modelFetchGeneration += 1
        let generation = modelFetchGeneration

        guard !apiKey.isEmpty else {
            isFetchingModels = false
            modelsFetchError = nil
            availableModels = provider.fallbackModels
            modelsProvider = provider
            if !availableModels.contains(selectedModel) {
                selectedModel = provider.defaultModel
            }
            return
        }

        isFetchingModels = true
        modelsFetchError = nil

        Task { @MainActor in
            let fetched: [String]
            do {
                fetched = try await self.listModels(provider: provider, apiKey: apiKey)
            } catch {
                guard generation == self.modelFetchGeneration else { return }
                self.modelsFetchError = (error as NSError).localizedDescription
                // Keep the previous list only when it belongs to this provider;
                // otherwise fall back to this provider's defaults.
                if self.modelsProvider != provider {
                    self.availableModels = provider.fallbackModels
                    self.modelsProvider = provider
                }
                self.isFetchingModels = false
                return
            }

            guard generation == self.modelFetchGeneration else { return }

            // A successful fetch always wins: show exactly what this provider
            // returned (deduped), never a leftover from another provider.
            if fetched.isEmpty {
                self.availableModels = provider.fallbackModels
            } else {
                var seen = Set<String>()
                self.availableModels = fetched.filter { seen.insert($0).inserted }
            }
            self.modelsProvider = provider
            self.modelsFetchError = nil
            if !self.availableModels.contains(self.selectedModel) {
                self.selectedModel = self.availableModels.first ?? provider.defaultModel
            }
            self.isFetchingModels = false
        }
    }

    private func listModels(provider: AIProvider, apiKey: String) async throws -> [String] {
        switch provider {
        case .chatGPT: return try await fetchOpenAIModels(apiKey: apiKey)
        case .gemini: return try await fetchGeminiModels(apiKey: apiKey)
        case .claude: return try await fetchClaudeModels(apiKey: apiKey)
        case .deepseek: return try await fetchDeepSeekModels(apiKey: apiKey)
        case .openRouter: return try await fetchOpenRouterModels(apiKey: apiKey)
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count >= 8 else { return "too short (\(key.count) chars)" }
        return "\(key.prefix(4))…\(key.suffix(4)) (length \(key.count))"
    }

    /// Sends the stored key to the chosen provider's models endpoint so the
    /// user can see, with the server's own answer, whether the key is valid.
    public func testConnection() async {
        let provider = selectedProvider
        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run { isTestingConnection = true }
        connectionStatus = nil
        defer { isTestingConnection = false }

        guard !apiKey.isEmpty else {
            await MainActor.run {
                self.connectionStatus = "No API key stored for \(provider.displayName). Paste it above."
            }
            return
        }

        let masked = maskedKey(apiKey)
        do {
            let models = try await listModels(provider: provider, apiKey: apiKey)
            let count = models.count
            await MainActor.run {
                self.connectionStatus = "OK — \(provider.displayName) accepted key \(masked) (\(count) models)."
            }
        } catch {
            let message = (error as NSError).localizedDescription
            await MainActor.run {
                self.connectionStatus = "Rejected (\(provider.displayName)): \(message) — key \(masked)."
            }
        }
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [String] {
        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "OpenAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models."])
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
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)"
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Gemini", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models."])
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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "Claude", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models."])
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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "DeepSeek", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models."])
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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "OpenRouter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch models."])
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

    // MARK: Send Message

    @discardableResult
    public func sendMessage(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isGenerating else { return false }

        let apiKey = activeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "No API key provided for \(selectedProvider.displayName)."
            return false
        }

        let userMsg = ChatMessage(role: .user, content: trimmed)
        messages.append(userMsg)
        saveMessages()
        errorMessage = nil
        isGenerating = true

        let currentProvider = selectedProvider
        let currentModel = selectedModel
        let currentSystemPrompt = systemPrompt
        let currentLanguage = selectedLanguage
        let history = Array(messages.suffix(20))

        Task {
            do {
                let responseText: String
                switch currentProvider {
                case .chatGPT:
                    responseText = try await callChatGPTAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .gemini:
                    responseText = try await callGeminiAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .claude:
                    responseText = try await callClaudeAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .deepseek:
                    responseText = try await callDeepSeekAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                case .openRouter:
                    responseText = try await callOpenRouterAPI(apiKey: apiKey, model: currentModel, systemPrompt: currentSystemPrompt, language: currentLanguage, history: history)
                }

                await MainActor.run {
                    let assistantMsg = ChatMessage(role: .assistant, content: responseText)
                    self.messages.append(assistantMsg)
                    self.saveMessages()
                    self.isGenerating = false
                }
            } catch {
                let masked = self.maskedKey(apiKey)
                NSLog("[Happy Quick-AI] \(currentProvider.displayName) request failed, key \(masked): \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGenerating = false
                }
            }
        }
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
            throw NSError(domain: "HappyQuickAI", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        guard httpResponse.statusCode == 200 else {
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errDict = errObj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw NSError(domain: "OpenAI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            throw NSError(domain: "OpenAI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenAI API returned HTTP status \(httpResponse.statusCode)."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "OpenAI", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse OpenAI response."])
        }

        return content
    }

    private func callGeminiAPI(apiKey: String, model: String, systemPrompt: String, language: String, history: [ChatMessage]) async throws -> String {
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "Gemini", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL."])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
            throw NSError(domain: "Gemini", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        guard httpResponse.statusCode == 200 else {
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errDict = errObj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw NSError(domain: "Gemini", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            throw NSError(domain: "Gemini", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini API returned HTTP status \(httpResponse.statusCode)."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let contentObj = firstCandidate["content"] as? [String: Any],
              let parts = contentObj["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            throw NSError(domain: "Gemini", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Gemini response."])
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
            throw NSError(domain: "Claude", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        guard httpResponse.statusCode == 200 else {
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errMsg = errObj["error"] as? [String: Any],
               let message = errMsg["message"] as? String {
                throw NSError(domain: "Claude", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
            }
            throw NSError(domain: "Claude", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Claude API returned HTTP status \(httpResponse.statusCode)."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw NSError(domain: "Claude", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Claude response."])
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
            throw NSError(domain: "DeepSeek", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        guard httpResponse.statusCode == 200 else {
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errDict = errObj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw NSError(domain: "DeepSeek", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            throw NSError(domain: "DeepSeek", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "DeepSeek API returned HTTP status \(httpResponse.statusCode)."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "DeepSeek", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse DeepSeek response."])
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
            throw NSError(domain: "OpenRouter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response."])
        }

        guard httpResponse.statusCode == 200 else {
            if let errObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errDict = errObj["error"] as? [String: Any],
               let errMsg = errDict["message"] as? String {
                throw NSError(domain: "OpenRouter", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            throw NSError(domain: "OpenRouter", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API returned HTTP status \(httpResponse.statusCode)."])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw NSError(domain: "OpenRouter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse OpenRouter response."])
        }

        // content is a String for text, or an array of text/image parts.
        if let text = message["content"] as? String {
            return text
        }
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        throw NSError(domain: "OpenRouter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse OpenRouter response."])
    }
}

// MARK: - Shelf Widget

extension HappyQuickAIDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "happy-quick-ai",
                title: "Happy Quick-AI",
                systemImage: "sparkles",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(220)
                ),
                focusPolicy: .keyboardFocusable
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(HappyQuickAIWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

// MARK: - Chat Widget View

private struct HappyQuickAIWidget: View {
    @ObservedObject var droplet: HappyQuickAIDroplet
    let context: ShelfWidgetContext

    @State private var inputText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            headerRow

            if droplet.activeApiKey.isEmpty {
                unconfiguredView
            } else if context.isCompact {
                compactView
            } else {
                expandedView
            }
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var headerRow: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
            Text("Happy Quick-AI")
                .font(.system(size: 12, weight: .semibold))

            if !context.isCompact {
                Text(droplet.selectedProvider.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background {
                        RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                            .fill(AdaptiveColors.notchSurfaceCardFill)
                    }
            }

            Spacer(minLength: 0)

            if !context.isCompact {
                Button {
                    droplet.clearMessages()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Clear chat")

                Button {
                    droplet.openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DroppyCircleButtonStyle(size: 20))
                .help("Settings")
            }
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    @ViewBuilder
    private var unconfiguredView: some View {
        VStack(spacing: DroppySpacing.sm) {
            Spacer(minLength: 0)
            Image(systemName: "key.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)

            Text("No API key configured")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)

            Text("Set up your \(droplet.selectedProvider.displayName) API key in settings.")
                .font(.system(size: 11))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                .multilineTextAlignment(.center)

            Button("Open Settings") {
                droplet.openSettings()
            }
            .buttonStyle(DroppyQuietButtonStyle(size: .small))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var compactView: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            if let last = droplet.messages.last {
                Text(last.role == .user ? "You:" : "AI:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Text(last.content)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    .lineLimit(3)
                    .truncationMode(.tail)
            } else {
                Text(droplet.selectedProvider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text("Start a chat in the full widget")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var expandedView: some View {
        // Chat scroll area
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DroppySpacing.xs) {
                    if droplet.messages.isEmpty {
                        Text("Ask a question to start the conversation…")
                            .font(.system(size: 12))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                            .padding(.vertical, DroppySpacing.sm)
                    } else {
                        ForEach(droplet.messages) { msg in
                            messageBubble(msg)
                        }
                    }

                    if droplet.isGenerating {
                        HStack(spacing: DroppySpacing.xs) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Thinking…")
                                .font(.system(size: 11))
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                        .padding(.vertical, 4)
                        .id("generating")
                    }

                    if let err = droplet.errorMessage {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.95))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background {
                                RoundedRectangle(cornerRadius: DroppyRadius.small, style: .continuous)
                                    .fill(Color.red.opacity(0.15))
                            }
                    }
                }
                .padding(.bottom, DroppySpacing.xs)
            }
            .onChange(of: droplet.messages.count) { _, _ in
                if let last = droplet.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: droplet.isGenerating) { _, generating in
                if generating {
                    withAnimation { proxy.scrollTo("generating", anchor: .bottom) }
                }
            }
        }

        // Input bar — outside ScrollViewReader so it always receives keyboard focus
        inputBar
    }

    @ViewBuilder
    private func messageBubble(_ msg: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if msg.role == .user { Spacer(minLength: 24) }
            Text(msg.content)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                        .fill(
                            msg.role == .user
                                ? AdaptiveColors.selectionBlueAuto.opacity(0.85)
                                : AdaptiveColors.notchSurfaceCardFill
                        )
                }
                .foregroundStyle(
                    msg.role == .user
                        ? AdaptiveColors.selectionForegroundAuto
                        : AdaptiveColors.notchSurfacePrimaryText
                )
                .fixedSize(horizontal: false, vertical: true)
            if msg.role == .assistant { Spacer(minLength: 24) }
        }
        .id(msg.id)
    }

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: DroppySpacing.xs) {
            ChatInputField(text: $inputText, onSubmit: { sendCurrentText() })
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    RoundedRectangle(cornerRadius: DroppyRadius.medium, style: .continuous)
                        .fill(AdaptiveColors.notchSurfaceCardFill)
                }

            Button {
                sendCurrentText()
            } label: {
                Image(systemName: droplet.isGenerating ? "ellipsis" : "paperplane.fill")
                    .font(.system(size: 11))
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 24))
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || droplet.isGenerating)
        }
    }

    private func sendCurrentText() {
        if droplet.sendMessage(inputText) {
            inputText = ""
        }
    }
}

// MARK: - Chat Input Field

/// One-line chat input backed by `NSTextField`.
///
/// A plain SwiftUI `TextField` cannot be trusted on every host: while the field
/// is being edited the host is free to swallow the key events at or before its
/// own event dispatch, so the caret appears and nothing types (observed when
/// Droppy runs in English but not Spanish). While this field is mid-edit, a
/// local key monitor feeds every keystroke straight into the field editor and
/// consumes it, so typing works identically in every host language and the
/// host's own focus cycle never has a chance to eat it.
private struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Ask AI…"
        field.textColor = .white
        field.alignment = .left
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        context.coordinator.install(on: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    static func dismantleNSView(_ nsView: NSTextField, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ChatInputField
        private weak var field: NSTextField?
        private var keyMonitor: Any?
        private var didMakeKey = false

        init(_ parent: ChatInputField) {
            self.parent = parent
        }

        func install(on field: NSTextField) {
            self.field = field
            // Must return the coordinator's decision verbatim: `nil` swallows the
            // event, anything else lets it keep its normal route. Returning the
            // event here when the handler chose `nil` redelivers the keystroke to
            // the field editor, which inserts it a second time.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handleKeyDown(event)
            }
        }

        func teardown() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            field = nil
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            // No dependence on NSApp.isActive: a floating shelf/hud panel can be
            // editing while the app is not the global active app.
            guard let field, let editor = field.currentEditor() as? NSTextView else { return event }
            // Command/control combinations keep their normal route (copy, paste, menus).
            if !event.modifierFlags.intersection([.command, .control]).isEmpty { return event }

            switch event.keyCode {
            case 36, 76: // Return / keypad Enter — submit and keep focus.
                parent.onSubmit()
                return nil
            case 48: // Tab — keep the host's focus cycle.
                return event
            case 53: // Escape — keep the host's route.
                return event
            case 51: // Delete.
                editor.deleteBackward(nil)
                return nil
            case 123, 124, 125, 126: // Arrow keys move the caret.
                editor.interpretKeyEvents([event])
                return nil
            default:
                // Every other key is written straight into the field editor.
                // The monitor runs before the host dispatches the event, so the
                // text lands even when the host would swallow the keystroke.
                if let chars = event.characters ?? event.charactersIgnoringModifiers, !chars.isEmpty {
                    // Never inject control characters (deletions, function keys,
                    // Option-generated control codes) as literal text.
                    if chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                        editor.insertText(chars, replacementRange: editor.selectedRange())
                        return nil
                    }
                }
                return event
            }
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field, let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertionPointColor = .white
            if !didMakeKey, let window = field.window {
                window.makeKey()
                window.makeFirstResponder(field)
                didMakeKey = true
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            parent.text = field.stringValue
        }

        @objc func submit(_ sender: Any?) {
            parent.onSubmit()
        }
    }
}

// MARK: - Settings Pane

extension HappyQuickAIDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(HappyQuickAISettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [
            SettingsSearchEntry(title: "Provider & model", keywords: ["provider", "chatgpt", "gemini", "claude", "anthropic", "deepseek", "openrouter", "openai", "model"]),
            SettingsSearchEntry(title: "API key", keywords: ["api", "key", "token", "auth", "secret", "connection", "test"]),
            SettingsSearchEntry(title: "Language & system prompt", keywords: ["system", "prompt", "language", "idioma"]),
            SettingsSearchEntry(title: "Chat history", keywords: ["history", "clear", "messages"])
        ]
    }
}

private struct HappyQuickAISettings: View {
    @ObservedObject var droplet: HappyQuickAIDroplet

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.lg) {

            // Card 1 — Provider & model
            DropletSettingsCard {
                DropletControlRow(title: "Provider") {
                    Picker("", selection: Binding(
                        get: { droplet.selectedProvider },
                        set: { droplet.selectedProvider = $0 }
                    )) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 180, alignment: .trailing)
                }

                DropletSettingsDivider()

                DropletControlRow(title: "Model", infoTip: "Fetch available models from the API or pick from defaults") {
                    HStack(spacing: DroppySpacing.xs) {
                        Picker("", selection: Binding(
                            get: { droplet.selectedModel },
                            set: { droplet.selectedModel = $0 }
                        )) {
                            if droplet.availableModels.isEmpty {
                                Text(droplet.isFetchingModels ? "Fetching…" : "Fetch to list")
                                    .tag(droplet.selectedModel)
                            } else {
                                ForEach(droplet.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 240, alignment: .trailing)

                        Button {
                            droplet.updateAvailableModelsList()
                        } label: {
                            if droplet.isFetchingModels {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(DroppyCircleButtonStyle(size: 24))
                        .help("Fetch models from API")
                        .disabled(droplet.isFetchingModels)
                    }

                    if let fetchError = droplet.modelsFetchError {
                        Text(fetchError)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red.opacity(0.95))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, DroppySpacing.xs)
                    }
                }
            }

            // Card 2 — API key
            DropletSettingsCard {
                switch droplet.selectedProvider {
                case .chatGPT:
                    DropletStackedRow(title: "ChatGPT API key", infoTip: "Your OpenAI secret key starting with sk-…") {
                        SecureField("sk-…", text: Binding(
                            get: { droplet.chatgptApiKey },
                            set: { droplet.chatgptApiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                case .gemini:
                    DropletStackedRow(title: "Gemini API key", infoTip: "Your Google Gemini key starting with AIza…") {
                        SecureField("AIza…", text: Binding(
                            get: { droplet.geminiApiKey },
                            set: { droplet.geminiApiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                case .claude:
                    DropletStackedRow(title: "Claude API key", infoTip: "Your Anthropic key starting with sk-ant-…") {
                        SecureField("sk-ant-…", text: Binding(
                            get: { droplet.claudeApiKey },
                            set: { droplet.claudeApiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                case .deepseek:
                    DropletStackedRow(title: "DeepSeek API key", infoTip: "Your DeepSeek platform key starting with sk-…") {
                        SecureField("sk-…", text: Binding(
                            get: { droplet.deepseekApiKey },
                            set: { droplet.deepseekApiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                case .openRouter:
                    DropletStackedRow(title: "OpenRouter API key", infoTip: "One key for hundreds of hosted models, starting with sk-or-…") {
                        SecureField("sk-or-…", text: Binding(
                            get: { droplet.openRouterApiKey },
                            set: { droplet.openRouterApiKey = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }

                DropletSettingsDivider()

                DropletControlRow(title: "Connection", infoTip: "Sends your stored key to the provider to confirm it is valid") {
                    HStack(spacing: DroppySpacing.xs) {
                        if droplet.isTestingConnection {
                            ProgressView().scaleEffect(0.6)
                        }
                        Button("Test") {
                            Task { await droplet.testConnection() }
                        }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                        .disabled(droplet.isTestingConnection)
                    }
                }

                if let status = droplet.connectionStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(status.hasPrefix("OK") ? Color.green.opacity(0.95) : Color.red.opacity(0.95))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.top, DroppySpacing.xs)
                }
            }

            // Card 3 — Language & system prompt
            DropletSettingsCard {
                DropletControlRow(title: "Output language", infoTip: "Language the AI will respond in") {
                    Picker("", selection: Binding(
                        get: { droplet.selectedLanguage },
                        set: { droplet.selectedLanguage = $0 }
                    )) {
                        ForEach(HappyQuickAIDroplet.supportedLanguages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 130)
                }

                DropletSettingsDivider()

                DropletStackedRow(title: "System prompt", infoTip: "Instruction that shapes the AI's personality and behaviour") {
                    TextField("System prompt…", text: Binding(
                        get: { droplet.systemPrompt },
                        set: { droplet.systemPrompt = $0 }
                    ), axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                }
            }

            // Card 4 — Chat history
            DropletSettingsCard {
                DropletControlRow(title: "Messages") {
                    DropletValuePill(text: "\(droplet.messages.count)")
                }

                DropletSettingsDivider()

                DropletControlRow(title: "Clear history") {
                    Button("Clear") {
                        droplet.clearMessages()
                    }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                }
            }
        }
        .onAppear { droplet.updateAvailableModelsList() }
    }
}