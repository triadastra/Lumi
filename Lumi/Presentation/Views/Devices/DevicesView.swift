//
//  DevicesView.swift
//  LumiAgent
//
//  Displays connected and paired mobile devices (iPhone/iPad).
//

#if os(macOS)
import SwiftUI

// MARK: - Devices List View

struct DevicesListView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDeviceID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(appState.remoteServer.connectedClients, selection: $selectedDeviceID) { client in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "iphone")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(client.name)
                            .font(.callout)
                            .fontWeight(.medium)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .tag(client.id)
            }
            .listStyle(.sidebar)
            
            Divider()
            
            // Server Status
            VStack(spacing: 8) {
                HStack {
                    Circle()
                        .fill(appState.remoteServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(appState.remoteServer.isRunning ? "Lumi Server Online" : "Lumi Server Offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !appState.remoteServer.isRunning {
                        Button("Start Server") {
                            appState.remoteServer.start()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                
                if appState.isUSBDeviceConnected {
                    HStack {
                        Image(systemName: "cable.connector")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Text("USB Device Detected")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        Spacer()
                        if !appState.remoteServer.connectedClients.isEmpty {
                            Button("Sync Now") {
                                // Sync is usually initiated by phone, but we show it here for UX
                                print("[DevicesView] Manual sync requested via USB")
                            }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))
        }
        .navigationTitle("Devices")
    }
}

// MARK: - Devices Detail View

struct DevicesDetailView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 56))
                    .foregroundStyle(.blue.gradient)
                    .shadow(color: .blue.opacity(0.2), radius: 10, x: 0, y: 5)
                
                VStack(spacing: 8) {
                    Text("Device Connectivity")
                        .font(.title2.bold())
                    Text("Pair your iPhone to control this Mac remotely and sync your AI Agents.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 560)
                
                VStack(alignment: .leading, spacing: 14) {
                    FeatureRow(icon: "wifi", title: "Same Wi-Fi", detail: "Ensure both devices are on the same local network.")
                    FeatureRow(icon: "cable.connector", title: "Cable/Port Link", detail: "USB-C/Thunderbolt/Ethernet direct links are supported via direct host connect.")
                    FeatureRow(icon: "lock.shield", title: "Secure Sync", detail: "Encrypted peer-to-peer data transfer for your agents.")
                    FeatureRow(icon: "bolt.fill", title: "Remote Control", detail: "Control volume, brightness, and run scripts from your phone.")
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(20)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
    
                VStack(alignment: .leading, spacing: 8) {
                    Text("Direct Connect Addresses")
                        .font(.headline)
                    ForEach(appState.remoteServer.connectionHints(), id: \.self) { hint in
                        Text(hint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Use one of these in iOS Remote → Direct Connect when discovery does not appear over cable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
    
                if !appState.remoteServer.pendingApprovals.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connection Requests")
                            .font(.headline)
    
                        ForEach(appState.remoteServer.pendingApprovals) { req in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(req.name).font(.subheadline.bold())
                                    Text(req.address).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Reject", role: .destructive) {
                                    appState.remoteServer.rejectConnection(req.id)
                                }
                                .buttonStyle(.bordered)
                                Button("Accept") {
                                    appState.remoteServer.approveConnection(req.id)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                }
                
                if appState.remoteServer.connectedClients.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for connection...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title)
                        Text("\(appState.remoteServer.connectedClients.count) device(s) linked")
                            .font(.headline)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
