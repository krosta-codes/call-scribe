// CallScribe: menu-bar app. Detects a WhatsApp call (Core Audio process with running input),
// ASKS before recording, records both sides on separate tracks, then runs process_call.sh.
import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import ServiceManagement
import UserNotifications

// MARK: - Settings and logging

let defaults = UserDefaults.standard
let home = NSHomeDirectory()
var targetPrefix: String { defaults.string(forKey: "targetBundlePrefix") ?? "net.whatsapp" }
var detectOutput: Bool { defaults.string(forKey: "detectProperty") == "output" }   // test hook, default is input
var vaultPath: String {
    if let e = ProcessInfo.processInfo.environment["CALLSCRIBE_VAULT"], !e.isEmpty { return e }
    return defaults.string(forKey: "vaultPath") ?? "\(home)/Documents/CallScribe"
}
let archiveRoot = (ProcessInfo.processInfo.environment["CALLSCRIBE_ARCHIVE"] ?? defaults.string(forKey: "archivePath") ?? "\(home)/Documents/CallScribe/Audio") + "/Projects"
/// Your name as it appears in transcripts and to-dos. Default: first name of the macOS account.
var myName: String { defaults.string(forKey: "myName") ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me" }
/// Folders inside Projects/ whose subfolders are listed as projects too (e.g. "Clients").
var nestedProjectFolders: [String] { defaults.stringArray(forKey: "nestedProjectFolders") ?? [] }
let logURL = URL(fileURLWithPath: "\(home)/Library/Logs/CallScribe.log")

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// MARK: - Core Audio helpers

struct AudioProc { let obj: AudioObjectID; let pid: Int32; let bundleID: String; let input: Bool; let output: Bool }

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getU32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32? {
    var a = addr(sel); var v: UInt32 = 0; var sz = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr ? v : nil
}
func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == noErr, let s = v?.takeRetainedValue() else { return nil }
    return s as String
}
func audioProcesses() -> [AudioProc] {
    var a = addr(kAudioHardwarePropertyProcessObjectList); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids.map { o in
        AudioProc(obj: o, pid: Int32(bitPattern: getU32(o, kAudioProcessPropertyPID) ?? 0),
                  bundleID: getString(o, kAudioProcessPropertyBundleID) ?? "",
                  input: (getU32(o, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                  output: (getU32(o, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
    }
}
func processObject(forPID pid: Int32) -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject); var p = pid; var out = AudioObjectID(0)
    var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &p, &sz, &out)
    return st == noErr && out != 0 ? out : nil
}
// MARK: - Which output the other side plays on
// The tap records WhatsApp's audio, but the aggregate device it runs in needs a clock device. Until 1.2.0 that was the
// "system output" (alert sounds) device; on 2026-11-23 it was not the device in use and the other side got 0 frames.
// Now: the device chosen in the menu, else the device WhatsApp plays to, else the default output.

struct OutDevice { let id: AudioObjectID; let uid: String; let name: String }

func outputDevices() -> [OutDevice] {
    var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == noErr else { return [] }
    return ids.compactMap { d in
        var sa = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var ssz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ssz) == noErr, ssz > 0,
              let uid = getString(d, kAudioDevicePropertyDeviceUID), let name = getString(d, kAudioObjectPropertyName),
              !name.hasPrefix("CallScribe") else { return nil }
        return OutDevice(id: d, uid: uid, name: name)
    }
}

func defaultOutput() -> OutDevice? {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioObjectID(0); var sz = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &dev) == noErr else { return nil }
    return outputDevices().first { $0.id == dev }
}

/// Output devices the given processes are playing to right now.
func devicesUsed(by objs: [AudioObjectID]) -> [AudioObjectID] {
    var out: [AudioObjectID] = []
    for o in objs {
        var a = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput); var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &sz) == noErr, sz > 0 else { continue }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(o, &a, 0, nil, &sz, &ids) == noErr { out += ids }
    }
    return out
}

/// Menu choice "Other side audio": nil = Automatic.
var preferredOutputUID: String? {
    get { defaults.string(forKey: "outputDeviceUID") }
    set { defaults.set(newValue, forKey: "outputDeviceUID") }
}

/// Clock devices to try for the tap, in order. nil = no clock device: the aggregate runs on the tap itself, which
/// depends on no speaker, monitor or headset (measured 2026-11-23: the only setups that delivered frames were this
/// and the MacBook speakers; US-4x4, BlackHole and the ASUS monitor gave 0 frames even while audio played).
func clockCandidates(for objs: [AudioObjectID]) -> [(device: OutDevice?, why: String)] {
    let all = outputDevices()
    var out: [(OutDevice?, String)] = []
    func add(_ d: OutDevice?, _ why: String) { if !out.contains(where: { $0.0?.uid == d?.uid }) { out.append((d, why)) } }
    if let uid = preferredOutputUID, let d = all.first(where: { $0.uid == uid }) { add(d, "chosen in the menu") }
    add(nil, "WhatsApp's own audio, no output device needed")
    if let d = all.first(where: { $0.uid == "BuiltInSpeakerDevice" }) { add(d, "built-in speakers as clock") }
    let used = devicesUsed(by: objs)
    for d in all where used.contains(d.id) { add(d, "WhatsApp plays here") }
    if let d = defaultOutput() { add(d, "default output") }
    for d in all { add(d, "fallback") }
    return out
}

// MARK: - Caller name (Accessibility: WhatsApp window titles)

