//
//  ContentView.swift
//  eunoia
//
//  Created by Aeden Thomas on 8/14/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ChatView()
                .tabItem {
                    Image(systemName: "message")
                    Text("Chat")
                }
            
            ModelListView()
                .tabItem {
                    Image(systemName: "square.stack.3d.down.right")
                    Text("Models")
                }
        }
        .tint(Color.accentColor)
    }
}

#Preview {
    ContentView()
}
