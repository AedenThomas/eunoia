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
        setupConnectionHandlers()
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
    
    private func setupConnectionHandlers() {
        // Override the peer connection state change handler
        // to add iOS-specific connection handling
//        messageHandlers[.ping] = { [weak self] _, peer in
//            print("DEBUG: Received ping from \(peer.displayName), sending pong response")
//            self?.sendMessage(.pong, to: peer)
//        }
        
//        messageHandlers[.pong] = { [weak self] _, peer in
//            print("DEBUG: Received pong response from \(peer.displayName)")
//        }
    }
    
    // Override the connection state handling to keep track of connected peers
    @objc @MainActor
    override func handlePeerConnectionStateChange(_ peerID: MCPeerID, state: MCSessionState) {
        print("DEBUG: iOS - handling connection state change for \(peerID.displayName): \(state)")
        
        switch state {
        case .connected:
            print("DEBUG: iOS - peer connected: \(peerID.displayName)")
            
            // Send an immediate ping to verify connection
            sendMessage(.ping, to: peerID)
            
        case .notConnected:
            print("DEBUG: iOS - peer disconnected: \(peerID.displayName)")
            
            // If this peer was in the middle of inference, we need to clean up
            // We don't need to handle anything here since the inference task will detect the disconnect
            
        default:
            break
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
        
        // Verify peer is still connected
        guard connectedPeers.contains(peer) else {
            print("DEBUG: ERROR - Peer \(peer.displayName) is no longer connected, cannot process request")
            return
        }
        
        // Track the request
        currentInferenceRequests.insert(request.id)
        totalInferenceRequests += 1
        
        // Check if we can handle this request
        guard deviceInfo.availableModels.contains(request.modelIdentifier) else {
            print("DEBUG: ERROR - Model \(request.modelIdentifier) not available on this device")
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
            print("DEBUG: ERROR - Device is busy handling other requests")
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
            // Verify connection status before starting inference
            print("DEBUG: Starting inference for request \(request.id), peer is still connected: \(connectedPeers.contains(peer))")
            
            let startTime = Date()
            print("DEBUG: About to call performInference for model \(request.modelIdentifier)")
            let response = try await performInference(for: request)
            let inferenceTime = Date().timeIntervalSince(startTime)
            
            print("DEBUG: Inference completed successfully in \(inferenceTime)s")
            print("DEBUG: Response length: \(response.count) chars")
            
            // Create a unique message ID for this response (used for chunking and acknowledgments)
            let messageId = UUID()
            
            let inferenceResponse = MLXInferenceResponse(
                requestId: request.id,
                content: response,
                isComplete: true,
                isStreaming: false,
                inferenceTime: inferenceTime,
                messageId: messageId,
                chunkCount: response.count > MLXServiceInfo.maxChunkSize ? 
                    Int(ceil(Double(response.count) / Double(MLXServiceInfo.maxChunkSize))) : 1
            )
            
            // Check if peer is still connected before sending response
            if connectedPeers.contains(peer) {
                print("DEBUG: Peer \(peer.displayName) is still connected, sending response")
                sendMessage(.inferenceResponse(inferenceResponse), to: peer)
                print("iOSMLXNetworkManager: Completed inference in \(String(format: "%.2f", inferenceTime))s")
                
                // Double-check that message was sent (verify peer is still in connected list)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self = self else { return }
                    if !self.connectedPeers.contains(peer) {
                        print("DEBUG: WARNING - Peer \(peer.displayName) disconnected after sending response!")
                    } else {
                        print("DEBUG: Connection with \(peer.displayName) still active after sending response")
                        
                        // Send another ping after 3 seconds to verify connection still works
                        self.sendMessage(.ping, to: peer)
                    }
                }
            } else {
                print("DEBUG: ERROR - Peer \(peer.displayName) disconnected during inference, cannot send response")
                // Try to reconnect and resend
                self.reconnectAndRetry(peer: peer, response: inferenceResponse)
            }
        } catch {
            print("DEBUG: Inference failed with error: \(error)")
            
            let networkError = MLXNetworkError(
                code: .unknownError,
                message: "Inference failed: \(error.localizedDescription)",
                requestId: request.id
            )
            
            if connectedPeers.contains(peer) {
                sendMessage(.error(networkError), to: peer)
            } else {
                print("DEBUG: ERROR - Peer \(peer.displayName) disconnected during inference, cannot send error")
            }
            print("iOSMLXNetworkManager: Inference failed: \(error)")
        }
        
        // Remove from tracking
        currentInferenceRequests.remove(request.id)
    }
    
    // Helper method to attempt reconnection and resend response
    private func reconnectAndRetry(peer: MCPeerID, response: MLXInferenceResponse) {
        print("DEBUG: Attempting to reconnect to peer \(peer.displayName) and resend response")
        
        // We can't directly reconnect in MultipeerConnectivity - the other side needs to initiate
        // But we can add debugging to help troubleshoot the issue
        print("DEBUG: Cannot directly reconnect in MultipeerConnectivity")
        print("DEBUG: Response for request \(response.requestId) could not be delivered")
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
    
    /// Estimates the token count of a string using a simple heuristic.
    /// For English text, 1 token is approximately 4 characters.
    private func estimateTokenCount(for text: String) -> Int {
        // A simple heuristic - 1 token is approximately 4 characters for English text
        // This is a rough estimate but should work for our context window management purposes
        let characterCount = text.count
        return max(1, Int(Double(characterCount) / 4.0))
    }
    
    private func performMLXInference(
        prompt: String,
        model: MLXModel,
        parameters: InferenceParameters,
        manager: ChatManager
    ) async throws -> String {
        guard let chatSession = manager.chatSession else {
            // This should not happen if performInference is called before.
            throw MLXNetworkError(code: .modelNotLoaded, message: "Model is not loaded in ChatManager's session.", requestId: nil)
        }
    
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
        
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
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
