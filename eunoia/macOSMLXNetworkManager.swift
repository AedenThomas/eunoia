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
        
        messageHandlers[.inferenceResponseChunk] = { [weak self] message, peer in
            if case .inferenceResponseChunk(let chunk) = message {
                print("DEBUG: Received inference response chunk \(chunk.chunkIndex + 1)/\(chunk.totalChunks) for request ID: \(chunk.requestId)")
                // Processing handled by MultipeerManager.handleInferenceResponseChunk
            }
        }
        
        messageHandlers[.responseAck] = { [weak self] message, peer in
            if case .responseAck(let ack) = message {
                print("DEBUG: Received response acknowledgment for request ID: \(ack.requestId), messageId: \(ack.messageId)")
                // Processing handled by MultipeerManager.handleResponseAcknowledgment
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
    func performRemoteInference(request: MLXInferenceRequest) async throws -> String {
        print("DEBUG: performRemoteInference(request:) called with request ID: \(request.id.uuidString)")
        return try await performRemoteInferenceInternal(request: request)
    }
        
    func performRemoteInference(
        prompt: String,
        modelIdentifier: String,
        parameters: InferenceParameters = InferenceParameters()
    ) async throws -> String {
        let request = MLXInferenceRequest(
            prompt: prompt,
            modelIdentifier: modelIdentifier,
            parameters: parameters
        )
        print("DEBUG: performRemoteInference(prompt:...) called, created request ID: \(request.id.uuidString)")
        return try await performRemoteInferenceInternal(request: request)
    }
    
    private func performRemoteInferenceInternal(request: MLXInferenceRequest) async throws -> String {
        
        print("DEBUG: macOSMLXNetworkManager.performRemoteInferenceInternal called")
        print("DEBUG: Prompt length: \(request.prompt.count), Model: \(request.modelIdentifier)")
        
        guard let selectedDevice = selectedRemoteDevice else {
            print("DEBUG: ERROR - No remote device selected")
            throw MLXNetworkError(code: .networkError, message: "No remote device selected")
        }
        
        print("DEBUG: Selected remote device: \(selectedDevice.name), connected: \(selectedDevice.isConnected)")
        print("DEBUG: Current connectedPeers: \(connectedPeers.map { $0.displayName })")
        
        // Make sure device is in connectedPeers list (more reliable than the isConnected flag)
        let isActuallyConnected = connectedPeers.contains(selectedDevice.peerID)
        
        guard isActuallyConnected else {
            print("DEBUG: ERROR - Remote device not in connected peers list")
            throw MLXNetworkError(code: .networkError, message: "Remote device not connected")
        }
        
        guard selectedDevice.availableModels.contains(request.modelIdentifier) else {
            print("DEBUG: ERROR - Model \(request.modelIdentifier) not available on remote device")
            print("DEBUG: Available models: \(selectedDevice.availableModels)")
            throw MLXNetworkError(code: .modelNotFound, message: "Model not available on remote device")
        }
        
        print("macOSMLXNetworkManager: Sending inference request to \(selectedDevice.name)")
        print("  - Model: \(request.modelIdentifier)")
        print("  - Prompt length: \(request.prompt.count) characters")
        print("  - Request ID: \(request.id)")
        print("  - Using consistent ID tracking for robust response handling")
        
        // BUGFIX: Create an actor to synchronize access to the completion status
        actor CompletionStatus {
            var isCompleted = false
            var hasReceivedResponse = false
            
            func markCompleted() {
                isCompleted = true
            }
            
            func markResponseReceived() {
                hasReceivedResponse = true
            }
            
            func isCompletedOrHasResponse() -> Bool {
                return isCompleted || hasReceivedResponse
            }
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            print("DEBUG: Creating pending request in continuation")
            
            // BUGFIX: Create a shared completion status
            let completionStatus = CompletionStatus()
            
            // BUGFIX: Set up a notification observer for responses
            let notificationName = Notification.Name("MLXInferenceResponseReceived-\(request.id.uuidString)")
            NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: .main) { [weak self] notification in
                guard let self = self else { return }
                
                Task {
                    // Mark that we've received a response
                    await completionStatus.markResponseReceived()
                    
                    if let responseContent = notification.userInfo?["content"] as? String {
                        print("DEBUG: BUGFIX: Received response notification for request \(request.id)")
                        
                        // Remove the pending request and complete the continuation
                        if let _ = self.pendingInferenceRequests.removeValue(forKey: request.id) {
                            print("DEBUG: BUGFIX: Processing response from notification")
                            await completionStatus.markCompleted()
                            continuation.resume(returning: responseContent)
                        }
                    }
                }
            }
            
            let pendingRequest = PendingRequest(
                request: request,
                startTime: Date(),
                completion: { result in
                    print("DEBUG: BUGFIX: Pending request completion handler called for request \(request.id)")
                    
                    Task {
                        // Check if we're already completed from the notification
                        if await completionStatus.isCompletedOrHasResponse() {
                            print("DEBUG: BUGFIX: Request already handled by notification, ignoring completion")
                            return
                        }
                        
                        // Mark as completed to prevent double-completion
                        await completionStatus.markCompleted()
                        
                        // Handle the result
                        switch result {
                        case .success(let response):
                            print("DEBUG: Request \(request.id) succeeded with response length: \(response.content.count)")
                            
                            // Post notification to ensure all ChatManagers update their state
                            NotificationCenter.default.post(
                                name: Notification.Name("MLXInferenceCompleted"),
                                object: nil,
                                userInfo: ["requestId": request.id, "content": response.content]
                            )
                            
                            continuation.resume(returning: response.content)
                            
                        case .failure(let error):
                            print("DEBUG: Request \(request.id) failed with error: \(error.message)")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            )
            
            print("DEBUG: Adding request \(request.id) to pendingInferenceRequests")
            print("DEBUG: Current pendingInferenceRequests count: \(self.pendingInferenceRequests.count)")
            self.pendingInferenceRequests[request.id] = pendingRequest
            print("DEBUG: Updated pendingInferenceRequests count: \(self.pendingInferenceRequests.count)")
            
            // Set up timeout - use the increased timeout from MLXServiceInfo
            print("DEBUG: Setting up timeout of \(MLXServiceInfo.inferenceTimeout) seconds for request ID: \(request.id)")
            
            // Setup timeout task with BUGFIX: Check completion status before timing out
            DispatchQueue.main.asyncAfter(deadline: .now() + MLXServiceInfo.inferenceTimeout) { [weak self] in
                guard let self = self else { return }
                
                Task {
                    // BUGFIX: Don't time out if we've already completed or received a response
                    if await completionStatus.isCompletedOrHasResponse() {
                        print("DEBUG: BUGFIX: Request \(request.id.uuidString) already completed or has response, skipping timeout")
                        return
                    }
                    
                    print("DEBUG: Timeout check for request ID: \(request.id.uuidString)")
                    
                    if let pendingRequest = self.pendingInferenceRequests[request.id] {
                        print("DEBUG: Request \(request.id.uuidString) timed out after \(MLXServiceInfo.inferenceTimeout) seconds")
                        
                        // Before timing out, let's see if the device is still connected
                        let isPeerStillConnected = self.connectedPeers.contains(selectedDevice.peerID)
                        print("DEBUG: Connection status before timeout: \(isPeerStillConnected ? "connected" : "disconnected")")
                        
                        if isPeerStillConnected {
                            // Device is still connected, but request timed out
                            print("DEBUG: Device is still connected, but the request timed out")
                            print("DEBUG: This could indicate the remote device is processing but taking too long")
                            
                            // Try sending a ping to verify connection is still responsive
                            self.sendMessage(.ping, to: selectedDevice.peerID)
                            
                            // BUGFIX: Wait a bit longer (10 more seconds) in case the response is almost ready
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
                                guard let self = self else { return }
                                
                                Task {
                                    // Double-check if we've completed or received a response during the extra wait time
                                    if await completionStatus.isCompletedOrHasResponse() {
                                        print("DEBUG: BUGFIX: Request \(request.id.uuidString) completed during extended timeout, skipping timeout")
                                        return
                                    }
                                    
                                    if let pending = self.pendingInferenceRequests.removeValue(forKey: request.id) {
                                        await completionStatus.markCompleted()
                                        let error = MLXNetworkError(
                                            code: .inferenceTimeout,
                                            message: "Remote inference request timed out",
                                            requestId: request.id
                                        )
                                        pending.completion(.failure(error))
                                    }
                                }
                            }
                        } else {
                            // Device is disconnected, fail immediately
                            if let pending = self.pendingInferenceRequests.removeValue(forKey: request.id) {
                                await completionStatus.markCompleted()
                                let error = MLXNetworkError(
                                    code: .networkError,
                                    message: "Remote device disconnected during inference",
                                    requestId: request.id
                                )
                                pending.completion(.failure(error))
                            }
                        }
                    } else {
                        print("DEBUG: Request \(request.id.uuidString) already completed before timeout")
                    }
                }
            }
            
            // Check if we're still connected before sending
            if self.connectedPeers.contains(selectedDevice.peerID) {
                // Send the request
                print("DEBUG: Sending inference request to \(selectedDevice.name)")
                self.sendMessage(.inferenceRequest(request), to: selectedDevice.peerID)
                
                // Double-check connection after sending
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self = self else { return }
                    if !self.connectedPeers.contains(selectedDevice.peerID) {
                        print("DEBUG: WARNING - Device disconnected immediately after sending request!")
                    } else {
                        print("DEBUG: Connection still active after sending request")
                    }
                }
            } else {
                print("DEBUG: ERROR - Device disconnected between checks!")
                
                Task {
                    await completionStatus.markCompleted()
                    let error = MLXNetworkError(
                        code: .networkError,
                        message: "Remote device disconnected",
                        requestId: request.id
                    )
                    self.pendingInferenceRequests.removeValue(forKey: request.id)
                    continuation.resume(throwing: error)
                }
                
                // Try to reconnect
                print("DEBUG: Attempting to reconnect to \(selectedDevice.name)...")
                self.connectToPeer(selectedDevice.peerID)
            }
        }
    }
    
    private func handleInferenceResponse(_ response: MLXInferenceResponse, from peer: MCPeerID) {
        print("DEBUG: macOSMLXNetworkManager.handleInferenceResponse for request: \(response.requestId)")
        print("DEBUG: Response from peer: \(peer.displayName)")
        print("DEBUG: Current pendingInferenceRequests count: \(pendingInferenceRequests.count)")
        print("DEBUG: Request IDs in pendingInferenceRequests: \(pendingInferenceRequests.keys.map { $0.uuidString })")
        print("DEBUG: Looking for request ID: \(response.requestId.uuidString)")
        print("DEBUG: Response message ID: \(response.messageId), chunk count: \(response.chunkCount)")
        
        // Enhanced debugging to help identify request ID mismatches
        print("DEBUG: Response message contents: \"\(response.content.prefix(50))...\"")
        print("DEBUG: Looking for request ID: \(response.requestId.uuidString) in pendingInferenceRequests")
        print("DEBUG: Also checking MultipeerManager.pendingRequests")
        
        // BUGFIX: Always immediately broadcast the response through the notification system
        // This is crucial - we need to notify about the response as early as possible
        print("DEBUG: BUGFIX: IMMEDIATE BROADCAST - Sending response notification for request \(response.requestId)")
        NotificationCenter.default.post(
            name: Notification.Name("MLXInferenceResponseReceived-\(response.requestId.uuidString)"),
            object: nil,
            userInfo: ["content": response.content]
        )
        
        // Also post the general notification for all ChatManagers to update their state
        print("DEBUG: BUGFIX: IMMEDIATE BROADCAST - Sending general inference completion notification")
        NotificationCenter.default.post(
            name: Notification.Name("MLXInferenceCompleted"),
            object: nil,
            userInfo: ["requestId": response.requestId, "content": response.content]
        )
        
        // First, check both request trackers for a match
        let pendingRequest = pendingInferenceRequests[response.requestId] 
        let hasPendingManagerRequest = pendingRequests[response.requestId] != nil
        
        // Handle the case where no direct match is found
        if pendingRequest == nil && !hasPendingManagerRequest {
            print("DEBUG: WARNING - Received response for unknown request: \(response.requestId.uuidString)")
            print("DEBUG: This could indicate the request timed out just before the response arrived")
            print("DEBUG: Or there's a request ID mismatch between the systems")
            print("DEBUG: Dumping all pending request IDs for debugging:")
            print("DEBUG: pendingInferenceRequests IDs: \(pendingInferenceRequests.keys.map { $0.uuidString })")
            print("DEBUG: MultipeerManager.pendingRequests IDs: \(pendingRequests.keys.map { $0.uuidString })")
            
            // Check if this is the ONLY pending request, which would indicate a likely match
            if pendingInferenceRequests.count == 1 {
                print("DEBUG: Found exactly ONE pending request - assuming it's a match despite ID mismatch")
                let singleRequest = pendingInferenceRequests.first!
                print("DEBUG: Using request ID: \(singleRequest.key.uuidString) as fallback match")
                
                // Complete the pending request with the successful response
                print("DEBUG: Calling completion handler with successful response from pendingInferenceRequests")
                pendingInferenceRequests.removeValue(forKey: singleRequest.key)
                singleRequest.value.completion(.success(response))
                return
            }
            
            // Check if this request exists in MultipeerManager pendingRequests
            print("DEBUG: Checking if request exists in MultipeerManager's pendingRequests")
            if let handler = pendingRequests[response.requestId] {
                print("DEBUG: Found request in MultipeerManager's pendingRequests, using that instead")
                pendingRequests.removeValue(forKey: response.requestId)
                handler(response)
                return
            }
            
            // If there are any pending requests at all, use the first one as a last resort
            if !pendingInferenceRequests.isEmpty {
                print("DEBUG: No exact match found but there are pending requests")
                print("DEBUG: Using the oldest pending request as a fallback")
                let oldestRequest = pendingInferenceRequests.sorted { $0.value.startTime < $1.value.startTime }.first!
                print("DEBUG: Using request ID: \(oldestRequest.key.uuidString) as fallback match")
                
                // Complete the pending request with the successful response
                print("DEBUG: Calling completion handler with successful response (oldest fallback)")
                pendingInferenceRequests.removeValue(forKey: oldestRequest.key)
                oldestRequest.value.completion(.success(response))
                return
            }
            
            print("DEBUG: BUGFIX: No handler found, but notifications were already sent")
            return
        }
        
        // Handle the case where we found a direct match in pendingInferenceRequests
        if let directRequest = pendingRequest {
            let inferenceTime = Date().timeIntervalSince(directRequest.startTime)
            print("macOSMLXNetworkManager: Received inference response in \(String(format: "%.2f", inferenceTime))s")
            print("DEBUG: Response content length: \(response.content.count)")
            print("DEBUG: Response content: \"\(response.content)\"")
            print("DEBUG: Response inferenceTime reported by device: \(String(describing: response.inferenceTime))")
            
            // Send acknowledgment for the response
            let ack = ResponseAcknowledgment(
                requestId: response.requestId,
                messageId: response.messageId,
                isComplete: true
            )
            sendMessage(.responseAck(ack), to: peer)
            
            // Complete the pending request with the successful response
            print("DEBUG: Calling completion handler with successful response (direct match)")
            // First save the completion handler, then remove from pending requests
            let completion = directRequest.completion
            pendingInferenceRequests.removeValue(forKey: response.requestId)
            
            // Actually call the completion handler AFTER removing from pending requests
            print("DEBUG: Actually executing completion handler now")
            completion(.success(response))
        }
    }
    
    private func handleNetworkError(_ error: MLXNetworkError, from peer: MCPeerID) {
        if let requestId = error.requestId {
            if let pendingRequest = pendingInferenceRequests.removeValue(forKey: requestId) {
                print("macOSMLXNetworkManager: Received error for request \(requestId): \(error.message)")
                pendingRequest.completion(.failure(error))
            } else {
                print("macOSMLXNetworkManager: Received error for unknown request \(requestId): \(error.message)")
            }
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
    public func updateDeviceConnectionStatus(_ peerID: MCPeerID, isConnected: Bool) {
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