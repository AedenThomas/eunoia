import SwiftUI
import Foundation

struct ChatThreadRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        threadContent
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color(hex: 0x007AFF).opacity(0.1) : (isHovered ? Color.gray.opacity(0.05) : Color.clear))
                    .animation(.easeOut(duration: 0.15), value: isSelected)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            #if os(macOS)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .contextMenu {
                Button("Select Thread") {
                    onSelect()
                }
                
                Divider()
                
                Button("Delete Thread", role: .destructive) {
                    onDelete()
                }
            }
            #endif
    }

    private var threadContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // Thread title
                Text(thread.title)
                    .font(.system(.body, design: .default, weight: .medium))
                    .foregroundColor(isSelected ? Color(hex: 0x007AFF) : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                // Preview text
                if !thread.previewText.isEmpty && thread.previewText != "No messages yet" {
                    Text(thread.previewText)
                        .font(.system(.caption, design: .default, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 4) {
                // Time stamp
                Text(timeString(for: thread.lastModified))
                    .font(.system(.caption2, design: .default, weight: .regular))
                    .foregroundColor(.secondary)
                
                // Message count
                if thread.messageCount > 0 {
                    Text("\(thread.messageCount)")
                        .font(.system(.caption2, design: .default, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func timeString(for date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return formatter.string(from: date)
        } else if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) {
            return "Yesterday"
        } else if calendar.dateInterval(of: .weekOfYear, for: now)?.contains(date) == true {
            let formatter = DateFormatter()
            formatter.dateFormat = "E" // Day of week
            return formatter.string(from: date)
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d" // Month and day
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d/yy" // Short date format
            return formatter.string(from: date)
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        // Sample threads for preview
        ChatThreadRow(
            thread: ChatThread(title: "How to use SwiftUI", selectedModel: nil).applying {
                $0.addMessage(ChatMessage(content: "Can you help me learn SwiftUI?", isUser: true))
                $0.addMessage(ChatMessage(content: "Of course! SwiftUI is Apple's modern framework...", isUser: false))
            },
            isSelected: true,
            onSelect: { print("Selected thread 1") },
            onDelete: { print("Delete thread 1") } 
        )
        
        ChatThreadRow(
            thread: ChatThread(title: "Weather question", selectedModel: nil).applying {
                $0.addMessage(ChatMessage(content: "What's the weather like today?", isUser: true))
            },
            isSelected: false,
            onSelect: { print("Selected thread 2") },
            onDelete: { print("Delete thread 2") }
        )
        
        ChatThreadRow(
            thread: ChatThread(title: "Empty thread"),
            isSelected: false,
            onSelect: { print("Selected thread 3") },
            onDelete: { print("Delete thread 3") }
        )
    }
    .padding()
    .frame(width: 300)
}

// Helper extension for preview
extension ChatThread {
    func applying(_ closure: (inout ChatThread) -> Void) -> ChatThread {
        var copy = self
        closure(&copy)
        return copy
    }
}