import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MultipeerConnectivity

// Helper function to add timeout to async operations
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {
    let localizedDescription = "Operation timed out"
}

@MainActor
class ChatManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isGenerating = false {
        didSet {
            print("DEBUG: isGenerating changed from \(oldValue) to \(isGenerating)")
        }
    }
    @Published var isLoadingModel = false
    @Published var selectedModel: MLXModel?
    @Published var currentResponse = ""
    @Published var modelInfo = "No model loaded"
    
    // Remote inference properties
    @Published var selectedRemoteDevice: RemoteMLXDevice?
    @Published var isUsingRemoteInference = false
    @Published var remoteInferenceStatus = "Not connected"
    @Published var selectedRemoteModelIdentifier: String?
    
    // Thread-specific properties
    var threadId: UUID?
    var onMessageAdded: ((UUID, ChatMessage) async -> Void)?
    
    private let downloadManager = ModelDownloadManager.shared
    private var loadedModel: ModelContext?
    var chatSession: ChatSession? // Changed from private to internal
    private var generateTask: Task<Void, Never>?
    
    // Multipeer managers (platform-specific)
    #if os(iOS)
    private var iosNetworkManager: iOSMLXNetworkManager?
    #elseif os(macOS)
    private var macOSNetworkManager: macOSMLXNetworkManager?
    #endif
    
    func selectModel(_ model: MLXModel) async {
        print("DEBUG: selectModel() called with model: \(model.name)")
        selectedModel = model
        print("DEBUG: Set selectedModel = \(model.name)")
        
        // Check if model is downloaded
        guard downloadManager.getDownloadState(for: model) == .completed else {
            print("DEBUG: Model \(model.name) not downloaded, aborting selection")
            modelInfo = "Model not downloaded"
            return
        }
        
        // Start loading state
        print("DEBUG: Setting isLoadingModel = true, this should trigger loading overlay")
        isLoadingModel = true
        
        // Load the actual MLX model
        do {
            modelInfo = "Loading \(model.name)..."
            print("Loading MLX model: \(model.identifier)")
            
            // Create model configuration with fixes for known issues
            let modelConfig: ModelConfiguration
            if model.identifier.contains("gemma-3") {
                // Fix for Gemma 3 infinite loop issue - add extraEOSTokens
                print("DEBUG: Applying Gemma 3 fix with extraEOSTokens")
                modelConfig = ModelConfiguration(
                    id: model.identifier,
                    extraEOSTokens: ["<end_of_turn>"]
                )
            } else if model.identifier.contains("SmolLM") {
                // SmolLM might need EOS token fixes similar to Gemma 3
                print("DEBUG: Applying SmolLM fix with ChatML EOS tokens")
                modelConfig = ModelConfiguration(
                    id: model.identifier,
                    extraEOSTokens: ["<|im_end|>"]
                )
            } else {
                // Use default configuration for other models
                modelConfig = ModelConfiguration(id: model.identifier)
            }
            
            // Use the MLX Swift API to load the model with configuration
            let loadedModel = try await loadModel(configuration: modelConfig)
            self.loadedModel = loadedModel
            
            // Create chat session
            self.chatSession = ChatSession(loadedModel)
            
            modelInfo = "Model \(model.name) loaded successfully"
            print("Successfully loaded MLX model for \(model.name)")
            
        } catch {
            modelInfo = "Error loading \(model.name): \(error.localizedDescription)"
            print("Error loading MLX model: \(error)")
            loadedModel = nil
            chatSession = nil
        }
        
        // End loading state
        print("DEBUG: Model loading completed or failed, setting isLoadingModel = false")
        isLoadingModel = false
        print("DEBUG: Load model operation finished for \(model.name), isLoadingModel = \(isLoadingModel)")
    }
    
    func sendMessage(_ content: String) {
        print("DEBUG: sendMessage called with content: \(content)")
        print("DEBUG: Current selectedModel before sending: \(selectedModel?.name ?? "nil")")
        print("DEBUG: Using remote inference: \(isUsingRemoteInference)")
        print("DEBUG: Current threadId: \(threadId?.uuidString ?? "nil")")
        print("DEBUG: Current selectedRemoteDevice: \(selectedRemoteDevice?.name ?? "nil")")
        
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        print("DEBUG: Added user message, messages count: \(messages.count)")
        
        // Notify thread manager if callback is set
        if let threadId = threadId, let callback = onMessageAdded {
            Task {
                await callback(threadId, userMessage)
            }
        }
        
        // Check for either a local model or a remote device being selected
        // This is the main check that determines if the model selection prompt shows
        let canProceed = selectedModel != nil || (isUsingRemoteInference && selectedRemoteDevice != nil)
        
        if !canProceed {
            print("DEBUG: ERROR - No model or remote device selected when trying to send message!")
            print("DEBUG: isUsingRemoteInference: \(isUsingRemoteInference)")
            print("DEBUG: selectedRemoteDevice: \(selectedRemoteDevice?.name ?? "nil")")
            print("DEBUG: selectedModel: \(selectedModel?.name ?? "nil")")
            
            let errorMessage = ChatMessage(content: "Please select a model or remote device first.", isUser: false)
            messages.append(errorMessage)
            // Notify thread manager of error message
            if let threadId = threadId, let callback = onMessageAdded {
                Task {
                    await callback(threadId, errorMessage)
                }
            }
            return
        }
        
        print("DEBUG: About to set isGenerating to true")
        isGenerating = true
        currentResponse = ""
        
        // Cancel any existing generation task
        generateTask?.cancel()
        
        // Choose between local and remote inference
        if isUsingRemoteInference {
            print("DEBUG: Using remote inference with device: \(selectedRemoteDevice?.name ?? "unknown")")
            generateTask = Task {
                await performRemoteInference(content: content, model: selectedModel)
            }
        } else {
            print("DEBUG: Using local inference with model: \(selectedModel?.name ?? "unknown")")
            generateTask = Task {
                await performLocalInference(content: content, model: selectedModel)
            }
        }
    }
    
    private func performRemoteInference(content: String, model: MLXModel?) async {
        #if os(macOS)
        print("DEBUG: ChatManager.performRemoteInference called with content length: \(content.count)")
        print("DEBUG: Using model: \(model?.name ?? "nil"), remote device: \(selectedRemoteDevice?.name ?? "nil")")
        
        guard let networkManager = macOSNetworkManager else {
            print("DEBUG: ERROR - Network manager not initialized")
            await handleRemoteInferenceFailure(
                content: content,
                model: model,
                error: "Remote inference not available (network manager not initialized)"
            )
            return
        }
        
        // Double-check connection status with enhanced logging
        guard let remoteDevice = selectedRemoteDevice, remoteDevice.isConnected else {
            print("DEBUG: ERROR - Remote device not connected or not selected")
            print("DEBUG: selectedRemoteDevice: \(selectedRemoteDevice?.name ?? "nil"), isConnected: \(selectedRemoteDevice?.isConnected ?? false)")
            print("DEBUG: Current connected peers: \(networkManager.connectedPeers.map { $0.displayName })")
            
            await handleRemoteInferenceFailure(
                content: content,
                model: model,
                error: "No remote device available for inference"
            )
            return
        }
        
        // Add extra connection verification
        if !networkManager.connectedPeers.contains(remoteDevice.peerID) {
            print("DEBUG: ERROR - Device marked as connected but not in connectedPeers list!")
            print("DEBUG: This indicates a device connection state inconsistency")
            
            // Update our device connection status to match reality
            networkManager.updateDeviceConnectionStatus(remoteDevice.peerID, isConnected: false)
            
            await handleRemoteInferenceFailure(
                content: content,
                model: model,
                error: "Remote device connection issue detected"
            )
            return
        }
        
        // Use the explicitly selected remote model identifier
        let modelId = selectedRemoteModelIdentifier ?? selectedRemoteDevice?.availableModels.first ?? ""
        if modelId.isEmpty {
            print("DEBUG: ERROR - No model ID available for remote inference")
            print("DEBUG: Local model: \(model?.identifier ?? "nil")")
            print("DEBUG: Remote device models: \(selectedRemoteDevice?.availableModels ?? [])")
            
            await handleRemoteInferenceFailure(
                content: content,
                model: model,
                error: "No model specified for remote inference"
            )
            return
        }
        
        do {
            print("DEBUG: Starting remote MLX inference...")
            print("DEBUG: Model identifier: \(modelId)")
            
            // Create the request. Let the initializer handle the UUID.
            let inferenceRequest = MLXInferenceRequest(
                prompt: content,
                modelIdentifier: modelId,
                parameters: InferenceParameters()
            )

            // Simply call the async function and await the string response.
            // The network manager will handle the request/response lifecycle internally.
            let response = try await networkManager.performRemoteInference(request: inferenceRequest)
            
            print("DEBUG: Remote inference completed, response length: \(response.count)")
            print("DEBUG: Response content: \"\(response)\"")
            
            // Update UI with the complete response
            print("DEBUG: *** CRITICAL SUCCESS PATH *** Remote inference callback invoked with response: \(response.prefix(50))...")
            await MainActor.run {
                if !Task.isCancelled {
                    print("DEBUG: *** CREATING MESSAGE *** Creating AI message from response")
                    let aiMessage = ChatMessage(content: response.trimmingCharacters(in: .whitespacesAndNewlines), isUser: false)
                    print("DEBUG: *** UPDATING UI *** Adding message to chat")
                    self.messages.append(aiMessage)
                    
                    // Notify thread manager of AI response
                    if let threadId = self.threadId, let callback = self.onMessageAdded {
                        print("DEBUG: *** CALLBACK CHAIN *** Notifying thread manager of new message")
                        Task {
                            await callback(threadId, aiMessage)
                        }
                    }
                    
                    print("DEBUG: *** FINAL STEP *** Resetting UI state - MUST HAPPEN")
                    print("DEBUG: Before reset: isGenerating=\(self.isGenerating)")
                    self.currentResponse = ""
                    self.isGenerating = false
                    print("DEBUG: After reset: isGenerating=\(self.isGenerating)")
                    print("DEBUG: Remote inference completed successfully")
                } else {
                    print("DEBUG: Task was cancelled, not updating UI")
                }
            }
            
        } catch {
            print("DEBUG: Error during remote inference: \(error)")
            
            // Get more detailed error info
            var errorDetails = error.localizedDescription
            let nsError = error as NSError
            errorDetails = "\(nsError.code): \(nsError.localizedDescription)"
            print("DEBUG: Error details - Code: \(nsError.code), Message: \(nsError.localizedDescription)")
            
            await handleRemoteInferenceFailure(
                content: content,
                model: model,
                error: "Remote inference failed: \(errorDetails)"
            )
        }
        #else
        await handleRemoteInferenceFailure(
            content: content,
            model: model,
            error: "Remote inference not supported on this platform"
        )
        #endif
    }
    
    private func handleRemoteInferenceFailure(content: String, model: MLXModel?, error: String) async {
        print("DEBUG: Remote inference failed, attempting fallback to local inference")
        
        // Check if we can fallback to local inference
        if let model = model, downloadManager.getDownloadState(for: model) == .completed {
            await MainActor.run {
                // Show fallback message
                let fallbackMessage = ChatMessage(
                    content: "⚠️ Remote inference failed, falling back to local processing...", 
                    isUser: false
                )
                self.messages.append(fallbackMessage)
                
                // Notify thread manager
                if let threadId = self.threadId, let callback = self.onMessageAdded {
                    Task {
                        await callback(threadId, fallbackMessage)
                    }
                }
                
                // Disable remote inference temporarily
                self.enableRemoteInference(nil)
            }
            
            // Attempt local inference
            await performLocalInference(content: content, model: model)
            
        } else {
            // No fallback available
            print("DEBUG: Error during remote inference: \(error)")
            if let networkError = error as? MLXNetworkError {
                print("DEBUG: MLXNetworkError details - Code: \(networkError.code.rawValue), Message: \(networkError.message)")
                print("DEBUG: Request ID: \(networkError.requestId?.uuidString ?? "nil")")
            }
            await handleInferenceError("\(error). Local model not available for fallback.")
        }
    }
    
    private func performLocalInference(content: String, model: MLXModel?) async {
        // Check that we have a model to use
        guard let model = model else {
            await handleInferenceError("No model selected. Please select a model first.")
            return
        }
        
        // Check if model is downloaded
        guard downloadManager.getDownloadState(for: model) == .completed else {
            await handleInferenceError("Please download the \(model.name) model first.")
            return
        }
        
        guard let loadedModel = self.loadedModel else {
            await handleInferenceError("Model context is not loaded. Please try selecting the model again.")
            return
        }
        
        // Always create a fresh chat session for each inference to prevent shape broadcasting errors
        // This ensures completely isolated inference for each request
        print("DEBUG: Creating fresh ChatSession to avoid shape broadcasting errors")
        let session = ChatSession(loadedModel)
        self.chatSession = session
        
        // Start local MLX text generation
        do {
            print("DEBUG: Starting local MLX text generation...")
            print("DEBUG: Model identifier: \(model.identifier)")
            print("DEBUG: Using fresh ChatSession for each inference to avoid state contamination")
            
            // Try a simple test first - see if the model can do basic operations
            let testArray = MLXArray([1.0, 2.0, 3.0])
            print("DEBUG: Test MLX array: \(testArray)")
            print("DEBUG: Content length: \(content.count) characters, estimated tokens: \(estimateTokenCount(for: content))")
            print("DEBUG: Previous message count: \(messages.count - 1)")
            
            // Diagnostic info about previous messages
            if messages.count > 1 {
                let previousMessages = messages.dropLast()
                print("DEBUG: Total tokens in previous messages: \(totalTokenCount(for: Array(previousMessages)))")
                if let lastAssistantMsg = previousMessages.last(where: { !$0.isUser }) {
                    print("DEBUG: Last assistant response: \(lastAssistantMsg.content.count) chars, ~\(estimateTokenCount(for: lastAssistantMsg.content)) tokens")
                }
            }
            
            // Use ChatSession to generate response - fixed with proper ModelConfiguration
            print("DEBUG: About to call session.respond(to:)")
            
            // Enhanced context detection for better shape error prevention
            // First, determine if the current message is a math question
            let isMathQuestion = content.range(of: "[0-9][+\\-*/][0-9]", options: .regularExpression) != nil
            
            // Check if there's a significant length difference that could cause shape issues
            let isLongContent = content.count > 100
            let hasPreviousLongContent = messages.filter { $0.isUser && $0.content.count > 100 }.count > 0
            
            // Detect math context in previous messages
            let hasMathInHistory = messages.filter { 
                $0.isUser && $0.content.range(of: "[0-9][+\\-*/][0-9]", options: .regularExpression) != nil 
            }.count > 0
            
            // Estimate token counts to prevent context window overflows
            let currentTokens = estimateTokenCount(for: content)
            let historyTokens = totalTokenCount(for: messages)
            let totalTokens = currentTokens + historyTokens
            
            // Determine if we're at risk of exceeding context window
            let isContextTooLarge = totalTokens > Int(Double(maxContextTokens) * 0.9) // 90% of max context
            
            print("DEBUG: Context size check: current=\(currentTokens), history=\(historyTokens), total=\(totalTokens)/\(maxContextTokens)")
            
            // Determine if we need a session reset based on these context shifts:
            // 1. From math to non-math questions (original fix)
            // 2. From non-math to math questions (new fix for the current issue)
            // 3. Between short and long content (which can trigger tensor shape issues)
            // 4. When the context size is getting too large (new size-based fix)
            let needsSessionReset = (isMathQuestion && !hasMathInHistory && messages.count > 0) || // Non-math to math
                                   (!isMathQuestion && hasMathInHistory && messages.count > 0) || // Math to non-math 
                                   (isLongContent && !hasPreviousLongContent && messages.count > 1) || // Short to long
                                   (!isLongContent && hasPreviousLongContent && messages.count > 1) || // Long to short
                                   isContextTooLarge // Context window getting too large
            
            // Reset session if we detect any significant context shift
            if needsSessionReset {
                print("DEBUG: Detected significant context shift or large context - creating new chat session")
                print("DEBUG: Context shift details - isMath: \(isMathQuestion), hadMath: \(hasMathInHistory), isLong: \(isLongContent), hadLong: \(hasPreviousLongContent), isContextTooLarge: \(isContextTooLarge)")
                
                // Create a new chat session with the same model to reset internal state
                do {
                    guard let loadedModel = self.loadedModel else {
                        throw NSError(domain: "ChatManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
                    }
                    self.chatSession = ChatSession(loadedModel)
                    print("DEBUG: Successfully reset chat session to handle context shift or large context")
                } catch {
                    print("DEBUG: Failed to reset chat session: \(error)")
                }
            }
            
            // Format the prompt according to model requirements
            let formattedPrompt: String
            if model.identifier.contains("SmolLM") {
                // SmolLM uses ChatML format with <|im_start|> and <|im_end|> tokens
                formattedPrompt = "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n"
                print("DEBUG: SmolLM formatted prompt: \(formattedPrompt)")
            } else if model.identifier.contains("gemma-3") {
                // Gemma 3 uses specific formatting with <start_of_turn> and <end_of_turn> tokens
                // Build conversation history correctly for multi-turn conversations
                var conversationHistory = ""
                
                // Add previous turns if they exist (for multi-turn conversations)
                // Start with the most recent message and work backwards
                let messageHistory = messages.dropLast() // Exclude current user message
                
                // Rather than trying to pair messages (which can get out of sync),
                // rebuild the conversation strictly alternating user/assistant messages
                var orderedMessages: [ChatMessage] = []
                
                // First, extract all messages in order, grouped by user/assistant
                var userMessages: [ChatMessage] = []
                var assistantMessages: [ChatMessage] = []
                
                for message in messageHistory {
                    if message.isUser {
                        userMessages.append(message)
                    } else {
                        assistantMessages.append(message)
                    }
                }
                
                // Initialize counters for token management
                var currentTokenCount = 0
                var tokensForCurrentMessage = estimateTokenCount(for: content)
                var maxHistoryTokens = maxContextTokens - tokensForCurrentMessage
                
                // Reserve 20% of the context window for the model's response
                maxHistoryTokens = Int(Double(maxHistoryTokens) * 0.8)
                
                // Only add messages until we hit our token limit, starting from most recent
                var messagesWithinTokenLimit: [ChatMessage] = []
                
                // Create pairs starting from the most recent and work backwards
                // Limit to at most 2 conversation turns (2 pairs) to prevent shape mismatches
                let totalPairs = min(2, min(userMessages.count, assistantMessages.count))
                
                // Start with the most recent messages and work backwards
                for i in 0..<totalPairs {
                    let userIndex = userMessages.count - 1 - i
                    let assistantIndex = assistantMessages.count - 1 - i
                    
                    if userIndex >= 0 && assistantIndex >= 0 {
                        let userMessage = userMessages[userIndex]
                        let assistantMessage = assistantMessages[assistantIndex]
                        
                        // Calculate token counts for these messages
                        let userTokens = estimateTokenCount(for: userMessage.content)
                        let assistantTokens = estimateTokenCount(for: assistantMessage.content)
                        let pairTokens = userTokens + assistantTokens
                        
                        // Check if adding this pair would exceed our limit
                        if currentTokenCount + pairTokens <= maxHistoryTokens {
                            messagesWithinTokenLimit.insert(userMessage, at: 0)
                            messagesWithinTokenLimit.insert(assistantMessage, at: 1)
                            currentTokenCount += pairTokens
                        } else {
                            // This pair would exceed our token limit, stop here
                            print("DEBUG: Token limit reached at \(currentTokenCount)/\(maxHistoryTokens) tokens, stopped at conversation turn \(i + 1)")
                            break
                        }
                    }
                }
                
                // Use the token-limited messages
                orderedMessages = messagesWithinTokenLimit
                
                print("DEBUG: Using \(orderedMessages.count) messages in context window with \(currentTokenCount) tokens")
                print("DEBUG: Current prompt estimated at \(tokensForCurrentMessage) tokens")
                print("DEBUG: Total context usage: \(currentTokenCount + tokensForCurrentMessage)/\(maxContextTokens) tokens")
                
                
                // Build conversation history from ordered messages
                for i in 0..<orderedMessages.count {
                    let message = orderedMessages[i]
                    if message.isUser {
                        conversationHistory += "<start_of_turn>user\n\(message.content)<end_of_turn>\n"
                    } else {
                        conversationHistory += "<start_of_turn>model\n\(message.content)<end_of_turn>\n"
                    }
                }
                
                // Add the current user message
                conversationHistory += "<start_of_turn>user\n\(content)<end_of_turn>\n"
                // Add the start token for model response
                conversationHistory += "<start_of_turn>model\n"
                
                formattedPrompt = conversationHistory
                print("DEBUG: Gemma 3 formatted prompt with conversation history: \(formattedPrompt)")
            } else {
                // Use default formatting for other models
                formattedPrompt = content
            }
            
            // Add timeout to prevent indefinite hanging
            let response = try await withTimeout(seconds: 30.0) {
                return try await session.respond(to: formattedPrompt)
            }
            
            // Check for empty response and retry once
            if response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("DEBUG: Detected empty response, retrying inference once")
                let retryResponse = try await withTimeout(seconds: 30.0) {
                    return try await session.respond(to: formattedPrompt)
                }
                
                if !retryResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("DEBUG: Retry successful, got non-empty response")
                    print("DEBUG: Local MLX generation completed, response: '\(retryResponse)'")
                    await MainActor.run {
                        if !Task.isCancelled {
                            let aiMessage = ChatMessage(content: retryResponse.trimmingCharacters(in: .whitespacesAndNewlines), isUser: false)
                            self.messages.append(aiMessage)
                            
                            // Notify thread manager of AI response
                            if let threadId = self.threadId, let callback = self.onMessageAdded {
                                Task {
                                    await callback(threadId, aiMessage)
                                }
                            }
                            
                            self.currentResponse = ""
                            self.isGenerating = false
                            print("DEBUG: Local MLX generation completed successfully after retry")
                        }
                    }
                    return
                }
                
                // If retry still empty, return a fallback message
                print("DEBUG: Retry also produced empty response, using fallback message")
                let fallbackMessage = "I'm having trouble generating a response. Please try again or ask a different question."
                await MainActor.run {
                    if !Task.isCancelled {
                        let aiMessage = ChatMessage(content: fallbackMessage, isUser: false)
                        self.messages.append(aiMessage)
                        
                        // Notify thread manager of AI response
                        if let threadId = self.threadId, let callback = self.onMessageAdded {
                            Task {
                                await callback(threadId, aiMessage)
                            }
                        }
                        
                        self.currentResponse = ""
                        self.isGenerating = false
                        print("DEBUG: Local MLX generation completed with fallback message")
                    }
                }
                return
            }
            
            print("DEBUG: Local MLX generation completed, response: '\(response)'")
            
            // Update UI with the complete response
            await MainActor.run {
                if !Task.isCancelled {
                    let aiMessage = ChatMessage(content: response.trimmingCharacters(in: .whitespacesAndNewlines), isUser: false)
                    self.messages.append(aiMessage)
                    
                    // Notify thread manager of AI response
                    if let threadId = self.threadId, let callback = self.onMessageAdded {
                        Task {
                            await callback(threadId, aiMessage)
                        }
                    }
                    
                    self.currentResponse = ""
                    self.isGenerating = false
                    print("DEBUG: Local MLX generation completed successfully")
                }
            }
            
        } catch is TimeoutError {
            print("DEBUG: MLX generation timed out - this suggests session.respond(to:) is hanging")
            await handleInferenceError("⚠️ Generation timed out. The MLX model may not be responding correctly.")
        } catch is CancellationError {
            print("DEBUG: MLX generation was cancelled")
            await MainActor.run {
                self.currentResponse = ""
                self.isGenerating = false
            }
        } catch {
            print("DEBUG: Error during local MLX generation: \(error)")
            await handleInferenceError("Error generating response: \(error.localizedDescription)")
        }
    }
    
    private func handleInferenceError(_ message: String) async {
        await MainActor.run {
            let errorMessage = ChatMessage(content: message, isUser: false)
            self.messages.append(errorMessage)
            
            // Notify thread manager of error message
            if let threadId = self.threadId, let callback = self.onMessageAdded {
                Task {
                    await callback(threadId, errorMessage)
                }
            }
            
            self.currentResponse = ""
            self.isGenerating = false
        }
    }
    
    // MARK: - Remote Inference Management
    
    func enableRemoteInference(_ device: RemoteMLXDevice?, modelIdentifier: String? = nil) {
        print("DEBUG: enableRemoteInference called with device: \(device?.name ?? "nil"), model: \(modelIdentifier ?? "default")")
        print("DEBUG: Device isConnected flag: \(device?.isConnected ?? false)")
        
        // Only set up remote inference if the device is actually connected
        if let device = device, device.isConnected {
            // Check if we actually need to get the network manager to verify connection
            #if os(macOS)
            if let networkManager = macOSNetworkManager {
                let actuallyConnected = networkManager.connectedPeers.contains(device.peerID)
                print("DEBUG: Actual connection status verified: \(actuallyConnected)")
                
                if !actuallyConnected {
                    print("DEBUG: ERROR - Device reports connected but isn't in connectedPeers!")
                    print("DEBUG: Will NOT enable remote inference with this device")
                    
                    // Handle this as a device not connected case
                    handleRemoteDeviceNotConnected()
                    return
                }
                
                // If actually connected, verify the connection with a ping
                networkManager.sendMessage(.ping, to: device.peerID)
            }
            #endif
            
            selectedRemoteDevice = device
            isUsingRemoteInference = true

            let remoteModelToUse = modelIdentifier ?? device.availableModels.first
            selectedRemoteModelIdentifier = remoteModelToUse
            
            let modelName = ModelRegistry.availableModels.first { $0.identifier == remoteModelToUse }?.name ?? remoteModelToUse?.split(separator: "/").last.map(String.init) ?? "Default"
            
            // Debug output to verify the state change
            print("DEBUG: isUsingRemoteInference set to \(isUsingRemoteInference)")
            print("DEBUG: selectedRemoteDevice set to \(selectedRemoteDevice?.name ?? "nil")")
            print("DEBUG: selectedRemoteModelIdentifier set to \(selectedRemoteModelIdentifier ?? "nil")")

            remoteInferenceStatus = "Connected to \(device.name)"
            modelInfo = "Using \(modelName) on \(device.name)"
            
            // Ensure we clear the selectedModel to prevent confusion when using remote inference
            if selectedModel != nil {
                print("DEBUG: Clearing selectedModel due to remote inference mode")
                selectedModel = nil
            }
            
            print("DEBUG: Remote inference successfully enabled with device: \(device.name)")
            print("DEBUG: Available models on remote device: \(device.availableModels.joined(separator: ", "))")
            
            // Start monitoring connection
            startConnectionMonitoring()
        } else {
            // Handle device not provided or not connected
            handleRemoteDeviceNotConnected()
        }
    }
    
    private func handleRemoteDeviceNotConnected() {
        print("DEBUG: Remote device not connected or not provided")
        selectedRemoteDevice = nil
        isUsingRemoteInference = false
        selectedRemoteModelIdentifier = nil
        remoteInferenceStatus = "Not connected"
        
        // Update model info based on local model if available
        if let model = selectedModel {
            modelInfo = "Model \(model.name) loaded locally"
        } else {
            modelInfo = "No model loaded"
        }
        
        // Stop monitoring when not using remote inference
        stopConnectionMonitoring()
    }
    
    private var connectionMonitorTask: Task<Void, Never>?
    
    private func startConnectionMonitoring() {
        stopConnectionMonitoring() // Stop any existing monitoring
        
        print("DEBUG: Starting connection monitoring for remote device")
        connectionMonitorTask = Task {
            // Do an immediate check to verify connection
            await checkConnectionHealth()
            
            // More frequent checks at first to quickly detect initial problems
            for i in 1...3 {
                if Task.isCancelled || !isUsingRemoteInference { break }
                
                // Check every 2 seconds for the first few checks
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await checkConnectionHealth()
                print("DEBUG: Initial connection check #\(i) completed")
            }
            
            // If we're still connected, switch to regular interval
            while !Task.isCancelled && isUsingRemoteInference {
                await checkConnectionHealth()
                
                // Check every 5 seconds (reduced from 10 seconds for more reliability)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            
            print("DEBUG: Connection monitoring task ended")
        }
    }
    
    private func stopConnectionMonitoring() {
        print("DEBUG: Stopping connection monitoring")
        connectionMonitorTask?.cancel()
        connectionMonitorTask = nil
    }
    
    private func checkConnectionHealth() async {
        #if os(macOS)
        guard let networkManager = macOSNetworkManager,
              let remoteDevice = selectedRemoteDevice else {
            return
        }
        
//        print("DEBUG: Checking connection health for device: \(remoteDevice.name)")
        
        // Check if the device is still in connectedPeers - more reliable than remoteDevice.isConnected
        // which might not be updated immediately
        let isActuallyConnected = networkManager.connectedPeers.contains(remoteDevice.peerID)
        
        if isActuallyConnected {
//            print("DEBUG: Device \(remoteDevice.name) is still connected")
            
            // Send a ping to keep the connection alive and verify it's responsive
            networkManager.sendMessage(.ping, to: remoteDevice.peerID)
            
            // Update the device connection status to ensure UI is correct
            networkManager.updateDeviceConnectionStatus(remoteDevice.peerID, isConnected: true)
            return
        }
        
        // We appear to be disconnected
        print("DEBUG: Device \(remoteDevice.name) appears disconnected, waiting to confirm...")
        
        // Only disconnect if we've been disconnected for some time (avoid false negatives)
        if !isActuallyConnected {
            // Add a delay and check again to avoid transient disconnections
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            
            // Check again if we're actually disconnected
            let isStillDisconnected = !networkManager.connectedPeers.contains(remoteDevice.peerID)
            
            if isStillDisconnected {
                print("DEBUG: Device confirmed disconnected after waiting")
                
                // Try to reconnect once before giving up
                print("DEBUG: Attempting to reconnect to \(remoteDevice.name)...")
                networkManager.connectToPeer(remoteDevice.peerID)
                
                // Wait a bit to see if reconnection works
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                
                // Final check - if still disconnected, give up
                if !networkManager.connectedPeers.contains(remoteDevice.peerID) {
                    print("DEBUG: Reconnection failed, disabling remote inference")
                    await MainActor.run {
                        print("DEBUG: Remote device disconnected, disabling remote inference")
                        self.enableRemoteInference(nil)
                        
                        // Update status
                        self.remoteInferenceStatus = "Connection lost"
                        
                        // Optionally show a message to the user
                        if !self.messages.isEmpty {
                            let disconnectMessage = ChatMessage(
                                content: "📱 Remote device disconnected. Switched to local inference.",
                                isUser: false
                            )
                            self.messages.append(disconnectMessage)
                            
                            // Notify thread manager
                            if let threadId = self.threadId, let callback = self.onMessageAdded {
                                Task {
                                    await callback(threadId, disconnectMessage)
                                }
                            }
                        }
                    }
                } else {
                    print("DEBUG: Reconnection successful!")
                    // Update the device connection status
                    networkManager.updateDeviceConnectionStatus(remoteDevice.peerID, isConnected: true)
                }
            } else {
                print("DEBUG: Device connection restored, was temporarily disconnected")
                // Make sure connection status is properly reflected
                networkManager.updateDeviceConnectionStatus(remoteDevice.peerID, isConnected: true)
            }
        }
        #endif
    }
    
    func initializeNetworking() {
        print("DEBUG: ChatManager.initializeNetworking() called")
        #if os(iOS)
        print("DEBUG: Creating iOSMLXNetworkManager")
        iosNetworkManager = iOSMLXNetworkManager()
        print("DEBUG: iOSMLXNetworkManager created successfully")
        #elseif os(macOS)
        print("DEBUG: Creating macOSMLXNetworkManager")
        macOSNetworkManager = macOSMLXNetworkManager()
        print("DEBUG: macOSMLXNetworkManager created successfully")
        #endif
    }
    
    func startNetworkServices() {
        print("DEBUG: ChatManager.startNetworkServices() called")
        #if os(iOS)
        print("DEBUG: Starting iOS inference server...")
        if let manager = iosNetworkManager {
            print("DEBUG: iOS network manager exists, calling startInferenceServer()")
            manager.startInferenceServer()
            print("DEBUG: iOS inference server start command completed")
        } else {
            print("DEBUG: ERROR - iOS network manager is nil!")
        }
        #elseif os(macOS)
        print("DEBUG: Starting macOS device discovery...")
        if let manager = macOSNetworkManager {
            print("DEBUG: macOS network manager exists, calling startDeviceDiscovery()")
            manager.startDeviceDiscovery()
            print("DEBUG: macOS device discovery start command completed")
        } else {
            print("DEBUG: ERROR - macOS network manager is nil!")
        }
        #endif
    }
    
    func stopNetworkServices() {
        print("DEBUG: ChatManager.stopNetworkServices() called")
        #if os(iOS)
        print("DEBUG: Stopping iOS inference server...")
        iosNetworkManager?.stopInferenceServer()
        #elseif os(macOS)
        print("DEBUG: Stopping macOS device discovery...")
        macOSNetworkManager?.stopDeviceDiscovery()
        #endif
    }
    
    func getAvailableRemoteDevices() -> [RemoteMLXDevice] {
        #if os(macOS)
        return macOSNetworkManager?.discoveredDevices ?? []
        #else
        return []
        #endif
    }
    
    func getNetworkManager() -> MultipeerManager? {
        #if os(iOS)
        return iosNetworkManager
        #elseif os(macOS)
        return macOSNetworkManager
        #else
        return nil
        #endif
    }
    
    
    func stopGeneration() {
        generateTask?.cancel()
        isGenerating = false
        
        // Add the partial response if any
        if !currentResponse.isEmpty {
            let aiMessage = ChatMessage(content: currentResponse, isUser: false)
            messages.append(aiMessage)
            
            // Notify thread manager of partial response
            if let threadId = threadId, let callback = onMessageAdded {
                Task {
                    await callback(threadId, aiMessage)
                }
            }
            
            currentResponse = ""
        }
    }
    
    func clearMessages() {
        messages.removeAll()
    }
    
    // MARK: - Token Management
    
    /// Estimates the token count of a string using a simple heuristic.
    /// For English text, 1 token is approximately 4 characters.
    private func estimateTokenCount(for text: String) -> Int {
        // A simple heuristic - 1 token is approximately 4 characters for English text
        // This is a rough estimate but should work for our context window management purposes
        let characterCount = text.count
        return max(1, Int(Double(characterCount) / 4.0))
    }
    
    /// Returns the estimated total token count for a collection of messages
    private func totalTokenCount(for messages: [ChatMessage]) -> Int {
        return messages.reduce(0) { (total, message) in
            return total + estimateTokenCount(for: message.content)
        }
    }
    
    /// Maximum token count allowed in the conversation window
    /// Gemma 3 models have a context window of 2048, but we use a very conservative limit
    /// to avoid any possibility of shape broadcasting errors
    private let maxContextTokens = 1000
    
    // MARK: - Thread Management
    
    func loadThread(_ thread: ChatThread) async {
        let oldThreadId = threadId
        let oldSelectedModel = selectedModel
        
        print("DEBUG: loadThread called for thread \(thread.id), title: '\(thread.title)'")
        print("DEBUG: oldThreadId = \(oldThreadId?.uuidString ?? "nil"), newThreadId = \(thread.id.uuidString)")
        print("DEBUG: oldSelectedModel = \(oldSelectedModel?.name ?? "nil"), thread.selectedModel = \(thread.selectedModel?.name ?? "nil")")
        
        threadId = thread.id
        messages = thread.messages
        
        // Only load model if this is a different thread
        if oldThreadId != thread.id {
            print("DEBUG: Different thread detected, checking model selection...")
            // Load the thread's selected model if available
            if let model = thread.selectedModel {
                print("DEBUG: Thread has selected model: \(model.name), loading...")
                await selectModel(model)
            } else if selectedModel == nil {
                // Only clear model if we don't have one selected already
                // This preserves user's active model selection when thread doesn't specify one
                print("DEBUG: No thread model and no current model, clearing model info")
                modelInfo = "No model selected"
            } else {
                print("DEBUG: No thread model but keeping current selection: \(selectedModel?.name ?? "unknown")")
            }
        } else {
            print("DEBUG: Same thread, preserving model selection: \(selectedModel?.name ?? "nil")")
        }
        
        print("DEBUG: Loaded thread: \(thread.title) with \(messages.count) messages, final model: \(selectedModel?.name ?? "nil")")
    }
    
    func setupThreadCallback(_ callback: @escaping (UUID, ChatMessage) async -> Void) {
        onMessageAdded = callback
    }
}
