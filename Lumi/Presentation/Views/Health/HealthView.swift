//
//  HealthView.swift
//  LumiAgent
//
//  Apple Health panel — metric cards, mini-charts, and per-category AI analysis.
//

import SwiftUI
import Combine

// MARK: - Health Category

enum HealthCategory: String, CaseIterable, Identifiable {
    case activity  = "Activity"
    case heart     = "Heart"
    case body      = "Body"
    case sleep     = "Sleep"
    case workouts  = "Workouts"
    case vitals    = "Vitals"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .activity: return "figure.walk"
        case .heart:    return "heart.fill"
        case .body:     return "scalemass.fill"
        case .sleep:    return "bed.double.fill"
        case .workouts: return "dumbbell.fill"
        case .vitals:   return "waveform.path.ecg"
        }
    }

    var color: Color {
        switch self {
        case .activity: return .green
        case .heart:    return .red
        case .body:     return .blue
        case .sleep:    return .indigo
        case .workouts: return .orange
        case .vitals:   return .teal
        }
    }
}

// MARK: - Health Metric

struct HealthMetric: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let unit: String
    let icon: String
    let color: Color
    var date: Date = Date()
    var weeklyData: [(label: String, value: Double)] = []
}

#if os(macOS)
import AppKit
import HealthKit

// MARK: - Local Screen Time Tracker (Health fallback)

@MainActor
final class ScreenTimeTracker {
    static let shared = ScreenTimeTracker()

    private let workspace = NSWorkspace.shared
    private let center = NSWorkspace.shared.notificationCenter
    private let defaults = UserDefaults.standard
    private let isoFormatter = ISO8601DateFormatter()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var currentBundleID: String?
    private var currentAppName: String?
    private var segmentStart: Date?
    private var todaySeconds: TimeInterval = 0
    private var todayByApp: [String: Double] = [:]
    private var appNames: [String: String] = [:]
    private var dailyTotals: [String: Double] = [:]

    private enum Key {
        static let dayStartISO = "health.screenTime.dayStartISO"
        static let todaySeconds = "health.screenTime.todaySeconds"
        static let todayByApp = "health.screenTime.todayByApp"
        static let appNames = "health.screenTime.appNames"
        static let dailyTotals = "health.screenTime.dailyTotals"
    }

    private init() {
        loadPersisted()
        rotateDayIfNeeded(now: Date())
        bootstrapFrontmostApp()
        center.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appActivated(_ note: Notification) {
        rotateDayIfNeeded(now: Date())
        flushCurrentSegment(until: Date())

        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleID = app.bundleIdentifier
        else {
            currentBundleID = nil
            currentAppName = nil
            segmentStart = nil
            persist()
            return
        }

        currentBundleID = bundleID
        currentAppName = app.localizedName ?? bundleID
        appNames[bundleID] = currentAppName
        segmentStart = Date()
        persist()
    }

    func snapshot() -> (todaySeconds: TimeInterval, topAppName: String?, topAppSeconds: TimeInterval, weekly: [(String, Double)]) {
        rotateDayIfNeeded(now: Date())
        flushCurrentSegment(until: Date())

        let top = todayByApp.max(by: { $0.value < $1.value })
        let topName = top.flatMap { appNames[$0.key] ?? $0.key }
        let topSeconds = top?.value ?? 0
        let weekly = weeklyTotals()
        return (todaySeconds, topName, topSeconds, weekly)
    }

    private func bootstrapFrontmostApp() {
        if let app = workspace.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            currentBundleID = bundleID
            currentAppName = app.localizedName ?? bundleID
            appNames[bundleID] = currentAppName
            segmentStart = Date()
        }
    }

