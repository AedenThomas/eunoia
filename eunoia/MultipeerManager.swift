import Foundation
import MultipeerConnectivity
import SwiftUI
#if os(iOS)
import Network
#endif

@MainActor
class MultipeerManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var connectedPeers: [MCPeerID] = []
    @Published var availableDevices: [MCPeerID] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastError: String?
    
    // MARK: - Core Multipeer Components
    private let serviceType = MLXServiceInfo.serviceType
    private let myPeerID: MCPeerID
    private let session: MCSession
    
    // MARK: - Platform-specific components (will be overridden in subclasses)
    private var serviceBrowser: MCNearbyServiceBrowser?
    private var serviceAdvertiser: MCNearbyServiceAdvertiser?
    
    // MARK: - Message Handling
    private var pendingRequests: [UUID: (MLXInferenceResponse) -> Void] = [:]
    internal var messageHandlers: [MLXNetworkMessage.MessageType: (MLXNetworkMessage, MCPeerID) -> Void] = [:]
    
    enum ConnectionStatus {
        case disconnected
        case discovering
        case advertising
        case connecting
        case connected
    }
    
    // MARK: - Initialization
    override init() {
        #if os(iOS)
        self.myPeerID = MCPeerID(displayName: UIDevice.current.name + " (iOS)")
        #elseif os(macOS)
        self.myPeerID = MCPeerID(displayName: (Host.current().localizedName ?? "Mac") + " (macOS)")
        #else
        self.myPeerID = MCPeerID(displayName: "Eunoia Device")
        #endif
        
        self.session = MCSession(
            peer: myPeerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        
        super.init()
        
        session.delegate = self
        setupMessageHandlers()
    }
    
    deinit {
        // Clean up synchronously without calling MainActor methods
        serviceBrowser?.stopBrowsingForPeers()
        serviceBrowser = nil
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceAdvertiser = nil
        session.disconnect()
    }
    
    // Override point for subclasses to handle connection state changes
    @objc @MainActor
    func handlePeerConnectionStateChange(_ peerID: MCPeerID, state: MCSessionState) {
        // Default implementation does nothing
    }
    
    // MARK: - Message Handler Setup
    private func setupMessageHandlers() {
        messageHandlers[.ping] = { [weak self] _, peer in
            self?.sendMessage(.pong, to: peer)
        }
        
        messageHandlers[.pong] = { _, _ in
            // Handle pong response if needed
        }
    }
    
    // MARK: - Public Methods
    func startBrowsing() {
        print("DEBUG: MultipeerManager.startBrowsing() called")
        print("DEBUG: serviceBrowser current state: \(serviceBrowser == nil ? "nil" : "exists")")
        
        guard serviceBrowser == nil else {
            print("DEBUG: startBrowsing() - already browsing, returning early")
            return
        }
        
        // Service type must already be in format: _servicename._tcp
        
        print("DEBUG: Creating MCNearbyServiceBrowser with:")
        print("DEBUG:   - peer: \(myPeerID.displayName)")
        print("DEBUG:   - serviceType: \(serviceType)")
        
        serviceBrowser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        
        print("DEBUG: Setting browser delegate...")
        serviceBrowser?.delegate = self
        
        print("DEBUG: Calling startBrowsingForPeers()...")
        serviceBrowser?.startBrowsingForPeers()
        
        connectionStatus = .discovering
        print("MultipeerManager: Started browsing for MLX inference devices")
        print("DEBUG: connectionStatus set to: \(connectionStatus)")
    }
    
    func stopBrowsing() {
        serviceBrowser?.stopBrowsingForPeers()
        serviceBrowser = nil
        
        if connectionStatus == .discovering {
            connectionStatus = .disconnected
        }
        print("MultipeerManager: Stopped browsing")
    }
    
    func startAdvertising(with deviceInfo: MLXDeviceInfo) {
        print("DEBUG: MultipeerManager.startAdvertising() called")
        print("DEBUG: serviceAdvertiser current state: \(serviceAdvertiser == nil ? "nil" : "exists")")
        
        guard serviceAdvertiser == nil else {
            print("DEBUG: startAdvertising() - already advertising, returning early")
            return
        }
        
        let discoveryInfo = [
            "device": deviceInfo.deviceCapabilities.platform.rawValue,
            "capability": "mlx",
            "models": deviceInfo.availableModels.joined(separator: ",")
        ]
        
        // Service type must already be in format: _servicename._tcp
        
        print("DEBUG: Creating MCNearbyServiceAdvertiser with:")
        print("DEBUG:   - peer: \(myPeerID.displayName)")
        print("DEBUG:   - serviceType: \(serviceType)")
        print("DEBUG:   - discoveryInfo: \(discoveryInfo)")
        
        serviceAdvertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: discoveryInfo,
            serviceType: serviceType
        )
        
        print("DEBUG: Setting advertiser delegate...")
        serviceAdvertiser?.delegate = self
        
        print("DEBUG: Calling startAdvertisingPeer()...")
        serviceAdvertiser?.startAdvertisingPeer()
        
        connectionStatus = .advertising
        print("MultipeerManager: Started advertising MLX inference capability")
        print("DEBUG: connectionStatus set to: \(connectionStatus)")
    }
    
    func stopAdvertising() {
        serviceAdvertiser?.stopAdvertisingPeer()
        serviceAdvertiser = nil
        
        if connectionStatus == .advertising {
            connectionStatus = .disconnected
        }
        print("MultipeerManager: Stopped advertising")
    }
    
    func stopAll() {
        stopBrowsing()
        stopAdvertising()
        disconnectAll()
    }
    
    func connectToPeer(_ peerID: MCPeerID) {
        guard let browser = serviceBrowser else { return }
        
        connectionStatus = .connecting
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: MLXServiceInfo.connectionTimeout)
        print("MultipeerManager: Inviting peer: \(peerID.displayName)")
    }
    
    func disconnectFromPeer(_ peerID: MCPeerID) {
        session.cancelConnectPeer(peerID)
        print("MultipeerManager: Disconnected from peer: \(peerID.displayName)")
    }
    
    func disconnectAll() {
        session.disconnect()
        connectedPeers.removeAll()
        availableDevices.removeAll()
        connectionStatus = .disconnected
        print("MultipeerManager: Disconnected from all peers")
    }
    
    // MARK: - Message Handling
    func sendMessage(_ message: MLXNetworkMessage, to peer: MCPeerID) {
        do {
            let data = try message.toData()
            try session.send(data, toPeers: [peer], with: .reliable)
            print("MultipeerManager: Sent message to \(peer.displayName)")
        } catch {
            lastError = "Failed to send message: \(error.localizedDescription)"
            print("MultipeerManager: Error sending message: \(error)")
        }
    }
    
    func sendMessageToAllPeers(_ message: MLXNetworkMessage) {
        guard !connectedPeers.isEmpty else { return }
        
        do {
            let data = try message.toData()
            try session.send(data, toPeers: connectedPeers, with: .reliable)
            print("MultipeerManager: Sent message to all connected peers")
        } catch {
            lastError = "Failed to broadcast message: \(error.localizedDescription)"
            print("MultipeerManager: Error broadcasting message: \(error)")
        }
    }
    
    private func handleReceivedMessage(_ message: MLXNetworkMessage, from peer: MCPeerID) {
        let messageType = message.messageType
        
        if let handler = messageHandlers[messageType] {
            handler(message, peer)
        } else {
            print("MultipeerManager: No handler for message type: \(messageType)")
        }
    }
    
    // MARK: - Request/Response Pattern
    func sendInferenceRequest(_ request: MLXInferenceRequest, to peer: MCPeerID, completion: @escaping (Result<MLXInferenceResponse, MLXNetworkError>) -> Void) {
        
        // Store the completion handler
        pendingRequests[request.id] = { response in
            completion(.success(response))
        }
        
        // Set up timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + MLXServiceInfo.inferenceTimeout) { [weak self] in
            if self?.pendingRequests.removeValue(forKey: request.id) != nil {
                let timeoutError = MLXNetworkError(
                    code: .inferenceTimeout,
                    message: "Inference request timed out",
                    requestId: request.id
                )
                completion(.failure(timeoutError))
            }
        }
        
        // Send the request
        sendMessage(.inferenceRequest(request), to: peer)
    }
    
    private func handleInferenceResponse(_ response: MLXInferenceResponse) {
        if let handler = pendingRequests.removeValue(forKey: response.requestId) {
            handler(response)
        }
    }
}

