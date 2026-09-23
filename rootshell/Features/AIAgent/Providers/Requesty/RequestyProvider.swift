#if !CHINA_BUILD
//
//  RequestyProvider.swift
//  rootshell
//
//  Requesty provider implementation using native URLSession.
//  Requesty is OpenAI-compatible, so the chat request/response types and the
//  SSE parser are shared with the OpenRouter provider.
//

import Foundation
import os.log

/// Requesty provider implementation using native URLSession
@MainActor
final class RequestyProvider: AIProvider {
    // MARK: - Static Properties

    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "RequestyProvider")

    static let providerID = "requesty"
    static let displayName = "Requesty"
    static let defaultBaseURL = "https://router.requesty.ai/v1"

    static var availableModels: [AIProviderModel] {
        // Requesty models are dynamically discovered
        AICredentialsManager.shared.requestyDiscoveredModels
    }

    // MARK: - Instance Properties

    private let apiKey: String
    private let baseURL: String
    private var currentTask: Task<Void, Never>?

    var selectedModelID: String

    var isConfigured: Bool {
        !apiKey.isEmpty
    }

    // MARK: - Initialization

    init(apiKey: String, selectedModelID: String) {
        self.apiKey = apiKey
        self.baseURL = Self.defaultBaseURL
        self.selectedModelID = selectedModelID
    }

    // MARK: - AIProvider Protocol

    func sendMessage(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) async throws -> AIProviderResponse {
        guard isConfigured else {
            throw AIProviderError.notConfigured
        }

        let request = try buildRequest(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            stream: false
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        try checkHTTPResponse(httpResponse, data: data, modelID: selectedModelID)

        let requestyResponse = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
        return parseResponse(requestyResponse)
    }

    func sendMessageStream(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool]
    ) -> AsyncThrowingStream<AIProviderStreamEvent, Error> {
        // Capture values needed for the detached task
        let isConfigured = self.isConfigured
        let modelID = self.selectedModelID

        return AsyncThrowingStream { continuation in
            // Run stream processing off MainActor to avoid UI freezes
            // Network I/O and byte-by-byte parsing should not block the main thread
            let task = Task.detached { [weak self] in
                guard isConfigured else {
                    continuation.finish(throwing: AIProviderError.notConfigured)
                    return
                }

                guard let self = self else {
                    continuation.finish(throwing: AIProviderError.cancelled)
                    return
                }

                // Retry logic for connection lost errors (common with SSH port forwards)
                let maxRetries = 2
                var lastError: Error?

                for attempt in 0...maxRetries {
                    // Check cancellation before each attempt
                    if Task.isCancelled {
                        continuation.finish(throwing: AIProviderError.cancelled)
                        return
                    }

                    if attempt > 0 {
                        Self.logger.info("Retrying stream request (attempt \(attempt + 1)/\(maxRetries + 1)) after connection error")
                        // Brief delay before retry to allow connection to reset
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    }

                    do {
                        try await self.executeStreamRequest(
                            messages: messages,
                            systemPrompt: systemPrompt,
                            tools: tools,
                            modelID: modelID,
                            continuation: continuation
                        )
                        // Success - exit retry loop
                        return
                    } catch {
                        // Check for cancellation first
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }

                        let nsError = error as NSError
                        // Only retry on connection lost errors (-1005)
                        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNetworkConnectionLost {
                            Self.logger.warning("Connection lost during stream (attempt \(attempt + 1)): \(error.localizedDescription)")
                            lastError = error
                            continue
                        }
                        // For other errors, don't retry - finish with error
                        continuation.finish(throwing: self.mapError(error))
                        return
                    }
                }

                // All retries exhausted
                if let error = lastError {
                    continuation.finish(throwing: self.mapError(error))
                }
            }

            Task { @MainActor [weak self] in
                self?.currentTask = task
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Execute the actual stream request (extracted for retry logic)
    private nonisolated func executeStreamRequest(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        modelID: String,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        let request = try await MainActor.run {
            try self.buildRequest(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                stream: true
            )
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        // Check for error status codes
        if httpResponse.statusCode >= 400 {
            // Try to read error body with cancellation check and size limit
            var errorData = Data()
            let maxErrorSize = 16384  // 16KB max error body
            for try await byte in bytes {
                if Task.isCancelled { break }
                errorData.append(byte)
                if errorData.count >= maxErrorSize { break }
            }
            try self.checkHTTPResponse(httpResponse, data: errorData, modelID: modelID)
        }

        // Process SSE stream
        try await self.processStream(bytes: bytes, continuation: continuation)
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Request Building

    private func buildRequest(
        messages: [AIAgentMessage],
        systemPrompt: String,
        tools: [AIAgentTool],
        stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AIProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Get model info for max tokens
        let modelInfo = AICredentialsManager.shared.requestyDiscoveredModels.first { $0.id == selectedModelID }
        let maxTokens = modelInfo?.effectiveMaxCompletionTokens ?? AIProviderModel.ModelTier.standard.defaultMaxCompletionTokens

        // Get user-configured or default temperature
        let effectiveTemperature = AICredentialsManager.shared.effectiveTemperature(
            for: RequestyProvider.providerID,
            supportsTemperature: true
        ) ?? AICredentialsManager.defaultTemperatures[RequestyProvider.providerID] ?? 0.4

        // Build messages array
        var requestyMessages = [OpenRouterMessage]()

        // Add system prompt
        requestyMessages.append(OpenRouterMessage(role: "system", content: systemPrompt))

        // Add conversation messages
        requestyMessages.append(contentsOf: convertMessages(messages))

        // Convert tools to OpenAI-compatible format
        let requestyTools = convertTools(tools)

        let requestyRequest = OpenRouterRequest(
            model: AIProviderModel.requestyAPIModelID(for: selectedModelID),
            messages: requestyMessages,
            tools: requestyTools.isEmpty ? nil : requestyTools,
            stream: stream,
            max_tokens: maxTokens,
            temperature: effectiveTemperature
        )

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestyRequest)

        Self.logger.debug("Requesty request: model=\(self.selectedModelID), stream=\(stream), messages=\(requestyMessages.count)")

        return request
    }

    // MARK: - Message Conversion

    private func convertMessages(_ messages: [AIAgentMessage]) -> [OpenRouterMessage] {
        var result: [OpenRouterMessage] = []

        for message in messages {
            switch message.content {
            case .text(let text):
                switch message.role {
                case .user:
                    result.append(OpenRouterMessage(role: "user", content: text))
                case .assistant:
                    // Strip thinking from text (thinking is not sent back to Requesty)
                    let parsed = ThinkingParser.parse(text)
                    if !parsed.text.isEmpty {
                        result.append(OpenRouterMessage(role: "assistant", content: parsed.text))
                    }
                case .system:
                    // System messages are handled separately
                    continue
                case .tool:
                    continue
                }

            case .textWithThinking(let text, _):
                // For Requesty, just use the text content (thinking is not supported)
                guard message.role == .assistant else { continue }
                if !text.isEmpty {
                    result.append(OpenRouterMessage(role: "assistant", content: text))
                }

            case .toolCall(let call):
                guard !call.isFromXMLParsing else { continue }
                let toolCall = OpenRouterToolCall(id: call.id, name: call.name, arguments: call.arguments)
                result.append(OpenRouterMessage(role: "assistant", toolCalls: [toolCall]))

            case .toolCalls(let calls, let precedingText, _):
                // Add text first if present
                if let text = precedingText, !text.isEmpty {
                    result.append(OpenRouterMessage(role: "assistant", content: text))
                }

                // Add tool calls (skip XML-parsed ones)
                let nonXMLCalls = calls.filter { !$0.isFromXMLParsing }
                if !nonXMLCalls.isEmpty {
                    let toolCalls = nonXMLCalls.map { call in
                        OpenRouterToolCall(id: call.id, name: call.name, arguments: call.arguments)
                    }
                    result.append(OpenRouterMessage(role: "assistant", toolCalls: toolCalls))
                }

            case .toolResult(let toolCallId, let output, _, let isFromXMLToolCall):
                if isFromXMLToolCall {
                    result.append(OpenRouterMessage(role: "user", content: "[Tool Result]\n\(output)"))
                } else {
                    result.append(OpenRouterMessage(role: "tool", toolCallId: toolCallId, content: output))
                }

            case .toolResults(let results):
                for toolResult in results {
                    if toolResult.isFromXMLToolCall {
                        result.append(OpenRouterMessage(
                            role: "user",
                            content: "[Tool Result for \(toolResult.toolCallId)]\n\(toolResult.output)"
                        ))
                    } else {
                        result.append(OpenRouterMessage(
                            role: "tool",
                            toolCallId: toolResult.toolCallId,
                            content: toolResult.output
                        ))
                    }
                }
            }
        }

        return result
    }

    // MARK: - Tool Conversion

    private func convertTools(_ tools: [AIAgentTool]) -> [OpenRouterTool] {
        tools.map { tool in
            let properties = tool.parameters.properties.mapValues { param -> OpenRouterPropertySchema in
                convertParameter(param)
            }

            return OpenRouterTool(
                function: OpenRouterFunctionDefinition(
                    name: tool.name,
                    description: tool.description,
                    parameters: OpenRouterToolParameters(
                        properties: properties,
                        required: tool.parameters.required
                    )
                )
            )
        }
    }

    private func convertParameter(_ param: AIToolParameter) -> OpenRouterPropertySchema {
        let items: OpenRouterPropertySchema? = param.items.map { convertParameter($0.value) }

        return OpenRouterPropertySchema(
            type: param.type,
            description: param.description,
            enumValues: param.enumValues,
            items: items
        )
    }

    // MARK: - Stream Processing

    /// Process SSE stream - runs off MainActor to avoid blocking UI
    private nonisolated func processStream(
        bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<AIProviderStreamEvent, Error>.Continuation
    ) async throws {
        var toolCallBuilders: [Int: ToolCallBuilder] = [:]
        var accumulatedUsage: OpenRouterUsage?

        for try await event in OpenRouterSSEParser.parseStream(from: bytes) {
            if Task.isCancelled {
                continuation.finish(throwing: AIProviderError.cancelled)
                return
            }

            switch event {
            case .textDelta(let text):
                continuation.yield(.textDelta(text))

            case .toolCallDelta(let index, let id, let name, let arguments):
                if toolCallBuilders[index] == nil {
                    toolCallBuilders[index] = ToolCallBuilder(index: index)
                }

                let builder = toolCallBuilders[index]!
                if let id = id {
                    builder.id = id
                }
                if let name = name {
                    builder.name = name
                }
                if let arguments = arguments {
                    builder.appendArguments(arguments)

                    // Emit delta for UI
                    continuation.yield(.toolCallDelta(
                        id: builder.id ?? "tool_\(index)",
                        name: builder.name,
                        argumentsDelta: arguments
                    ))
                }

            case .done(let usage, let finishReason):
                // Emit any completed tool calls (only once)
                for (_, builder) in toolCallBuilders.sorted(by: { $0.key < $1.key }) {
                    if let toolCall = builder.build() {
                        continuation.yield(.toolCallComplete(toolCall))
                    }
                }
                // Clear to prevent re-emission on subsequent .done events
                // (some models like Amazon Nova send multiple .done events)
                toolCallBuilders.removeAll()

                if let usage = usage {
                    accumulatedUsage = usage
                }

                let usageStats = accumulatedUsage.map { u in
                    AIUsageStats(
                        promptTokens: u.prompt_tokens ?? 0,
                        completionTokens: u.completion_tokens ?? 0,
                        totalTokens: u.total_tokens ?? 0
                    )
                }

                let finish = mapFinishReason(finishReason)
                continuation.yield(.responseComplete(usage: usageStats, finishReason: finish))

            case .error(let message):
                continuation.finish(throwing: AIProviderError.unknown(message))
                return
            }
        }

        continuation.finish()
    }

    /// Helper class to build tool calls from streaming deltas
    /// Marked nonisolated to allow use from detached tasks in stream processing
    /// Thread safety is handled by single-task usage pattern (one builder per tool call)
    private final class ToolCallBuilder: @unchecked Sendable {
        nonisolated let index: Int
        nonisolated(unsafe) var id: String?
        nonisolated(unsafe) var name: String?
        nonisolated(unsafe) var arguments: String = ""

        nonisolated init(index: Int) {
            self.index = index
        }

        nonisolated func appendArguments(_ delta: String) {
            arguments += delta
        }

        nonisolated func build() -> AIToolCall? {
            guard let id = id, let name = name else { return nil }
            return AIToolCall(
                id: id,
                name: name,
                arguments: arguments
            )
        }
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: OpenRouterResponse) -> AIProviderResponse {
        var text = ""
        var toolCalls: [AIToolCall] = []

        if let choices = response.choices {
            for choice in choices {
                if let message = choice.message {
                    if let content = message.content {
                        text += content
                    }

                    if let responseToolCalls = message.tool_calls {
                        for toolCall in responseToolCalls {
                            if let id = toolCall.id,
                               let name = toolCall.function?.name,
                               let arguments = toolCall.function?.arguments {
                                toolCalls.append(AIToolCall(id: id, name: name, arguments: arguments))
                            }
                        }
                    }
                }
            }
        }

        let usage = response.usage.map { u in
            AIUsageStats(
                promptTokens: u.prompt_tokens ?? 0,
                completionTokens: u.completion_tokens ?? 0,
                totalTokens: u.total_tokens ?? 0
            )
        }

        let finishReason = response.choices?.first?.finish_reason.flatMap { mapFinishReason($0) }

        let content: AIProviderResponse.Content
        if !toolCalls.isEmpty && !text.isEmpty {
            content = .textAndToolCalls(text, toolCalls)
        } else if !toolCalls.isEmpty {
            content = .toolCalls(toolCalls)
        } else {
            content = .text(text)
        }

        return AIProviderResponse(content: content, usage: usage, finishReason: finishReason)
    }

    private nonisolated func mapFinishReason(_ reason: String?) -> AIProviderResponse.FinishReason? {
        guard let reason = reason else { return nil }
        switch reason {
        case "stop":
            return .stop
        case "tool_calls":
            return .toolCalls
        case "length":
            return .length
        case "content_filter":
            return .contentFilter
        default:
            return nil
        }
    }

    // MARK: - Error Handling

    private nonisolated func checkHTTPResponse(_ response: HTTPURLResponse, data: Data, modelID: String) throws {
        guard response.statusCode < 400 else {
            // Requesty errors look like {"error":{"origin":"router","message":"..."}}
            let message = (try? JSONDecoder().decode(OpenRouterErrorResponse.self, from: data))?.error.message
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw mapHTTPError(statusCode: response.statusCode, message: message, retryAfter: retryAfter, modelID: modelID)
        }
    }

    private nonisolated func mapHTTPError(
        statusCode: Int,
        message: String?,
        retryAfter: TimeInterval?,
        modelID: String
    ) -> AIProviderError {
        switch statusCode {
        case 401:
            return .invalidAPIKey
        case 402, 412:
            // 402: balance exhausted, 412: monthly spend limit reached
            return .quotaExceeded
        case 403:
            // 403 is returned for an invalid key and for a model blocked by org policy
            if let message, !message.lowercased().contains("authorization") {
                return .unknown(message)
            }
            return .invalidAPIKey
        case 404:
            return .modelNotAvailable(AIProviderModel.requestyAPIModelID(for: modelID))
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 500...599:
            return .networkError("Server error (\(statusCode))")
        default:
            if let message {
                return .unknown(message)
            }
            return .networkError("HTTP error \(statusCode)")
        }
    }

    private nonisolated func mapError(_ error: Error) -> AIProviderError {
        if let providerError = error as? AIProviderError {
            return providerError
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorNotConnectedToInternet:
                return .networkError("No internet connection")
            case NSURLErrorNetworkConnectionLost:
                return .networkError("Connection lost")
            case NSURLErrorTimedOut:
                return .networkError("Request timed out")
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .networkError(error.localizedDescription)
            }
        }

        return .unknown(error.localizedDescription)
    }

    // MARK: - Model Discovery

    /// Discover available models from Requesty.
    /// Managed policies (GET /models/managed, curated multi-provider routing) are listed
    /// first, followed by the full catalog (GET /models). The authenticated catalog call
    /// also validates the key and returns only the models the key's organization allows.
    static func discoverModels(apiKey: String) async throws -> [AIProviderModel] {
        let managed: [RequestyAPIModel]
        do {
            managed = try await fetchModels(path: "models/managed", apiKey: nil)
        } catch {
            logger.warning("Requesty managed policy discovery failed: \(error.localizedDescription)")
            managed = []
        }

        let catalog: [RequestyAPIModel]
        do {
            catalog = try await fetchModels(path: "models", apiKey: apiKey)
        } catch AIProviderError.invalidAPIKey {
            throw AIProviderError.invalidAPIKey
        } catch {
            guard !managed.isEmpty else { throw error }
            logger.warning("Requesty catalog discovery failed: \(error.localizedDescription)")
            catalog = []
        }

        logger.info("Discovered \(managed.count) Requesty managed policies and \(catalog.count) catalog models")

        let managedModels = managed.filter { $0.isChatModel }
            .map { AIProviderModel.requestyModel(from: $0, isManagedPolicy: true) }
            .sorted { $0.displayName < $1.displayName }
        let managedIDs = Set(managedModels.map(\.id))
        let catalogModels = catalog.filter { $0.isChatModel }
            .map { AIProviderModel.requestyModel(from: $0, isManagedPolicy: false) }
            .filter { !managedIDs.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }

        return managedModels + catalogModels
    }

    private static func fetchModels(path: String, apiKey: String?) async throws -> [RequestyAPIModel] {
        guard let url = URL(string: "\(defaultBaseURL)/\(path)") else {
            throw AIProviderError.networkError("Invalid URL")
        }

        var request = URLRequest(url: url)
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw AIProviderError.invalidAPIKey
            }
            throw AIProviderError.networkError("HTTP error \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(RequestyModelsResponse.self, from: data).data
    }
}
#endif
