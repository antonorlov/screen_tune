import SwiftUI
import CoreGraphics
import IOKit

// MARK: - Private API

let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
typealias DisplayListFunc = @convention(c) (UInt32, UnsafeMutablePointer<CGDirectDisplayID>?, UnsafeMutablePointer<UInt32>) -> CGError
typealias ConfigDisplayFunc = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError
typealias CGSConfigureDisplayModeFunc = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Int32) -> CGError

func loadSym<T>(_ name: String) -> T? {
    guard let sym = dlsym(skylight, name) ?? dlsym(nil, name) else { return nil }
    return unsafeBitCast(sym, to: T.self)
}

let SLSGetActiveDisplayList: DisplayListFunc? = loadSym("SLSGetActiveDisplayList")
let SLSGetDisplayList: DisplayListFunc? = loadSym("SLSGetDisplayList")
let SLSConfigureDisplayEnabled: ConfigDisplayFunc? = loadSym("SLSConfigureDisplayEnabled")
let CGSConfigureDisplayMode: CGSConfigureDisplayModeFunc? = loadSym("CGSConfigureDisplayMode")

let kDisplayModeNativeFlag: UInt32 = 0x02000000

// MARK: - Display helpers

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isActive: Bool
}

func getIDs(_ fn: DisplayListFunc?) -> [CGDirectDisplayID] {
    guard let fn = fn else { return [] }
    var c: UInt32 = 0
    guard fn(0, nil, &c) == .success, c > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(c))
    guard fn(c, &ids, &c) == .success else { return [] }
    return Array(ids.prefix(Int(c)))
}

func setDisplayEnabled(_ id: CGDirectDisplayID, _ on: Bool) -> Bool {
    guard let fn = SLSConfigureDisplayEnabled else { return false }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
    guard fn(c, id, on) == .success else { CGCancelDisplayConfiguration(c); return false }
    return CGCompleteDisplayConfiguration(c, .permanently) == .success
}

// MARK: - Brightness (gamma table-based software brightness)

func getBrightness(_ id: CGDirectDisplayID) -> Float {
    let size: UInt32 = 256
    var rTable = [CGGammaValue](repeating: 0, count: Int(size))
    var gTable = [CGGammaValue](repeating: 0, count: Int(size))
    var bTable = [CGGammaValue](repeating: 0, count: Int(size))
    var sampleCount: UInt32 = 0
    guard CGGetDisplayTransferByTable(id, size, &rTable, &gTable, &bTable, &sampleCount) == .success,
          sampleCount > 0 else { return 1.0 }
    let last = Int(sampleCount) - 1
    let raw = max(rTable[last], max(gTable[last], bTable[last]))
    return (raw * 100).rounded() / 100
}

func setBrightness(_ id: CGDirectDisplayID, _ value: Float) {
    let v = max(0.0, min(1.0, value))
    let size = 256
    var table = [CGGammaValue](repeating: 0, count: size)
    for i in 0..<size {
        table[i] = v * Float(i) / Float(size - 1)
    }
    CGSetDisplayTransferByTable(id, UInt32(size), table, table, table)
}

// MARK: - Resolution

struct ResolutionMode: Identifiable, Hashable {
    let id: Int32
    let width: Int
    let height: Int
    let hiDPI: Bool
    let refreshRate: Double

    var label: String {
        hiDPI ? "\(width) x \(height) (HiDPI)" : "\(width) x \(height)"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: ResolutionMode, rhs: ResolutionMode) -> Bool { lhs.id == rhs.id }
}

// Cached on first load per display to survive macOS mode-list filtering bug
var modeCache: [CGDirectDisplayID: [CGDisplayMode]] = [:]

func getAllModes(_ displayID: CGDirectDisplayID) -> [CGDisplayMode] {
    if let cached = modeCache[displayID] { return cached }
    let opts: [CFString: Any] = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue as Any]
    let modes = (CGDisplayCopyAllDisplayModes(displayID, opts as CFDictionary) as? [CGDisplayMode]) ?? []
    modeCache[displayID] = modes
    return modes
}

