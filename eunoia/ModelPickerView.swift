import SwiftUI

struct ModelPickerView: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var downloadManager: ModelDownloadManager
    @Environment(\.dismiss) private var dismiss
    
    private let models = ModelRegistry.availableModels
    
    var downloadedModels: [MLXModel] {
        let filtered = models.filter { downloadManager.getDownloadState(for: $0) == .completed }
        print("ModelPickerView - Total models: \(models.count), Downloaded: \(filtered.count)")
        print("ModelPickerView - Downloaded model names: \(filtered.map { $0.name })")
        return filtered
    }
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if downloadedModels.isEmpty {
                    emptyStateView
                } else {
                    modelsList
                }
            }
            .padding(.horizontal, 16)
            .navigationTitle("Select Model")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
#else
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
#endif
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 12) {
                Text("No Models Downloaded")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Text("Download a model from the Models tab to start chatting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
    }
    
    private var modelsList: some View {
        VStack(spacing: 12) {
            ForEach(downloadedModels) { model in
                ModelPickerRow(
                    model: model,
                    isSelected: chatManager.selectedModel?.id == model.id
                ) {
                    Task {
                        await chatManager.selectModel(model)
                        await MainActor.run {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct ModelPickerRow: View {
    let model: MLXModel
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    
                    Text(model.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.green.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: isSelected ? 1.5 : 0.5)
                    }
            }
        }
        .buttonStyle(.plain)
    }
}