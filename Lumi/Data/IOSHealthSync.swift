import Foundation
import Combine
import HealthKit

// MARK: - Health Sync DTOs
// These are available on both iOS and macOS to facilitate data transfer.

public struct HealthMetricDTO: Codable, Identifiable {
    public var id: UUID
    public let name: String
    public let value: String
    public let unit: String
    public let icon: String
    public let colorName: String
    public var date: Date
    public var weeklyData: [WeeklyDataPointDTO]

    public init(id: UUID = UUID(), name: String, value: String, unit: String, icon: String, colorName: String, date: Date = Date(), weeklyData: [WeeklyDataPointDTO] = []) {
        self.id = id
        self.name = name
        self.value = value
        self.unit = unit
        self.icon = icon
        self.colorName = colorName
        self.date = date
        self.weeklyData = weeklyData
    }
}

public struct WeeklyDataPointDTO: Codable {
    public let label: String
    public let value: Double

    public init(label: String, value: Double) {
        self.label = label
        self.value = value
    }
}

public struct HealthSyncData: Codable {
    public var activity: [HealthMetricDTO] = []
    public var heart: [HealthMetricDTO] = []
    public var body: [HealthMetricDTO] = []
    public var sleep: [HealthMetricDTO] = []
    public var workouts: [HealthMetricDTO] = []
    public var vitals: [HealthMetricDTO] = []
    public var updatedAt: Date = Date()
    
    public init() {}
}

// MARK: - iOS HealthKit Manager
// Only compiled on iOS as macOS uses this to decode data, not to fetch from HealthKit.

#if os(iOS)
@MainActor
public final class IOSHealthKitManager: ObservableObject {
    public static let shared = IOSHealthKitManager()

    private let store = HKHealthStore()
    private let syncFileName = "health_data.json"
    @Published public var isAuthorized = false
    @Published public var error: String?

    /// Cached sync data ready for immediate transfer, avoiding semaphore deadlocks.
    public private(set) var cachedSyncData: Data?

