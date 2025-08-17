import Foundation
import MultipeerConnectivity

// MARK: - MLX Inference Communication Models

enum MLXNetworkMessage: Codable {
    case inferenceRequest(MLXInferenceRequest)
    case inferenceResponse(MLXInferenceResponse)
    case error(MLXNetworkError)
    case ping
    case pong
}

struct MLXInferenceRequest: Codable {
    let id: UUID
    let prompt: String
    let modelIdentifier: String
    let parameters: InferenceParameters
    let timestamp: Date
    
    init(prompt: String, modelIdentifier: String, parameters: InferenceParameters = InferenceParameters()) {
        self.id = UUID()
        self.prompt = prompt
        self.modelIdentifier = modelIdentifier
        self.parameters = parameters
        self.timestamp = Date()
    }
}

struct MLXInferenceResponse: Codable {
    let requestId: UUID
    let content: String
    let isComplete: Bool
    let isStreaming: Bool
    let timestamp: Date
    let inferenceTime: TimeInterval?
    
    init(requestId: UUID, content: String, isComplete: Bool = true, isStreaming: Bool = false, inferenceTime: TimeInterval? = nil) {
        self.requestId = requestId
        self.content = content
        self.isComplete = isComplete
        self.isStreaming = isStreaming
        self.timestamp = Date()
        self.inferenceTime = inferenceTime
    }
}

struct InferenceParameters: Codable {
    let maxTokens: Int
    let temperature: Double
    let topP: Double
    let useModelSpecificFormatting: Bool
    
    init(maxTokens: Int = 512, temperature: Double = 0.7, topP: Double = 0.9, useModelSpecificFormatting: Bool = true) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.useModelSpecificFormatting = useModelSpecificFormatting
    }
}

struct MLXNetworkError: Codable, Error {
    let code: ErrorCode
    let message: String
    let requestId: UUID?
    let timestamp: Date
    
    enum ErrorCode: String, Codable {
        case modelNotLoaded
        case modelNotFound
        case inferenceTimeout
        case networkError
        case invalidRequest
        case deviceBusy
        case unknownError
    }
    
    init(code: ErrorCode, message: String, requestId: UUID? = nil) {
        self.code = code
        self.message = message
        self.requestId = requestId
        self.timestamp = Date()
    }
}

// MARK: - Device Information Models

struct MLXDeviceInfo: Codable {
    let deviceId: String
    let deviceName: String
    let availableModels: [String]
    let deviceCapabilities: DeviceCapabilities
    let isAvailable: Bool
    let lastSeen: Date
    
    init(deviceName: String, availableModels: [String], capabilities: DeviceCapabilities) {
        self.deviceId = UUID().uuidString
        self.deviceName = deviceName
        self.availableModels = availableModels
        self.deviceCapabilities = capabilities
        self.isAvailable = true
        self.lastSeen = Date()
    }
}

struct DeviceCapabilities: Codable {
    let supportsStreaming: Bool
    let maxConcurrentRequests: Int
    let preferredModels: [String]
    let platform: DevicePlatform
    
    enum DevicePlatform: String, Codable {
        case iOS
        case macOS
        case iPadOS
        case visionOS
    }
    
    #if os(iOS)
    static let current = DeviceCapabilities(
        supportsStreaming: true,
        maxConcurrentRequests: 1,
        preferredModels: [],
        platform: .iOS
    )
    #elseif os(macOS)
    static let current = DeviceCapabilities(
        supportsStreaming: true,
        maxConcurrentRequests: 1,
        preferredModels: [],
        platform: .macOS
    )
    #endif
}

// MARK: - Remote Device Models

struct RemoteMLXDevice: Identifiable, Equatable {
    let id = UUID()
    let peerID: MCPeerID
    let name: String
    let availableModels: [String]
    let capabilities: DeviceCapabilities
    let isConnected: Bool
    let lastSeen: Date
    
    static func == (lhs: RemoteMLXDevice, rhs: RemoteMLXDevice) -> Bool {
        return lhs.peerID == rhs.peerID
    }
    
    var displayName: String {
        let status = isConnected ? "Connected" : "Available"
        let modelCount = availableModels.count
        return "\(name) (\(status), \(modelCount) models)"
    }
    
    var statusIcon: String {
        return isConnected ? "iphone.and.arrow.forward" : "iphone"
    }
}

// MARK: - Network Service Discovery

struct MLXServiceInfo {
    // Use proper Bonjour service type format (no leading underscore in MCNearbyServiceAdvertiser)
    // Must be 1-15 chars of lowercase letters, numbers, or hyphens only
    static let serviceType = "mlx-ai-local"
    static let discoveryTimeout: TimeInterval = 30.0
    static let connectionTimeout: TimeInterval = 15.0
    static let inferenceTimeout: TimeInterval = 60.0
}

// MARK: - Message Serialization Helpers

extension MLXNetworkMessage {
    func toData() throws -> Data {
        return try JSONEncoder().encode(self)
    }
    
    static func fromData(_ data: Data) throws -> MLXNetworkMessage {
        return try JSONDecoder().decode(MLXNetworkMessage.self, from: data)
    }
}
