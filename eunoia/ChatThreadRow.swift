import SwiftUI
import Foundation

#if os(macOS)
import AppKit
#endif

struct ChatThreadRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    
    @State private var isHovered = false
    @State private var dragOffset: CGFloat = 0
    @State private var showingDeleteButton = false
    
    var body: some View {
        #if os(macOS)
        ZStack {
            // Background delete area (always present but hidden)
            HStack {
                Spacer()
                deleteButtonArea
            }
            .allowsHitTesting(showingDeleteButton)
            
            // Main thread content that slides over the delete area
            threadContent
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color(hex: 0x007AFF).opacity(0.1) : (isHovered ? Color.gray.opacity(0.05) : Color.clear))
                        .animation(.easeOut(duration: 0.15), value: isSelected)
                        .animation(.easeOut(duration: 0.15), value: isHovered)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
                .offset(x: dragOffset)
                .onTapGesture {
                    if showingDeleteButton {
                        // Hide delete button if visible
                        withAnimation(.easeOut(duration: 0.2)) {
                            showingDeleteButton = false
                            dragOffset = 0
                        }
                    } else {
                        onSelect()
                    }
                }
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
                .background(
                    // Add scroll wheel event monitoring
                    ScrollWheelMonitor { deltaX, deltaY in
                        print("DEBUG: Scroll wheel event - deltaX: \(deltaX), deltaY: \(deltaY)")
                        
                        let horizontalThreshold: Double = 5.0
                        let absHorizontal = abs(deltaX)
                        let absVertical = abs(deltaY)
                        
                        // Check if horizontal movement is dominant and significant
                        if absHorizontal > horizontalThreshold && absHorizontal > absVertical {
                            if deltaX < 0 {
                                print("DEBUG: Left swipe detected via scroll wheel (deltaX: \(deltaX))")
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showingDeleteButton = true
                                    dragOffset = -80 // Slide content to the left
                                }
                            } else if deltaX > 0 {
                                print("DEBUG: Right swipe detected via scroll wheel (deltaX: \(deltaX))")
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showingDeleteButton = false
                                    dragOffset = 0 // Return content to original position
                                }
                            }
                        }
                    }
                )
        }
        #else
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        #endif
    }
    
    #if os(macOS)
    private var deleteButtonArea: some View {
        Button(action: {
            print("DEBUG: Delete button tapped!")
            withAnimation(.easeOut(duration: 0.2)) {
                showingDeleteButton = false
                dragOffset = 0
            }
            onDelete()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                
                Text("Delete")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity) // Fill the entire available space
            .background(Color.red)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(width: 80) // Fixed width to match the slide distance
        .frame(minHeight: 60) // Match the approximate height of thread content
        .opacity(showingDeleteButton ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: showingDeleteButton)
        .allowsHitTesting(showingDeleteButton) // Only allow clicks when visible
    }
    #endif

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

#if os(macOS)
// Enhanced scroll wheel monitor with better event handling
struct ScrollWheelMonitor: NSViewRepresentable {
    let onScrollWheel: (Double, Double) -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = ScrollWheelView()
        view.onScrollWheel = onScrollWheel
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let scrollView = nsView as? ScrollWheelView {
            scrollView.onScrollWheel = onScrollWheel
        }
    }
}

class ScrollWheelView: NSView {
    var onScrollWheel: ((Double, Double) -> Void)?
    private var eventMonitor: Any?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        print("DEBUG: ScrollWheelView setupView called")
        wantsLayer = true
        
        // Make view slightly visible for debugging (can be removed later)
        layer?.backgroundColor = NSColor.clear.cgColor // NSColor.red.withAlphaComponent(0.01).cgColor
        
        // Ensure we can receive all mouse events
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        
        print("DEBUG: ScrollWheelView setup completed")
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        // Remove old tracking areas
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        
        // Add new tracking area
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        
        if window != nil {
            print("DEBUG: ScrollWheelView moved to window, setting up event monitoring")
            setupEventMonitoring()
        } else {
            print("DEBUG: ScrollWheelView removed from window, cleaning up")
            cleanupEventMonitoring()
        }
    }
    
    private func setupEventMonitoring() {
        // Clean up existing monitor first
        cleanupEventMonitoring()
        
        // Add local event monitor for scroll wheel events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            print("DEBUG: Local event monitor caught scroll wheel event")
            
            // Check if the event is within our bounds
            if let strongSelf = self,
               let window = strongSelf.window {
                let windowPoint = event.locationInWindow
                let viewPoint = strongSelf.convert(windowPoint, from: nil)
                
                if strongSelf.bounds.contains(viewPoint) {
                    print("DEBUG: Scroll event is within our view bounds")
                    strongSelf.handleScrollEvent(event)
                    return nil // Consume the event
                }
            }
            
            return event // Let the event continue
        }
        
        print("DEBUG: Event monitoring setup completed")
    }
    
    private func cleanupEventMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
            print("DEBUG: Event monitoring cleaned up")
        }
    }
    
    private func handleScrollEvent(_ event: NSEvent) {
        print("DEBUG: ScrollWheelView handleScrollEvent called")
        print("DEBUG: deltaX: \(event.deltaX), deltaY: \(event.deltaY)")
        print("DEBUG: scrollingDeltaX: \(event.scrollingDeltaX), scrollingDeltaY: \(event.scrollingDeltaY)")
        print("DEBUG: hasPreciseScrollingDeltas: \(event.hasPreciseScrollingDeltas)")
        print("DEBUG: phase: \(event.phase.rawValue), momentumPhase: \(event.momentumPhase.rawValue)")
        
        // Use precise deltas if available (trackpad), otherwise use regular deltas
        let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        
        // Call the callback on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onScrollWheel?(deltaX, deltaY)
        }
    }
    
    override func scrollWheel(with event: NSEvent) {
        print("DEBUG: ScrollWheelView scrollWheel method called directly")
        handleScrollEvent(event)
        // Don't call super to consume the event
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        print("DEBUG: ScrollWheelView hitTest called, point: \(point), result: \(result != nil)")
        return result
    }
    
    override func mouseEntered(with event: NSEvent) {
        print("DEBUG: ScrollWheelView mouseEntered")
    }
    
    override func mouseExited(with event: NSEvent) {
        print("DEBUG: ScrollWheelView mouseExited")
    }
    
    deinit {
        cleanupEventMonitoring()
        print("DEBUG: ScrollWheelView deinit")
    }
}
#else
// Placeholder for non-macOS platforms
struct ScrollWheelMonitor: View {
    let onScrollWheel: (Double, Double) -> Void
    
    var body: some View {
        Color.clear
    }
}
#endif