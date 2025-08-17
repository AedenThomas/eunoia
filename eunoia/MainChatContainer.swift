import SwiftUI
import MarkdownUI

#if os(macOS)
import AppKit
#endif

// A shared class to manage the download modal state
class DownloadModalManager: ObservableObject {
    static let shared = DownloadModalManager()
    @Published var showDownloadModal = false
    
    func openDownloadModal() {
        print("DEBUG: DownloadModalManager.openDownloadModal() - Setting showDownloadModal to true")
        self.showDownloadModal = true
    }
}

// Singleton to maintain ChatManager instances across view recreations
class ChatManagerStore: ObservableObject {
    static let shared = ChatManagerStore()
    
    @Published var chatManagers: [UUID: ChatManager] = [:]
    
    private init() {}
}

struct MainChatContainer: View {
    @StateObject private var threadManager = ChatThreadManager.shared
    @State private var selectedThreadId: UUID?
    @StateObject private var chatManagerStore = ChatManagerStore.shared
    @StateObject private var downloadModalManager = DownloadModalManager.shared
    
    // Sidebar visibility for iOS
    @State private var showingSidebar = false
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            ChatSidebar(threadManager: threadManager)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
        } detail: {
            // Main content area
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            setupInitialThread()
        }
        .onChange(of: threadManager.activeThreadId) { _, newThreadId in
            selectedThreadId = newThreadId
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        if let activeThreadId = threadManager.activeThreadId,
           let thread = threadManager.threads.first(where: { $0.id == activeThreadId }) {
            
            // Show chat view for active thread
            ThreadChatView(
                thread: thread,
                threadManager: threadManager,
                chatManager: getChatManager(for: activeThreadId)
            )
            .id("thread-\(activeThreadId)") // Prevent unnecessary view recreation
            
        } else if threadManager.isLoading {
            // Loading state
            loadingView
            
        } else if !threadManager.hasThreads {
            // Auto-create first thread instead of showing welcome screen
            Color.clear
                .onAppear {
                    Task {
                        let newThreadId = await threadManager.createNewThread()
                        selectedThreadId = newThreadId
                    }
                }
            
        } else {
            // No active thread selected
            noThreadSelectedView
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: 0x007AFF)))
                .scaleEffect(1.2)
            
            Text("Loading conversations...")
                .font(.system(.body, design: .default, weight: .regular))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 20) {
                Image(systemName: "message.circle")
                    .font(.system(size: 80, weight: .ultraLight))
                    .foregroundColor(.gray.opacity(0.5))
                
                VStack(spacing: 12) {
                    Text("Welcome to Eunoia")
                        .font(.system(.largeTitle, design: .default, weight: .bold))
                        .foregroundColor(.primary)
                    
                    Text("Start your first conversation with an AI model")
                        .font(.system(.title3, design: .default, weight: .regular))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            Button(action: {
                Task {
                    let newThreadId = await threadManager.createNewThread()
                    selectedThreadId = newThreadId
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .medium))
                    
                    Text("Start New Conversation")
                        .font(.system(.body, design: .default, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color(hex: 0x007AFF))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor))
        .padding(.horizontal, 40)
    }
    
    private var noThreadSelectedView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "arrow.left")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundColor(.gray.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("Select a Conversation")
                    .font(.system(.title2, design: .default, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("Choose a conversation from the sidebar to continue chatting")
                    .font(.system(.body, design: .default, weight: .regular))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.controlBackgroundColor))
        .padding(.horizontal, 40)
    }
    
    // MARK: - Chat Manager Management
    
    private func getChatManager(for threadId: UUID) -> ChatManager {
        print("DEBUG: getChatManager called for thread \(threadId)")
        print("DEBUG: Current chatManagers count: \(chatManagerStore.chatManagers.count)")
        print("DEBUG: ChatManagers keys: \(chatManagerStore.chatManagers.keys.map { $0.uuidString })")
        
        if let existingManager = chatManagerStore.chatManagers[threadId] {
            print("DEBUG: Returning existing ChatManager for thread \(threadId)")
            print("DEBUG: Existing manager's selected model: \(existingManager.selectedModel?.name ?? "nil")")
            return existingManager
        }
        
        print("DEBUG: Creating new ChatManager for thread \(threadId)")
        
        // Create new ChatManager for this thread
        let chatManager = ChatManager()
        
        // Setup the callback to update the thread when messages are added
        chatManager.setupThreadCallback { threadId, message in
            print("DEBUG: ChatManager callback triggered for thread \(threadId)")
            await threadManager.addMessage(to: threadId, message: message)
        }
        
        // Load the thread data if it exists
        if let thread = threadManager.threads.first(where: { $0.id == threadId }) {
            print("DEBUG: Loading thread data for new ChatManager: \(thread.title)")
            Task {
                await chatManager.loadThread(thread)
            }
        }
        
        chatManagerStore.chatManagers[threadId] = chatManager
        return chatManager
    }
    
    private func setupInitialThread() {
        // If there's an active thread, select it
        if let activeId = threadManager.activeThreadId {
            selectedThreadId = activeId
        }
        // If no active thread but threads exist, select the first one
        else if let firstThread = threadManager.threads.first {
            selectedThreadId = firstThread.id
            Task {
                await threadManager.selectThread(with: firstThread.id)
            }
        }
    }
    
    // MARK: - Memory Management
    
    private func cleanupUnusedChatManagers() {
        let activeThreadIds = Set(threadManager.threads.map { $0.id })
        let managersToRemove = chatManagerStore.chatManagers.keys.filter { !activeThreadIds.contains($0) }
        
        for threadId in managersToRemove {
            chatManagerStore.chatManagers.removeValue(forKey: threadId)
        }
    }
}

