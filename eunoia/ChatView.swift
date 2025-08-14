import SwiftUI

struct ChatView: View {
    @State private var messageText = ""
    @StateObject private var chatManager = ChatManager()
    @ObservedObject private var downloadManager = ModelDownloadManager.shared
    @State private var showingModelPicker = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if chatManager.messages.isEmpty {
                    Spacer()
                    emptyStateView
                    Spacer()
                } else {
                    messagesView
                }
                
                inputArea
            }
            .background(.regularMaterial.opacity(0.1))
            .navigationTitle("Chat")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingModelPicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                            if let selectedModel = chatManager.selectedModel {
                                Text(selectedModel.name)
                                    .font(.caption)
                                    .lineLimit(1)
                            } else {
                                Text("Select Model")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
#else
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showingModelPicker = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "brain")
                            if let selectedModel = chatManager.selectedModel {
                                Text(selectedModel.name)
                                    .font(.caption)
                                    .lineLimit(1)
                            } else {
                                Text("Select Model")
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
#endif
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerView(chatManager: chatManager, downloadManager: downloadManager)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "message")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            
            VStack(spacing: 12) {
                Text("Start a Conversation")
                    .font(.title2)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Text("Download a model from the Models tab to begin chatting")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 40)
    }
    
    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(chatManager.messages) { message in
                        ChatBubbleView(message: message)
                            .id(message.id)
                    }
                    
                    if chatManager.isGenerating {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                                    .scaleEffect(0.8)
                                
                                Text("Generating...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                                
                                Button("Stop") {
                                    chatManager.stopGeneration()
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            
                            if !chatManager.currentResponse.isEmpty {
                                ChatBubbleView(message: ChatMessage(content: chatManager.currentResponse, isUser: false))
                                    .opacity(0.8)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .onChange(of: chatManager.messages.count) { _, _ in
                if let lastMessage = chatManager.messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var inputArea: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.3)
            
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($isTextFieldFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.2), lineWidth: 0.5)
                            }
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .background {
                            Circle()
                                .fill(Color.accentColor)
                        }
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
                .scaleEffect(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.9 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: messageText.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial)
        }
    }
    
    private func sendMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        chatManager.sendMessage(trimmedText)
        messageText = ""
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let timestamp = Date()
    
    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id
    }
}

struct ChatBubbleView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack {
            if message.isUser {
                Spacer(minLength: 60)
            }
            
            Text(message.content)
                .font(.body)
                .foregroundStyle(message.isUser ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(message.isUser ? Color.accentColor : Color.clear)
                        .background(.regularMaterial)
                        .overlay {
                            if !message.isUser {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(.separator.opacity(0.2), lineWidth: 0.5)
                            }
                        }
                }
            
            if !message.isUser {
                Spacer(minLength: 60)
            }
        }
    }
}