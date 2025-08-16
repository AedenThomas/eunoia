import Foundation

// MARK: - Chat Persistence Manager
class ChatPersistenceManager {
    static let shared = ChatPersistenceManager()
    
    private let fileManager = FileManager.default
    private let threadsDirectoryName = "eunoia_threads"
    private let threadsIndexFileName = "threads_index.json"
    
    // MARK: - Directory Management
    
    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
    
    private var threadsDirectory: URL {
        documentsDirectory.appendingPathComponent(threadsDirectoryName)
    }
    
    private var threadsIndexURL: URL {
        threadsDirectory.appendingPathComponent(threadsIndexFileName)
    }
    
    private func threadFileURL(for threadId: UUID) -> URL {
        threadsDirectory.appendingPathComponent("thread_\(threadId.uuidString).json")
    }
    
    // MARK: - Initialization
    
    private init() {
        createDirectoryIfNeeded()
    }
    
    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: threadsDirectory.path) {
            do {
                try fileManager.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
                print("Created threads directory at: \(threadsDirectory.path)")
            } catch {
                print("Error creating threads directory: \(error)")
            }
        }
    }
    
    // MARK: - Thread Collection Management
    
    func loadThreadCollection() async -> ChatThreadCollection {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Data(contentsOf: self.threadsIndexURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let collection = try decoder.decode(ChatThreadCollection.self, from: data)
                    print("Loaded \(collection.threads.count) threads from storage")
                    continuation.resume(returning: collection)
                } catch {
                    print("Error loading thread collection (creating new): \(error)")
                    // Return empty collection if file doesn't exist or is corrupted
                    continuation.resume(returning: ChatThreadCollection())
                }
            }
        }
    }
    
    func saveThreadCollection(_ collection: ChatThreadCollection) async {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(collection)
                    try data.write(to: self.threadsIndexURL)
                    print("Saved thread collection with \(collection.threads.count) threads")
                    continuation.resume()
                } catch {
                    print("Error saving thread collection: \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Individual Thread Management
    
    func loadThread(with id: UUID) async -> ChatThread? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = self.threadFileURL(for: id)
                    let data = try Data(contentsOf: url)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let thread = try decoder.decode(ChatThread.self, from: data)
                    print("Loaded thread: \(thread.title) with \(thread.messages.count) messages")
                    continuation.resume(returning: thread)
                } catch {
                    print("Error loading thread \(id): \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    func saveThread(_ thread: ChatThread) async {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(thread)
                    let url = self.threadFileURL(for: thread.id)
                    try data.write(to: url)
                    print("Saved thread: \(thread.title) with \(thread.messages.count) messages")
                    continuation.resume()
                } catch {
                    print("Error saving thread \(thread.id): \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    func deleteThread(with id: UUID) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let url = self.threadFileURL(for: id)
                    if self.fileManager.fileExists(atPath: url.path) {
                        try self.fileManager.removeItem(at: url)
                        print("Deleted thread file: \(id)")
                        continuation.resume(returning: true)
                    } else {
                        print("Thread file not found: \(id)")
                        continuation.resume(returning: false)
                    }
                } catch {
                    print("Error deleting thread \(id): \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    // MARK: - Batch Operations
    
    func saveThreadWithCollection(_ thread: ChatThread, collection: ChatThreadCollection) async {
        // Save both the individual thread and the updated collection
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.saveThread(thread)
            }
            group.addTask {
                await self.saveThreadCollection(collection)
            }
        }
    }
    
    // MARK: - Migration and Maintenance
    
    func getStorageInfo() -> (threadsCount: Int, totalSize: String) {
        do {
            let files = try fileManager.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: [.fileSizeKey])
            let threadFiles = files.filter { $0.lastPathComponent.hasPrefix("thread_") }
            
            let totalBytes = try files.reduce(0) { total, url in
                let resources = try url.resourceValues(forKeys: [.fileSizeKey])
                return total + (resources.fileSize ?? 0)
            }
            
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB]
            formatter.countStyle = .file
            
            return (threadFiles.count, formatter.string(fromByteCount: Int64(totalBytes)))
        } catch {
            print("Error getting storage info: \(error)")
            return (0, "Unknown")
        }
    }
    
    func cleanupOrphanedThreadFiles(validThreadIds: Set<UUID>) async {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .background).async {
                do {
                    let files = try self.fileManager.contentsOfDirectory(at: self.threadsDirectory, includingPropertiesForKeys: nil)
                    let threadFiles = files.filter { $0.lastPathComponent.hasPrefix("thread_") }
                    
                    var deletedCount = 0
                    for file in threadFiles {
                        let filename = file.lastPathComponent
                        if let uuidString = filename.components(separatedBy: "_").last?.components(separatedBy: ".").first,
                           let uuid = UUID(uuidString: uuidString),
                           !validThreadIds.contains(uuid) {
                            
                            try self.fileManager.removeItem(at: file)
                            deletedCount += 1
                        }
                    }
                    
                    if deletedCount > 0 {
                        print("Cleaned up \(deletedCount) orphaned thread files")
                    }
                    continuation.resume()
                } catch {
                    print("Error during cleanup: \(error)")
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Error Recovery
    
    func recoverCorruptedData() async -> ChatThreadCollection {
        print("Attempting to recover from corrupted data...")
        
        // Try to recover individual thread files
        var recoveredThreads: [ChatThread] = []
        
        do {
            let files = try fileManager.contentsOfDirectory(at: threadsDirectory, includingPropertiesForKeys: nil)
            let threadFiles = files.filter { $0.lastPathComponent.hasPrefix("thread_") }
            
            for file in threadFiles {
                if let thread = await loadThread(from: file) {
                    recoveredThreads.append(thread)
                }
            }
            
            print("Recovered \(recoveredThreads.count) threads from individual files")
        } catch {
            print("Error during recovery: \(error)")
        }
        
        var collection = ChatThreadCollection()
        for thread in recoveredThreads {
            collection.addThread(thread)
        }
        
        // Save the recovered collection
        await saveThreadCollection(collection)
        
        return collection
    }
    
    private func loadThread(from url: URL) async -> ChatThread? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ChatThread.self, from: data)
        } catch {
            print("Could not recover thread from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
}