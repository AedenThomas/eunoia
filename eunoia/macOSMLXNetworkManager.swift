import Foundation
import MultipeerConnectivity
import SwiftUI

#if os(macOS)
@MainActor
class macOSMLXNetworkManager: MultipeerManager {
    // MARK: - Published Properties
    @Published var isDiscoveryEnabled = false
    @Published var discoveredDevices: [RemoteMLXDevice] = []
    @Published var selectedRemoteDevice: RemoteMLXDevice?
    @Published var pendingInferenceRequests: [UUID: PendingRequest] = [:]
    
    // MARK: - Private Properties
    private var deviceInfoCache: [MCPeerID: MLXDeviceInfo] = [:]
    private var lastDeviceInfoUpdate: [MCPeerID: Date] = [:]
    private let deviceInfoCacheTimeout: TimeInterval = 300 // 5 minutes
    
    struct PendingRequest {
        let request: MLXInferenceRequest
        let startTime: Date
        let completion: (Result<MLXInferenceResponse, MLXNetworkError>) -> Void
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupInferenceHandlers()
        print("macOSMLXNetworkManager: Initialized for macOS device")
    }
    
    // MARK: - Setup
    private func setupInferenceHandlers() {
        // Handle inference responses
        messageHandlers[.inferenceResponse] = { [weak self] message, peer in
            if case .inferenceResponse(let response) = message {
                self?.handleInferenceResponse(response, from: peer)
            }
        }
        
        // Handle errors
        messageHandlers[.error] = { [weak self] message, peer in
            if case .error(let error) = message {
                self?.handleNetworkError(error, from: peer)
            }
        }
    }
    
    // MARK: - Discovery Control
    func startDeviceDiscovery() {
        print("DEBUG: macOSMLXNetworkManager.startDeviceDiscovery() called")
        print("DEBUG: isDiscoveryEnabled = \(isDiscoveryEnabled)")
        
        guard !isDiscoveryEnabled else {
            print("DEBUG: startDeviceDiscovery() - already enabled, returning early")
            return
        }
        
        print("DEBUG: Calling startBrowsing()...")
        startBrowsing()
        
        isDiscoveryEnabled = true
        print("DEBUG: isDiscoveryEnabled set to: \(isDiscoveryEnabled)")
        
        print("macOSMLXNetworkManager: Started device discovery")
    }
    
    func stopDeviceDiscovery() {
        guard isDiscoveryEnabled else { return }
        
        stopBrowsing()
        isDiscoveryEnabled = false
        discoveredDevices.removeAll()
        selectedRemoteDevice = nil
        
        print("macOSMLXNetworkManager: Stopped device discovery")
    }
    
    // MARK: - Device Management
    func selectRemoteDevice(_ device: RemoteMLXDevice) {
        selectedRemoteDevice = device
        
        // Connect to the device if not already connected
        if !connectedPeers.contains(device.peerID) {
            connectToPeer(device.peerID)
        }
        
        print("macOSMLXNetworkManager: Selected remote device: \(device.name)")
    }
    
    func deselectRemoteDevice() {
        selectedRemoteDevice = nil
        print("macOSMLXNetworkManager: Deselected remote device")
    }
    
    private func updateDiscoveredDevices() {
        var updatedDevices: [RemoteMLXDevice] = []
        
        for peerID in availableDevices {
            if let deviceInfo = deviceInfoCache[peerID] {
                let device = RemoteMLXDevice(
                    peerID: peerID,
                    name: deviceInfo.deviceName,
                    availableModels: deviceInfo.availableModels,
                    capabilities: deviceInfo.deviceCapabilities,
                    isConnected: connectedPeers.contains(peerID),
                    lastSeen: deviceInfo.lastSeen
                )
                updatedDevices.append(device)
            } else {
                // Create a basic device entry while we wait for device info
                let device = RemoteMLXDevice(
                    peerID: peerID,
                    name: peerID.displayName,
                    availableModels: [],
                    capabilities: DeviceCapabilities.current,
                    isConnected: connectedPeers.contains(peerID),
                    lastSeen: Date()
                )
                updatedDevices.append(device)
                
                // Request device info
                requestDeviceInfo(from: peerID)
            }
        }
        
        discoveredDevices = updatedDevices
    }
    
    private func requestDeviceInfo(from peerID: MCPeerID) {
        // Check if we recently requested info from this device
        if let lastUpdate = lastDeviceInfoUpdate[peerID],
           Date().timeIntervalSince(lastUpdate) < 30 {
            return
        }
        
        // Send a ping to establish communication
        sendMessage(.ping, to: peerID)
        lastDeviceInfoUpdate[peerID] = Date()
    }
    
