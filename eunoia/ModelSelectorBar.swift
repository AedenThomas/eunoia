import SwiftUI
import MultipeerConnectivity
#if os(macOS)
import AppKit
#endif

struct ModelSelectorBar: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @ObservedObject private var downloadModalManager = DownloadModalManager.shared
    @State private var showingModelDropdown = false
    @State private var isHovered = false
    @State private var expandedDevicePeerID: MCPeerID? = nil
    
    private let models = ModelRegistry.availableModels
    
    // Add a public method to show the download modal
    func showDownloadModal() {
        print("DEBUG: ModelSelectorBar.showDownloadModal() called")
        downloadModalManager.openDownloadModal()
    }
    
    var downloadedModels: [MLXModel] {
        models.filter { downloadManager.getDownloadState(for: $0) == .completed }
    }
    
    var hasDownloadedModels: Bool {
        !downloadedModels.isEmpty
    }
    
    var availableRemoteDevices: [RemoteMLXDevice] {
        let devices = chatManager.getAvailableRemoteDevices()
        print("DEBUG: ModelSelectorBar - Available remote devices: \(devices.count)")
        for device in devices {
            print("DEBUG: → Available device: \(device.name), Models: \(device.availableModels.joined(separator: ", ")), Connected: \(device.isConnected)")
        }
        return devices
    }
    
    var hasAvailableOptions: Bool {
        hasDownloadedModels || !availableRemoteDevices.isEmpty
    }

    private func prettify(identifier: String) -> String {
        if let model = ModelRegistry.availableModels.first(where: { $0.identifier == identifier }) {
            return model.name
        }
        return identifier.split(separator: "/").last?.replacingOccurrences(of: "-", with: " ").capitalized ?? identifier
    }
    
    var body: some View {
        VStack(spacing: 0) {
            selectorBar
            
            if showingModelDropdown && hasAvailableOptions {
                modelDropdown
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: showingModelDropdown)
        .sheet(isPresented: $downloadModalManager.showDownloadModal) {
            ModelDownloadModal(
                downloadManager: downloadManager, 
                isPresented: $downloadModalManager.showDownloadModal, 
                chatManager: chatManager
            )
        }
        .onAppear {
            if chatManager.getNetworkManager() == nil {
                chatManager.initializeNetworking()
            }
        }
    }
    
    private var selectorBar: some View {
        Group {
            if hasAvailableOptions {
                // Show dropdown for local models and remote devices
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if chatManager.isUsingRemoteInference {
                            if let remoteDevice = chatManager.selectedRemoteDevice {
                                HStack(spacing: 4) {
                                    Image(systemName: "iphone.and.arrow.forward")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color(hex: 0x007AFF))
                                    Text(remoteDevice.name)
                                        .font(.system(.body, design: .default, weight: .medium))
                                        .foregroundColor(Color.primary)
                                }
                                if let modelId = chatManager.selectedRemoteModelIdentifier {
                                    Text("Using: \(prettify(identifier: modelId))")
                                        .font(.system(.caption, design: .default, weight: .regular))
                                        .foregroundColor(Color.secondary)
                                }
                            } else {
                                Text("Remote device connecting...")
                                    .font(.system(.subheadline, design: .default, weight: .regular))
                                    .foregroundColor(Color.orange)
                            }
                        } else if let selectedModel = chatManager.selectedModel {
                            HStack(spacing: 4) {
                                Image(systemName: "cpu")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.gray)
                                Text(selectedModel.name)
                                    .font(.system(.body, design: .default, weight: .medium))
                                    .foregroundColor(Color.primary)
                            }
                        } else {
                            Text("Select a model or device")
                                .font(.system(.subheadline, design: .default, weight: .regular))
                                .foregroundColor(Color.gray)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.primary)
                        .rotationEffect(.degrees(showingModelDropdown ? 180 : 0))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showingModelDropdown.toggle()
                    }
                }
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.2)) {
                        isHovered = hovering
                    }
                }
            } else {
                // Show setup options when no models or devices are available
                Button(action: {
                    print("DEBUG: Download models button clicked in ModelSelectorBar")
                    print("DEBUG: Opening download modal via downloadModalManager.openDownloadModal()")
                    // Initialize networking first
                    chatManager.initializeNetworking()
                    chatManager.startNetworkServices()
                    
                    // Important: Introduce slight delay before showing modal
                    // This ensures the view update cycle completes first
                    DispatchQueue.main.async {
                        downloadModalManager.openDownloadModal()
                        print("DEBUG: downloadModalManager.showDownloadModal is now: \(downloadModalManager.showDownloadModal)")
                    }
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            #if os(macOS)
                            Text("Download models or find devices")
                                .font(.system(.subheadline, design: .default, weight: .regular))
                                .foregroundColor(Color(hex: 0x007AFF))
                            #else
                            Text("Download models to get started")
                                .font(.system(.subheadline, design: .default, weight: .regular))
                                .foregroundColor(Color(hex: 0x007AFF))
                            #endif
                        }
                        
                        Spacer()
                        
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(hex: 0x007AFF))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var modelDropdown: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1)
            
            VStack(spacing: 8) {
                // Local Models Section
                if hasDownloadedModels {
                    HStack {
                        Text("Local Models")
                            .font(.system(.caption, design: .default, weight: .semibold))
                            .foregroundColor(Color.secondary)
                            .textCase(.uppercase)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    
                    ForEach(downloadedModels) { model in
                        ModelDropdownRow(
                            model: model,
                            isSelected: !chatManager.isUsingRemoteInference && chatManager.selectedModel?.id == model.id,
                            action: {
                                Task {
                                    // Disable remote inference and select local model
                                    chatManager.enableRemoteInference(nil)
                                    await chatManager.selectModel(model)
                                    await MainActor.run {
                                        withAnimation(.easeOut(duration: 0.3)) {
                                            showingModelDropdown = false
                                        }
                                    }
                                }
                            },
                            downloadManager: downloadManager
                        )
                    }
                }
                
                // Remote Devices Section
                #if os(macOS)
                if !availableRemoteDevices.isEmpty {
                    if hasDownloadedModels {
                        Divider()
                            .padding(.vertical, 4)
                    }
                    
                    HStack {
                        Text("Remote Devices")
                            .font(.system(.caption, design: .default, weight: .semibold))
                            .foregroundColor(Color.secondary)
                            .textCase(.uppercase)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    
                    ForEach(availableRemoteDevices) { device in
                        RemoteDeviceRow(
                            device: device,
                            chatManager: chatManager,
                            isExpanded: expandedDevicePeerID == device.peerID,
                            onExpand: {
                                if expandedDevicePeerID == device.peerID {
                                    expandedDevicePeerID = nil
                                } else {
                                    expandedDevicePeerID = device.peerID
                                }
                            },
                            onSelectModel: { modelIdentifier in
                                // First select the device in the network manager to establish connection
                                if let networkManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager {
                                    print("DEBUG: Starting remote device selection process with model: \(modelIdentifier)")
                                    
                                    // Clear any existing selected model first
                                    chatManager.selectedModel = nil
                                    
                                    // This will connect to the device if not already connected
                                    networkManager.selectRemoteDevice(device)
                                    
                                    // Wait for connection to establish before enabling remote inference
                                    // Using 5.0 seconds to ensure connection is stable
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                                        print("DEBUG: Connection delay completed, verifying connection...")
                                        
                                        // First verify the device is still connected
                                        if networkManager.connectedPeers.contains(device.peerID) {
                                            print("DEBUG: Connection verified, enabling remote inference with model: \(modelIdentifier)")
                                            
                                            // Update the device to reflect it's actually connected
                                            networkManager.updateDeviceConnectionStatus(device.peerID, isConnected: true)
                                            
                                            // Get the updated device from the manager
                                            if let updatedDevice = networkManager.discoveredDevices.first(where: { $0.peerID == device.peerID }) {
                                                // Then call enableRemoteInference which will properly update all related state
                                                chatManager.enableRemoteInference(updatedDevice, modelIdentifier: modelIdentifier)
                                            } else {
                                                print("DEBUG: ERROR - Updated device not found after connection!")
                                                chatManager.enableRemoteInference(nil)
                                            }
                                        } else {
                                            print("DEBUG: ERROR - Device connection failed, not enabling remote inference")
                                            
                                            // Update UI to reflect failure
                                            chatManager.enableRemoteInference(nil)
                                            chatManager.selectedModel = nil
                                        }
                                    }
                                }
                                
                                withAnimation {
                                    showingModelDropdown = false
                                    expandedDevicePeerID = nil
                                }
                            },
                            prettify: prettify
                        )
                    }
                }
                #endif
                
                // Action Buttons
                Divider()
                    .padding(.vertical, 4)
                
                Button(action: {
                    print("DEBUG: Download More Models button clicked inside dropdown")
                    // First call openDownloadModal
                    downloadModalManager.openDownloadModal()
                    print("DEBUG: After openDownloadModal(), showDownloadModal = \(downloadModalManager.showDownloadModal)")
                    
                    // Then close the dropdown with a slight delay to ensure modal shows first
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showingModelDropdown = false
                            print("DEBUG: Dropdown closed, showingModelDropdown = \(showingModelDropdown)")
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14))
                        Text("Download More Models...")
                            .font(.system(.body, design: .default, weight: .regular))
                        Spacer()
                    }
                    .foregroundColor(Color(hex: 0x007AFF))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                
                #if os(macOS)
                Button(action: {
                    // Toggle device discovery
                    if let networkManager = chatManager.getNetworkManager() as? macOSMLXNetworkManager {
                        if networkManager.isDiscoveryEnabled {
                            networkManager.stopDeviceDiscovery()
                        } else {
                            networkManager.startDeviceDiscovery()
                        }
                    }
                    withAnimation(.easeOut(duration: 0.3)) {
                        showingModelDropdown = false
                    }
                }) {
                    HStack {
                        let isDiscovering = (chatManager.getNetworkManager() as? macOSMLXNetworkManager)?.isDiscoveryEnabled ?? false
                        Image(systemName: isDiscovering ? "wifi.slash" : "wifi")
                            .font(.system(size: 14))
                        Text(isDiscovering ? "Stop Device Discovery" : "Find Remote Devices")
                            .font(.system(.body, design: .default, weight: .regular))
                        Spacer()
                    }
                    .foregroundColor(Color(hex: 0x007AFF))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                #endif
            }
            .padding(.vertical, 8)
            #if os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
            #else
            .background(Color(.systemBackground))
            #endif
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.primary.opacity(0.1), radius: 8, x: 0, y: 4)
        }
        .padding(.horizontal, 20)
    }
}