func getResolutions(_ displayID: CGDirectDisplayID, onlyHiDPI: Bool, onlyNativeAspect: Bool) -> [ResolutionMode] {
    let modes = getAllModes(displayID)
    let nativeMode = modes.first { ($0.ioFlags & kDisplayModeNativeFlag) != 0 }
    let nativeRatio: Double? = nativeMode.map { Double($0.pixelWidth) / Double($0.pixelHeight) }

    return modes
        .filter { $0.isUsableForDesktopGUI() }
        .filter { mode in
            if onlyNativeAspect, let nr = nativeRatio {
                let ratio = Double(mode.width) / Double(mode.height)
                if abs(ratio - nr) >= 0.01 { return false }
            }
            if onlyHiDPI && mode.pixelWidth <= mode.width { return false }
            return true
        }
        .map { m in
            ResolutionMode(
                id: m.ioDisplayModeID,
                width: m.width, height: m.height,
                hiDPI: m.pixelWidth > m.width,
                refreshRate: m.refreshRate
            )
        }
        .sorted { ($0.width * $0.height, $0.hiDPI ? 1 : 0) > ($1.width * $1.height, $1.hiDPI ? 1 : 0) }
}

func getCurrentModeID(_ displayID: CGDirectDisplayID) -> Int32? {
    CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID
}

func setResolution(_ displayID: CGDirectDisplayID, modeID: Int32) {
    guard let fn = CGSConfigureDisplayMode else { return }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return }
    if fn(c, displayID, modeID) == .success {
        CGCompleteDisplayConfiguration(c, .forSession)
    } else {
        CGCancelDisplayConfiguration(c)
    }
}

// MARK: - Display name via IOKit

var nameCache: [CGDirectDisplayID: String] = {
    if let s = UserDefaults.standard.dictionary(forKey: "dn") as? [String: String] {
        var m: [CGDirectDisplayID: String] = [:]
        for (k, v) in s { if let i = UInt32(k) { m[CGDirectDisplayID(i)] = v } }
        return m
    }
    return [:]
}()

func iterateIOKit(_ className: String, _ body: ([String: Any]) -> Void) {
    var iter: io_iterator_t = 0
    guard let matching = IOServiceMatching(className),
          IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
    defer { IOObjectRelease(iter) }
    var svc = IOIteratorNext(iter)
    while svc != 0 {
        defer { IOObjectRelease(svc); svc = IOIteratorNext(iter) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
        body(dict)
    }
}

func refreshNames() {
    // Build IOKit lookup tables once, then match against unnamed displays
    var clcdNames: [(vendor: UInt32, product: UInt32, name: String)] = []
    iterateIOKit("AppleCLCD2") { dict in
        guard let attrs = dict["DisplayAttributes"] as? [String: Any],
              let pa = attrs["ProductAttributes"] as? [String: Any],
              let name = pa["ProductName"] as? String,
              let mfr = pa["LegacyManufacturerID"] as? UInt32,
              let pid = pa["ProductID"] as? UInt32 else { return }
        clcdNames.append((vendor: mfr, product: pid, name: name))
    }

    var avNames: [(serial: UInt32, name: String)] = []
    iterateIOKit("DCPAVServiceProxy") { dict in
        guard let name = dict["ProductName"] as? String,
              let sn = dict["SerialNumber"] as? UInt32 else { return }
        avNames.append((serial: sn, name: name))
    }

    var changed = false
    for id in getIDs(SLSGetActiveDisplayList) {
        if CGDisplayIsBuiltin(id) != 0 || nameCache[id] != nil { continue }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)

        if let match = clcdNames.first(where: { $0.vendor == vendor && $0.product == model }) {
            nameCache[id] = match.name
            changed = true
        } else if let match = avNames.first(where: { $0.serial == serial }) {
            nameCache[id] = match.name
            changed = true
        }
    }

    if changed {
        var dict: [String: String] = [:]
        for (k, v) in nameCache { dict["\(k)"] = v }
        UserDefaults.standard.set(dict, forKey: "dn")
    }
}

// MARK: - Display list

var savedDisplayIDs: Set<Int> = Set((UserDefaults.standard.array(forKey: "savedIDs") as? [Int]) ?? [])

func getExternalDisplays() -> [DisplayInfo] {
    let active = Set(getIDs(SLSGetActiveDisplayList))
    let all = getIDs(SLSGetDisplayList)
    var result: [DisplayInfo] = []
    var seen = Set<CGDirectDisplayID>()
    for id in all {
        guard !seen.contains(id) else { continue }
        seen.insert(id)
        if CGDisplayIsBuiltin(id) != 0 || CGDisplayVendorNumber(id) == 0 { continue }
        result.append(DisplayInfo(id: id, name: nameCache[id] ?? "Display \(id)", isActive: active.contains(id)))
    }

    let currentIDs = Set(result.map { Int($0.id) })
    for raw in savedDisplayIDs where !currentIDs.contains(raw) {
        let id = CGDirectDisplayID(raw)
        result.append(DisplayInfo(id: id, name: nameCache[id] ?? "Display \(id)", isActive: false))
    }

    let newSaved = Set(result.map { Int($0.id) })
    if newSaved != savedDisplayIDs {
        savedDisplayIDs = newSaved
        UserDefaults.standard.set(Array(savedDisplayIDs), forKey: "savedIDs")
    }

    return result.sorted { $0.name < $1.name }
}