// MARK: - Thread-Specific Chat View
struct ThreadChatView: View {
    let thread: ChatThread
    @ObservedObject var threadManager: ChatThreadManager
    @ObservedObject var chatManager: ChatManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with new chat button
            chatHeader
            
            // Chat content
            ThreadChatViewContent(chatManager: chatManager)
                .onAppear {
                    print("DEBUG: ThreadChatView onAppear for thread \(thread.id), title: '\(thread.title)'")
                    print("DEBUG: ChatManager.threadId = \(chatManager.threadId?.uuidString ?? "nil"), thread.id = \(thread.id.uuidString)")
                    print("DEBUG: ChatManager selectedModel before onAppear: \(chatManager.selectedModel?.name ?? "nil")")
                    
                    // Ensure chat manager is loaded with thread data
                    if chatManager.threadId != thread.id {
                        print("DEBUG: ThreadId mismatch detected, calling loadThread...")
                        Task {
                            await chatManager.loadThread(thread)
                        }
                    } else {
                        print("DEBUG: ThreadId matches, NOT calling loadThread")
                    }
                }
        }
    }
    
    private var chatHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title)
                    .font(.system(.title2, design: .default, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if thread.messageCount > 0 {
                    Text("\(thread.messageCount) messages")
                        .font(.system(.caption, design: .default, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // New chat button
            Button(action: {
                Task {
                    await threadManager.createNewThread()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                    
                    Text("New")
                        .font(.system(.body, design: .default, weight: .medium))
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("New Chat")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(.controlBackgroundColor))
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }
}

// MARK: - Custom Chat View Wrapper
private struct ThreadChatViewContent: View {
    @ObservedObject var chatManager: ChatManager
    @ObservedObject var downloadModalManager = DownloadModalManager.shared
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    @State private var showModelSelectionPrompt = false
    @State private var selectedModelForPrompt: MLXModel? = nil
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ModelSelectorBar(chatManager: chatManager, downloadManager: ModelDownloadManager.shared)
                
                if chatManager.messages.isEmpty {
                    Spacer()
                    emptyStateView
                    Spacer()
                } else {
                    messagesView
                }
                
                inputArea
            }
            .background(Color(.controlBackgroundColor))
            .ignoresSafeArea(.keyboard, edges: .bottom)
            
            // Full screen loading overlay
            if chatManager.isLoadingModel {
                modelLoadingOverlay
                    .onAppear {
                        print("DEBUG: modelLoadingOverlay appeared")
                    }
            }
            
            // Model selection prompt
            if showModelSelectionPrompt {
                modelSelectionPromptOverlay
                    .onAppear {
                        print("DEBUG: modelSelectionPromptOverlay appeared")
                    }
            }
        }
    }
    
    // Copy the implementation from original ChatView
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
            .background(Color(.controlBackgroundColor))
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
        .padding(.vertical, 12)
        .background(Color(.controlBackgroundColor))
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
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.primary.opacity(0.1), radius: 20, x: 0, y: 10)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: chatManager.isLoadingModel)
    }
    
    private var modelSelectionPromptOverlay: some View {
        // Capture the downloadModalManager reference for use in closures
        let downloadModalMgr = self.downloadModalManager
        
        return ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    showModelSelectionPrompt = false
                }
            
            // Model selection prompt
            VStack(spacing: 24) {
                VStack(spacing: 16) {
                    Image(systemName: "cpu")
                        .font(.system(size: 48, weight: .light))
                        .foregroundColor(Color(hex: 0x007AFF))
                    
                    VStack(spacing: 8) {
                        Text("Select a Model to Chat")
                            .font(.system(.title2, design: .default, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Text("Choose from your downloaded models to start chatting")
                            .font(.system(.body, design: .default, weight: .regular))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                
                let downloadManager = ModelDownloadManager.shared
                let availableModels = ModelRegistry.availableModels.filter { model in
                    downloadManager.downloadedModels.contains(model.identifier)
                }
                
                if availableModels.isEmpty {
                    VStack(spacing: 16) {
                        Text("No models downloaded yet")
                            .font(.system(.body, design: .default, weight: .medium))
                            .foregroundColor(.secondary)
                        
                        Button(action: {
                            print("DEBUG: Download Models button pressed in model selection prompt")
                            
                            // First hide this prompt
                            showModelSelectionPrompt = false
                            
                            // Give UI time to update
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                print("DEBUG: Calling downloadModalManager.openDownloadModal() to show download sheet")
                                // Use the shared manager to open the download modal
                                downloadModalMgr.openDownloadModal()
                                print("DEBUG: downloadModalManager.showDownloadModal is now: \(downloadModalMgr.showDownloadModal)")
                            }
                        }) {
                            Text("Download Models")
                                .font(.system(.body, design: .default, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(minWidth: 220)
                                .padding(.vertical, 12)
                        }
                        .background(Color(hex: 0x007AFF))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    VStack(spacing: 12) {
                        ForEach(availableModels, id: \.identifier) { model in
                            Button(action: {
                                selectedModelForPrompt = model
                            }) {
                                HStack {
                                    // Selection indicator
                                    Image(systemName: selectedModelForPrompt?.id == model.id ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(selectedModelForPrompt?.id == model.id ? Color(hex: 0x007AFF) : Color.gray)
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(model.name)
                                            .font(.system(.body, design: .default, weight: .semibold))
                                            .foregroundColor(.primary)
                                        
                                        Text(model.description)
                                            .font(.system(.caption, design: .default, weight: .regular))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(model.size)
                                        .font(.system(.caption, design: .default, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(.controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(selectedModelForPrompt?.id == model.id ? Color(hex: 0x007AFF).opacity(0.5) : Color.gray.opacity(0.3), lineWidth: selectedModelForPrompt?.id == model.id ? 2 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 400)
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        print("DEBUG: Cancel button clicked, dismissing model selection prompt")
                        showModelSelectionPrompt = false
                        selectedModelForPrompt = nil
                    }) {
                        Text("Cancel")
                            .font(.system(.body, design: .default, weight: .regular))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 100)
                            .padding(.vertical, 8)
                    }
                    .background(Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    
                    Button(action: {
                        if let selectedModel = selectedModelForPrompt {
                            print("DEBUG: Submit button clicked with model: \(selectedModel.name)")
                            Task {
                                print("DEBUG: Starting model selection Task")
                                // Important: First set showModelSelectionPrompt = false immediately
                                // to ensure loading modal becomes visible
                                await MainActor.run {
                                    print("DEBUG: Setting showModelSelectionPrompt = false before model loads")
                                    showModelSelectionPrompt = false
                                }
                                
                                // Then select the model which will show loading modal
                                print("DEBUG: About to call chatManager.selectModel")
                                await chatManager.selectModel(selectedModel)
                                
                                await MainActor.run {
                                    print("DEBUG: Model selection completed, cleaning up state")
                                    selectedModelForPrompt = nil
                                }
                            }
                        }
                    }) {
                        Text("Submit")
                            .font(.system(.body, design: .default, weight: .regular))
                            .foregroundColor(selectedModelForPrompt != nil ? .white : Color.gray)
                            .frame(minWidth: 100)
                            .padding(.vertical, 8)
                    }
                    .background(selectedModelForPrompt != nil ? Color(hex: 0x007AFF) : Color.gray.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(selectedModelForPrompt == nil)
                }
            }
            .padding(32)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(color: Color.primary.opacity(0.1), radius: 20, x: 0, y: 10)
            .frame(maxWidth: 500)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: showModelSelectionPrompt)
    }
    
    private func sendMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        
        // Check if a model is selected before sending
        guard chatManager.selectedModel != nil else {
            showModelSelectionPrompt = true
            return
        }
        
        chatManager.sendMessage(trimmedText)
        messageText = ""
    }
    
    // Helper function to find the ModelSelectorBar instance
    private func findModelSelectorBar() -> ModelSelectorBar? {
        print("DEBUG: Attempting to find ModelSelectorBar instance")
        
        // For a better solution, we should use a StateObject to maintain this state
        // But for now, we can create a new instance and update its state directly
        let modelSelectorBar = ModelSelectorBar(
            chatManager: chatManager,
            downloadManager: ModelDownloadManager.shared
        )
        
        print("DEBUG: Created new ModelSelectorBar instance with same parameters")
        
        // A better approach would be to use an environment object or state object
        // that is shared between views, but this workaround should function
        
        return modelSelectorBar
    }
}

#Preview {
    MainChatContainer()
}