// MARK: - MCSessionDelegate
extension MultipeerManager: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            switch state {
            case .connected:
                if !connectedPeers.contains(peerID) {
                    connectedPeers.append(peerID)
                }
                connectionStatus = .connected
                print("MultipeerManager: Connected to \(peerID.displayName)")
                
                // Additional processing for subclasses in MainActor context
                handlePeerConnectionStateChange(peerID, state: state)
                
            case .connecting:
                connectionStatus = .connecting
                print("MultipeerManager: Connecting to \(peerID.displayName)")
                
                // Additional processing for subclasses in MainActor context
                handlePeerConnectionStateChange(peerID, state: state)
                
            case .notConnected:
                connectedPeers.removeAll { $0 == peerID }
                if connectedPeers.isEmpty {
                    connectionStatus = .disconnected
                }
                print("MultipeerManager: Disconnected from \(peerID.displayName)")
                
                // Additional processing for subclasses in MainActor context
                handlePeerConnectionStateChange(peerID, state: state)
                
            @unknown default:
                print("MultipeerManager: Unknown connection state")
            }
        }
    }
    
    
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        do {
            let message = try MLXNetworkMessage.fromData(data)
            
            Task { @MainActor in
                // Handle inference responses specially
                if case .inferenceResponse(let response) = message {
                    handleInferenceResponse(response)
                } else {
                    handleReceivedMessage(message, from: peerID)
                }
            }
        } catch {
            Task { @MainActor in
                lastError = "Failed to decode message: \(error.localizedDescription)"
                print("MultipeerManager: Error decoding message: \(error)")
            }
        }
    }
    
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Not used in this implementation
    }
    
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Not used in this implementation
    }
    
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        // Not used in this implementation
    }
}

