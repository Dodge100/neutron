//
//  ContentView.swift
//  neutron
//
//  Created by Dodge1 on 10/31/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            SidebarView()
//            ViewBar(viewMode: $viewMode)
        }
        .toolbar(id:"toolbar") {
            ToolbarItem(id:"nav", placement: .navigation) {
                Section(content: {
                    Button( "Back", systemImage: "chevron.left" ) {}
                    Button( "Forward", systemImage: "chevron.right" ) {}
                })
            }
            ToolbarItem(id:"group") {
                Button( "Group", systemImage: "square.grid.3x1.below.line.grid.1x2" ) {}
            }
//            ToolbarItem(id:"view") {
//                Section(content: {
//                    Button( "Icons", systemImage: "square.grid.2x2" ) {}
//                    Button( "List", systemImage: "list.bullet" ) {}
//                    Button( "Columns", systemImage: "rectangle.split.3x1" ) {}
//                })
//            }
            ToolbarItem(id: "space" ) {
                Spacer()
            }
            ToolbarItem(id: "newFolder" ) {
                Button( "New Folder", systemImage: "folder.badge.plus" ) {}
            }
            ToolbarItem(id: "delete" ) {
                Button( "Delete", systemImage: "trash", role:.destructive ) {}
            }
            ToolbarItem(id: "connect" ) {
                Button( "Connect", systemImage: "externaldrive" ) {}
            }
            ToolbarItem(id: "search" ) {
                Button( "Search", systemImage: "magnifyingglass" ) {}
            }
            ToolbarItem(id: "share" ) {
                Button( "Share", systemImage: "square.and.arrow.up" ) {}
            }
            ToolbarItem(id: "editTags" ) {
                Button( "Edit Tags", systemImage: "tag" ) {}
            }
        }
    }
}

#Preview {
    ContentView()
}
