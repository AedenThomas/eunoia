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
    
    // Thread-specific properties
    var threadId: UUID?
    var onMessageAdded: ((UUID, ChatMessage) async -> Void)?
    
    private let downloadManager = ModelDownloadManager.shared
    private var loadedModel: ModelContext?
    private var chatSession: ChatSession?
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
        
        // Get the model ID from either the local model or use a default from the remote device
        let modelId = model?.identifier ?? selectedRemoteDevice?.availableModels.first ?? ""
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
            print("DEBUG: Connected peers before inference: \(networkManager.connectedPeers.map { $0.displayName })")
            
            // Add connection check timeout to run in parallel with inference
            let connectionCheckTask = Task {
                // Check every 5 seconds if we're still connected during long inferences
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    print("DEBUG: Connection check during inference - still connected: \(networkManager.connectedPeers.contains(remoteDevice.peerID))")
                }
            }
            
            // Register the request in both tracking systems
            // IMPORTANT: We'll use the same request ID that will be created in performRemoteInference
            // First, get the ID from the macOSMLXNetworkManager before creating the request
            let requestId = UUID()
            print("DEBUG: Creating inference request with ID: \(requestId.uuidString)")
            
            // Important: Add the request to MultipeerManager's pendingRequests before sending
            // This handler will capture the actual response and display it in debug logs
            networkManager.pendingRequests[requestId] = { response in
                print("DEBUG: MultipeerManager handler triggered for request ID: \(requestId.uuidString)")
                print("DEBUG: ===== INFERENCE RESPONSE FROM iOS =====")
                print("DEBUG: Response content length: \(response.content.count)")
                print("DEBUG: Response content: \"\(response.content)\"")
                print("DEBUG: Inference time: \(String(describing: response.inferenceTime))")
                print("DEBUG: ===== END RESPONSE =====")
                // The response will be processed and returned via the continuation
            }
            
            print("DEBUG: Added request to MultipeerManager.pendingRequests, count: \(networkManager.pendingRequests.count)")
            
            // Create the request with our custom ID to ensure consistent tracking
            let inferenceRequest = MLXInferenceRequest(
                prompt: content,
                modelIdentifier: modelId,
                parameters: InferenceParameters(),
                id: requestId
            )
            
            // IMPORTANT: Instead of using our UUID directly, we'll use the one from performRemoteInference
            // But we'll register a special handler to capture responses from iOS for either ID
            
            // Add a special request handler to check for any response that might come in
            networkManager.messageHandlers[.inferenceResponse] = { message, peer in
                if case .inferenceResponse(let response) = message {
                    print("DEBUG: SPECIAL HANDLER: Received direct inference response from \(peer.displayName)")
                    print("DEBUG: Response request ID: \(response.requestId.uuidString)")
                    print("DEBUG: Response content: \"\(response.content)\"")
                    
                    // Look for handlers in both systems
                    if networkManager.pendingRequests[response.requestId] != nil {
                        print("DEBUG: Found handler in pendingRequests, will process automatically")
                    } else {
                        print("DEBUG: No handler in pendingRequests for ID: \(response.requestId.uuidString)")
                    }
                    
                    // Just let the normal system handle it
                    print("DEBUG: Letting MultipeerManager handle the response normally")
                }
            }
            
            // Now let the system perform inference using our pre-created request with consistent ID
            let response = try await networkManager.performRemoteInference(request: inferenceRequest)
            
            // Cancel the connection check
            connectionCheckTask.cancel()
            
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
            if let networkError = error as? MLXNetworkError {
                errorDetails = "\(networkError.code.rawValue): \(networkError.message)"
                print("DEBUG: MLXNetworkError details - Code: \(networkError.code.rawValue), Message: \(networkError.message)")
            }
            
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
        
        guard let session = chatSession else {
            await handleInferenceError("Model is not loaded. Please try selecting the model again.")
            return
        }
        
        // Start local MLX text generation
        do {
            print("DEBUG: Starting local MLX text generation...")
            print("DEBUG: Model identifier: \(model.identifier)")
            print("DEBUG: ChatSession exists: true")
            
            // Try a simple test first - see if the model can do basic operations
            let testArray = MLXArray([1.0, 2.0, 3.0])
            print("DEBUG: Test MLX array: \(testArray)")
            
            // Use ChatSession to generate response - fixed with proper ModelConfiguration
            print("DEBUG: About to call session.respond(to:)")
            
            // Format the prompt according to model requirements
            let formattedPrompt: String
            if model.identifier.contains("SmolLM") {
                // SmolLM uses ChatML format with <|im_start|> and <|im_end|> tokens
                formattedPrompt = "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n"
                print("DEBUG: SmolLM formatted prompt: \(formattedPrompt)")
            } else {
                // Use default formatting for other models
                formattedPrompt = content
            }
            
            // Add timeout to prevent indefinite hanging
            let response = try await withTimeout(seconds: 30.0) {
                return try await session.respond(to: formattedPrompt)
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
    
    func enableRemoteInference(_ device: RemoteMLXDevice?) {
        print("DEBUG: enableRemoteInference called with device: \(device?.name ?? "nil")")
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
            
            // Debug output to verify the state change
            print("DEBUG: isUsingRemoteInference set to \(isUsingRemoteInference)")
            print("DEBUG: selectedRemoteDevice set to \(selectedRemoteDevice?.name ?? "nil")")
            
            remoteInferenceStatus = "Connected to \(device.name)"
            modelInfo = "Using remote device: \(device.name) for inference"
            
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
        
        print("DEBUG: Checking connection health for device: \(remoteDevice.name)")
        
        // Check if the device is still in connectedPeers - more reliable than remoteDevice.isConnected
        // which might not be updated immediately
        let isActuallyConnected = networkManager.connectedPeers.contains(remoteDevice.peerID)
        
        if isActuallyConnected {
            print("DEBUG: Device \(remoteDevice.name) is still connected")
            
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
        
        // BUGFIX: Set up notification handlers for inference completion
        setupNotificationHandlers()
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
    
    // BUGFIX: Add observer for inference completion notifications
    func setupInferenceCompletionObserver() {
        // Remove any existing observer first to avoid duplicates
        NotificationCenter.default.removeObserver(self, name: Notification.Name("MLXInferenceCompleted"), object: nil)
        
        // Add observer for inference completion notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInferenceCompletedNotification(_:)),
            name: Notification.Name("MLXInferenceCompleted"),
            object: nil
        )
        print("DEBUG: BUGFIX: Set up observer for inference completion notifications")
    }
    
    // Call this method when initializing networking
    func setupNotificationHandlers() {
        setupInferenceCompletionObserver()
    }
    
    // BUGFIX: Handle inference completed notifications to reset UI state
    @objc private func handleInferenceCompletedNotification(_ notification: Notification) {
        print("DEBUG: BUGFIX: ChatManager received MLXInferenceCompleted notification")
        
        guard let content = notification.userInfo?["content"] as? String else {
            print("DEBUG: ERROR: Inference completion notification missing content")
            return
        }
        
        // Skip if we're not currently generating (already handled by another method)
        guard isGenerating else {
            print("DEBUG: BUGFIX: isGenerating already false, skipping notification handling")
            return
        }
        
        // Create and add the AI message
        let aiMessage = ChatMessage(content: content.trimmingCharacters(in: .whitespacesAndNewlines), isUser: false)
        messages.append(aiMessage)
        
        // Notify thread manager of AI response
        if let threadId = threadId, let callback = onMessageAdded {
            print("DEBUG: BUGFIX: Notifying thread manager of new message from notification")
            Task {
                await callback(threadId, aiMessage)
            }
        }
        
        // Reset UI state
        print("DEBUG: BUGFIX: Resetting UI state from notification handler")
        currentResponse = ""
        isGenerating = false
        print("DEBUG: BUGFIX: UI state reset complete")
    }
}