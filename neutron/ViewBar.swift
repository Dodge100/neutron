//
//  ViewBar.swift
//  neutron
//
//  Created by Dodge1 on 11/1/25.
//
import SwiftUI

struct ViewBar: View {
    @Binding var viewMode: String
    
    var body: some View {
        HStack {
            HStack {
                Button(action:{}) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                
                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)
                
                Button(action:{}) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .clipShape(Capsule())
            .background(Color.white.opacity(0.1))
            .cornerRadius(20)
            
            Text("Desktop")
                .font(.system(size: 14))
                .foregroundColor(.white)
                .padding(.leading, 4)
            
            Spacer()
            
            HStack() {
                ForEach(["grid","list","columns", "gallery"], id: \.self) { mode in Button(action: { viewMode = mode }) {
                    Image(systemName: icon(for: mode))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            Group {
                                if viewMode == mode {
                                    Circle().fill(Color.white.opacity(0.25))
                                }
                            }
                        )
                }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .clipShape(Capsule())
            Button(action: {}) {
                HStack {
                    Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    Image(systemName: "chevron.down")
                }
            }
        }
    }
    
    
    private func icon(for mode:String) -> String {
        switch mode {
        case "grid": return "square.grid.2x2"
        case "list": return "list.bullet"
        case "columns": return "rectangle.split.3x1"
        case "gallery": return "rectangle.grid.3x1"
        default: return "list.bullet"
        }
    }
}