// MARK: - View Model

class DisplayVM: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    var timer: Timer?

    init() {
        refreshNames()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            refreshNames()
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.main.async { self.displays = getExternalDisplays() }
    }

    func toggle(_ d: DisplayInfo) {
        if let idx = displays.firstIndex(where: { $0.id == d.id }) {
            displays[idx] = DisplayInfo(id: d.id, name: d.name, isActive: !d.isActive)
        }
        DispatchQueue.global(qos: .userInitiated).async { _ = setDisplayEnabled(d.id, !d.isActive) }
    }
}

// MARK: - Settings

class AppSettings: ObservableObject {
    @AppStorage("onlyHiDPI") var onlyHiDPI: Bool = false
    @AppStorage("onlyNativeAspect") var onlyNativeAspect: Bool = true
}

// MARK: - SwiftUI App

@main
struct ScreenTuneApp: App {
    @StateObject private var vm = DisplayVM()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 0) {
                if vm.displays.isEmpty {
                    Text("No external displays")
                        .foregroundColor(.secondary)
                        .padding(16)
                } else {
                    ForEach(vm.displays) { display in
                        DisplaySection(display: display, vm: vm, settings: settings)
                    }
                }
                Divider()
                Button("Settings...") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.title == "ScreenTune Settings" }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
                            styleMask: [.titled, .closable],
                            backing: .buffered, defer: false
                        )
                        window.title = "ScreenTune Settings"
                        window.center()
                        window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
                        window.isReleasedWhenClosed = false
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(width: 300)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resolution")
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("HiDPI only", isOn: $settings.onlyHiDPI)
                Toggle("Native aspect only", isOn: $settings.onlyNativeAspect)
            }
        }
        .padding(24)
        .frame(width: 340, alignment: .leading)
        .fixedSize()
    }
}

// MARK: - Display Section

struct DisplaySection: View {
    let display: DisplayInfo
    @ObservedObject var vm: DisplayVM
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display")
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(display.name)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { display.isActive },
                    set: { _ in vm.toggle(display) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if display.isActive {
                BrightnessControl(displayID: display.id)
                ResolutionControl(displayID: display.id, settings: settings)
            }
        }
    }
}

// MARK: - Brightness Control

struct BrightnessControl: View {
    let displayID: CGDirectDisplayID
    @State private var brightness: Double = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Brightness")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(brightness * 100))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "sun.min")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $brightness, in: 0.0...1.0)
                    .onChange(of: brightness) {
                        setBrightness(displayID, Float(brightness))
                    }
                Image(systemName: "sun.max")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            let current = Double(getBrightness(displayID))
            if abs(current - brightness) > 0.01 { brightness = current }
        }
    }
}

// MARK: - Resolution Control

struct ResolutionControl: View {
    let displayID: CGDirectDisplayID
    @ObservedObject var settings: AppSettings
    @State private var modes: [ResolutionMode] = []
    @State private var selectedModeID: Int32 = 0
    @State private var isReloading = false

    var body: some View {
        HStack {
            Text("Resolution")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            Picker("", selection: $selectedModeID) {
                ForEach(modes) { mode in
                    Text(mode.label).tag(mode.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .onChange(of: selectedModeID) {
                guard !isReloading else { return }
                setResolution(displayID, modeID: selectedModeID)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.bottom, 4)
        .onAppear { reloadModes() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reloadModes()
        }
        .onChange(of: settings.onlyHiDPI) { reloadModes() }
        .onChange(of: settings.onlyNativeAspect) { reloadModes() }
    }

    private func reloadModes() {
        isReloading = true
        defer { isReloading = false }
        modes = getResolutions(displayID, onlyHiDPI: settings.onlyHiDPI, onlyNativeAspect: settings.onlyNativeAspect)
        let current = getCurrentModeID(displayID) ?? 0
        if modes.contains(where: { $0.id == current }) {
            selectedModeID = current
        } else if let first = modes.first {
            selectedModeID = first.id
        }
    }
}
