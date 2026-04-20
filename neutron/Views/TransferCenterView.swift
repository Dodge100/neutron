import SwiftUI

struct TransferCenterView: View {
    var body: some View {
        TabView {
            DownloadManagerPanelView()
                .tabItem {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }

            CLIToolsPanelView()
                .tabItem {
                    Label("Media & Torrents", systemImage: "dot.radiowaves.left.and.right")
                }
        }
        .frame(minWidth: 420, minHeight: 520)
    }
}

#Preview {
    TransferCenterView()
}
