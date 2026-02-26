//
//  AutomationRule.swift
//  LumiAgent
//
//  Data model for an automation rule with freeform task notes and event triggers.
//

import Foundation

// MARK: - Repeat Schedule

enum RepeatSchedule: String, Codable, CaseIterable, Identifiable {
    case once     = "Once"
    case daily    = "Daily"
    case weekdays = "Weekdays"
    case weekly   = "Weekly"
    case monthly  = "Monthly"

    var id: String { rawValue }
}

// MARK: - Automation Trigger

enum AutomationTrigger: Codable, Equatable {
    /// User manually triggers via "Run Now"
    case manual
    /// Time-based trigger at a fixed hour:minute
    case scheduled(hour: Int, minute: Int, schedule: RepeatSchedule)
    /// When a specific app launches
    case appLaunched(name: String)
    /// When a specific app quits
    case appQuit(name: String)
    /// When a Bluetooth device connects
    case bluetoothConnected(deviceName: String)
    /// When a Bluetooth device disconnects
    case bluetoothDisconnected(deviceName: String)
    /// When joining a specific Wi-Fi network
    case wifiConnected(ssid: String)
    /// When power adapter is plugged in
    case powerPlugged
    /// When power adapter is unplugged
    case powerUnplugged
    /// When the screen is unlocked
    case screenUnlocked

    var displayName: String {
        switch self {
        case .manual:                  return "Manual"
        case .scheduled:               return "Scheduled"
        case .appLaunched:             return "App Launched"
        case .appQuit:                 return "App Quit"
        case .bluetoothConnected:      return "Bluetooth Connected"
        case .bluetoothDisconnected:   return "Bluetooth Disconnected"
        case .wifiConnected:           return "Wi-Fi Connected"
        case .powerPlugged:            return "Power Plugged In"
        case .powerUnplugged:          return "Power Unplugged"
        case .screenUnlocked:          return "Screen Unlocked"
        }
    }

    var icon: String {
        switch self {
        case .manual:                  return "hand.tap"
        case .scheduled:               return "clock"
        case .appLaunched:             return "app.badge"
        case .appQuit:                 return "xmark.app"
        case .bluetoothConnected:      return "antenna.radiowaves.left.and.right"
        case .bluetoothDisconnected:   return "antenna.radiowaves.left.and.right.slash"
        case .wifiConnected:           return "wifi"
        case .powerPlugged:            return "bolt.fill"
        case .powerUnplugged:          return "bolt.slash"
        case .screenUnlocked:          return "lock.open"
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, hour, minute, schedule, name, deviceName, ssid
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try c.encode("manual", forKey: .type)
        case .scheduled(let h, let m, let s):
            try c.encode("scheduled", forKey: .type)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
            try c.encode(s, forKey: .schedule)
        case .appLaunched(let n):
            try c.encode("appLaunched", forKey: .type)
            try c.encode(n, forKey: .name)
        case .appQuit(let n):
            try c.encode("appQuit", forKey: .type)
            try c.encode(n, forKey: .name)
        case .bluetoothConnected(let d):
            try c.encode("bluetoothConnected", forKey: .type)
            try c.encode(d, forKey: .deviceName)
        case .bluetoothDisconnected(let d):
            try c.encode("bluetoothDisconnected", forKey: .type)
            try c.encode(d, forKey: .deviceName)
        case .wifiConnected(let s):
            try c.encode("wifiConnected", forKey: .type)
            try c.encode(s, forKey: .ssid)
        case .powerPlugged:
            try c.encode("powerPlugged", forKey: .type)
        case .powerUnplugged:
            try c.encode("powerUnplugged", forKey: .type)
        case .screenUnlocked:
            try c.encode("screenUnlocked", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "manual":
            self = .manual
        case "scheduled":
            let h = try c.decode(Int.self, forKey: .hour)
            let m = try c.decode(Int.self, forKey: .minute)
            let s = try c.decode(RepeatSchedule.self, forKey: .schedule)
            self = .scheduled(hour: h, minute: m, schedule: s)
        case "appLaunched":
            self = .appLaunched(name: try c.decode(String.self, forKey: .name))
        case "appQuit":
            self = .appQuit(name: try c.decode(String.self, forKey: .name))
        case "bluetoothConnected":
            self = .bluetoothConnected(deviceName: try c.decode(String.self, forKey: .deviceName))
        case "bluetoothDisconnected":
            self = .bluetoothDisconnected(deviceName: try c.decode(String.self, forKey: .deviceName))
        case "wifiConnected":
            self = .wifiConnected(ssid: try c.decode(String.self, forKey: .ssid))
        case "powerPlugged":
            self = .powerPlugged
        case "powerUnplugged":
            self = .powerUnplugged
        case "screenUnlocked":
            self = .screenUnlocked
        default:
            self = .manual
        }
    }
}

// MARK: - Automation Rule

struct AutomationRule: Identifiable, Codable {
    var id: UUID
    var title: String
    /// Freeform description of what the agent should do — agents read this to infer the workflow.
    var notes: String
    var trigger: AutomationTrigger
    var agentId: UUID?
    var isEnabled: Bool
    var lastRunAt: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "New Automation",
        notes: String = "",
        trigger: AutomationTrigger = .manual,
        agentId: UUID? = nil,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.trigger = trigger
        self.agentId = agentId
        self.isEnabled = isEnabled
        self.lastRunAt = nil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New Automation"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        trigger = try container.decodeIfPresent(AutomationTrigger.self, forKey: .trigger) ?? .manual
        agentId = try container.decodeIfPresent(UUID.self, forKey: .agentId)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
