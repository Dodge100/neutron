//
//  SettingsView.swift
//  neutron
//
//  Created by Dodge1 on 12/15/25.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Tags", systemImage: "tag") {
                GeneralSettingsView()
            }
            Tab("Cloud", systemImage: "cloud") {
                GeneralSettingsView()
            }
            Tab("Sidebar", systemImage: "sidebar.left") {
                GeneralSettingsView()
            }
            Tab("Advanced", systemImage: "gearshape.2") {
                GeneralSettingsView()
            }
        }
        .scenePadding()
        .frame(maxWidth: 350, minHeight: 100)
    }
}

struct GeneralSettingsView: View {
    @State var yes = true
    var body: some View {
        Toggle("Open folders in tabs instead of new windows", isOn: $yes).toggleStyle(.checkbox)
    }
}
