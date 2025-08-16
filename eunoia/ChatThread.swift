import Foundation
import SwiftUI

// MARK: - ChatThread Data Model
struct ChatThread: Identifiable, Codable {
    let id: UUID
    var title: String
    var messages: [ChatMessage]
    var selectedModelId: String? // Store model identifier instead of full model
    let createdAt: Date
    var lastModified: Date
    
    init(title: String = "New Chat", selectedModel: MLXModel? = nil) {
        self.id = UUID()
        self.title = title
        self.messages = []
        self.selectedModelId = selectedModel?.identifier
        self.createdAt = Date()
        self.lastModified = Date()
    }
    
    // Computed property to get the actual model from the identifier
    var selectedModel: MLXModel? {
        guard let modelId = selectedModelId else { return nil }
        return ModelRegistry.availableModels.first { $0.identifier == modelId }
    }
    
    // Auto-generate title from first user message (limit to 40 characters)
    mutating func updateTitleFromFirstMessage() {
        if let firstUserMessage = messages.first(where: { $0.isUser }) {
            let trimmedContent = firstUserMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                self.title = String(trimmedContent.prefix(40))
                if trimmedContent.count > 40 {
                    self.title += "..."
                }
                self.lastModified = Date()
            }
        }
    }
    
    // Add a message to the thread
    mutating func addMessage(_ message: ChatMessage) {
        messages.append(message)
        lastModified = Date()
        
        // Auto-update title if this is the first user message and we're using default title
        if title == "New Chat" && message.isUser && messages.filter({ $0.isUser }).count == 1 {
            updateTitleFromFirstMessage()
        }
    }
    
    // Get preview text for sidebar display
    var previewText: String {
        if let lastMessage = messages.last {
            let preview = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(preview.prefix(60))
        }
        return "No messages yet"
    }
    
    // Check if thread has any messages
    var isEmpty: Bool {
        return messages.isEmpty
    }
    
    // Get message count
    var messageCount: Int {
        return messages.count
    }
}

// ChatMessage is now Codable in ChatView.swift

// MARK: - Thread Collection Helper
struct ChatThreadCollection: Codable {
    var threads: [ChatThread]
    var activeThreadId: UUID?
    
    init() {
        self.threads = []
        self.activeThreadId = nil
    }
    
    // Get active thread
    var activeThread: ChatThread? {
        guard let activeId = activeThreadId else { return nil }
        return threads.first { $0.id == activeId }
    }
    
    // Find thread by ID
    func thread(with id: UUID) -> ChatThread? {
        return threads.first { $0.id == id }
    }
    
    // Update a specific thread
    mutating func updateThread(_ updatedThread: ChatThread) {
        if let index = threads.firstIndex(where: { $0.id == updatedThread.id }) {
            threads[index] = updatedThread
        }
    }
    
    // Remove thread by ID
    mutating func removeThread(with id: UUID) {
        threads.removeAll { $0.id == id }
        
        // Clear active thread ID if we're removing the active thread
        if activeThreadId == id {
            activeThreadId = threads.first?.id
        }
    }
    
    // Add new thread
    mutating func addThread(_ thread: ChatThread) {
        threads.append(thread)
        // Sort threads by last modified date (most recent first)
        threads.sort { $0.lastModified > $1.lastModified }
    }
    
    // Sort threads by activity
    mutating func sortByActivity() {
        threads.sort { $0.lastModified > $1.lastModified }
    }
}