func cleanTitle(_ s: String) -> String {   // WhatsApp prefixes titles with U+200E and similar invisible marks
    String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.properties.generalCategory != .format }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
func axString(_ e: AXUIElement, _ attr: String) -> String? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success ? (v as? String).map(cleanTitle) : nil
}
func axWindows(pid: Int32) -> [AXUIElement] {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v) == .success else { return [] }
    return (v as? [AXUIElement]) ?? []
}
func axTexts(_ e: AXUIElement, depth: Int = 0, into out: inout [String]) {
    guard depth < 12, out.count < 60 else { return }
    // value of texts plus title/description of any element: participant names may sit on buttons or images
    let role = axString(e, kAXRoleAttribute) ?? "?"
    for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
        if let t = axString(e, attr), !t.isEmpty, !out.contains(where: { $0.hasSuffix(":" + t) }) { out.append("\(role):\(t)") }
    }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success, let kids = v as? [AXUIElement] else { return }
    for k in kids { axTexts(k, depth: depth + 1, into: &out) }
}
/// Window titles of the target app. During a call WhatsApp opens a second window; its title should be the contact.
func windowTitles(pids: [Int32]) -> [String] { pids.flatMap { axWindows(pid: $0).compactMap { axString($0, kAXTitleAttribute) } } }
/// Titles WhatsApp uses for call windows that carry no name (group calls).
let genericCallTitles: Set<String> = ["group voice call", "group video call", "voice call", "video call", "whatsapp", "incoming call", "calling"]
func callerName(pids: [Int32]) -> String? {
    windowTitles(pids: pids).first { !$0.isEmpty && !genericCallTitles.contains($0.lowercased()) && !$0.lowercased().hasPrefix("whatsapp ") }
}
/// Log line for diagnosis: every window title plus the visible texts of non-main windows.
func describeWindows(pids: [Int32]) -> String {
    pids.flatMap { axWindows(pid: $0) }.map { w in
        let t = axString(w, kAXTitleAttribute) ?? "?"
        var texts: [String] = []
        if t.lowercased() != "whatsapp" { axTexts(w, into: &texts) }
        return "'\(t)'" + (texts.isEmpty ? "" : " texts=\(texts.prefix(40))")
    }.joined(separator: "; ")
}
/// Folder name for a contact: keeps the display name, strips path characters.
func contactFolder(_ s: String) -> String {
    let t = cleanTitle(s).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return t.isEmpty ? "Unknown" : t
}

// MARK: - Recorder (mic + process tap)

/// One audio track on disk. The file keeps the format of the first source; a later source (after a device switch or a
/// rebuilt tap) is converted. The timeline follows the wall clock: a gap is padded with silence, so me and them stay aligned.
final class TrackWriter {
    let fmt: AVAudioFormat
    private let file: AVAudioFile, start: Date
    private var converter: AVAudioConverter?, convFrom: AVAudioFormat?
    private(set) var frames: Int64 = 0
    private(set) var lastWrite: Date?
    private(set) var lastSound: Date?
    private(set) var padded: Double = 0

    init(url: URL, format: AVAudioFormat, start: Date) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        fmt = format; self.start = start
    }

    private func silence(_ n: Int64) -> AVAudioPCMBuffer? {
        guard n > 0, let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        b.frameLength = AVAudioFrameCount(n)
        for buf in UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList) { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
        return b
    }

    func write(_ input: AVAudioPCMBuffer) {
        var b = input
        if !input.format.isEqual(fmt) {
            if convFrom == nil || !convFrom!.isEqual(input.format) { converter = AVAudioConverter(from: input.format, to: fmt); convFrom = input.format }
            let cap = AVAudioFrameCount(Double(input.frameLength) * fmt.sampleRate / max(input.format.sampleRate, 1)) + 256
            guard let c = converter, let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            var fed = false; var err: NSError?
            c.convert(to: out, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return input
            }
            guard err == nil, out.frameLength > 0 else { return }
            b = out
        }
        var gap = Int64(Date().timeIntervalSince(start) * fmt.sampleRate) - Int64(b.frameLength) - frames
        if gap > Int64(fmt.sampleRate / 2) {
            padded += Double(gap) / fmt.sampleRate
            let chunk = Int64(fmt.sampleRate)   // pad in 1 s pieces, a 15 min gap must not allocate 400 MB at once
            while gap > 0, let s = silence(min(gap, chunk)) { if (try? file.write(from: s)) == nil { break }; frames += Int64(s.frameLength); gap -= Int64(s.frameLength) }
        }
        if (try? file.write(from: b)) != nil { frames += Int64(b.frameLength); lastWrite = Date() }
        if let ch = b.floatChannelData {
            let n = Int(b.frameLength) * (b.format.isInterleaved ? Int(b.format.channelCount) : 1)
            var peak: Float = 0
            for i in stride(from: 0, to: n, by: 4) { peak = max(peak, abs(ch[0][i])) }
            if peak > 0.0001 { lastSound = Date() }   // -80 dB: true digital silence is 0, quiet speech is far above
        }
    }
}