    private func rotateDayIfNeeded(now: Date) {
        let todayStart = Calendar.current.startOfDay(for: now)
        let storedStart = storedDayStart() ?? todayStart
        if !Calendar.current.isDate(storedStart, inSameDayAs: todayStart) {
            let previousKey = dayFormatter.string(from: storedStart)
            dailyTotals[previousKey] = todaySeconds
            todaySeconds = 0
            todayByApp = [:]
            defaults.set(isoFormatter.string(from: todayStart), forKey: Key.dayStartISO)
        } else if defaults.string(forKey: Key.dayStartISO) == nil {
            defaults.set(isoFormatter.string(from: todayStart), forKey: Key.dayStartISO)
        }
    }

    private func flushCurrentSegment(until now: Date) {
        guard let start = segmentStart, let bundleID = currentBundleID else { return }
        let delta = max(0, now.timeIntervalSince(start))
        guard delta > 0 else { return }
        todaySeconds += delta
        todayByApp[bundleID, default: 0] += delta
        segmentStart = now
        let todayKey = dayFormatter.string(from: now)
        dailyTotals[todayKey] = todaySeconds
        persist()
    }

    private func weeklyTotals() -> [(String, Double)] {
        let cal = Calendar.current
        var rows: [(String, Double)] = []
        for offset in (0..<7).reversed() {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = dayFormatter.string(from: day)
            let label = offset == 0 ? "Today" : cal.shortWeekdaySymbols[cal.component(.weekday, from: day) - 1]
            rows.append((label, dailyTotals[key] ?? 0))
        }
        return rows
    }

    private func storedDayStart() -> Date? {
        guard let iso = defaults.string(forKey: Key.dayStartISO) else { return nil }
        return isoFormatter.date(from: iso)
    }

    private func loadPersisted() {
        todaySeconds = defaults.double(forKey: Key.todaySeconds)
        todayByApp = defaults.dictionary(forKey: Key.todayByApp) as? [String: Double] ?? [:]
        appNames = defaults.dictionary(forKey: Key.appNames) as? [String: String] ?? [:]
        dailyTotals = defaults.dictionary(forKey: Key.dailyTotals) as? [String: Double] ?? [:]
    }

    private func persist() {
        defaults.set(todaySeconds, forKey: Key.todaySeconds)
        defaults.set(todayByApp, forKey: Key.todayByApp)
        defaults.set(appNames, forKey: Key.appNames)
        defaults.set(dailyTotals, forKey: Key.dailyTotals)
    }
}

