import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// Helper function to add timeout to async operations
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct TimeoutError: Error {
    let localizedDescription = "Operation timed out"
}

@MainActor
class ChatManager: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isGenerating = false
    @Published var selectedModel: MLXModel?
    @Published var currentResponse = ""
    @Published var modelInfo = "No model loaded"
    
    private let downloadManager = ModelDownloadManager.shared
    private var loadedModel: ModelContext?
    private var chatSession: ChatSession?
    private var generateTask: Task<Void, Never>?
    
    func selectModel(_ model: MLXModel) async {
        selectedModel = model
        print("Selected model: \(model.name)")
        
        // Check if model is downloaded
        guard downloadManager.getDownloadState(for: model) == .completed else {
            modelInfo = "Model not downloaded"
            return
        }
        
        // Load the actual MLX model
        do {
            modelInfo = "Loading \(model.name)..."
            print("Loading MLX model: \(model.identifier)")
            
            // Create model configuration with fixes for known issues
            let modelConfig: ModelConfiguration
            if model.identifier.contains("gemma-3") {
                // Fix for Gemma 3 infinite loop issue - add extraEOSTokens
                print("DEBUG: Applying Gemma 3 fix with extraEOSTokens")
                modelConfig = ModelConfiguration(
                    id: model.identifier,
                    extraEOSTokens: ["<end_of_turn>"]
                )
            } else if model.identifier.contains("SmolLM") {
                // SmolLM might need EOS token fixes similar to Gemma 3
                print("DEBUG: Applying SmolLM fix with ChatML EOS tokens")
                modelConfig = ModelConfiguration(
                    id: model.identifier,
                    extraEOSTokens: ["<|im_end|>"]
                )
            } else {
                // Use default configuration for other models
                modelConfig = ModelConfiguration(id: model.identifier)
            }
            
            // Use the MLX Swift API to load the model with configuration
            let loadedModel = try await loadModel(configuration: modelConfig)
            self.loadedModel = loadedModel
            
            // Create chat session
            self.chatSession = ChatSession(loadedModel)
            
            modelInfo = "Model \(model.name) loaded successfully"
            print("Successfully loaded MLX model for \(model.name)")
            
        } catch {
            modelInfo = "Error loading \(model.name): \(error.localizedDescription)"
            print("Error loading MLX model: \(error)")
            loadedModel = nil
            chatSession = nil
        }
    }
    
    func sendMessage(_ content: String) {
        print("DEBUG: sendMessage called with content: \(content)")
        let userMessage = ChatMessage(content: content, isUser: true)
        messages.append(userMessage)
        print("DEBUG: Added user message, messages count: \(messages.count)")
        
        guard let selectedModel = selectedModel else {
            let errorMessage = ChatMessage(content: "Please select a model from the Models tab first.", isUser: false)
            messages.append(errorMessage)
            return
        }
        
        // Check if model is downloaded
        guard downloadManager.getDownloadState(for: selectedModel) == .completed else {
            let errorMessage = ChatMessage(content: "Please download the \(selectedModel.name) model first.", isUser: false)
            messages.append(errorMessage)
            return
        }
        
        guard let session = chatSession else {
            let errorMessage = ChatMessage(content: "Model is not loaded. Please try selecting the model again.", isUser: false)
            messages.append(errorMessage)
            return
        }
        
        print("DEBUG: About to set isGenerating to true")
        isGenerating = true
        currentResponse = ""
        
        // Cancel any existing generation task
        generateTask?.cancel()
        
        // Start real MLX text generation with multiple approaches
        generateTask = Task {
            do {
                print("DEBUG: Starting MLX text generation...")
                print("DEBUG: Model identifier: \(selectedModel.identifier)")
                print("DEBUG: ChatSession exists: true")
                
                // Try a simple test first - see if the model can do basic operations
                let testArray = MLXArray([1.0, 2.0, 3.0])
                print("DEBUG: Test MLX array: \(testArray)")
                
                // Use ChatSession to generate response - fixed with proper ModelConfiguration
                print("DEBUG: About to call session.respond(to:)")
                
                // Format the prompt according to model requirements
                let formattedPrompt: String
                if selectedModel.identifier.contains("SmolLM") {
                    // SmolLM uses ChatML format with <|im_start|> and <|im_end|> tokens
                    formattedPrompt = "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n"
                    print("DEBUG: SmolLM formatted prompt: \(formattedPrompt)")
                } else {
                    // Use default formatting for other models
                    formattedPrompt = content
                }
                
                // Add timeout to prevent indefinite hanging
                let response = try await withTimeout(seconds: 30.0) {
                    return try await session.respond(to: formattedPrompt)
                }
                
                print("DEBUG: MLX generation completed, response: '\(response)'")
                
                // Update UI with the complete response
                await MainActor.run {
                    if !Task.isCancelled {
                        let aiMessage = ChatMessage(content: response.trimmingCharacters(in: .whitespacesAndNewlines), isUser: false)
                        self.messages.append(aiMessage)
                        self.currentResponse = ""
                        self.isGenerating = false
                        print("DEBUG: MLX generation completed successfully")
                    }
                }
                
            } catch is TimeoutError {
                print("DEBUG: MLX generation timed out - this suggests session.respond(to:) is hanging")
                await MainActor.run {
                    let timeoutMessage = ChatMessage(content: "⚠️ Generation timed out. The MLX model may not be responding correctly.", isUser: false)
                    self.messages.append(timeoutMessage)
                    self.currentResponse = ""
                    self.isGenerating = false
                }
            } catch is CancellationError {
                print("DEBUG: MLX generation was cancelled")
                await MainActor.run {
                    self.currentResponse = ""
                    self.isGenerating = false
                }
            } catch {
                print("DEBUG: Error during MLX generation: \(error)")
                await MainActor.run {
                    let errorMessage = ChatMessage(content: "Error generating response: \(error.localizedDescription)", isUser: false)
                    self.messages.append(errorMessage)
                    self.currentResponse = ""
                    self.isGenerating = false
                }
            }
        }
    }
    
    func stopGeneration() {
        generateTask?.cancel()
        isGenerating = false
        
        // Add the partial response if any
        if !currentResponse.isEmpty {
            let aiMessage = ChatMessage(content: currentResponse, isUser: false)
            messages.append(aiMessage)
            currentResponse = ""
        }
    }
    
    func clearMessages() {
        messages.removeAll()
    }
}