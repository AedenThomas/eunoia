import Foundation
import SwiftUI

@MainActor
class ChatThreadManager: ObservableObject {
    static let shared = ChatThreadManager()
    
    // MARK: - Published Properties
    @Published var threads: [ChatThread] = []
    @Published var activeThreadId: UUID?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    private let persistenceManager = ChatPersistenceManager.shared
    private var chatManagers: [UUID: ChatManager] = [:]
    
    // MARK: - Computed Properties
    var activeThread: ChatThread? {
        guard let activeId = activeThreadId else { return nil }
        return threads.first { $0.id == activeId }
    }
    
    var hasThreads: Bool {
        return !threads.isEmpty
    }
    
    var threadsOrderedByActivity: [ChatThread] {
        return threads.sorted { $0.lastModified > $1.lastModified }
    }
    
    // MARK: - Initialization
    private init() {
        Task {
            await loadThreads()
        }
    }
    
    // MARK: - Thread Loading
    func loadThreads() async {
        isLoading = true
        errorMessage = nil
        
        let collection = await persistenceManager.loadThreadCollection()
        
        await MainActor.run {
            self.threads = collection.threads.sorted { $0.lastModified > $1.lastModified }
            self.activeThreadId = collection.activeThreadId
            
            // If no active thread but we have threads, select the most recent one
            if activeThreadId == nil && !threads.isEmpty {
                activeThreadId = threads.first?.id
            }
            
            print("Loaded \(threads.count) threads, active: \(activeThreadId?.uuidString ?? "none")")
        }
        
        isLoading = false
    }
    
    // MARK: - Thread Creation
    func createNewThread(withModel model: MLXModel? = nil) async -> UUID {
        // Check if the most recent thread is empty - if so, return its ID instead of creating a new one
        if let mostRecentThread = threads.first, mostRecentThread.isEmpty {
            print("Most recent thread is empty, returning existing thread ID: \(mostRecentThread.id)")
            return mostRecentThread.id
        }
        
        let newThread = ChatThread(title: "New Chat", selectedModel: model)
        let threadId = newThread.id
        
        // Add to local array
        threads.insert(newThread, at: 0) // Insert at beginning for most recent
        activeThreadId = threadId
        
        // Create a ChatManager for this thread
        let chatManager = ChatManager()
        chatManagers[threadId] = chatManager
        
        // If model is provided, select it
        if let model = model {
            await chatManager.selectModel(model)
        }
        
        // Save to persistence
        await saveThreadCollection()
        await persistenceManager.saveThread(newThread)
        
        print("Created new thread: \(threadId)")
        return threadId
    }
    
    // MARK: - Thread Selection
    func selectThread(with id: UUID) async {
        guard threads.contains(where: { $0.id == id }) else {
            print("Warning: Attempted to select non-existent thread: \(id)")
            return
        }
        
        activeThreadId = id
        
        // Update the collection's active thread
        await saveThreadCollection()
        
        print("Selected thread: \(id)")
    }
    
    // MARK: - Thread Deletion
    func deleteThread(with id: UUID) async {
        guard let threadIndex = threads.firstIndex(where: { $0.id == id }) else {
            print("Warning: Attempted to delete non-existent thread: \(id)")
            return
        }
        
        // Remove from local array
        threads.remove(at: threadIndex)
        
        // Remove ChatManager
        chatManagers.removeValue(forKey: id)
        
        // Update active thread if we deleted the active one
        if activeThreadId == id {
            activeThreadId = threads.first?.id
        }
        
        // Delete from persistence
        let success = await persistenceManager.deleteThread(with: id)
        if success {
            await saveThreadCollection()
            print("Deleted thread: \(id)")
        } else {
            print("Warning: Failed to delete thread file: \(id)")
        }
    }
    
    // MARK: - Thread Updates
    func updateThread(_ updatedThread: ChatThread) async {
        if let index = threads.firstIndex(where: { $0.id == updatedThread.id }) {
            threads[index] = updatedThread
            
            // Re-sort threads by activity
            threads.sort { $0.lastModified > $1.lastModified }
            
            // Save updates
            await persistenceManager.saveThread(updatedThread)
            await saveThreadCollection()
            
            print("Updated thread: \(updatedThread.title)")
        }
    }
    
