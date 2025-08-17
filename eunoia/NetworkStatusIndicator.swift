import SwiftUI
import MultipeerConnectivity

struct NetworkStatusIndicator: View {
    @ObservedObject var chatManager: ChatManager
    @State private var isExpanded = false
    
    var body: some View {
        HStack(spacing: 8) {
            networkStatusIcon
            
            if isExpanded {
                networkStatusText
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(statusBackgroundColor)
                .stroke(statusBorderColor, lineWidth: 1)
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.3)) {
                isExpanded.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isExpanded)
    }
    
    private var networkStatusIcon: some View {
        Group {
            if chatManager.isUsingRemoteInference {
                if let device = chatManager.selectedRemoteDevice, device.isConnected {
                    // Connected to remote device
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundColor(.green)
                } else {
                    // Remote inference enabled but not connected
                    Image(systemName: "iphone.slash")
                        .foregroundColor(.orange)
                }
            } else {
                #if os(iOS)
                // iOS device - show inference server status
                if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager {
                    if iosManager.isInferenceServerEnabled {
                        if iosManager.connectedPeers.isEmpty {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.green)
                        }
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.gray)
                    }
                } else {
                    Image(systemName: "cpu")
                        .foregroundColor(.gray)
                }
                #elseif os(macOS)
                // macOS device - show discovery status
                if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager {
                    if macManager.isDiscoveryEnabled {
                        if macManager.discoveredDevices.isEmpty {
                            Image(systemName: "wifi")
                                .foregroundColor(.orange)
                        } else {
                            Image(systemName: "wifi")
                                .foregroundColor(.green)
                        }
                    } else {
                        Image(systemName: "wifi.slash")
                            .foregroundColor(.gray)
                    }
                } else {
                    Image(systemName: "cpu")
                        .foregroundColor(.gray)
                }
                #else
                Image(systemName: "cpu")
                    .foregroundColor(.gray)
                #endif
            }
        }
        .font(.system(size: 14, weight: .medium))
    }
    
    private var networkStatusText: some View {
        Text(statusMessage)
            .font(.system(.caption, design: .default, weight: .medium))
            .foregroundColor(statusTextColor)
            .lineLimit(1)
    }
    
    private var statusMessage: String {
        if chatManager.isUsingRemoteInference {
            if let device = chatManager.selectedRemoteDevice {
                return device.isConnected ? "Connected to \(device.name)" : "Connecting to \(device.name)"
            } else {
                return "No remote device"
            }
        } else {
            #if os(iOS)
            if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager {
                if iosManager.isInferenceServerEnabled {
                    let connectedCount = iosManager.connectedPeers.count
                    return connectedCount == 0 ? "Sharing available" : "\(connectedCount) device\(connectedCount == 1 ? "" : "s") connected"
                } else {
                    return "Local inference only"
                }
            } else {
                return "Local inference"
            }
            #elseif os(macOS)
            if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager {
                if macManager.isDiscoveryEnabled {
                    let deviceCount = macManager.discoveredDevices.count
                    return deviceCount == 0 ? "Looking for devices" : "\(deviceCount) device\(deviceCount == 1 ? "" : "s") found"
                } else {
                    return "Local inference only"
                }
            } else {
                return "Local inference"
            }
            #else
            return "Local inference"
            #endif
        }
    }
    
    private var statusBackgroundColor: Color {
        if chatManager.isUsingRemoteInference {
            if let device = chatManager.selectedRemoteDevice, device.isConnected {
                return Color.green.opacity(0.1)
            } else {
                return Color.orange.opacity(0.1)
            }
        } else {
            #if os(iOS)
            if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager,
               iosManager.isInferenceServerEnabled {
                return iosManager.connectedPeers.isEmpty ? Color.blue.opacity(0.1) : Color.green.opacity(0.1)
            }
            #elseif os(macOS)
            if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager,
               macManager.isDiscoveryEnabled {
                return macManager.discoveredDevices.isEmpty ? Color.orange.opacity(0.1) : Color.green.opacity(0.1)
            }
            #endif
            return Color.gray.opacity(0.1)
        }
    }
    
    private var statusBorderColor: Color {
        if chatManager.isUsingRemoteInference {
            if let device = chatManager.selectedRemoteDevice, device.isConnected {
                return Color.green.opacity(0.3)
            } else {
                return Color.orange.opacity(0.3)
            }
        } else {
            #if os(iOS)
            if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager,
               iosManager.isInferenceServerEnabled {
                return iosManager.connectedPeers.isEmpty ? Color.blue.opacity(0.3) : Color.green.opacity(0.3)
            }
            #elseif os(macOS)
            if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager,
               macManager.isDiscoveryEnabled {
                return macManager.discoveredDevices.isEmpty ? Color.orange.opacity(0.3) : Color.green.opacity(0.3)
            }
            #endif
            return Color.gray.opacity(0.3)
        }
    }
    
    private var statusTextColor: Color {
        if chatManager.isUsingRemoteInference {
            if let device = chatManager.selectedRemoteDevice, device.isConnected {
                return Color.green
            } else {
                return Color.orange
            }
        } else {
            #if os(iOS)
            if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager,
               iosManager.isInferenceServerEnabled {
                return iosManager.connectedPeers.isEmpty ? Color.blue : Color.green
            }
            #elseif os(macOS)
            if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager,
               macManager.isDiscoveryEnabled {
                return macManager.discoveredDevices.isEmpty ? Color.orange : Color.green
            }
            #endif
            return Color.gray
        }
    }
}

// Compact version for tight spaces
struct CompactNetworkStatusIndicator: View {
    @ObservedObject var chatManager: ChatManager
    
    var body: some View {
        Group {
            if chatManager.isUsingRemoteInference {
                if let device = chatManager.selectedRemoteDevice, device.isConnected {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "iphone.slash")
                        .foregroundColor(.orange)
                }
            } else {
                #if os(iOS)
                if let iosManager = chatManager.getNetworkManager() as? iOSMLXNetworkManager,
                   iosManager.isInferenceServerEnabled {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundColor(iosManager.connectedPeers.isEmpty ? .blue : .green)
                } else {
                    Image(systemName: "cpu")
                        .foregroundColor(.gray)
                }
                #elseif os(macOS)
                if let macManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager,
                   macManager.isDiscoveryEnabled {
                    Image(systemName: "wifi")
                        .foregroundColor(macManager.discoveredDevices.isEmpty ? .orange : .green)
                } else {
                    Image(systemName: "cpu")
                        .foregroundColor(.gray)
                }
                #else
                Image(systemName: "cpu")
                    .foregroundColor(.gray)
                #endif
            }
        }
        .font(.system(size: 12, weight: .medium))
    }
}

#Preview {
    VStack(spacing: 20) {
        NetworkStatusIndicator(chatManager: ChatManager())
        CompactNetworkStatusIndicator(chatManager: ChatManager())
    }
    .padding()
}