final class Recorder {
    private var engine = AVAudioEngine()
    private var mic: TrackWriter?, them: TrackWriter?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private let ioQueue = DispatchQueue(label: "callscribe.io", qos: .userInitiated)
    private var dir = URL(fileURLWithPath: "/tmp"), start = Date(), objs: [AudioObjectID] = []
    private var lastMicRestart = Date.distantPast, lastTapRestart = Date.distantPast
    private var candidate = 0                    // index into clockCandidates(); moves on when a clock delivers nothing
    private var tapStarted = Date()
    private var cfgObserver: NSObjectProtocol?
    private(set) var running = false
    private(set) var device = ""                 // output device the other side is recorded from
    private(set) var events: [String] = []       // restarts and device choices, logged and written to meta.json
    /// Finds the target processes again when the tap is rebuilt (a video call can move audio to another process).
    var rescan: (() -> [AudioObjectID])?
    var themFrames: Int64 { them?.frames ?? 0 }
    var micFrames: Int64 { mic?.frames ?? 0 }
    /// True while one of the two tracks is not delivering audio. Drives the warning icon.
    private(set) var degraded = false

    private func note(_ s: String) {
        let t = Int(Date().timeIntervalSince(start))
        events.append(String(format: "%02d:%02d %@", t / 60, t % 60, s)); log("recorder: \(s)")
    }

    /// Starts both tracks. Returns a list of problems (empty = fully ok).
    func start(dir: URL, processObjects: [AudioObjectID]) -> [String] {
        self.dir = dir; start = Date(); objs = processObjects; events = []; candidate = 0
        var problems: [String] = []
        if let p = startMic() { problems.append(p) }
        if let p = startTap() { problems.append(p) }
        running = true
        // macOS stops AVAudioEngine when the audio setup changes (headphones, video call). Until 1.2.0 the mic then
        // stayed dead for the rest of the call (2026-11-23: 3:45 of 17:51 recorded).
        cfgObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] n in
            guard let self, self.running, (n.object as? AVAudioEngine) === self.engine else { return }
            self.note("audio setup changed, restarting the mic"); self.restartMic(force: true)
        }
        return problems
    }

    private func startMic() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0); var ok = false
            AVCaptureDevice.requestAccess(for: .audio) { ok = $0; sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
            if !ok { return "Microphone permission not granted" }
        default: return "Microphone permission denied (System Settings > Privacy > Microphone)"
        }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return "No microphone input format" }
        do {
            if mic == nil { mic = try TrackWriter(url: dir.appendingPathComponent("me.caf"), format: fmt, start: start) }
            let w = mic
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in w?.write(buf) }
            try engine.start()
            return nil
        } catch { return "Mic start failed: \(error.localizedDescription)" }
    }

    func restartMic(force: Bool) {
        guard running, force || Date().timeIntervalSince(lastMicRestart) > 6 else { return }
        lastMicRestart = Date()
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        engine = AVAudioEngine()
        if let p = startMic() { note("mic restart failed: \(p)") } else { note("mic restarted") }
    }

    private func startTap() -> String? {
        guard !objs.isEmpty else { return "No target audio process found for the tap" }
        let desc = CATapDescription(stereoMixdownOfProcesses: objs)
        desc.uuid = UUID(); desc.name = "CallScribe tap"; desc.isPrivate = true; desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else { return "AudioHardwareCreateProcessTap failed (\(st)); grant 'System Audio Recording' permission" }
        var asbd = AudioStreamBasicDescription(); var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fa = addr(kAudioTapPropertyFormat)
        st = AudioObjectGetPropertyData(tapID, &fa, 0, nil, &sz, &asbd)
        guard st == noErr else { return "Tap format unavailable (\(st))" }
        let sub: [String: Any] = [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallScribe aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [sub],
        ]
        let cands = clockCandidates(for: objs)
        let (d, why) = cands[candidate % cands.count]
        if let d {
            dict[kAudioAggregateDeviceMainSubDeviceKey] = d.uid
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: d.uid]]
            device = d.name
        } else { device = "WhatsApp audio (no output device)" }
        note("other side: \(device) (\(why))")
        tapStarted = Date()
        st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
        guard st == noErr else { return "Aggregate device failed (\(st))" }
        // The IOProc delivers frames at the aggregate's rate (the output device, e.g. 44.1 kHz speakers), not the
        // tap's reported rate (48 kHz). Labelling the file 48 kHz shrank the other side's timeline by 8% (2026-11-16).
        var rate = Float64(0); var rsz = UInt32(MemoryLayout<Float64>.size); var ra = addr(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectGetPropertyData(aggID, &ra, 0, nil, &rsz, &rate) == noErr, rate > 0, rate != asbd.mSampleRate {
            log("tap reports \(Int(asbd.mSampleRate)) Hz, aggregate runs at \(Int(rate)) Hz: writing them.caf at \(Int(rate)) Hz")
            asbd.mSampleRate = rate
        }
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return "Tap format unusable" }
        tapFormat = fmt
        if them == nil {
            do { them = try TrackWriter(url: dir.appendingPathComponent("them.caf"), format: fmt, start: start) }
            catch { return "them.caf open failed: \(error.localizedDescription)" }
        }
        let w = them
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inData, _, _, _ in
            guard let w, let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else { return }
            w.write(buf)
        }
        guard st == noErr else { return "IOProc failed (\(st))" }
        st = AudioDeviceStart(aggID, procID)
        return st == noErr ? nil : "AudioDeviceStart failed (\(st))"
    }

    private func stopTap() {
        if aggID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil; aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
        ioQueue.sync {}
    }

    /// Rebuilds the tap with a fresh process list. next = try the next clock device (the current one delivered nothing);
    /// a menu change restarts from the top of the list.
    func restartTap(force: Bool, next: Bool = false) {
        guard running, force || Date().timeIntervalSince(lastTapRestart) > 4 else { return }
        lastTapRestart = Date()
        candidate = next ? candidate + 1 : 0
        stopTap()
        if let r = rescan?(), !r.isEmpty { objs = r }
        if let p = startTap() { note("tap rebuild failed: \(p)") } else { note("tap rebuilt") }
    }

    /// Called once per second while recording. otherSideActive = the target app is playing audio right now.
    func health(otherSideActive: Bool) {
        guard running else { return }
        let now = Date(), age = now.timeIntervalSince(start)
        let micStalled = age > 4 && now.timeIntervalSince(mic?.lastWrite ?? start) > 4
        let tapStalled = otherSideActive && now.timeIntervalSince(max(them?.lastWrite ?? start, tapStarted)) > 3
        if micStalled, now.timeIntervalSince(lastMicRestart) > 6 { note("mic delivered nothing for 4 s"); restartMic(force: false) }
        if tapStalled, now.timeIntervalSince(lastTapRestart) > 4 { note("other side delivered nothing for 3 s on '\(device)', trying the next clock"); restartTap(force: false, next: true) }
        degraded = micStalled || tapStalled
    }

    /// Stops both tracks and returns what went wrong, in plain words, for meta.json and the note.
    @discardableResult
    func stop() -> [String] {
        guard running else { return [] }
        running = false
        if let o = cfgObserver { NotificationCenter.default.removeObserver(o); cfgObserver = nil }
        engine.inputNode.removeTap(onBus: 0); engine.stop()
        stopTap()
        let secs = Date().timeIntervalSince(start)
        var issues: [String] = []
        if let t = them {
            if t.frames == 0 { issues.append("Other side NOT recorded: no audio arrived from WhatsApp (output '\(device)')") }
            else if t.lastSound == nil { issues.append("Other side silent the whole call (output '\(device)'): wrong output chosen, or they were muted") }
            if t.padded > 2 { issues.append(String(format: "Other side had gaps, %.0f s of %.0f s filled with silence", t.padded, secs)) }
        } else { issues.append("Other side NOT recorded: tap never started") }
        if let m = mic {
            if m.frames == 0 { issues.append("Your mic NOT recorded") }
            else if m.padded > 2 { issues.append(String(format: "Your mic had gaps, %.0f s of %.0f s filled with silence", m.padded, secs)) }
        } else { issues.append("Your mic NOT recorded: mic never started") }
        mic = nil; them = nil   // closes files
        return issues
    }
}