    // MARK: - Message Management
    func addMessage(to threadId: UUID, message: ChatMessage) async {
        print("DEBUG: ChatThreadManager.addMessage called for thread \(threadId)")
        print("DEBUG: Message content: '\(message.content.prefix(50))...', isUser: \(message.isUser)")
        
        guard let threadIndex = threads.firstIndex(where: { $0.id == threadId }) else {
            print("Warning: Attempted to add message to non-existent thread: \(threadId)")
            return
        }
        
        var updatedThread = threads[threadIndex]
        updatedThread.addMessage(message)
        
        print("DEBUG: Thread \(updatedThread.title) now has \(updatedThread.messageCount) messages")
        await updateThread(updatedThread)
    }
    
    // MARK: - ChatManager Integration
    func getChatManager(for threadId: UUID) -> ChatManager? {
        if let chatManager = chatManagers[threadId] {
            return chatManager
        }
        
        // Create a new ChatManager for this thread if one doesn't exist
        guard let thread = threads.first(where: { $0.id == threadId }) else {
            return nil
        }
        
        let chatManager = ChatManager()
        
        // Load the thread's messages into the ChatManager
        Task {
            await chatManager.loadThread(thread)
        }
        
        chatManagers[threadId] = chatManager
        return chatManager
    }
    
    func getOrCreateChatManager(for threadId: UUID) async -> ChatManager? {
        if let existingManager = getChatManager(for: threadId) {
            return existingManager
        }
        
        guard let thread = threads.first(where: { $0.id == threadId }) else {
            return nil
        }
        
        let chatManager = ChatManager()
        await chatManager.loadThread(thread)
        
        chatManagers[threadId] = chatManager
        return chatManager
    }
    
    // MARK: - Persistence Helpers
    private func saveThreadCollection() async {
        var collection = ChatThreadCollection()
        collection.threads = threads
        collection.activeThreadId = activeThreadId
        
        await persistenceManager.saveThreadCollection(collection)
    }
    
    // MARK: - Utility Functions
    func getThreadTitle(for id: UUID) -> String {
        return threads.first { $0.id == id }?.title ?? "Unknown Thread"
    }
    
    func getThreadPreview(for id: UUID) -> String {
        return threads.first { $0.id == id }?.previewText ?? "No messages"
    }
    
    func getThreadMessageCount(for id: UUID) -> Int {
        return threads.first { $0.id == id }?.messageCount ?? 0
    }
    
    func getThreadLastModified(for id: UUID) -> Date? {
        return threads.first { $0.id == id }?.lastModified
    }
    
    // MARK: - Search and Filtering
    func searchThreads(query: String) -> [ChatThread] {
        guard !query.isEmpty else { return threadsOrderedByActivity }
        
        let lowercasedQuery = query.lowercased()
        return threads.filter { thread in
            thread.title.lowercased().contains(lowercasedQuery) ||
            thread.messages.contains { message in
                message.content.lowercased().contains(lowercasedQuery)
            }
        }.sorted { $0.lastModified > $1.lastModified }
    }
    
    // MARK: - Maintenance
    func performMaintenance() async {
        let validThreadIds = Set(threads.map { $0.id })
        await persistenceManager.cleanupOrphanedThreadFiles(validThreadIds: validThreadIds)
    }
    
    func getStorageInfo() -> (threadsCount: Int, totalSize: String) {
        return persistenceManager.getStorageInfo()
    }
    
    // MARK: - Error Recovery
    func recoverFromCorruptedData() async {
        isLoading = true
        errorMessage = nil
        
        let recoveredCollection = await persistenceManager.recoverCorruptedData()
        
        threads = recoveredCollection.threads.sorted { $0.lastModified > $1.lastModified }
        activeThreadId = recoveredCollection.activeThreadId ?? threads.first?.id
        
        // Clear existing chat managers to force reload
        chatManagers.removeAll()
        
        isLoading = false
        print("Recovery completed with \(threads.count) threads")
    }
    
    // MARK: - Development Helpers
    #if DEBUG
    func createSampleThreads() async {
        // Create a few sample threads for testing
        let sampleMessages = [
            "Hello, how are you today?",
            "Can you help me with Swift programming?",
            "What's the weather like?",
            "Tell me a joke about programming"
        ]
        
        for (index, message) in sampleMessages.enumerated() {
            let threadId = await createNewThread()
            let userMessage = ChatMessage(content: message, isUser: true)
            let aiMessage = ChatMessage(content: "This is a sample AI response for message \(index + 1).", isUser: false)
            
            await addMessage(to: threadId, message: userMessage)
            await addMessage(to: threadId, message: aiMessage)
        }
        
        print("Created \(sampleMessages.count) sample threads")
    }
    #endif
}