import Foundation

class ModelRegistry {
    static let availableModels: [MLXModel] = [
        MLXModel(name: "Gemma 3 1b", identifier: "mlx-community/gemma-3-1b-it-qat-4bit", size: "733 MB", description: "Gemma 3 1b"),
        MLXModel(
            name: "Llama 3.2 3B",
            identifier: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            size: "2.4 GB",
            description: "Fast and efficient model for everyday conversations"
        ),
        MLXModel(
            name: "Phi-3.5 Mini",
            identifier: "mlx-community/Phi-3.5-mini-instruct-4bit",
            size: "2.8 GB",
            description: "Compact model optimized for quick responses"
        ),
        MLXModel(
            name: "Gemma 3 270M",
            identifier: "mlx-community/gemma-3-270m-it-bf16",
            size: "800 MB",
            description: "Google's efficient Gemma model for chat"
        ),
        MLXModel(
            name: "SmolLM 135M",
            identifier: "mlx-community/SmolLM-135M-Instruct-4bit",
            size: "75 MB",
            description: "Ultra-compact model for quick testing"
        ),
        MLXModel(
            name: "Mistral 7B",
            identifier: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
            size: "4.1 GB", 
            description: "Balanced performance for complex reasoning tasks"
        ),
        MLXModel(
            name: "CodeLlama 7B",
            identifier: "mlx-community/CodeLlama-7b-Instruct-hf-4bit",
            size: "4.3 GB",
            description: "Specialized models for code generation and analysis"
        ),
        MLXModel(
            name: "Qwen2.5 7B",
            identifier: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            size: "4.2 GB",
            description: "Advanced model with strong multilingual capabilities"
        ),
        MLXModel(
            name: "Gemma 2 9B",
            identifier: "mlx-community/gemma-2-9b-it-4bit",
            size: "5.4 GB",
            description: "High-performance model for detailed conversations"
        )
    ]
}
