//
//  APIError.swift
//  HappyQuickAI
//
//  Shared plumbing for the provider REST clients. Everything here is module
//  internal: the droplet owns the endpoints and the model-specific JSON, this
//  file only keeps the duplicated "parse an HTTP failure" code in one place.
//

import Foundation

/// An HTTP/provider failure, carrying the server's own message when one can
/// be decoded. Showing the server's words instead of a wrapper is what makes
/// the Connection test useful: a rejected key answers with a readable reason.
enum APIError: LocalizedError {
    case httpStatus(domain: String, statusCode: Int, message: String)
    case parsing(domain: String)
    case invalidURL(domain: String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(_, _, let message) where !message.isEmpty:
            return message
        case .httpStatus(let domain, let statusCode, _):
            return "\(domain) returned HTTP status \(statusCode)."
        case .parsing(let domain):
            return "Failed to parse the \(domain) response."
        case .invalidURL(let domain):
            return "The \(domain) URL is invalid."
        }
    }
}

/// Helpers for building requests and turning error bodies into readable text.
enum APIClient {
    /// Pulls the human-readable reason out of a provider error body.
    ///
    /// Handles the shapes that matter in practice, which are all a top-level
    /// `error` object with a `message`:
    /// - OpenAI/DeepSeek/OpenRouter: `{ "error": { "message": "..." } }`
    /// - Anthropic: `{ "type": "error", "error": { "message": "..." } }`
    /// - Gemini: `{ "error": { "code": 400, "message": "...", "status": "..." } }`
    ///
    /// Returns `nil` when the body carries nothing decodable.
    static func serverMessage(from errorBody: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any],
              let error = obj["error"] else {
            return nil
        }
        if let message = (error as? [String: Any])?["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = error as? String, !message.isEmpty {
            return message
        }
        return nil
    }

    /// The non-2xx guard for one provider call, so call sites never swallow
    /// the server's own explanation behind a generic "failed" text.
    static func httpError(data: Data, response: HTTPURLResponse, domain: String) -> APIError {
        let message = serverMessage(from: data) ?? ""
        return .httpStatus(domain: domain, statusCode: response.statusCode, message: message)
    }
}