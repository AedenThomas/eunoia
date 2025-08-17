import Foundation
import MultipeerConnectivity
import SwiftUI
import MLX
import MLXLLM
import MLXLMCommon

#if os(iOS)
@MainActor
class iOSMLXNetworkManager: MultipeerManager {
    // MARK: - Published Properties
    @Published var isInferenceServerEnabled = false
    @Published var currentInferenceRequests: Set<UUID> = []
    @Published var totalInferenceRequests = 0
    @Published var deviceInfo: MLXDeviceInfo
    
    // MARK: - Private Properties
    private let modelDownloadManager = ModelDownloadManager.shared
    private var chatManager: ChatManager?
    
    // MARK: - Initialization
    override init() {
        // Create device info with current capabilities
        let availableModels = ModelDownloadManager.shared.getDownloadedModels().map { $0.identifier }
        self.deviceInfo = MLXDeviceInfo(
            deviceName: UIDevice.current.name,
            availableModels: availableModels,
            capabilities: DeviceCapabilities.current
        )
        
        super.init()
        
        setupInferenceHandlers()
        print("iOSMLXNetworkManager: Initialized for iOS device: \(deviceInfo.deviceName)")
    }
    
    // MARK: - Setup
    private func setupInferenceHandlers() {
        // Add inference request handler
        messageHandlers[.inferenceRequest] = { [weak self] message, peer in
            if case .inferenceRequest(let request) = message {
                Task {
                    await self?.handleInferenceRequest(request, from: peer)
                }
            }
        }
    }
    
    // MARK: - Server Control
    func startInferenceServer() {
        print("DEBUG: iOSMLXNetworkManager.startInferenceServer() called")
        print("DEBUG: isInferenceServerEnabled = \(isInferenceServerEnabled)")
        
        guard !isInferenceServerEnabled else {
            print("DEBUG: startInferenceServer() - already enabled, returning early")
            return
        }
        
        print("DEBUG: Updating device info...")
        updateDeviceInfo()
        print("DEBUG: Device info updated - available models: \(deviceInfo.availableModels)")
        
        print("DEBUG: Calling startAdvertising()...")
        startAdvertising(with: deviceInfo)
        
        isInferenceServerEnabled = true
        print("DEBUG: isInferenceServerEnabled set to: \(isInferenceServerEnabled)")
        
        print("iOSMLXNetworkManager: Started MLX inference server")
    }
    
    func stopInferenceServer() {
        guard isInferenceServerEnabled else { return }
        
        stopAdvertising()
        isInferenceServerEnabled = false
        currentInferenceRequests.removeAll()
        
        print("iOSMLXNetworkManager: Stopped MLX inference server")
    }
    
    private func updateDeviceInfo() {
        let availableModels = modelDownloadManager.getDownloadedModels().map { $0.identifier }
        deviceInfo = MLXDeviceInfo(
            deviceName: UIDevice.current.name,
            availableModels: availableModels,
            capabilities: DeviceCapabilities.current
        )
    }
    
    // MARK: - Inference Handling
    private func handleInferenceRequest(_ request: MLXInferenceRequest, from peer: MCPeerID) async {
        print("iOSMLXNetworkManager: Received inference request from \(peer.displayName)")
        print("  - Request ID: \(request.id)")
        print("  - Model: \(request.modelIdentifier)")
        print("  - Prompt length: \(request.prompt.count) characters")
        
        // Track the request
        currentInferenceRequests.insert(request.id)
        totalInferenceRequests += 1
        
        // Check if we can handle this request
        guard deviceInfo.availableModels.contains(request.modelIdentifier) else {
            let error = MLXNetworkError(
                code: .modelNotFound,
                message: "Model \(request.modelIdentifier) not available on this device",
                requestId: request.id
            )
            sendMessage(.error(error), to: peer)
            currentInferenceRequests.remove(request.id)
            return
        }
        
        // Check if we're not too busy
        guard currentInferenceRequests.count <= deviceInfo.deviceCapabilities.maxConcurrentRequests else {
            let error = MLXNetworkError(
                code: .deviceBusy,
                message: "Device is currently handling maximum concurrent requests",
                requestId: request.id
            )
            sendMessage(.error(error), to: peer)
            currentInferenceRequests.remove(request.id)
            return
        }
        
        do {
            let startTime = Date()
            let response = try await performInference(for: request)
            let inferenceTime = Date().timeIntervalSince(startTime)
            
            let inferenceResponse = MLXInferenceResponse(
                requestId: request.id,
                content: response,
                isComplete: true,
                isStreaming: false,
                inferenceTime: inferenceTime
            )
            
            sendMessage(.inferenceResponse(inferenceResponse), to: peer)
            print("iOSMLXNetworkManager: Completed inference in \(String(format: "%.2f", inferenceTime))s")
            
        } catch {
            let networkError = MLXNetworkError(
                code: .unknownError,
                message: "Inference failed: \(error.localizedDescription)",
                requestId: request.id
            )
            sendMessage(.error(networkError), to: peer)
            print("iOSMLXNetworkManager: Inference failed: \(error)")
        }
        
        // Remove from tracking
        currentInferenceRequests.remove(request.id)
    }
    
