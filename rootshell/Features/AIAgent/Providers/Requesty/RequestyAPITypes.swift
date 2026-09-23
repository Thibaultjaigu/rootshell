#if !CHINA_BUILD
//
//  RequestyAPITypes.swift
//  rootshell
//
//  API response types for Requesty model discovery.
//  Chat completions use the OpenAI-compatible types in OpenRouterAPITypes.swift.
//

import Foundation

// MARK: - Model Discovery

/// Response shape shared by GET /v1/models and GET /v1/models/managed
struct RequestyModelsResponse: Decodable {
    let data: [RequestyAPIModel]
}

struct RequestyAPIModel: Decodable {
    let id: String
    let api: String?
    let description: String?
    let context_window: Int?
    let max_output_tokens: Int?
    let input_price: Double?
    let output_price: Double?
    let supports_tool_calling: Bool?
    let supports_vision: Bool?
    let supports_reasoning: Bool?

    /// Chat models only (the catalog can also list embedding models)
    var isChatModel: Bool {
        api == nil || api == "chat"
    }
}
#endif
