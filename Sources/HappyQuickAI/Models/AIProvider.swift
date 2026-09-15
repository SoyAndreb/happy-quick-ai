//
//  AIProvider.swift
//  HappyQuickAI
//

import Foundation

/// The chat backends the droplet can talk to.
public enum AIProvider: String, Codable, CaseIterable, Identifiable {
    case chatGPT = "ChatGPT"
    case gemini = "Gemini"
    case claude = "Claude"
    case deepseek = "DeepSeek"
    case openRouter = "OpenRouter"
    /// Any OpenAI-compatible server: the user supplies its base URL, and the
    /// droplet talks to its `/v1/models` and `/v1/chat/completions` endpoints
    /// the same way it talks to OpenAI — optionally with a Bearer key.
    case custom = "Custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        case .deepseek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom"
        }
    }

    public var defaultModel: String {
        switch self {
        case .chatGPT: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .claude: return "claude-sonnet-4-5"
        case .deepseek: return "deepseek-chat"
        case .openRouter: return "openrouter/auto"
        case .custom: return ""
        }
    }

    public var fallbackModels: [String] {
        switch self {
        case .chatGPT: return ["gpt-4o-mini", "gpt-4o", "gpt-4-turbo", "o1-mini"]
        case .gemini: return ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-1.5-flash", "gemini-1.5-pro"]
        case .claude: return ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .openRouter: return ["openrouter/auto", "openrouter/auto:free", "meta-llama/llama-3.3-70b-instruct:free"]
        // The custom server owns its model names; an empty fallback just means
        // "you pick, or fetch the list from its /models endpoint".
        case .custom: return []
        }
    }

    /// Whether this provider is addressed by a configurable base URL instead
    /// of a fixed remote host.
    public var usesBaseURL: Bool { self == .custom }
}

/// One exchange in the conversation shown in the widget and stored in
/// preferences as the chat history.
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