// MARK: - Prompt panel

final class KeyPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class PromptController: NSObject {
    let panel: KeyPanel
    let withField = NSTextField()
    let projectPopup = NSPopUpButton()
    var onAnswer: ((_ record: Bool, _ with: String, _ project: String) -> Void)?

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.level = .floating; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "WhatsApp call detected. Record it?")
        title.font = .boldSystemFont(ofSize: 14)
        withField.stringValue = defaults.string(forKey: "lastWith") ?? ""
        withField.placeholderString = "Name"
        let withRow = row("With", withField)
        for p in PromptController.projects() { projectPopup.addItem(withTitle: p) }
        let last = defaults.string(forKey: "lastProject") ?? "Calls"
        if projectPopup.itemTitles.contains(last) { projectPopup.selectItem(withTitle: last) }
        else if projectPopup.numberOfItems == 0 || !projectPopup.itemTitles.contains(last) { projectPopup.insertItem(withTitle: last, at: 0); projectPopup.selectItem(at: 0) }
        let projRow = row("Project", projectPopup)
        let hint = NSTextField(wrappingLabelWithString: "Say first: I'm recording this for my notes, ok?")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let rec = NSButton(title: "Record", target: self, action: #selector(record)); rec.keyEquivalent = "\r"; rec.bezelStyle = .rounded
        let no = NSButton(title: "Not this call", target: self, action: #selector(decline)); no.bezelStyle = .rounded
        let buttons = NSStackView(views: [no, rec]); buttons.spacing = 8
        let stack = NSStackView(views: [title, withRow, projRow, hint, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 18, bottom: 16, right: 18)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let vfx = NSVisualEffectView(); vfx.material = .hudWindow; vfx.state = .active; vfx.blendingMode = .behindWindow
        vfx.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: vfx.topAnchor), stack.bottomAnchor.constraint(equalTo: vfx.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: vfx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: vfx.trailingAnchor),
            withRow.widthAnchor.constraint(equalToConstant: 324), projRow.widthAnchor.constraint(equalToConstant: 324),
            hint.widthAnchor.constraint(equalToConstant: 324),
        ])
        panel.contentView = vfx
        panel.setContentSize(vfx.fittingSize)
    }

    private func row(_ label: String, _ control: NSView) -> NSStackView {
        let l = NSTextField(labelWithString: label); l.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let r = NSStackView(views: [l, control]); r.spacing = 8; r.alignment = .centerY
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return r
    }

    static func projects() -> [String] {
        let fm = FileManager.default
        let base = "\(vaultPath)/Projects"
        var out: [String] = []
        for name in ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted() where !name.hasPrefix(".") && !name.hasPrefix("_") {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: "\(base)/\(name)", isDirectory: &isDir), isDir.boolValue else { continue }
            if nestedProjectFolders.contains(name) {
                for sub in ((try? fm.contentsOfDirectory(atPath: "\(base)/\(name)")) ?? []).sorted() where !sub.hasPrefix(".") {
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: "\(base)/\(name)/\(sub)", isDirectory: &d), d.boolValue { out.append("\(name)/\(sub)") }
                }
            } else { out.append(name) }
        }
        return out
    }

    func show() {
        if let s = NSScreen.main {
            let f = s.visibleFrame, sz = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: f.maxX - sz.width - 16, y: f.maxY - sz.height - 16))
        }
        NSSound(named: "Glass")?.play()
        panel.orderFrontRegardless()
        panel.makeKey()
    }
    var nameDetected = false
    /// Fills in the caller detected from WhatsApp and the project last used with that contact.
    func setDetected(_ name: String) {
        nameDetected = true
        withField.stringValue = name
        if let p = (defaults.dictionary(forKey: "projectByContact") as? [String: String])?[name], projectPopup.itemTitles.contains(p) {
            projectPopup.selectItem(withTitle: p)
        }
    }
    func close() { panel.orderOut(nil) }
    @objc func record() {
        let w = withField.stringValue.trimmingCharacters(in: .whitespaces)
        let who = w.isEmpty ? "Unknown" : w
        let proj = projectPopup.titleOfSelectedItem ?? "Calls"
        defaults.set(who, forKey: "lastWith"); defaults.set(proj, forKey: "lastProject")
        var map = (defaults.dictionary(forKey: "projectByContact") as? [String: String]) ?? [:]; map[who] = proj
        defaults.set(map, forKey: "projectByContact")
        close(); onAnswer?(true, who, proj)
    }
    @objc func decline() { close(); onAnswer?(false, "", "") }
}