// MARK: - HealthKit Manager

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private let screenTime = ScreenTimeTracker.shared

    @Published var isAvailable: Bool
    @Published var isAuthorized = false
    @Published var isLoading = false
    @Published var error: String?

    @Published var activityMetrics: [HealthMetric] = []
    @Published var heartMetrics: [HealthMetric] = []
    @Published var bodyMetrics: [HealthMetric] = []
    @Published var sleepMetrics: [HealthMetric] = []
    @Published var workoutMetrics: [HealthMetric] = []
    @Published var vitalsMetrics: [HealthMetric] = []

    @Published var analysisResults: [HealthCategory: String] = [:]
    @Published var analyzingCategory: HealthCategory?

    private init() {
        isAvailable = HKHealthStore.isHealthDataAvailable()
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        let quantityIds: [HKQuantityTypeIdentifier] = [
            .stepCount, .activeEnergyBurned, .appleExerciseTime,
            .flightsClimbed, .distanceWalkingRunning,
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
            .oxygenSaturation, .vo2Max,
            .bodyMass, .bodyMassIndex, .height,
            .respiratoryRate, .bloodPressureSystolic, .bloodPressureDiastolic
        ]
        let categoryIds: [HKCategoryTypeIdentifier] = [
            .sleepAnalysis, .mindfulSession, .appleStandHour
        ]
        for id in quantityIds {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        for id in categoryIds {
            if let t = HKCategoryType.categoryType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKObjectType.workoutType())
        return types
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() async {
        guard isAvailable else {
            error = "Apple Health is not available on this device."
            return
        }

        let status = await authorizationRequestStatus()
        switch status {
        case .shouldRequest, .unknown:
            await requestAuthorization()
        case .unnecessary:
            isAuthorized = true
            await loadAllMetrics()
        @unknown default:
            await requestAuthorization()
        }
    }

    func requestAuthorization() async {
        guard isAvailable else {
            error = "Apple Health is not available on this device."
            await loadAllMetrics()
            return
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            await loadAllMetrics()
        } catch {
            isAuthorized = false
            self.error = "Authorization failed: \(error.localizedDescription)"
            await loadAllMetrics()
        }
    }

    private func authorizationRequestStatus() async -> HKAuthorizationRequestStatus {
        await withCheckedContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { status, _ in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: - Load All

    func loadAllMetrics() async {
        isLoading = true
        error = nil

        // Fallback mode for macOS without HealthKit access: use local screen-time tracking.
        guard isAvailable && isAuthorized else {
            let fallback = loadScreenTimeFallbackMetrics()
            activityMetrics = fallback
            heartMetrics = []
            bodyMetrics = []
            sleepMetrics = []
            workoutMetrics = []
            vitalsMetrics = []
            isLoading = false
            return
        }

        async let a = loadActivityMetrics()
        async let h = loadHeartMetrics()
        async let b = loadBodyMetrics()
        async let s = loadSleepMetrics()
        async let w = loadWorkoutMetrics()
        async let v = loadVitalsMetrics()
        let (am, hm, bm, sm, wm, vm) = await (a, h, b, s, w, v)
        activityMetrics = am
        heartMetrics    = hm
        bodyMetrics     = bm
        sleepMetrics    = sm
        workoutMetrics  = wm
        vitalsMetrics   = vm
        isLoading = false
        isAuthorized = true
    }

    func metricsForCategory(_ category: HealthCategory) -> [HealthMetric] {
        switch category {
        case .activity: return activityMetrics
        case .heart:    return heartMetrics
        case .body:     return bodyMetrics
        case .sleep:    return sleepMetrics
        case .workouts: return workoutMetrics
        case .vitals:   return vitalsMetrics
        }
    }

    // MARK: - Activity

    private func loadActivityMetrics() async -> [HealthMetric] {
        var metrics: [HealthMetric] = loadScreenTimeFallbackMetrics()
        if let steps = await fetchDailySum(.stepCount, unit: .count()) {
            let weekly = await fetchWeeklySum(.stepCount, unit: .count())
            metrics.append(HealthMetric(name: "Steps", value: "\(Int(steps))", unit: "steps",
                                        icon: "figure.walk", color: .green, weeklyData: weekly))
        }
        if let energy = await fetchDailySum(.activeEnergyBurned, unit: .kilocalorie()) {
            let weekly = await fetchWeeklySum(.activeEnergyBurned, unit: .kilocalorie())
            metrics.append(HealthMetric(name: "Active Energy", value: "\(Int(energy))", unit: "kcal",
                                        icon: "flame.fill", color: .orange, weeklyData: weekly))
        }
        if let exercise = await fetchDailySum(.appleExerciseTime, unit: .minute()) {
            metrics.append(HealthMetric(name: "Exercise", value: "\(Int(exercise))", unit: "min",
                                        icon: "timer", color: .yellow))
        }
        if let flights = await fetchDailySum(.flightsClimbed, unit: .count()) {
            metrics.append(HealthMetric(name: "Floors Climbed", value: "\(Int(flights))", unit: "floors",
                                        icon: "arrow.up.right", color: .mint))
        }
        if let distance = await fetchDailySum(.distanceWalkingRunning, unit: .mile()) {
            metrics.append(HealthMetric(name: "Distance", value: String(format: "%.1f", distance), unit: "mi",
                                        icon: "map.fill", color: .teal))
        }
        return metrics
    }

    private func loadScreenTimeFallbackMetrics() -> [HealthMetric] {
        let snap = screenTime.snapshot()
        var metrics: [HealthMetric] = []
        metrics.append(
            HealthMetric(
                name: "Screen Time (Today)",
                value: formatDuration(snap.todaySeconds),
                unit: "",
                icon: "desktopcomputer",
                color: .purple,
                weeklyData: snap.weekly.map { ($0.0, $0.1 / 3600.0) }
            )
        )
        if let topAppName = snap.topAppName, snap.topAppSeconds > 0 {
            metrics.append(
                HealthMetric(
                    name: "Top App",
                    value: topAppName,
                    unit: "· \(formatDuration(snap.topAppSeconds))",
                    icon: "app.fill",
                    color: .indigo
                )
            )
        }
        return metrics
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds / 60)
        let h = mins / 60
        let m = mins % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - Heart

    private func loadHeartMetrics() async -> [HealthMetric] {
        var metrics: [HealthMetric] = []
        let bpmUnit = HKUnit(from: "count/min")
        if let hr = await fetchLatest(.heartRate, unit: bpmUnit) {
            let weekly = await fetchWeeklyAvg(.heartRate, unit: bpmUnit)
            metrics.append(HealthMetric(name: "Heart Rate", value: "\(Int(hr))", unit: "bpm",
                                        icon: "heart.fill", color: .red, weeklyData: weekly))
        }
        if let rhr = await fetchLatest(.restingHeartRate, unit: bpmUnit) {
            metrics.append(HealthMetric(name: "Resting HR", value: "\(Int(rhr))", unit: "bpm",
                                        icon: "heart", color: .pink))
        }
        if let hrv = await fetchLatest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)) {
            metrics.append(HealthMetric(name: "HRV", value: String(format: "%.0f", hrv), unit: "ms",
                                        icon: "waveform.path.ecg.rectangle.fill", color: .purple))
        }
        if let spo2 = await fetchLatest(.oxygenSaturation, unit: .percent()) {
            metrics.append(HealthMetric(name: "Blood Oxygen", value: String(format: "%.0f", spo2 * 100), unit: "%",
                                        icon: "drop.fill", color: .blue))
        }
        if let vo2 = await fetchLatest(.vo2Max, unit: HKUnit(from: "ml/kg·min")) {
            metrics.append(HealthMetric(name: "VO₂ Max", value: String(format: "%.1f", vo2), unit: "mL/kg/min",
                                        icon: "lungs.fill", color: .cyan))
        }
        return metrics
    }

    // MARK: - Body

    private func loadBodyMetrics() async -> [HealthMetric] {
        var metrics: [HealthMetric] = []
        if let weight = await fetchLatest(.bodyMass, unit: .pound()) {
            let weekly = await fetchWeeklyAvg(.bodyMass, unit: .pound())
            metrics.append(HealthMetric(name: "Weight", value: String(format: "%.1f", weight), unit: "lbs",
                                        icon: "scalemass.fill", color: .blue, weeklyData: weekly))
        }
        if let bmi = await fetchLatest(.bodyMassIndex, unit: .count()) {
            metrics.append(HealthMetric(name: "BMI", value: String(format: "%.1f", bmi), unit: "",
                                        icon: "person.crop.rectangle.fill", color: .indigo))
        }
        if let height = await fetchLatest(.height, unit: .foot()) {
            let feet = Int(height)
            let inches = Int((height - Double(feet)) * 12)
            metrics.append(HealthMetric(name: "Height", value: "\(feet)'\(inches)\"", unit: "",
                                        icon: "ruler.fill", color: .gray))
        }
        return metrics
    }

    // MARK: - Sleep

    private func loadSleepMetrics() async -> [HealthMetric] {
        var metrics: [HealthMetric] = []
        let (inBed, asleep, deep, rem) = await fetchSleepMinutes()
        func fmt(_ minutes: Double) -> String {
            let h = Int(minutes / 60), m = Int(minutes) % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
        if inBed > 0 {
            metrics.append(HealthMetric(name: "Time in Bed", value: fmt(inBed), unit: "",
                                        icon: "bed.double.fill", color: .indigo))
        }
        if asleep > 0 {
            metrics.append(HealthMetric(name: "Sleep", value: fmt(asleep), unit: "",
                                        icon: "moon.zzz.fill", color: .purple))
        }
        if deep > 0 {
            metrics.append(HealthMetric(name: "Deep Sleep", value: fmt(deep), unit: "",
                                        icon: "moon.fill", color: .blue))
        }
        if rem > 0 {
            metrics.append(HealthMetric(name: "REM Sleep", value: fmt(rem), unit: "",
                                        icon: "sparkles", color: .cyan))
        }
        let mindful = await fetchMindfulMinutes()
        if mindful > 0 {
            metrics.append(HealthMetric(name: "Mindful (7d)", value: "\(Int(mindful))", unit: "min",
                                        icon: "brain.head.profile", color: .mint))
        }
        return metrics
    }

    // MARK: - Workouts

    private func loadWorkoutMetrics() async -> [HealthMetric] {
        let workouts = await fetchRecentWorkouts(limit: 10)
        return workouts.map { w in
            let duration = Int(w.duration / 60)
            let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            return HealthMetric(
                name: w.workoutActivityType.displayName,
                value: "\(duration) min",
                unit: energy > 0 ? "· \(Int(energy)) kcal" : "",
                icon: w.workoutActivityType.sfSymbol,
                color: .orange,
                date: w.startDate
            )
        }
    }

    // MARK: - Vitals

    private func loadVitalsMetrics() async -> [HealthMetric] {
        var metrics: [HealthMetric] = []
        let bpmUnit = HKUnit(from: "count/min")
        if let rr = await fetchLatest(.respiratoryRate, unit: bpmUnit) {
            metrics.append(HealthMetric(name: "Respiratory Rate", value: "\(Int(rr))", unit: "breaths/min",
                                        icon: "lungs.fill", color: .teal))
        }
        if let sys = await fetchLatest(.bloodPressureSystolic, unit: .millimeterOfMercury()),
           let dia = await fetchLatest(.bloodPressureDiastolic, unit: .millimeterOfMercury()) {
            metrics.append(HealthMetric(name: "Blood Pressure", value: "\(Int(sys))/\(Int(dia))", unit: "mmHg",
                                        icon: "heart.text.square.fill", color: .red))
        }
        return metrics
    }

    // MARK: - HK Helpers

    private func fetchDailySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        let pred  = HKQuery.predicateForSamples(withStart: start, end: Date())
        return await withCheckedContinuation { cont in
            let q = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
                cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    private func fetchLatest(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: qType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                cont.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    private func fetchWeeklySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> [(label: String, value: Double)] {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        var results: [(String, Double)] = []
        for offset in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let start = calendar.startOfDay(for: day)
            let end   = calendar.date(byAdding: .day, value: 1, to: start) ?? day
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end)
            let label = offset == 0 ? "Today" : calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
            let value: Double = await withCheckedContinuation { cont in
                let q = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: pred, options: .cumulativeSum) { _, stats, _ in
                    cont.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
                }
                store.execute(q)
            }
            results.append((label, value))
        }
        return results
    }

    private func fetchWeeklyAvg(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> [(label: String, value: Double)] {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        var results: [(String, Double)] = []
        for offset in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let start = calendar.startOfDay(for: day)
            let end   = calendar.date(byAdding: .day, value: 1, to: start) ?? day
            let pred  = HKQuery.predicateForSamples(withStart: start, end: end)
            let label = offset == 0 ? "Today" : calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
            let value: Double = await withCheckedContinuation { cont in
                let q = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: pred, options: .discreteAverage) { _, stats, _ in
                    cont.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit) ?? 0)
                }
                store.execute(q)
            }
            results.append((label, value))
        }
        return results
    }

    private func fetchSleepMinutes() async -> (inBed: Double, asleep: Double, deep: Double, rem: Double) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return (0, 0, 0, 0)
        }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
        let pred = HKQuery.predicateForSamples(withStart: yesterday, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: sleepType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        var inBed = 0.0, asleep = 0.0, deep = 0.0, rem = 0.0
        for sample in samples {
            let mins = sample.endDate.timeIntervalSince(sample.startDate) / 60
            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBed += mins
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deep += mins; asleep += mins
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                rem += mins; asleep += mins
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                 HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                asleep += mins
            default:
                // Legacy "asleep" value (1) from pre-iOS 16 data
                if sample.value == 1 { asleep += mins }
            }
        }
        return (inBed, asleep, deep, rem)
    }

    private func fetchMindfulMinutes() async -> Double {
        guard let mindfulType = HKCategoryType.categoryType(forIdentifier: .mindfulSession) else { return 0 }
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let pred = HKQuery.predicateForSamples(withStart: weekAgo, end: Date())
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: mindfulType, predicate: pred, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, s, _ in
                cont.resume(returning: (s as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }
        return samples.reduce(0) { $0 + $1.endDate.timeIntervalSince($1.startDate) / 60 }
    }

    private func fetchRecentWorkouts(limit: Int) async -> [HKWorkout] {
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: .workoutType(), predicate: nil, limit: limit, sortDescriptors: [sort]) { _, s, _ in
                cont.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    // MARK: - AI Analysis

    func analyzeCategory(_ category: HealthCategory, agent: Agent?) async {
        analyzingCategory = category
        defer { analyzingCategory = nil }

        let metrics = metricsForCategory(category)
        guard !metrics.isEmpty else {
            analysisResults[category] = "No health data available for \(category.rawValue). Connect your iPhone or Apple Watch to sync data."
            return
        }

        let dataLines = metrics.map { m -> String in
            let unitStr = m.unit.isEmpty ? "" : " \(m.unit)"
            return "  • \(m.name): \(m.value)\(unitStr)"
        }.joined(separator: "\n")

        let weeklyContext: String = {
            let withWeekly = metrics.filter { !$0.weeklyData.isEmpty }
            guard !withWeekly.isEmpty else { return "" }
            let lines = withWeekly.map { m -> String in
                let pts = m.weeklyData.map { "\($0.label): \(Int($0.value))" }.joined(separator: ", ")
                return "  • \(m.name) (7-day): \(pts)"
            }.joined(separator: "\n")
            return "\n\nWeekly trends:\n\(lines)"
        }()

        let prompt = """
        You are a knowledgeable health and wellness coach. Analyze the following health data and provide personalized, actionable feedback.

        Category: \(category.rawValue)
        Date: \(Date().formatted(date: .long, time: .omitted))

        Today's metrics:
        \(dataLines)\(weeklyContext)

        Please provide:
        1. A brief summary of what these numbers indicate
        2. What's going well
        3. Specific, actionable improvements (not generic advice)
        4. Any patterns worth noting from the weekly trends
        5. One concrete goal to focus on this week

        Keep it concise (3–4 paragraphs), encouraging, and practical. Always remind the user to consult a healthcare professional for medical concerns.
        """

        let repo = AIProviderRepository()
        let provider: AIProvider
        let model: String

        if let agent {
            provider = agent.configuration.provider
            model    = agent.configuration.model
        } else if (try? repo.getAPIKey(for: .openai)).flatMap({ $0.isEmpty ? nil : $0 }) != nil {
            provider = .openai
            model    = "gpt-4o"
        } else if (try? repo.getAPIKey(for: .anthropic)).flatMap({ $0.isEmpty ? nil : $0 }) != nil {
            provider = .anthropic
            model    = "claude-sonnet-4-6"
        } else if (try? repo.getAPIKey(for: .gemini)).flatMap({ $0.isEmpty ? nil : $0 }) != nil {
            provider = .gemini
            model    = "gemini-3.1-pro"
        } else {
            provider = .ollama
            model    = "llama3.2:latest"
        }

        do {
            let response = try await repo.sendMessage(
                provider: provider, model: model,
                messages: [AIMessage(role: .user, content: prompt)],
                systemPrompt: "You are a health and wellness coach. Provide personalized, evidence-based insights."
            )
            analysisResults[category] = response.content ?? "No analysis generated."
        } catch {
            analysisResults[category] = "Analysis failed: \(error.localizedDescription)\n\nCheck your AI provider settings."
        }
    }
}

// MARK: - HKWorkoutActivityType Extensions

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running:          return "Running"
        case .walking:          return "Walking"
        case .cycling:          return "Cycling"
        case .swimming:         return "Swimming"
        case .yoga:             return "Yoga"
        case .hiking:           return "Hiking"
        case .functionalStrengthTraining, .traditionalStrengthTraining:
                                return "Strength Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .pilates:          return "Pilates"
        case .dance:            return "Dance"
        case .soccer:           return "Soccer"
        case .basketball:       return "Basketball"
        case .tennis:           return "Tennis"
        case .rowing:           return "Rowing"
        case .elliptical:       return "Elliptical"
        case .stairClimbing:    return "Stair Climbing"
        case .crossTraining:    return "Cross Training"
        default:                return "Workout"
        }
    }

    var sfSymbol: String {
        switch self {
        case .running:          return "figure.run"
        case .walking:          return "figure.walk"
        case .cycling:          return "figure.outdoor.cycle"
        case .swimming:         return "figure.pool.swim"
        case .yoga:             return "figure.mind.and.body"
        case .hiking:           return "figure.hiking"
        case .functionalStrengthTraining, .traditionalStrengthTraining:
                                return "dumbbell.fill"
        case .highIntensityIntervalTraining: return "bolt.fill"
        case .pilates:          return "figure.pilates"
        case .dance:            return "music.note"
        default:                return "figure.mixed.cardio"
        }
    }
}