// MARK: - MCNearbyServiceBrowserDelegate
extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    // Dictionary to track unique peers across all browser instances
    // Using peerID.displayName as the key to ensure uniqueness
    private static var discoveredPeers = [String: Date]()
    
    // Minimum time to consider a re-discovery of the same device
    private static let rediscoveryThreshold: TimeInterval = 10.0 // 10 seconds
    
    @objc nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("DEBUG: BROWSER DELEGATE - foundPeer: \(peerID.displayName)")
        print("DEBUG: Discovery info: \(info ?? [:])")
        
        // Check if we have valid discovery info before proceeding
        guard let info = info, 
              info["capability"] == "mlx",
              !info["models", default: ""].isEmpty else {
            print("DEBUG: Skipping peer with invalid discovery info")
            return
        }
        
        // For all browser events, use a single synchronized block to modify availableDevices
        Task { @MainActor in
            // Get current time for discovery tracking
            let now = Date()
            let deviceName = peerID.displayName
            
            // Create a unique identifier combining name and discovery info hash
            // This helps distinguish between devices with the same name but different info
            let infoHash = info.hashValue
            let uniqueKey = "\(deviceName)-\(infoHash)"
            
            // Check if we've already discovered this peer recently
            if let lastDiscovery = Self.discoveredPeers[uniqueKey] {
                let timeSinceLastDiscovery = now.timeIntervalSince(lastDiscovery)
                
                // Only process if enough time has passed since the last discovery
                if timeSinceLastDiscovery < Self.rediscoveryThreshold {
                    print("DEBUG: Ignoring duplicate discovery of \(deviceName) (last seen \(Int(timeSinceLastDiscovery))s ago)")
                    return
                }
                
                print("DEBUG: Re-processing peer \(deviceName) after \(Int(timeSinceLastDiscovery))s")
            }
            
            // Update the last discovery time for this peer with its unique key
            Self.discoveredPeers[uniqueKey] = now
            
            // Always add to available devices to ensure it's included in child class processing
            if !availableDevices.contains(peerID) {
                availableDevices.append(peerID)
                print("MultipeerManager: Found peer: \(deviceName)")
            } else {
                print("DEBUG: Peer \(deviceName) already in availableDevices")
            }
        }
    }
    
    @objc nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("DEBUG: BROWSER DELEGATE - lostPeer: \(peerID.displayName)")
        
        Task { @MainActor in
            // Remove from discovery tracking to allow rediscovery if it comes back
            // We need to remove all entries that start with this device name
            let deviceName = peerID.displayName
            
            // Remove all entries for this device, regardless of info hash
            Self.discoveredPeers = Self.discoveredPeers.filter { key, _ in
                !key.starts(with: "\(deviceName)-")
            }
            
            // Remove from available devices list
            availableDevices.removeAll { $0 == peerID }
            print("MultipeerManager: Lost peer: \(peerID.displayName)")
        }
    }
    
    @objc nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("DEBUG: BROWSER DELEGATE - didNotStartBrowsingForPeers error: \(error)")
        print("DEBUG: Error details: \(error.localizedDescription)")
        
        Task { @MainActor in
            lastError = "Failed to start browsing: \(error.localizedDescription)"
            connectionStatus = .disconnected
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate
extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    @objc nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("DEBUG: ADVERTISER DELEGATE - didReceiveInvitationFromPeer: \(peerID.displayName)")
        
        Task { @MainActor in
            // For now, automatically accept all invitations
            // In a production app, you might want to show a user confirmation dialog
            print("DEBUG: Accepting invitation from \(peerID.displayName)")
            invitationHandler(true, session)
            print("MultipeerManager: Accepted invitation from \(peerID.displayName)")
        }
    }
    
    @objc nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("DEBUG: ADVERTISER DELEGATE - didNotStartAdvertisingPeer error: \(error)")
        print("DEBUG: Error details: \(error.localizedDescription)")
        print("DEBUG: Service type being used: '\(serviceType)'")
        
        if let nsError = error as NSError? {
            print("DEBUG: Error domain: \(nsError.domain)")
            print("DEBUG: Error code: \(nsError.code)")
            print("DEBUG: User info: \(nsError.userInfo)")
            
            if nsError.domain == NetService.errorDomain {
                print("DEBUG: NSNetServicesErrorDomain error code: \(nsError.code)")
                
                // Add detailed error diagnostics
                switch nsError.code {
                case -72000:
                    print("DEBUG: Error -72000: Unknown error")
                case -72001:
                    print("DEBUG: Error -72001: Processing error (invalid data)")
                case -72002:
                    print("DEBUG: Error -72002: Service unavailable")
                case -72003:
                    print("DEBUG: Error -72003: User declined permission")
                case -72004:
                    print("DEBUG: Error -72004: Invalid argument")
                case -72005:
                    print("DEBUG: Error -72005: Name conflict")
                case -72006:
                    print("DEBUG: Error -72006: Not found")
                case -72007:
                    print("DEBUG: Error -72007: Collision")
                case -72008:
                    print("DEBUG: Error -72008: Service type must be 1-15 chars of lowercase letters, numbers, or hyphens only, with NO underscores")
                    print("DEBUG: For unregistered types, use 'local-' prefix (e.g., 'local-myservice')")
                    print("DEBUG: Make sure NSBonjourServices is correctly configured in Info.plist with _local-mlxai._tcp")
                case -72009:
                    print("DEBUG: Error -72009: Bad argument")
                case -72010:
                    print("DEBUG: Error -72010: Network error")
                case -72011:
                    print("DEBUG: Error -72011: Out of memory")
                default:
                    print("DEBUG: Unrecognized NSNetServicesErrorDomain error code: \(nsError.code)")
                }
            }
        }
        
        Task { @MainActor in
            lastError = "Failed to start advertising: \(error.localizedDescription)"
            connectionStatus = .disconnected
        }
    }
}

// MARK: - Message Type Extension
extension MLXNetworkMessage {
    enum MessageType {
        case ping, pong, inferenceRequest, inferenceResponse, error
    }
    
    var messageType: MessageType {
        switch self {
        case .ping: return .ping
        case .pong: return .pong
        case .inferenceRequest: return .inferenceRequest
        case .inferenceResponse: return .inferenceResponse
        case .error: return .error
        }
    }
}