struct ModelDropdownRow: View {
    let model: MLXModel
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject var downloadManager: ModelDownloadManager
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: action) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? Color(hex: 0x007AFF) : Color.gray)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(.system(.body, design: .default, weight: .medium))
                            .foregroundColor(Color.primary)
                        
                        Text(model.description)
                            .font(.system(.caption, design: .default, weight: .regular))
                            .foregroundColor(Color.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    Text(model.size)
                        .font(.system(.caption, design: .default, weight: .regular))
                        .foregroundColor(Color.gray)
                }
            }
            .buttonStyle(.plain)
            
            Button(action: {
                showingDeleteConfirmation = true
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .alert("Delete Model", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    downloadManager.deleteModel(model)
                }
            } message: {
                Text("Are you sure you want to delete \(model.name)? This action cannot be undone.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ModelDownloadModal: View {
    @ObservedObject var downloadManager: ModelDownloadManager
    @Binding var isPresented: Bool
    var chatManager: ChatManager
    
    var body: some View {
        VStack(spacing: 0) {
            ModelDownloadInterface(
                downloadManager: downloadManager,
                onBack: {
                    isPresented = false
                },
                onModelDownloaded: {
                    // Auto-dismiss modal when model is downloaded so user can see the loading screen
                    isPresented = false
                },
                chatManager: chatManager
            )
        }
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        #endif
    }
}

struct RemoteDeviceRow: View {
    let device: RemoteMLXDevice
    @ObservedObject var chatManager: ChatManager
    let isExpanded: Bool
    let onExpand: () -> Void
    let onSelectModel: (String) -> Void
    let prettify: (String) -> String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    Image(systemName: device.statusIcon)
                        .font(.system(size: 14))
                        .foregroundColor(device.isConnected ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(.body, design: .default, weight: .medium))
                            .foregroundColor(Color.primary)
                        
                        Text("\(device.availableModels.count) models available")
                            .font(.system(.caption, design: .default, weight: .regular))
                            .foregroundColor(Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            if isExpanded {
                ForEach(device.availableModels, id: \.self) { modelIdentifier in
                    RemoteModelRow(
                        modelIdentifier: modelIdentifier,
                        prettifiedName: prettify(modelIdentifier),
                        isSelected: chatManager.isUsingRemoteInference &&
                                    chatManager.selectedRemoteDevice?.peerID == device.peerID &&
                                    chatManager.selectedRemoteModelIdentifier == modelIdentifier,
                        action: { onSelectModel(modelIdentifier) }
                    )
                }
            }
        }
    }
}

struct RemoteModelRow: View {
    let modelIdentifier: String
    let prettifiedName: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? Color(hex: 0x007AFF) : Color.gray)
                
                Text(prettifiedName)
                    .font(.system(.body, design: .default, weight: .regular))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .padding(.leading, 24) // Indent for hierarchy
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}