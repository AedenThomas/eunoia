import SwiftUI

struct ModelSelectorBar: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @State private var showingModelDropdown = false
    @State private var showingDownloadModal = false
    @State private var isHovered = false
    
    private let models = ModelRegistry.availableModels
    
    var downloadedModels: [MLXModel] {
        models.filter { downloadManager.getDownloadState(for: $0) == .completed }
    }
    
    var hasDownloadedModels: Bool {
        !downloadedModels.isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            selectorBar
            
            if showingModelDropdown && hasDownloadedModels {
                modelDropdown
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.3), value: showingModelDropdown)
        .sheet(isPresented: $showingDownloadModal) {
            ModelDownloadModal(downloadManager: downloadManager, isPresented: $showingDownloadModal)
        }
    }
    
    private var selectorBar: some View {
        Group {
            if hasDownloadedModels {
                // Show dropdown for downloaded models
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let selectedModel = chatManager.selectedModel {
                            Text(selectedModel.name)
                                .font(.system(.body, design: .default, weight: .medium))
                                .foregroundColor(Color.primary)
                        } else {
                            Text("Select a model")
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
                // Show download modal when no models are available
                Button(action: {
                    showingDownloadModal = true
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download models to get started")
                                .font(.system(.subheadline, design: .default, weight: .regular))
                                .foregroundColor(Color(hex: 0x007AFF))
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
                ForEach(downloadedModels) { model in
                    ModelDropdownRow(
                        model: model,
                        isSelected: chatManager.selectedModel?.id == model.id,
                        action: {
                            Task {
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
                
                Button(action: {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showingModelDropdown = false
                    }
                    showingDownloadModal = true
                }) {
                    HStack {
                        Text("Download More Models...")
                            .font(.system(.body, design: .default, weight: .regular))
                            .foregroundColor(Color(hex: 0x007AFF))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))
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
    
    var body: some View {
        VStack(spacing: 0) {
            ModelDownloadInterface(
                downloadManager: downloadManager,
                onBack: {
                    isPresented = false
                },
                onModelDownloaded: {
                    // Don't auto-dismiss when model is downloaded, let user stay and download more
                }
            )
        }
        .background(Color(.controlBackgroundColor))
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        #endif
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