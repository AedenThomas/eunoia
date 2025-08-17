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
    
    // MARK: - Private Properties
    private var deviceInfoCache: [MCPeerID: MLXDeviceInfo] = [:]
    private var lastDeviceInfoUpdate: [MCPeerID: Date] = [:]
    private let deviceInfoCacheTimeout: TimeInterval = 300 // 5 minutes
    private var notificationObservers: [UUID: [NSObjectProtocol]] = [:] // Observer storage

    // REMOVED: PendingRequest struct and pendingInferenceRequests dictionary
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupInferenceHandlers()
        print("macOSMLXNetworkManager: Initialized for macOS device")
    }
    
    deinit {
        // Clean up any remaining observers
        for (_, observers) in notificationObservers {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
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
    
    // MARK: - Discovery Control (No changes here)
    func startDeviceDiscovery() {
        guard !isDiscoveryEnabled else { return }
        startBrowsing()
        isDiscoveryEnabled = true
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
    
    // MARK: - Device Management (No changes here)
    func selectRemoteDevice(_ device: RemoteMLXDevice) {
        selectedRemoteDevice = device
        if !connectedPeers.contains(device.peerID) {
            connectToPeer(device.peerID)
        } else {
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
        
        for peerID in availableDevices {
            if seenDeviceNames.contains(peerID.displayName) { continue }
            seenDeviceNames.insert(peerID.displayName)
            
            let device: RemoteMLXDevice
            if let deviceInfo = deviceInfoCache[peerID] {
                device = RemoteMLXDevice(
                    peerID: peerID, name: deviceInfo.deviceName, availableModels: deviceInfo.availableModels,
                    capabilities: deviceInfo.deviceCapabilities, isConnected: connectedPeers.contains(peerID), lastSeen: Date()
                )
            } else {
                device = RemoteMLXDevice(
                    peerID: peerID, name: peerID.displayName, availableModels: [],
                    capabilities: DeviceCapabilities.current, isConnected: connectedPeers.contains(peerID), lastSeen: Date()
                )
                requestDeviceInfo(from: peerID)
            }
            updatedDevices.append(device)
        }
        
        if let selected = selectedRemoteDevice, !updatedDevices.contains(where: { $0.peerID == selected.peerID }) {
            if connectedPeers.contains(selected.peerID) || Date().timeIntervalSince(selected.lastSeen) < 30 {
                updatedDevices.append(selected)
            }
        }
        
        if Set(discoveredDevices.map { $0.id }) != Set(updatedDevices.map { $0.id }) {
            discoveredDevices = updatedDevices
        }
    }
    
    private func requestDeviceInfo(from peerID: MCPeerID) {
        if let lastUpdate = lastDeviceInfoUpdate[peerID], Date().timeIntervalSince(lastUpdate) < 30 { return }
        sendMessage(.ping, to: peerID)
        lastDeviceInfoUpdate[peerID] = Date()
    }
    
    // MARK: - Remote Inference
    func performRemoteInference(request: MLXInferenceRequest) async throws -> String {
        return try await performRemoteInferenceInternal(request: request)
    }
        
    func performRemoteInference(prompt: String, modelIdentifier: String, parameters: InferenceParameters = InferenceParameters()) async throws -> String {
        let request = MLXInferenceRequest(prompt: prompt, modelIdentifier: modelIdentifier, parameters: parameters)
        return try await performRemoteInferenceInternal(request: request)
    }
    
    private func performRemoteInferenceInternal(request: MLXInferenceRequest) async throws -> String {
        guard let selectedDevice = selectedRemoteDevice else {
            throw MLXNetworkError(code: .networkError, message: "No remote device selected")
        }
        guard connectedPeers.contains(selectedDevice.peerID) else {
            throw MLXNetworkError(code: .networkError, message: "Remote device not connected")
        }
        guard selectedDevice.availableModels.contains(request.modelIdentifier) else {
            throw MLXNetworkError(code: .modelNotFound, message: "Model not available on remote device")
        }
        
        print("macOSMLXNetworkManager: Sending inference request to \(selectedDevice.name) with ID \(request.id)")
        
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = request.id
            
            actor ContinuationManager {
                var isResumed = false
                func resume(with result: Result<String, Error>, using continuation: CheckedContinuation<String, Error>) {
                    if !isResumed {
                        isResumed = true
                        continuation.resume(with: result)
                    }
                }
            }
            let manager = ContinuationManager()

            // Define cleanup logic
            let cleanup = {
                if let observers = self.notificationObservers.removeValue(forKey: requestId) {
                    for observer in observers {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
            }
            
            // Success observer
            let successName = Notification.Name("MLXInferenceResponseReceived-\(requestId.uuidString)")
            let successObserver = NotificationCenter.default.addObserver(forName: successName, object: nil, queue: .main) { notification in
                if let content = notification.userInfo?["content"] as? String {
                    print("DEBUG: Received response from NOTIFICATION for request \(requestId)")
                    Task { await manager.resume(with: .success(content), using: continuation) }
                    cleanup()
                }
            }

            // Error observer
            let errorName = Notification.Name("MLXInferenceErrorReceived-\(requestId.uuidString)")
            let errorObserver = NotificationCenter.default.addObserver(forName: errorName, object: nil, queue: .main) { notification in
                if let error = notification.userInfo?["error"] as? MLXNetworkError {
                    print("DEBUG: Received error from NOTIFICATION for request \(requestId)")
                    Task { await manager.resume(with: .failure(error), using: continuation) }
                    cleanup()
                }
            }
            
            self.notificationObservers[requestId] = [successObserver, errorObserver]

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + MLXServiceInfo.inferenceTimeout) {
                let timeoutError = MLXNetworkError(code: .inferenceTimeout, message: "Request timed out", requestId: requestId)
                Task { await manager.resume(with: .failure(timeoutError), using: continuation) }
                cleanup()
            }
            
            // Send the request
            self.sendMessage(.inferenceRequest(request), to: selectedDevice.peerID)
        }
    }
    
    private func handleInferenceResponse(_ response: MLXInferenceResponse, from peer: MCPeerID) {
        print("DEBUG: macOSMLXNetworkManager.handleInferenceResponse for request: \(response.requestId)")
        
        // The only job of this method is to post a notification.
        // The async/await machinery will handle the rest.
        let notificationName = Notification.Name("MLXInferenceResponseReceived-\(response.requestId.uuidString)")
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: ["content": response.content]
        )
    }
    
    private func handleNetworkError(_ error: MLXNetworkError, from peer: MCPeerID) {
        print("macOSMLXNetworkManager: Received error from \(peer.displayName): \(error.message)")
        
        if let requestId = error.requestId {
            // Post a notification for the specific request that failed.
            let notificationName = Notification.Name("MLXInferenceErrorReceived-\(requestId.uuidString)")
            NotificationCenter.default.post(
                name: notificationName,
                object: nil,
                userInfo: ["error": error]
            )
        } else {
            // Handle general errors if necessary
            lastError = error.message
        }
    }

    // MARK: - Device Status and Connection Handling (No changes here)
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
    
    public func updateDeviceConnectionStatus(_ peerID: MCPeerID, isConnected: Bool) {
        for (index, device) in discoveredDevices.enumerated() {
            if device.peerID == peerID {
                discoveredDevices[index] = RemoteMLXDevice(
                    peerID: device.peerID, name: device.name, availableModels: device.availableModels,
                    capabilities: device.capabilities, isConnected: isConnected, lastSeen: Date()
                )
                if selectedRemoteDevice?.peerID == peerID {
                    selectedRemoteDevice = discoveredDevices[index]
                }
                break
            }
        }
    }
    
    @objc @MainActor
    override func handlePeerConnectionStateChange(_ peerID: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected: updateDeviceConnectionStatus(peerID, isConnected: true)
        case .notConnected: updateDeviceConnectionStatus(peerID, isConnected: false)
        default: break
        }
    }
    
    // MARK: - Browser Delegate and Discovery (No changes here)
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        super.browser(browser, foundPeer: peerID, withDiscoveryInfo: info)
        guard let info = info, info["capability"] == "mlx", !info["models", default: ""].isEmpty else { return }
        
        Task { @MainActor in
            let deviceInfo = parseDiscoveryInfo(info, for: peerID)
            deviceInfoCache[peerID] = deviceInfo
            if !availableDevices.contains(peerID) {
                availableDevices.append(peerID)
            }
            updateDiscoveredDevices()
        }
    }
    
    nonisolated override func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        super.browser(browser, lostPeer: peerID)
        Task { @MainActor in
            deviceInfoCache.removeValue(forKey: peerID)
            lastDeviceInfoUpdate.removeValue(forKey: peerID)
            if selectedRemoteDevice?.peerID == peerID {
                selectedRemoteDevice = nil
            }
            updateDiscoveredDevices()
        }
    }
    
    private func parseDiscoveryInfo(_ info: [String: String], for peerID: MCPeerID) -> MLXDeviceInfo {
        let platform = DeviceCapabilities.DevicePlatform(rawValue: info["device"] ?? "iOS") ?? .iOS
        let modelsString = info["models"] ?? ""
        let availableModels = modelsString.isEmpty ? [] : modelsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let capabilities = DeviceCapabilities(
            supportsStreaming: true, maxConcurrentRequests: 1, preferredModels: availableModels, platform: platform
        )
        return MLXDeviceInfo(
            deviceName: peerID.displayName, availableModels: availableModels, capabilities: capabilities
        )
    }
    
    // MARK: - Connection Cleanup
    override func disconnectAll() {
        // Errors will be handled by timeouts for any pending requests
        selectedRemoteDevice = nil
        super.disconnectAll()
    }
}

#endif
