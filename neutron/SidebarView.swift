//
//  Sidebar.swift
//  neutron
//
//  Created by Dodge1 on 11/1/25.
//

import SwiftUI

enum FilePane {
    case left, right
}

struct SidebarItem: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let icon: String
    let url: URL?
    let type: Items
    
    enum Items {
        case cloud, drive, external, folder, yipee
    }
}

struct SidebarView: View {
//    @Binding var leftPath: URL
//    @Binding var rightPath: URL
//    @Binding var activePane: FilePane
//    
    @State private var selected: SidebarItem.ID?
    
    private let favorites: [SidebarItem] = [
        SidebarItem(name: "Recents", icon: "clock", url: nil, type: .yipee),
        SidebarItem(name: "Applications", icon: "app.specular", url: FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first, type: .folder),
        SidebarItem(name: "Desktop", icon: "menubar.dock.rectangle", url: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first, type: .folder),
        SidebarItem(name: "Documents", icon: "document", url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first, type: .folder),
        SidebarItem(name: "Downloads", icon: "arrow.down.circle", url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first, type: .folder),
        
    ]
    
    var body: some View {
        List {
            Section(content: {
                HStack {
                    Image(systemName: "clock")
                    Text("Recents")
                }
                HStack {
                    Image(systemName: "folder.badge.person.crop")
                    Text("Shared")
                }
            })
        }
        .listStyle(SidebarListStyle())
        .frame(minWidth: 20)
    }
}