// MARK: - App

enum State { case idle, prompting, recording, declined }

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var state = State.idle { didSet { updateIcon() } }
    var inactiveSince: Date?
    var prompt: PromptController?
    let recorder = Recorder()
    var sessionDir: URL?, sessionWith = "", sessionProject = "", sessionStart = Date(), sessionProblems: [String] = []
    let outputMenu = NSMenu()
    var statusLine = NSMenuItem(), stopItem = NSMenuItem(), lastItem = NSMenuItem(), loginItem = NSMenuItem()
    var timer: Timer?
    var promptShown = Date()
    var lastSignal = ""
    var pipelinesRunning = 0 { didSet { updateIcon() } }
    var notificationsOK = false
    var updateItem = NSMenuItem(), available: Release?
    var updateTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        log("CallScribe started, target prefix '\(targetPrefix)'")
        statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: ""); statusLine.isEnabled = false
        stopItem = NSMenuItem(title: "Stop recording", action: #selector(stopFromMenu), keyEquivalent: "")
        lastItem = NSMenuItem(title: "Open last note", action: #selector(openLast), keyEquivalent: "")
        loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        updateItem = NSMenuItem(title: "Update…", action: #selector(installUpdate), keyEquivalent: ""); updateItem.isHidden = true
        let checkItem = NSMenuItem(title: "Check for updates… (v\(appVersion))", action: #selector(checkFromMenu), keyEquivalent: "")
        let menu = NSMenu()
        let outputItem = NSMenuItem(title: "Other side audio", action: nil, keyEquivalent: "")
        outputItem.submenu = outputMenu; outputMenu.delegate = self
        for i in [statusLine, .separator(), stopItem, lastItem, outputItem, .separator(), loginItem, updateItem, checkItem, .separator()] { menu.addItem(i) }
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for i in menu.items where i.action != nil { i.target = self }
        menu.delegate = self
        menu.autoenablesItems = false   // otherwise "Stop recording" always looks clickable, even when nothing records
        item.menu = menu
        updateIcon()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            log("notifications authorized: \(ok)"); DispatchQueue.main.async { self?.notificationsOK = ok } }
        DistributedNotificationCenter.default().addObserver(forName: stopNotification, object: nil, queue: .main) { [weak self] _ in
            log("stop requested via --stop"); self?.stopFromMenu() }
        let axOK = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        log("accessibility (caller name) trusted: \(axOK)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkForUpdates(manual: false) }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in self?.checkForUpdates(manual: false) }
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let rec = state == .recording
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let warn = rec && recorder.degraded
        let img = NSImage(systemSymbolName: warn ? "exclamationmark.circle.fill" : rec ? "record.circle.fill" : "phone.badge.waveform", accessibilityDescription: "CallScribe")?
            .withSymbolConfiguration(rec ? cfg.applying(.init(paletteColors: [warn ? .systemOrange : .systemRed])) : cfg)
        img?.isTemplate = !rec
        b.image = img
        statusLine.title = rec ? (warn ? "Recording \(sessionWith): a track is not coming through, repairing" : "Recording \(sessionWith) · other side: \(recorder.device)") : state == .prompting ? "Call detected, waiting for your answer"
            : pipelinesRunning > 0 ? "Writing call note…" : "Idle"
        stopItem.isEnabled = rec
    }

    // Detection, once per second
    func tick() {
        let procs = audioProcesses().filter { $0.bundleID.hasPrefix(targetPrefix) }
        // A call = mic running, or (2026-11-16, group call joined muted) audio playing while a second window
        // (the call window) is open. Voice notes and videos play in the main window and do not count.
        let mic = procs.contains { detectOutput ? $0.output : $0.input }
        let out = procs.contains { $0.output }
        let titles = (out || mic || state != .idle) ? windowTitles(pids: procs.map { $0.pid }) : []
        let callWindow = titles.count >= 2 || titles.contains { !$0.isEmpty && $0.lowercased() != "whatsapp" }
        let active = mic || (out && callWindow)
        let sig = "mic=\(mic) out=\(out) windows=\(titles)"
        if sig != lastSignal { log("whatsapp: \(sig)"); lastSignal = sig }
        if active { inactiveSince = nil } else if inactiveSince == nil { inactiveSince = Date() }
        let ended = !active && Date().timeIntervalSince(inactiveSince ?? Date()) >= 3
        switch state {
        case .idle:
            if active { log("call detected (\(procs.map { "\($0.bundleID)#\($0.pid)" }.joined(separator: ","))), prompting"); showPrompt() }
        case .prompting:
            if let p = prompt, !p.nameDetected, Date().timeIntervalSince(promptShown) < 15, let n = callerName(pids: procs.map { $0.pid }) {
                log("caller name detected: '\(n)'"); p.setDetected(n)
            }
            if ended { log("call ended before answer, prompt dismissed"); prompt?.close(); state = .idle }
        case .declined:
            if ended { state = .idle }
        case .recording:
            if ended { log("call ended, stopping"); stopRecording(); break }
            let was = recorder.degraded
            recorder.health(otherSideActive: out)
            if was != recorder.degraded { updateIcon() }
        }
    }

    func showPrompt() {
        state = .prompting
        let p = PromptController()
        let pids = audioProcesses().filter { $0.bundleID.hasPrefix(targetPrefix) }.map { $0.pid }
        log("windows: \(describeWindows(pids: pids))")
        if let n = callerName(pids: pids) { log("caller name detected: '\(n)'"); p.setDetected(n) }
        promptShown = Date()
        p.onAnswer = { [weak self] rec, who, proj in
            guard let self else { return }
            if rec { self.startRecording(with: who, project: proj) } else { log("declined by user"); self.state = .declined }
        }
        prompt = p; p.show()
    }

    func startRecording(with who: String, project: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let parent = "\(archiveRoot)/\(project)/calls/\(contactFolder(who))"   // one folder per contact
        let base = f.string(from: Date())
        var stem = base, n = 2   // never overwrite an earlier recording from the same minute
        while FileManager.default.fileExists(atPath: "\(parent)/\(stem)") { stem = "\(base)-\(n)"; n += 1 }
        let dir = URL(fileURLWithPath: "\(parent)/\(stem)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir; sessionWith = who; sessionProject = project; sessionStart = Date()
        let objs = audioProcesses().filter { $0.bundleID.hasPrefix(targetPrefix) }.map { $0.obj }
        recorder.rescan = { audioProcesses().filter { $0.bundleID.hasPrefix(targetPrefix) }.map { $0.obj } }
        let problems = recorder.start(dir: dir, processObjects: objs)
        sessionProblems = problems
        for p in problems { log("PROBLEM: \(p)") }
        if problems.count >= 2 { alert("Recording failed", problems.joined(separator: "\n")); recorder.stop(); state = .declined; return }
        if !problems.isEmpty { notify("CallScribe: partial recording", problems.joined(separator: "; "), path: nil) }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]; iso.timeZone = .current
        writeMeta(dir: dir, problems: problems, events: recorder.events)
        log("recording to \(dir.path)")
        state = .recording
    }

    func stopRecording() {
        guard state == .recording, let dir = sessionDir else { return }
        log("stopping recording (\(Int(Date().timeIntervalSince(sessionStart))) s)")
        let issues = recorder.stop()
        for i in issues { log("PROBLEM: \(i)") }
        writeMeta(dir: dir, problems: sessionProblems + issues, events: recorder.events)
        state = .idle   // WhatsApp input may still be active if stopped by menu; avoid instant re-prompt
        runPipeline(dir: dir, with: sessionWith, project: sessionProject)
        if audioProcesses().contains(where: { $0.bundleID.hasPrefix(targetPrefix) && (detectOutput ? $0.output : $0.input) }) { state = .declined }
    }

    /// meta.json: who, project, start, problems (plain words, shown in the note) and the recorder's event log.
    func writeMeta(dir: URL, problems: [String], events: [String]) {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]; iso.timeZone = .current
        let meta: [String: Any] = ["start": iso.string(from: sessionStart).replacingOccurrences(of: "Z", with: ""), "with": sessionWith,
                                   "project": sessionProject, "problems": problems, "events": events]
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("meta.json")) }
    }

    func runPipeline(dir: URL, with who: String, project: String) {
        let script = Bundle.main.path(forResource: "process_call", ofType: "sh") ?? "\(home)/Projects/apps/call-scribe/process_call.sh"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [script, dir.path, who, project]
        var env = ProcessInfo.processInfo.environment; env["CALLSCRIBE_FROM_APP"] = "1"; env["CALLSCRIBE_VAULT"] = vaultPath; env["CALLSCRIBE_ME"] = myName
        task.environment = env
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        pipelinesRunning += 1
        task.terminationHandler = { [weak self] _ in
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let note = out.split(separator: "\n").last(where: { $0.hasPrefix("NOTE: ") }).map { String($0.dropFirst(6)) }
            DispatchQueue.main.async {
                self?.pipelinesRunning -= 1
                log("pipeline finished, note: \(note ?? "none")")
                if let note { defaults.set(note, forKey: "lastNotePath"); self?.notify("Call note ready", URL(fileURLWithPath: note).lastPathComponent, path: note) }
                else { self?.notify("CallScribe: processing failed", "Audio is kept in \(dir.path)", path: nil) }
            }
        }
        do { try task.run(); log("pipeline started: \(script)") } catch { pipelinesRunning -= 1; log("pipeline launch failed: \(error)") }
    }

    func notify(_ title: String, _ body: String, path: String?) {
        if !notificationsOK { banner(title, body); return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        if let path { c.userInfo = ["path": path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            if let err { log("notification failed (\(err.localizedDescription)), falling back to osascript"); self.banner(title, body) }
        }
    }
    func banner(_ title: String, _ body: String) {
        let q = { (s: String) in s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "'") }
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", "display notification \"\(q(body))\" with title \"\(q(title))\""]; try? t.run()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler h: @escaping () -> Void) {
        if let p = r.notification.request.content.userInfo["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        h()
    }
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) { h([.banner, .sound]) }

    func alert(_ t: String, _ m: String) { let a = NSAlert(); a.messageText = t; a.informativeText = m; a.runModal() }

    @objc func stopFromMenu() {
        if state == .recording { stopRecording() } else { log("stop ignored: not recording (state \(state))") }
    }
    @objc func openLast() {
        if let p = defaults.string(forKey: "lastNotePath"), FileManager.default.fileExists(atPath: p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
        else { alert("No note yet", "No call note has been written yet.") }
    }
    @objc func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { alert("Start at login failed", error.localizedDescription) }
    }
    @objc func quit() { if state == .recording { recorder.stop() }; NSApp.terminate(nil) }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outputMenu { fillOutputMenu(); return }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// "Other side audio": Automatic (where WhatsApp plays, else the default output) or one fixed output device.
    func fillOutputMenu() {
        outputMenu.removeAllItems()
        let current = preferredOutputUID
        let auto = NSMenuItem(title: "Automatic (recommended)", action: #selector(pickOutput(_:)), keyEquivalent: "")
        auto.target = self; auto.representedObject = nil; auto.state = current == nil ? .on : .off
        outputMenu.addItem(auto); outputMenu.addItem(.separator())
        let def = defaultOutput()?.uid
        for d in outputDevices() {
            let i = NSMenuItem(title: d.name + (d.uid == def ? "  (default output)" : ""), action: #selector(pickOutput(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = d.uid; i.state = d.uid == current ? .on : .off
            outputMenu.addItem(i)
        }
        if state == .recording, !recorder.device.isEmpty {
            outputMenu.addItem(.separator())
            let now = NSMenuItem(title: "Recording from: \(recorder.device)", action: nil, keyEquivalent: ""); now.isEnabled = false
            outputMenu.addItem(now)
        }
    }

    @objc func pickOutput(_ sender: NSMenuItem) {
        preferredOutputUID = sender.representedObject as? String
        log("other side audio set to \(preferredOutputUID ?? "Automatic")")
        if state == .recording { recorder.restartTap(force: true); updateIcon() }
    }
}

// MARK: - Update check (app-standard UPDATES.md): asks GitHub Releases of the repo, sends nothing else

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let repoSlug = Bundle.main.object(forInfoDictionaryKey: "CSRepo") as? String ?? "krosta-codes/call-scribe"
let sourceDir = Bundle.main.object(forInfoDictionaryKey: "CSSourceDir") as? String
struct Release { let tag: String; let url: String }

func isNewer(_ a: String, than b: String) -> Bool {
    let parts = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}
func parseRelease(_ d: Data) -> Release? {
    guard let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let tag = j["tag_name"] as? String else { return nil }
    return Release(tag: tag, url: j["html_url"] as? String ?? "https://github.com/\(repoSlug)/releases")
}
func ghAPI(_ path: String) -> Data? {   // private repo fallback: the user's own gh login
    guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: gh); p.arguments = ["api", path]; p.standardOutput = out; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15) { if p.isRunning { p.terminate() } }
    let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return p.terminationStatus == 0 ? d : nil
}
func fetchLatestRelease(_ done: @escaping (Release?, String?) -> Void) {
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!, timeoutInterval: 10)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("CallScribe/\(appVersion)", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, let d = data, let r = parseRelease(d) { return done(r, nil) }
        if code == 404, let d = ghAPI("repos/\(repoSlug)/releases/latest"), let r = parseRelease(d) { return done(r, nil) }
        done(nil, err?.localizedDescription ?? (code == 404 ? "No release published yet (or the repo is private and gh is not logged in)." : "GitHub answered HTTP \(code)."))
    }.resume()
}