    private func performInference(for request: MLXInferenceRequest) async throws -> String {
        // Find the requested model
        guard let model = modelDownloadManager.getDownloadedModels().first(where: { $0.identifier == request.modelIdentifier }) else {
            throw MLXNetworkError(code: .modelNotFound, message: "Model not found", requestId: request.id)
        }
        
        // Check if model is actually downloaded
        guard modelDownloadManager.getDownloadState(for: model) == .completed else {
            throw MLXNetworkError(code: .modelNotLoaded, message: "Model not properly downloaded", requestId: request.id)
        }
        
        // Create a temporary chat manager for inference if needed
        let inferenceManager: ChatManager
        if let existingManager = chatManager {
            inferenceManager = existingManager
        } else {
            inferenceManager = ChatManager()
            chatManager = inferenceManager
        }
        
        // Load the model if it's not already loaded or if it's a different model
        if inferenceManager.selectedModel?.identifier != model.identifier {
            print("iOSMLXNetworkManager: Loading model \(model.name) for inference")
            await inferenceManager.selectModel(model)
            
            // Verify the model loaded successfully
            guard inferenceManager.selectedModel != nil else {
                throw MLXNetworkError(code: .modelNotLoaded, message: "Failed to load model", requestId: request.id)
            }
        }
        
        // Perform the actual inference using MLX
        return try await performMLXInference(
            prompt: request.prompt,
            model: model,
            parameters: request.parameters,
            manager: inferenceManager
        )
    }
    
    private func performMLXInference(
        prompt: String,
        model: MLXModel,
        parameters: InferenceParameters,
        manager: ChatManager
    ) async throws -> String {
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                // Create a temporary message to trigger inference
                let tempMessage = ChatMessage(content: prompt, isUser: true)
                manager.messages.append(tempMessage)
                
                // Create model configuration similar to ChatManager
                let modelConfig: ModelConfiguration
                if model.identifier.contains("gemma-3") {
                    modelConfig = ModelConfiguration(
                        id: model.identifier,
                        extraEOSTokens: ["<end_of_turn>"]
                    )
                } else if model.identifier.contains("SmolLM") {
                    modelConfig = ModelConfiguration(
                        id: model.identifier,
                        extraEOSTokens: ["<|im_end|>"]
                    )
                } else {
                    modelConfig = ModelConfiguration(id: model.identifier)
                }
                
                do {
                    // Load model and create session
                    let loadedModel = try await loadModel(configuration: modelConfig)
                    let chatSession = ChatSession(loadedModel)
                    
                    // Format prompt according to model requirements
                    let formattedPrompt: String
                    if parameters.useModelSpecificFormatting && model.identifier.contains("SmolLM") {
                        formattedPrompt = "<|im_start|>user\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
                    } else {
                        formattedPrompt = prompt
                    }
                    
                    // Perform inference with timeout
                    let response = try await withTimeout(seconds: MLXServiceInfo.inferenceTimeout) {
                        return try await chatSession.respond(to: formattedPrompt)
                    }
                    
                    let cleanResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: cleanResponse)
                    
                } catch {
                    continuation.resume(throwing: error)
                }
                
                // Clean up the temporary message
                if let index = manager.messages.firstIndex(where: { $0.id == tempMessage.id }) {
                    manager.messages.remove(at: index)
                }
            }
        }
    }
    
    // MARK: - Device Status
    func getInferenceServerStatus() -> String {
        if !isInferenceServerEnabled {
            return "Inference server disabled"
        }
        
        let connectedCount = connectedPeers.count
        let activeRequests = currentInferenceRequests.count
        let totalModels = deviceInfo.availableModels.count
        
        return "Connected: \(connectedCount), Active: \(activeRequests), Models: \(totalModels)"
    }
    
    // MARK: - Connection Management
    override func disconnectAll() {
        stopInferenceServer()
        super.disconnectAll()
    }
}

// MARK: - Helper Extensions
extension ModelDownloadManager {
    func getDownloadedModels() -> [MLXModel] {
        return ModelRegistry.availableModels.filter { model in
            getDownloadState(for: model) == .completed
        }
    }
}

#endif