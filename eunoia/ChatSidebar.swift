import SwiftUI

struct ChatSidebar: View {
    @ObservedObject var threadManager: ChatThreadManager
    @State private var searchText = ""
    @State private var showingDeleteConfirmation = false
    @State private var threadToDelete: UUID?
    
    var filteredThreads: [ChatThread] {
        if searchText.isEmpty {
            return threadManager.threadsOrderedByActivity
        } else {
            return threadManager.searchThreads(query: searchText)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            sidebarHeader
            
            if threadManager.hasThreads {
                // Thread list
                threadList
            } else {
                // Empty state
                emptyState
            }
        }
        .background(Color(.controlBackgroundColor))
        .alert("Delete Thread", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                threadToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let threadId = threadToDelete {
                    Task {
                        await threadManager.deleteThread(with: threadId)
                    }
                }
                threadToDelete = nil
            }
        } message: {
            if let threadId = threadToDelete {
                Text("Are you sure you want to delete \"\(threadManager.getThreadTitle(for: threadId))\"? This action cannot be undone.")
            }
        }
    }
    
    private var sidebarHeader: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Conversations")
                    .font(.system(.title2, design: .default, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                Button(action: {
                    Task {
                        await threadManager.createNewThread()
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color.gray.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("New Chat")
            }
            
            // Search bar
            if threadManager.hasThreads {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                    
                    TextField("Search conversations...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .default, weight: .regular))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color(.controlBackgroundColor))
    }
    
    private var threadList: some View {
        List {
            ForEach(filteredThreads) { thread in
                ChatThreadRow(
                    thread: thread,
                    isSelected: thread.id == threadManager.activeThreadId,
                    onSelect: {
                        Task {
                            await threadManager.selectThread(with: thread.id)
                        }
                    },
                    onDelete: {
                        // This is now handled by .onDelete modifier below
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .onDelete(perform: deleteThread)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
    
    private func deleteThread(at offsets: IndexSet) {
        // Get the thread to delete
        let threadsToDelete = offsets.map { filteredThreads[$0] }
        
        // Show confirmation for the first thread (usually only one)
        if let firstThread = threadsToDelete.first {
            threadToDelete = firstThread.id
            showingDeleteConfirmation = true
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundColor(.gray.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No Conversations Yet")
                    .font(.system(.title3, design: .default, weight: .medium))
                    .foregroundColor(.primary)
                
                Text("Start a new conversation to begin chatting with AI models")
                    .font(.system(.subheadline, design: .default, weight: .regular))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            
            Button(action: {
                Task {
                    await threadManager.createNewThread()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                    
                    Text("New Chat")
                        .font(.system(.body, design: .default, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(hex: 0x007AFF))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

#Preview {
    ChatSidebar(threadManager: ChatThreadManager.shared)
        .frame(width: 300, height: 600)
}