extension AppDelegate {
    func checkForUpdates(manual: Bool) {
        if !manual && defaults.object(forKey: "updateCheck") as? Bool == false { return }
        fetchLatestRelease { [weak self] rel, err in DispatchQueue.main.async {
            guard let self else { return }
            if let rel, isNewer(rel.tag, than: appVersion) {
                self.available = rel
                self.updateItem.title = "Update to \(rel.tag)…"; self.updateItem.isHidden = false
                log("update available: \(rel.tag) (running \(appVersion))")
                if manual { self.installUpdate() }
                else if defaults.string(forKey: "notifiedVersion") != rel.tag {
                    defaults.set(rel.tag, forKey: "notifiedVersion")
                    self.notify("CallScribe \(rel.tag) is out", "Menu bar › Update to \(rel.tag)", path: nil)
                }
            } else if let rel {
                log("update check: \(rel.tag) is latest, running \(appVersion)")
                if manual { self.alert("You're up to date", "CallScribe \(appVersion) is the latest version.") }
            } else {
                log("update check failed: \(err ?? "?")")
                if manual { self.alert("Update check failed", err ?? "Unknown error.") }
            }
        } }
    }
    @objc func checkFromMenu() { checkForUpdates(manual: true) }
    @objc func installUpdate() {
        guard let rel = available else { return checkForUpdates(manual: true) }
        if state == .recording || pipelinesRunning > 0 { return alert("Not now", "A call is being recorded or processed. Update once it's done.") }
        guard let src = sourceDir, FileManager.default.fileExists(atPath: "\(src)/.git"), FileManager.default.fileExists(atPath: "\(src)/update.sh") else {
            NSWorkspace.shared.open(URL(string: rel.url)!); return
        }
        let a = NSAlert(); a.messageText = "Update to \(rel.tag)?"
        a.informativeText = "Pulls the new version into \(src), rebuilds and restarts CallScribe (takes about a minute)."
        a.addButton(withTitle: "Update"); a.addButton(withTitle: "Release notes"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let logPath = "\(home)/Library/Logs/CallScribe-update.log"
            if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["\(src)/update.sh"]
            if let h = FileHandle(forWritingAtPath: logPath) { h.seekToEndOfFile(); p.standardOutput = h; p.standardError = h }
            do { try p.run(); log("update started: \(appVersion) -> \(rel.tag)") } catch { alert("Update failed", error.localizedDescription) }
        case .alertSecondButtonReturn: NSWorkspace.shared.open(URL(string: rel.url)!)
        default: break
        }
    }
}

