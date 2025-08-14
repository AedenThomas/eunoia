import SwiftUI

struct ModelRowView: View {
    let model: MLXModel
    @ObservedObject var downloadManager: ModelDownloadManager
    
    private var downloadState: ModelDownloadManager.DownloadState {
        downloadManager.getDownloadState(for: model)
    }
    
    private var downloadProgress: Double {
        downloadManager.getDownloadProgress(for: model)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(model.name)
                            .font(.headline)
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        Text(model.size)
                            .font(.subheadline)
                            .fontWeight(.regular)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text(model.description)
                        .font(.subheadline)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                
                actionButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            if downloadState == .downloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(LinearProgressViewStyle())
                    .tint(Color.accentColor)
                    .scaleEffect(y: 0.5)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .opacity(downloadProgress > 0 ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: downloadProgress)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator.opacity(0.3), lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    
    @ViewBuilder
    private var actionButton: some View {
        Button(action: handleAction) {
            Image(systemName: buttonImageName)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundStyle(buttonColor)
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(.regularMaterial)
                        .overlay {
                            Circle()
                                .strokeBorder(.separator.opacity(0.2), lineWidth: 0.5)
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(downloadState == .downloading && downloadProgress == 0)
        .scaleEffect(downloadState == .downloading ? 1.05 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: downloadState)
    }
    
    private var buttonImageName: String {
        switch downloadState {
        case .notDownloaded:
            return "arrow.down.circle"
        case .downloading:
            return downloadProgress > 0 ? "stop.circle" : "arrow.down.circle"
        case .paused:
            return "play.circle"
        case .completed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle"
        }
    }
    
    private var buttonColor: Color {
        switch downloadState {
        case .notDownloaded:
            return Color.accentColor
        case .downloading:
            return .orange
        case .paused:
            return Color.accentColor
        case .completed:
            return .green
        case .failed:
            return .red
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
            downloadManager.deleteModel(model)
        case .failed:
            downloadManager.startDownload(for: model)
        }
    }
}