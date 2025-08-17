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
            print("DEBUG: Device not connected, initiating connection to \(device.name)")
            connectToPeer(device.peerID)
        } else {
            print("DEBUG: Device already connected: \(device.name)")
            // Update the device in discoveredDevices to mark it as connected
            updateDeviceConnectionStatus(device.peerID, isConnected: true)
        }
        
        print("macOSMLXNetworkManager: Selected remote device: \(device.name)")
    }
    
    func deselectRemoteDevice() {
        selectedRemoteDevice = nil
        print("macOSMLXNetworkManager: Deselected remote device")
    }
    
    private func updateDiscoveredDevices() {
        var updatedDevices: [RemoteMLXDevice] = []
        var seenDeviceNames = Set<String>()
        
        print("DEBUG: Updating discovered devices - availableDevices count: \(availableDevices.count)")
        print("DEBUG: Available device names: \(availableDevices.map { $0.displayName })")
        print("DEBUG: deviceInfoCache count: \(deviceInfoCache.count)")
        print("DEBUG: deviceInfoCache keys: \(deviceInfoCache.keys.map { $0.displayName })")
        
        // Process all available devices from our device tracking
        for peerID in availableDevices {
            // Skip duplicate device names - this is the key fix for the duplicate device issue
            if seenDeviceNames.contains(peerID.displayName) {
                print("DEBUG: Skipping duplicate device: \(peerID.displayName)")
                continue
            }
            seenDeviceNames.insert(peerID.displayName)
            
            if let deviceInfo = deviceInfoCache[peerID] {
                print("DEBUG: Adding device with cached info: \(peerID.displayName)")
                let device = RemoteMLXDevice(
                    peerID: peerID,
                    name: deviceInfo.deviceName,
                    availableModels: deviceInfo.availableModels,
                    capabilities: deviceInfo.deviceCapabilities,
                    isConnected: connectedPeers.contains(peerID),
                    lastSeen: Date()  // Update the last seen timestamp to now
                )
                updatedDevices.append(device)
            } else {
                // Create a basic device entry while we wait for device info
                print("DEBUG: Adding device with basic info: \(peerID.displayName)")
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
        
        // Process devices in cache that might not be in availableDevices yet
        // This ensures we show devices that have been discovered but might not be in availableDevices
        for (peerID, deviceInfo) in deviceInfoCache {
            if seenDeviceNames.contains(peerID.displayName) {
                // Already processed this device
                continue
            }
            
            print("DEBUG: Adding device from cache: \(peerID.displayName)")
            seenDeviceNames.insert(peerID.displayName)
            
            // Create device from cached info
            let device = RemoteMLXDevice(
                peerID: peerID,
                name: deviceInfo.deviceName,
                availableModels: deviceInfo.availableModels,
                capabilities: deviceInfo.deviceCapabilities,
                isConnected: connectedPeers.contains(peerID),
                lastSeen: Date()  // Update the last seen timestamp to now
            )
            updatedDevices.append(device)
            
            // Force add to availableDevices if not already there
            if !availableDevices.contains(peerID) {
                print("DEBUG: Adding peer from cache to availableDevices: \(peerID.displayName)")
                availableDevices.append(peerID)
            }
        }
        
        // Preserve selected device even if temporarily missing from availableDevices
        if let selected = selectedRemoteDevice, !updatedDevices.contains(where: { $0.peerID == selected.peerID }) {
            // Only keep if we're connected or recently seen
            if connectedPeers.contains(selected.peerID) || 
               Date().timeIntervalSince(selected.lastSeen) < 30 {
                updatedDevices.append(selected)
                print("DEBUG: Preserved selected device that was temporarily not discovered: \(selected.name)")
            }
        }
        
        // Log the final results
        print("DEBUG: Final discovered devices count: \(updatedDevices.count)")
        for device in updatedDevices {
            print("DEBUG: - Device: \(device.name), Models: \(device.availableModels.count), Connected: \(device.isConnected)")
        }
        
        // Only update if there's a change to avoid unnecessary UI refreshes
        if discoveredDevices.count != updatedDevices.count || 
           !Set(discoveredDevices.map { $0.id }).isSubset(of: Set(updatedDevices.map { $0.id })) {
            print("DEBUG: Updating discoveredDevices property with \(updatedDevices.count) devices")
            discoveredDevices = updatedDevices
        } else {
            print("DEBUG: No change in discoveredDevices, skipping update")
        }
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
    
    // Helper method to update a device's connection status
    private func updateDeviceConnectionStatus(_ peerID: MCPeerID, isConnected: Bool) {
        for (index, device) in discoveredDevices.enumerated() {
            if device.peerID == peerID {
                let updatedDevice = RemoteMLXDevice(
                    peerID: device.peerID,
                    name: device.name,
                    availableModels: device.availableModels,
                    capabilities: device.capabilities,
                    isConnected: isConnected,
                    lastSeen: Date()
                )
                discoveredDevices[index] = updatedDevice
                
                // Also update selected device if this is the one
                if selectedRemoteDevice?.peerID == peerID {
                    selectedRemoteDevice = updatedDevice
                }
                
                print("DEBUG: Updated connection status for \(device.name) to \(isConnected ? "connected" : "disconnected")")
                break
            }
        }
    }
    
    // MARK: - Override Connection Handling
    
    // Override the connection state handling
    @objc @MainActor
    override func handlePeerConnectionStateChange(_ peerID: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            updateDeviceConnectionStatus(peerID, isConnected: true)
        case .notConnected:
            updateDeviceConnectionStatus(peerID, isConnected: false)
        default:
            break
        }
    }
    
    // MARK: - Override MCNearbyServiceBrowserDelegate
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        // Let the parent class handle basic device discovery using our new uniqueness tracking
        super.browser(browser, foundPeer: peerID, withDiscoveryInfo: info)
        
        // Then handle the macOS-specific enhanced device info
        print("DEBUG: macOSMLXNetworkManager - processing found peer for device info")
        
        // Check if we have valid discovery info before proceeding
        guard let info = info, 
              info["capability"] == "mlx",
              !info["models", default: ""].isEmpty else {
            print("DEBUG: macOS - Skipping peer with invalid discovery info")
            return
        }
        
        Task { @MainActor in
            // Cache device info from discovery
            let deviceInfo = parseDiscoveryInfo(info, for: peerID)
            deviceInfoCache[peerID] = deviceInfo
            
            // Ensure the peer is in availableDevices so it's included in updateDiscoveredDevices
            if !availableDevices.contains(peerID) {
                print("DEBUG: Adding found peer to availableDevices: \(peerID.displayName)")
                availableDevices.append(peerID)
            }
            
            // Update the enhanced device info display
            updateDiscoveredDevices()
            print("DEBUG: macOS - Updated device info for \(peerID.displayName)")
            
            // Log the current state of discovered devices
            print("DEBUG: Current discovered devices count: \(discoveredDevices.count)")
            for device in discoveredDevices {
                print("DEBUG: → Device: \(device.name), Models: \(device.availableModels.count), Connected: \(device.isConnected)")
            }
        }
    }
    
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // First let the parent class handle basic device discovery cleanup
        super.browser(browser, lostPeer: peerID)
        
        // Then handle the macOS-specific device info cleanup
        print("DEBUG: macOSMLXNetworkManager - processing lost peer for device cleanup")
        
        Task { @MainActor in
            // Clean up cached info
            deviceInfoCache.removeValue(forKey: peerID)
            lastDeviceInfoUpdate.removeValue(forKey: peerID)
            
            // Deselect if this was the selected device
            if selectedRemoteDevice?.peerID == peerID {
                print("DEBUG: Selected device was lost, clearing selection")
                selectedRemoteDevice = nil
            }
            
            // Update the enhanced device info display
            updateDiscoveredDevices()
            print("DEBUG: macOS - Cleaned up device info for \(peerID.displayName)")
        }
    }
    
    private func parseDiscoveryInfo(_ info: [String: String], for peerID: MCPeerID) -> MLXDeviceInfo {
        let platform = DeviceCapabilities.DevicePlatform(rawValue: info["device"] ?? "iOS") ?? .iOS
        let modelsString = info["models"] ?? ""
        
        print("DEBUG: Parsing discovery info for \(peerID.displayName)")
        print("DEBUG: Raw models string: '\(modelsString)'")
        
        // Split by commas and trim whitespace from each model
        let availableModels = modelsString.isEmpty ? [] : modelsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        
        print("DEBUG: Parsed available models: \(availableModels)")
        
        let capabilities = DeviceCapabilities(
            supportsStreaming: true,
            maxConcurrentRequests: 1,
            preferredModels: availableModels,
            platform: platform
        )
        
        let deviceInfo = MLXDeviceInfo(
            deviceName: peerID.displayName,
            availableModels: availableModels,
            capabilities: capabilities
        )
        
        print("DEBUG: Created device info for \(peerID.displayName) with \(availableModels.count) models")
        return deviceInfo
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