// MARK: - Health List View (Sidebar content panel)

struct HealthListView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var hk = HealthKitManager.shared

    var body: some View {
        Group {
            List(selection: $appState.selectedHealthCategory) {
                if !hk.isAvailable {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Apple Health unavailable on this build", systemImage: "heart.slash")
                                .font(.headline)
                            Text("Using local screen-time tracking for Activity insights.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                if hk.isAvailable && !hk.isAuthorized {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Allow Apple Health Access")
                                .font(.headline)
                            Text("Grant permission to read your health data from iPhone/Apple Watch.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await hk.requestAuthorization() }
                            } label: {
                                Label("Request Access", systemImage: "heart.text.square.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section {
                    ForEach(HealthCategory.allCases) { category in
                        HealthCategoryRow(
                            category: category,
                            metricCount: hk.metricsForCategory(category).count,
                            isLoading: hk.isLoading
                        )
                        .tag(category)
                    }
                }
            }
            .navigationTitle("Health")
            .toolbar {
                ToolbarItemGroup {
                    if hk.isLoading {
                        ProgressView().scaleEffect(0.7)
                    }
                    Button {
                        Task {
                            if hk.isAuthorized {
                                await hk.loadAllMetrics()
                            } else if hk.isAvailable {
                                await hk.requestAuthorizationIfNeeded()
                            } else {
                                await hk.loadAllMetrics()
                            }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(hk.isLoading)
                }
            }
        }
        .task {
            if hk.isAuthorized {
                await hk.loadAllMetrics()
            } else if hk.isAvailable {
                await hk.requestAuthorizationIfNeeded()
            } else {
                await hk.loadAllMetrics()
            }
        }
    }
}

private struct HealthCategoryRow: View {
    let category: HealthCategory
    let metricCount: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(category.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: category.icon)
                    .font(.callout)
                    .foregroundStyle(category.color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .font(.callout)
                    .fontWeight(.medium)
                Group {
                    if isLoading {
                        Text("Loading…")
                    } else if metricCount == 0 {
                        Text("No data")
                    } else {
                        Text("\(metricCount) metric\(metricCount == 1 ? "" : "s")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Health Detail View

struct HealthDetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var hk = HealthKitManager.shared

    var body: some View {
        if let category = appState.selectedHealthCategory {
            let agent = appState.selectedAgentId.flatMap { id in appState.agents.first { $0.id == id } }
            HealthCategoryDetailView(
                category: category,
                metrics: hk.metricsForCategory(category),
                isLoading: hk.isLoading,
                analysis: hk.analysisResults[category],
                isAnalyzing: hk.analyzingCategory == category,
                onAnalyze: {
                    Task { await hk.analyzeCategory(category, agent: agent) }
                },
                onClearAnalysis: {
                    hk.analysisResults.removeValue(forKey: category)
                }
            )
        } else {
            EmptyDetailView(message: "Select a health category")
        }
    }
}

// MARK: - Category Detail View

struct HealthCategoryDetailView: View {
    let category: HealthCategory
    let metrics: [HealthMetric]
    let isLoading: Bool
    let analysis: String?
    let isAnalyzing: Bool
    let onAnalyze: () -> Void
    let onClearAnalysis: () -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ────────────────────────────────────────────────
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(category.color.opacity(0.15))
                            .frame(width: 52, height: 52)
                        Image(systemName: category.icon)
                            .font(.title2)
                            .foregroundStyle(category.color)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.rawValue)
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text(Date().formatted(date: .long, time: .omitted))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onAnalyze) {
                        if isAnalyzing {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.75)
                                Text("Analyzing…")
                            }
                        } else {
                            Label(analysis == nil ? "AI Analysis" : "Re-analyze", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAnalyzing || metrics.isEmpty)
                    .tint(category.color)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider()

                // ── Metrics grid ──────────────────────────────────────────
                Group {
                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading health data…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else if metrics.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No \(category.rawValue) data")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("Make sure your iPhone or Apple Watch is syncing to Apple Health.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    } else {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(metrics) { metric in
                                HealthMetricCard(metric: metric, category: category)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 10)
                    }
                }

                // ── AI Analysis ───────────────────────────────────────────
                if isAnalyzing {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.75)
                        Text("Analyzing your \(category.rawValue.lowercased()) data with AI…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }

                if let analysis, !analysis.isEmpty {
                    Divider()
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(category.color)
                            Text("AI Health Insight")
                                .font(.headline)
                            Spacer()
                            Button {
                                onClearAnalysis()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Text(analysis)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(category.color.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(category.color.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }

                Spacer(minLength: 28)
            }
        }
    }
}

// MARK: - Health Metric Card

struct HealthMetricCard: View {
    let metric: HealthMetric
    let category: HealthCategory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Icon + date (for workouts)
            HStack {
                Image(systemName: metric.icon)
                    .font(.callout)
                    .foregroundStyle(metric.color)
                Spacer()
                if Calendar.current.isDateInToday(metric.date) == false && metric.date < Date().addingTimeInterval(-86400) {
                    Text(metric.date.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Value + unit
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(metric.value)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(metric.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(metric.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Mini bar chart
            if !metric.weeklyData.isEmpty {
                HealthMiniChart(data: metric.weeklyData, color: metric.color)
                    .frame(height: 30)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(metric.color.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Mini Bar Chart

struct HealthMiniChart: View {
    let data: [(label: String, value: Double)]
    let color: Color

    private var maxVal: Double { data.map(\.value).max() ?? 1 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data.indices, id: \.self) { i in
                let item = data[i]
                let ratio = maxVal > 0 ? item.value / maxVal : 0
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i == data.count - 1 ? color : color.opacity(0.35))
                    .frame(height: max(2, CGFloat(ratio) * 30))
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: data.map(\.value))
    }
}
#endif
