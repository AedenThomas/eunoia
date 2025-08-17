import SwiftUI

struct ModelDownloadInterface: View {
    @ObservedObject var downloadManager: ModelDownloadManager
    let onBack: () -> Void
    let onModelDownloaded: () -> Void
    var chatManager: ChatManager? = nil
    
    private let models = ModelRegistry.availableModels
    
    var essentialModels: [MLXModel] {
        [
            models.first { $0.identifier.contains("SmolLM-135M") }!,
            models.first { $0.identifier.contains("gemma-3-1b-it-qat-4bit") }!,
            models.first { $0.identifier.contains("gemma-3-270m") }!,
            models.first { $0.identifier.contains("Phi-3.5-mini") }!
        ]
    }
    
    var specializedModels: [MLXModel] {
        [
            models.first { $0.identifier.contains("Llama-3.2-3B") }!,
            models.first { $0.identifier.contains("Mistral-7B") }!,
            models.first { $0.identifier.contains("CodeLlama-7b") }!,
            models.first { $0.identifier.contains("Qwen2.5-7B") }!
        ]
    }
    
    var experimentalModels: [MLXModel] {
        [
            models.first { $0.identifier.contains("gemma-2-9b") }!
        ]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            
            ScrollView {
                VStack(spacing: 32) {
                    modelSection(title: "Essential Models", models: essentialModels)
                    modelSection(title: "Specialized Models", models: specializedModels)
                    modelSection(title: "Experimental Models", models: experimentalModels)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .background(Color(.controlBackgroundColor))
    }
    
    private var header: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color.primary)
                    Text("Cancel")
                        .font(.system(.body, design: .default, weight: .regular))
                        .foregroundColor(Color.primary)
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text("Download Models")
                .font(.system(.title2, design: .default, weight: .medium))
                .foregroundColor(Color.primary)
            
            Spacer()
            
            // Invisible spacer to center the title
            HStack(spacing: 8) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                Text("Cancel")
                    .font(.system(.body, design: .default, weight: .regular))
            }
            .opacity(0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    private func modelSection(title: String, models: [MLXModel]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(.headline, design: .default, weight: .medium))
                .foregroundColor(Color.primary)
            
            LazyVStack(spacing: 12) {
                ForEach(models) { model in
                    ModelCard(model: model, downloadManager: downloadManager, onDownloaded: onModelDownloaded, chatManager: chatManager)
                }
            }
        }
    }
}

struct ModelCard: View {
    let model: MLXModel
    @ObservedObject var downloadManager: ModelDownloadManager
    let onDownloaded: () -> Void
    var chatManager: ChatManager? = nil
    @State private var showingDeleteConfirmation = false
    
    private var downloadState: ModelDownloadManager.DownloadState {
        downloadManager.getDownloadState(for: model)
    }
    
    private var downloadProgress: Double {
        downloadManager.getDownloadProgress(for: model)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundColor(Color.primary)
                    .lineLimit(1)
                
                Text(model.description)
                    .font(.system(.subheadline, design: .default, weight: .regular))
                    .foregroundColor(Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                HStack {
                    Text(model.size)
                        .font(.system(.caption, design: .default, weight: .regular))
                        .foregroundColor(Color.gray)
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    actionButton
                    
                    if downloadState == .completed {
                        Button(action: {
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 14))
                                .foregroundColor(.red.opacity(0.7))
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if downloadState == .downloading && downloadProgress > 0 {
                    VStack(spacing: 4) {
                        Text("\(Int(downloadProgress * 100))%")
                            .font(.system(.caption2, design: .default, weight: .medium))
                            .foregroundColor(Color.secondary)
                        
                        ProgressView(value: downloadProgress)
                            .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: 0x007AFF)))
                            .frame(width: 80)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: Color.primary.opacity(0.03), radius: 1, x: 0, y: 1)
        .onChange(of: downloadState) { _, newState in
            if newState == .completed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Automatically select the newly downloaded model
                    if let chatManager = chatManager {
                        Task {
                            await chatManager.selectModel(model)
                        }
                    }
                    onDownloaded()
                }
            }
        }
        .alert("Delete Model", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                downloadManager.deleteModel(model)
            }
        } message: {
            Text("Are you sure you want to delete \(model.name)? This action cannot be undone.")
        }
    }
    
    @ViewBuilder
    private var actionButton: some View {
        Button(action: handleAction) {
            Text(buttonText)
                .font(.system(.subheadline, design: .default, weight: .medium))
                .foregroundColor(buttonTextColor)
                .frame(minWidth: 96)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(buttonBackgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(downloadState == .downloading && downloadProgress == 0)
    }
    
    private var buttonText: String {
        switch downloadState {
        case .notDownloaded:
            return "Download"
        case .downloading:
            return downloadProgress > 0 ? "Cancel" : "Download"
        case .paused:
            return "Resume"
        case .completed:
            return "Downloaded"
        case .failed:
            return "Retry"
        }
    }
    
    private var buttonTextColor: Color {
        switch downloadState {
        case .completed:
            return .black
        default:
            return .white
        }
    }
    
    private var buttonBackgroundColor: Color {
        switch downloadState {
        case .notDownloaded, .paused, .failed:
            return Color(hex: 0x007AFF)
        case .downloading:
            return .orange
        case .completed:
            return Color.gray.opacity(0.3)
        }
    }
    
    private func handleAction() {
        switch downloadState {
        case .notDownloaded:
            downloadManager.startDownload(for: model)
        case .downloading:
            downloadManager.cancelDownload(for: model)
        case .paused:
            downloadManager.resumeDownload(for: model)
        case .completed:
            break // Delete is handled by separate trash button
        case .failed:
            downloadManager.startDownload(for: model)
        }
    }
}
