import SwiftUI

struct ModelListView: View {
    @ObservedObject private var downloadManager = ModelDownloadManager.shared
    private let models = ModelRegistry.availableModels
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(models) { model in
                        ModelRowView(model: model, downloadManager: downloadManager)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(.regularMaterial.opacity(0.1))
            .navigationTitle("Models")
#if os(iOS)
            .navigationBarTitleDisplayMode(.large)
#endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reset") {
                        downloadManager.resetAllStates()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }
}