// MARK: - CLI helpers (debug and tests)

let stopNotification = Notification.Name("com.jurekkrosta.callscribe.stop")

func cliMain(_ a: [String]) -> Bool {
    if a.count >= 2, a[1] == "--who" {   // what the prompt would pre-fill right now
        let pids = audioProcesses().filter { $0.bundleID.hasPrefix(targetPrefix) }.map { $0.pid }
        print("accessibility trusted: \(AXIsProcessTrusted())"); print("windows: \(describeWindows(pids: pids))")
        print("caller: \(callerName(pids: pids) ?? "<none>")"); return true
    }
    if a.count >= 2, a[1] == "--stop" {   // same as menu "Stop recording", for tests and shortcuts
        DistributedNotificationCenter.default().postNotificationName(stopNotification, object: nil, userInfo: nil, deliverImmediately: true)
        print("stop sent"); return true
    }
    if a.count >= 2, a[1] == "--check-update" {   // same check as the menu, prints the result
        let s = DispatchSemaphore(value: 0)
        fetchLatestRelease { r, e in
            print("running \(appVersion), latest \(r?.tag ?? "?"), newer: \(r.map { isNewer($0.tag, than: appVersion) } ?? false)\(e.map { ", error: \($0)" } ?? "")")
            s.signal()
        }
        s.wait(); return true
    }
    if a.count >= 2, a[1] == "--devices" {   // output devices the "Other side audio" menu offers
        let def = defaultOutput()?.uid
        for d in outputDevices() {
            var rate = Float64(0); var sz = UInt32(MemoryLayout<Float64>.size); var ra = addr(kAudioDevicePropertyNominalSampleRate)
            _ = AudioObjectGetPropertyData(d.id, &ra, 0, nil, &sz, &rate)
            print("\(d.uid == def ? "*" : " ") \(d.name) | \(Int(rate)) Hz | uid=\(d.uid)")
        }
        print("menu choice: \(preferredOutputUID ?? "Automatic")"); return true
    }
    if a.count >= 2, a[1] == "--list" {
        for p in audioProcesses() { print("obj=\(p.obj) pid=\(p.pid) bundle='\(p.bundleID)' input=\(p.input) output=\(p.output)") }
        return true
    }
    // CallScribe --record-test <pid|prefix> <seconds> <outdir>: records without prompt, for permission and signal tests only
    if a.count >= 5, a[1] == "--record-test" {
        let target = a[2], secs = Double(a[3]) ?? 10, dir = URL(fileURLWithPath: a[4])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var objs: [AudioObjectID] = []
        if let pid = Int32(target) { if let o = processObject(forPID: pid) { objs = [o] } }
        else { objs = audioProcesses().filter { $0.bundleID.hasPrefix(target) }.map { $0.obj } }
        print("target objects: \(objs)")
        let r = Recorder()
        r.rescan = { objs }
        let problems = r.start(dir: dir, processObjects: objs)
        print("problems: \(problems)")
        // CALLSCRIBE_TEST_RESTART=<s>: rebuild tap and mic once at second s, to prove the timeline survives a restart
        let restartAt = Double(ProcessInfo.processInfo.environment["CALLSCRIBE_TEST_RESTART"] ?? "") ?? -1
        let t0 = Date(); var restarted = false
        while Date().timeIntervalSince(t0) < secs {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            if restartAt >= 0, !restarted, Date().timeIntervalSince(t0) >= restartAt { restarted = true; r.restartTap(force: true); r.restartMic(force: true) }
            r.health(otherSideActive: true)
        }
        print("device: \(r.device)"); print("frames before stop: mic \(r.micFrames), them \(r.themFrames)")
        let issues = r.stop()
        print("events: \(r.events)"); print("issues: \(issues)")
        return true
    }
    return false
}

if cliMain(CommandLine.arguments) { exit(0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