    // MARK: - Remote Inference
    func performRemoteInference(
        prompt: String,
        modelIdentifier: String,
        parameters: InferenceParameters = InferenceParameters()
    ) async throws -> String {
        
        guard let selectedDevice = selectedRemoteDevice else {
            throw MLXNetworkError(code: .networkError, message: "No remote device selected")
        }
        
        guard selectedDevice.isConnected else {
            throw MLXNetworkError(code: .networkError, message: "Remote device not connected")
        }
        
        guard selectedDevice.availableModels.contains(modelIdentifier) else {
            throw MLXNetworkError(code: .modelNotFound, message: "Model not available on remote device")
        }
        
        let request = MLXInferenceRequest(
            prompt: prompt,
            modelIdentifier: modelIdentifier,
            parameters: parameters
        )
        
        print("macOSMLXNetworkManager: Sending inference request to \(selectedDevice.name)")
        print("  - Model: \(modelIdentifier)")
        print("  - Prompt length: \(prompt.count) characters")
        
        return try await withCheckedThrowingContinuation { continuation in
            let pendingRequest = PendingRequest(
                request: request,
                startTime: Date(),
                completion: { result in
                    switch result {
                    case .success(let response):
                        continuation.resume(returning: response.content)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )
            
            pendingInferenceRequests[request.id] = pendingRequest
            
            // Set up timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + MLXServiceInfo.inferenceTimeout) { [weak self] in
                if let pending = self?.pendingInferenceRequests.removeValue(forKey: request.id) {
                    let error = MLXNetworkError(
                        code: .inferenceTimeout,
                        message: "Remote inference request timed out",
                        requestId: request.id
                    )
                    pending.completion(.failure(error))
                }
            }
            
            // Send the request
            sendMessage(.inferenceRequest(request), to: selectedDevice.peerID)
        }
    }
    
    private func handleInferenceResponse(_ response: MLXInferenceResponse, from peer: MCPeerID) {
        guard let pendingRequest = pendingInferenceRequests.removeValue(forKey: response.requestId) else {
            print("macOSMLXNetworkManager: Received response for unknown request: \(response.requestId)")
            return
        }
        
        let inferenceTime = Date().timeIntervalSince(pendingRequest.startTime)
        print("macOSMLXNetworkManager: Received inference response in \(String(format: "%.2f", inferenceTime))s")
        
        pendingRequest.completion(.success(response))
    }
    
    private func handleNetworkError(_ error: MLXNetworkError, from peer: MCPeerID) {
        if let requestId = error.requestId,
           let pendingRequest = pendingInferenceRequests.removeValue(forKey: requestId) {
            print("macOSMLXNetworkManager: Received error for request \(requestId): \(error.message)")
            pendingRequest.completion(.failure(error))
        } else {
            print("macOSMLXNetworkManager: Received general error from \(peer.displayName): \(error.message)")
            lastError = error.message
        }
    }
    
    // MARK: - Device Status
    func getRemoteDeviceStatus() -> String {
        let availableCount = discoveredDevices.count
        let connectedCount = connectedPeers.count
        let selectedDevice = selectedRemoteDevice?.name ?? "None"
        
        return "Available: \(availableCount), Connected: \(connectedCount), Selected: \(selectedDevice)"
    }
    
    func hasAvailableRemoteDevices() -> Bool {
        return !discoveredDevices.isEmpty
    }
    
    func isRemoteInferenceAvailable() -> Bool {
        return selectedRemoteDevice?.isConnected == true
    }
    
    // MARK: - Override MCNearbyServiceBrowserDelegate
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        super.browser(browser, foundPeer: peerID, withDiscoveryInfo: info)
        
        Task { @MainActor in
            // Cache device info from discovery
            if let info = info {
                let deviceInfo = parseDiscoveryInfo(info, for: peerID)
                deviceInfoCache[peerID] = deviceInfo
            }
            
            updateDiscoveredDevices()
        }
    }
    
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        super.browser(browser, lostPeer: peerID)
        
        Task { @MainActor in
            // Clean up cached info
            deviceInfoCache.removeValue(forKey: peerID)
            lastDeviceInfoUpdate.removeValue(forKey: peerID)
            
            // Deselect if this was the selected device
            if selectedRemoteDevice?.peerID == peerID {
                selectedRemoteDevice = nil
            }
            
            updateDiscoveredDevices()
        }
    }
    
    private func parseDiscoveryInfo(_ info: [String: String], for peerID: MCPeerID) -> MLXDeviceInfo {
        let platform = DeviceCapabilities.DevicePlatform(rawValue: info["device"] ?? "iOS") ?? .iOS
        let modelsString = info["models"] ?? ""
        let availableModels = modelsString.isEmpty ? [] : modelsString.components(separatedBy: ",")
        
        let capabilities = DeviceCapabilities(
            supportsStreaming: true,
            maxConcurrentRequests: 1,
            preferredModels: availableModels,
            platform: platform
        )
        
        return MLXDeviceInfo(
            deviceName: peerID.displayName,
            availableModels: availableModels,
            capabilities: capabilities
        )
    }
    
    // MARK: - Connection Cleanup
    override func disconnectAll() {
        pendingInferenceRequests.forEach { _, request in
            let error = MLXNetworkError(
                code: .networkError,
                message: "Connection lost",
                requestId: request.request.id
            )
            request.completion(.failure(error))
        }
        pendingInferenceRequests.removeAll()
        
        selectedRemoteDevice = nil
        super.disconnectAll()
    }
}

// MARK: - Remote Device Model

#endif