    private init() {
        cachedSyncData = loadPersistedSyncData()
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
            .sleepAnalysis, .mindfulSession
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

    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "HealthKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit is not available on this device."])
        }
        // Verify the required Info.plist keys exist before calling the API.
        // Without these, HealthKit throws an uncatchable NSException that crashes the app.
        guard Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") != nil else {
            self.error = "HealthKit requires NSHealthShareUsageDescription in Info.plist. Add it in Xcode under your target's Info tab."
            throw NSError(domain: "HealthKit", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing NSHealthShareUsageDescription in Info.plist."])
        }
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
        } catch {
            isAuthorized = false
            throw error
        }
    }

    public func fetchSyncData() async -> HealthSyncData {
        await refreshAuthorizationState()
        guard isAuthorized else {
            if let cached = cachedOrPersistedSyncData(),
               let decoded = try? JSONDecoder().decode(HealthSyncData.self, from: cached) {
                return decoded
            }
            return HealthSyncData()
        }
        
        async let a = loadActivityMetrics()
        async let h = loadHeartMetrics()
        async let b = loadBodyMetrics()
        async let s = loadSleepMetrics()
        async let w = loadWorkoutMetrics()
        async let v = loadVitalsMetrics()
        let (am, hm, bm, sm, wm, vm) = await (a, h, b, s, w, v)
        
        var data = HealthSyncData()
        data.activity = am
        data.heart = hm
        data.body = bm
        data.sleep = sm
        data.workouts = wm
        data.vitals = vm
        data.updatedAt = Date()
        return data
    }

    /// Fetches all health data and caches the encoded JSON so the next sync can grab it instantly.
    public func prefetchAndCacheSync() async {
        let syncData = await fetchSyncData()
        guard let encoded = try? JSONEncoder().encode(syncData) else { return }
        cachedSyncData = encoded
        persistSyncData(encoded)
    }

    /// Returns cached sync JSON if available, otherwise attempts to load it from disk.
    public func cachedOrPersistedSyncData() -> Data? {
        if let cachedSyncData { return cachedSyncData }
        let persisted = loadPersistedSyncData()
        cachedSyncData = persisted
        return persisted
    }

    /// Updates in-memory and on-disk sync JSON payloads (used when data is pulled from Mac).
    public func updateCachedSyncData(_ data: Data) {
        cachedSyncData = data
        persistSyncData(data)
    }

    /// Exports a fresh health JSON snapshot to Documents so the user can access it in Files.
    public func exportSyncSnapshotToDocuments() async throws -> URL {
        await prefetchAndCacheSync()
        guard let payload = cachedOrPersistedSyncData() else {
            throw NSError(
                domain: "HealthKit",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "No health JSON available to export."]
            )
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = docs.appendingPathComponent("LumiAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "health_data_\(formatter.string(from: Date())).json"
        let targetURL = folder.appendingPathComponent(fileName)
        try payload.write(to: targetURL, options: .atomic)
        return targetURL
    }

    private func refreshAuthorizationState() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            isAuthorized = false
            return
        }
        let status: HKAuthorizationRequestStatus = await withCheckedContinuation { cont in
            store.getRequestStatusForAuthorization(toShare: [], read: readTypes) { requestStatus, _ in
                cont.resume(returning: requestStatus)
            }
        }
        isAuthorized = (status == .unnecessary)
    }

    private func persistSyncData(_ data: Data) {
        try? data.write(to: syncFileURL(), options: .atomic)
    }

    private func loadPersistedSyncData() -> Data? {
        try? Data(contentsOf: syncFileURL())
    }

    private func syncFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("LumiAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(syncFileName)
    }

    // MARK: - Activity
    private func loadActivityMetrics() async -> [HealthMetricDTO] {
        var metrics: [HealthMetricDTO] = []
        if let steps = await fetchDailySum(.stepCount, unit: .count()) {
            let weekly = await fetchWeeklySum(.stepCount, unit: .count())
            metrics.append(HealthMetricDTO(name: "Steps", value: "\(Int(steps))", unit: "steps", icon: "figure.walk", colorName: "green", weeklyData: weekly))
        }
        if let energy = await fetchDailySum(.activeEnergyBurned, unit: .kilocalorie()) {
            let weekly = await fetchWeeklySum(.activeEnergyBurned, unit: .kilocalorie())
            metrics.append(HealthMetricDTO(name: "Active Energy", value: "\(Int(energy))", unit: "kcal", icon: "flame.fill", colorName: "orange", weeklyData: weekly))
        }
        if let exercise = await fetchDailySum(.appleExerciseTime, unit: .minute()) {
            metrics.append(HealthMetricDTO(name: "Exercise", value: "\(Int(exercise))", unit: "min", icon: "timer", colorName: "yellow"))
        }
        if let flights = await fetchDailySum(.flightsClimbed, unit: .count()) {
            metrics.append(HealthMetricDTO(name: "Floors Climbed", value: "\(Int(flights))", unit: "floors", icon: "arrow.up.right", colorName: "mint"))
        }
        if let distance = await fetchDailySum(.distanceWalkingRunning, unit: .mile()) {
            metrics.append(HealthMetricDTO(name: "Distance", value: String(format: "%.1f", distance), unit: "mi", icon: "map.fill", colorName: "teal"))
        }
        return metrics
    }

    // MARK: - Heart
    private func loadHeartMetrics() async -> [HealthMetricDTO] {
        var metrics: [HealthMetricDTO] = []
        let bpmUnit = HKUnit(from: "count/min")
        if let hr = await fetchLatest(.heartRate, unit: bpmUnit) {
            let weekly = await fetchWeeklyAvg(.heartRate, unit: bpmUnit)
            metrics.append(HealthMetricDTO(name: "Heart Rate", value: "\(Int(hr))", unit: "bpm", icon: "heart.fill", colorName: "red", weeklyData: weekly))
        }
        if let rhr = await fetchLatest(.restingHeartRate, unit: bpmUnit) {
            metrics.append(HealthMetricDTO(name: "Resting HR", value: "\(Int(rhr))", unit: "bpm", icon: "heart", colorName: "pink"))
        }
        if let hrv = await fetchLatest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli)) {
            metrics.append(HealthMetricDTO(name: "HRV", value: String(format: "%.0f", hrv), unit: "ms", icon: "waveform.path.ecg.rectangle.fill", colorName: "purple"))
        }
        if let spo2 = await fetchLatest(.oxygenSaturation, unit: .percent()) {
            metrics.append(HealthMetricDTO(name: "Blood Oxygen", value: String(format: "%.0f", spo2 * 100), unit: "%", icon: "drop.fill", colorName: "blue"))
        }
        if let vo2 = await fetchLatest(.vo2Max, unit: HKUnit(from: "ml/kg·min")) {
            metrics.append(HealthMetricDTO(name: "VO₂ Max", value: String(format: "%.1f", vo2), unit: "mL/kg/min", icon: "lungs.fill", colorName: "cyan"))
        }
        return metrics
    }

    // MARK: - Body
    private func loadBodyMetrics() async -> [HealthMetricDTO] {
        var metrics: [HealthMetricDTO] = []
        if let weight = await fetchLatest(.bodyMass, unit: .pound()) {
            let weekly = await fetchWeeklyAvg(.bodyMass, unit: .pound())
            metrics.append(HealthMetricDTO(name: "Weight", value: String(format: "%.1f", weight), unit: "lbs", icon: "scalemass.fill", colorName: "blue", weeklyData: weekly))
        }
        if let bmi = await fetchLatest(.bodyMassIndex, unit: .count()) {
            metrics.append(HealthMetricDTO(name: "BMI", value: String(format: "%.1f", bmi), unit: "", icon: "person.crop.rectangle.fill", colorName: "indigo"))
        }
        if let height = await fetchLatest(.height, unit: .foot()) {
            let feet = Int(height)
            let inches = Int((height - Double(feet)) * 12)
            metrics.append(HealthMetricDTO(name: "Height", value: "\(feet)'\(inches)\"", unit: "", icon: "ruler.fill", colorName: "gray"))
        }
        return metrics
    }

    // MARK: - Sleep
    private func loadSleepMetrics() async -> [HealthMetricDTO] {
        var metrics: [HealthMetricDTO] = []
        let (inBed, asleep, deep, rem) = await fetchSleepMinutes()
        func fmt(_ minutes: Double) -> String {
            let h = Int(minutes / 60), m = Int(minutes) % 60
            return h > 0 ? "\(h)h \(m)m" : "\(m)m"
        }
        if inBed > 0 { metrics.append(HealthMetricDTO(name: "Time in Bed", value: fmt(inBed), unit: "", icon: "bed.double.fill", colorName: "indigo")) }
        if asleep > 0 { metrics.append(HealthMetricDTO(name: "Sleep", value: fmt(asleep), unit: "", icon: "moon.zzz.fill", colorName: "purple")) }
        if deep > 0 { metrics.append(HealthMetricDTO(name: "Deep Sleep", value: fmt(deep), unit: "", icon: "moon.fill", colorName: "blue")) }
        if rem > 0 { metrics.append(HealthMetricDTO(name: "REM Sleep", value: fmt(rem), unit: "", icon: "sparkles", colorName: "cyan")) }
        let mindful = await fetchMindfulMinutes()
        if mindful > 0 { metrics.append(HealthMetricDTO(name: "Mindful (7d)", value: "\(Int(mindful))", unit: "min", icon: "brain.head.profile", colorName: "mint")) }
        return metrics
    }

    // MARK: - Workouts
    private func loadWorkoutMetrics() async -> [HealthMetricDTO] {
        let workouts = await fetchRecentWorkouts(limit: 10)
        return workouts.map { w in
            let duration = Int(w.duration / 60)
            let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
            let energy = w.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
            return HealthMetricDTO(name: "Workout", value: "\(duration) min", unit: energy > 0 ? "· \(Int(energy)) kcal" : "", icon: "dumbbell.fill", colorName: "orange", date: w.startDate)
        }
    }

    // MARK: - Vitals
    private func loadVitalsMetrics() async -> [HealthMetricDTO] {
        var metrics: [HealthMetricDTO] = []
        let bpmUnit = HKUnit(from: "count/min")
        if let rr = await fetchLatest(.respiratoryRate, unit: bpmUnit) {
            metrics.append(HealthMetricDTO(name: "Respiratory Rate", value: "\(Int(rr))", unit: "breaths/min", icon: "lungs.fill", colorName: "teal"))
        }
        if let sys = await fetchLatest(.bloodPressureSystolic, unit: .millimeterOfMercury()),
           let dia = await fetchLatest(.bloodPressureDiastolic, unit: .millimeterOfMercury()) {
            metrics.append(HealthMetricDTO(name: "Blood Pressure", value: "\(Int(sys))/\(Int(dia))", unit: "mmHg", icon: "heart.text.square.fill", colorName: "red"))
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

    private func fetchWeeklySum(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> [WeeklyDataPointDTO] {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        var results: [WeeklyDataPointDTO] = []
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
            results.append(WeeklyDataPointDTO(label: label, value: value))
        }
        return results
    }

    private func fetchWeeklyAvg(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> [WeeklyDataPointDTO] {
        guard let qType = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let calendar = Calendar.current
        var results: [WeeklyDataPointDTO] = []
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
            results.append(WeeklyDataPointDTO(label: label, value: value))
        }
        return results
    }

    private func fetchSleepMinutes() async -> (inBed: Double, asleep: Double, deep: Double, rem: Double) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return (0, 0, 0, 0) }
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
            case HKCategoryValueSleepAnalysis.inBed.rawValue: inBed += mins
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: deep += mins; asleep += mins
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: rem += mins; asleep += mins
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: asleep += mins
            default: if sample.value == 1 { asleep += mins }
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
}
#endif
