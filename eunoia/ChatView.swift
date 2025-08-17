import SwiftUI
import MarkdownUI

#if os(macOS)
import AppKit
#endif

struct ChatView: View {
    @State private var messageText = ""
    @StateObject private var chatManager = ChatManager()
    @ObservedObject private var downloadManager = ModelDownloadManager.shared
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ModelSelectorBar(chatManager: chatManager, downloadManager: downloadManager)
                
                if chatManager.messages.isEmpty {
                    Spacer()
                    emptyStateView
                    Spacer()
                } else {
                    messagesView
                }
                
                inputArea
            }
            #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
            .ignoresSafeArea(.keyboard, edges: .bottom)
            
            // Full screen loading overlay
            if chatManager.isLoadingModel {
                modelLoadingOverlay
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Image(systemName: "message")
                .font(.system(size: 64, weight: .ultraLight, design: .default))
                .foregroundColor(.gray.opacity(0.5))
            
            VStack(spacing: 12) {
                Text("Start a Conversation")
                    .font(.system(.title2, design: .default, weight: .medium))
                    .foregroundColor(Color.primary)
                
                Text("Download a model to begin chatting")
                    .font(.system(.subheadline, design: .default, weight: .regular))
                    .foregroundColor(Color.secondary)
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
                                    .progressViewStyle(CircularProgressViewStyle(tint: Color.secondary))
                                    .scaleEffect(0.8)
                                
                                Text("Generating...")
                                    .font(.system(.subheadline, design: .default, weight: .regular))
                                    .foregroundColor(Color.secondary)
                                
                                Spacer()
                                
                                Button("Stop") {
                                    chatManager.stopGeneration()
                                }
                                .font(.system(.caption, design: .default, weight: .medium))
                                .foregroundColor(.red)
                            }
                            
                            if !chatManager.currentResponse.isEmpty {
                                ChatBubbleView(message: ChatMessage(content: chatManager.currentResponse, isUser: false))
                                    .opacity(0.8)
                            }
                        }
                        .padding(.horizontal, 20)
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
        VStack(spacing: 8) {
            // Network status indicator
            HStack {
                Spacer()
                NetworkStatusIndicator(chatManager: chatManager)
            }
            .padding(.horizontal, 20)
            
            // Input field
            HStack(spacing: 12) {
                HStack {
                    TextField("Message", text: $messageText)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .default, weight: .regular))
                        .focused($isTextFieldFocused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .onSubmit {
                            sendMessage()
                        }
                    
                    if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: sendMessage) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                                .background(Color(hex: 0x007AFF))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeOut(duration: 0.2), value: messageText.isEmpty)
                    }
                }
                #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            isTextFieldFocused ? Color(hex: 0x007AFF) : Color.gray.opacity(0.3),
                            lineWidth: isTextFieldFocused ? 2 : 1
                        )
                        .animation(.easeOut(duration: 0.2), value: isTextFieldFocused)
                )
            }
            .padding(.horizontal, 20)
        }
        .padding(.vertical, 12)
        #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
    }
    
    private var modelLoadingOverlay: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            // Loading content
            VStack(spacing: 24) {
                // Animated loading indicator
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: 0x007AFF)))
                    .scaleEffect(1.5)
                
                VStack(spacing: 8) {
                    Text("Loading Model")
                        .font(.system(.title2, design: .default, weight: .medium))
                        .foregroundColor(.primary)
                    
                    if let selectedModel = chatManager.selectedModel {
                        Text(selectedModel.name)
                            .font(.system(.body, design: .default, weight: .regular))
                            .foregroundColor(.secondary)
                    }
                    
                    Text("This may take a few moments...")
                        .font(.system(.subheadline, design: .default, weight: .regular))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(40)
            #if os(macOS)
        .background(Color(NSColor.windowBackgroundColor))
        #else
        .background(Color(.systemBackground))
        #endif
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.1), radius: 20, x: 0, y: 10)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: chatManager.isLoadingModel)
        .onAppear {
            if chatManager.getNetworkManager() == nil {
                print("DEBUG: ChatView onAppear - initializing networking")
                chatManager.initializeNetworking()
                print("DEBUG: ChatView onAppear - starting network services")
                chatManager.startNetworkServices()
                print("DEBUG: ChatView onAppear - network services started")
            } else {
                print("DEBUG: ChatView onAppear - network manager already exists")
            }
        }
    }
    
    private func sendMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        chatManager.sendMessage(trimmedText)
        messageText = ""
    }
}

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    let content: String
    let isUser: Bool
    let timestamp: Date
    
    init(content: String, isUser: Bool) {
        self.id = UUID()
        self.content = content
        self.isUser = isUser
        self.timestamp = Date()
    }
    
    // Custom initializer for decoding from JSON
    init(id: UUID, content: String, isUser: Bool, timestamp: Date) {
        self.id = id
        self.content = content
        self.isUser = isUser
        self.timestamp = timestamp
    }
    
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
            
            Group {
                if message.isUser {
                    Text(message.content)
                        .font(.system(.body, design: .default, weight: .regular))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    Markdown(message.content)
                        .markdownTheme(.gitHub)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.isUser ? Color.gray : {
                         #if os(macOS)
                         return Color(NSColor.windowBackgroundColor)
                         #else
                         return Color(.systemBackground)
                         #endif
                    }())
                    .overlay {
                        if !message.isUser {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                        }
                    }
                    .shadow(color: Color.primary.opacity(0.05), radius: 1, x: 0, y: 1)
            }
            
            if !message.isUser {
                Spacer(minLength: 60)
            }
        }
    }
}