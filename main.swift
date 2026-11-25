import Cocoa
import CoreBluetooth
import AVFoundation
import CoreAudio
import AudioToolbox
import ApplicationServices

// MARK: - Constants & Logging

let kLogDir: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GoogleTVVoiceBridge", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let kLogPath: String = kLogDir.appendingPathComponent("bridge.log").path
let kBuddyMicUID = "BuddyMic2ch_UID"

let kATVVServiceUUID = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
let kATVVTxUUID      = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
let kATVVRxUUID      = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
let kATVVCtlUUID     = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
let kBatterySvcUUID  = CBUUID(string: "180F")
let kBatteryCharUUID = CBUUID(string: "2A19")

let logQueue = DispatchQueue(label: "bridge.log")

func bridgeLog(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    fputs(line, stdout)
    fflush(stdout)
    logQueue.async {
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: kLogPath),
               let fh = FileHandle(forWritingAtPath: kLogPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: kLogPath))
            }
        }
    }
}

// MARK: - IMA-ADPCM Decoder (ATVV v1.0 8kHz 134B / 16kHz 160B frames)

final class ATVVADPCMDecoder {
    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
        157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
    ]
    private static let indexTable: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8
    ]

    /// Decodes a standard ATVV v1.0 frame:
    /// [0..1]: seq (BE UInt16), [2]: id, [3..4]: prevSample (BE Int16), [5]: stepIndex, [6..]: ADPCM (high nibble first)
    func decodeFrame(_ frame: Data, gain: Float) -> [Float] {
        guard frame.count > 6 else { return [] }
        let rawPrev = (Int16(frame[3]) << 8) | Int16(frame[4])
        var predictor = Int32(rawPrev)
        var stepIndex = max(0, min(88, Int32(frame[5])))

        let adpcmCount = frame.count - 6
        var output = [Float]()
        output.reserveCapacity(adpcmCount * 2)

        for i in 6..<frame.count {
            let byte = frame[i]
            let highNibble = Int32((byte >> 4) & 0x0F)
            let lowNibble = Int32(byte & 0x0F)

            output.append(decodeNibble(highNibble, predictor: &predictor, stepIndex: &stepIndex, gain: gain))
            output.append(decodeNibble(lowNibble, predictor: &predictor, stepIndex: &stepIndex, gain: gain))
        }
        return output
    }

    @inline(__always)
    private func decodeNibble(_ nib: Int32, predictor: inout Int32, stepIndex: inout Int32, gain: Float) -> Float {
        let step = Self.stepTable[Int(stepIndex)]
        let diff = ((2 * (nib & 7) + 1) * step) >> 3
        if (nib & 8) != 0 {
            predictor -= diff
        } else {
            predictor += diff
        }
        if predictor > 32767 { predictor = 32767 }
        if predictor < -32768 { predictor = -32768 }

        stepIndex += Self.indexTable[Int(nib)]
        if stepIndex < 0 { stepIndex = 0 }
        if stepIndex > 88 { stepIndex = 88 }

        var sample = (Float(predictor) / 32768.0) * gain
        if sample > 1.0 { sample = 1.0 }
        if sample < -1.0 { sample = -1.0 }
        return sample
    }
}

// MARK: - Virtual Microphone Output (Remote Buddy Mic)

final class VirtualMicPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?
    private var deviceID: AudioDeviceID = 0
    private(set) var deviceName: String = "未检测到"
    private(set) var isReady: Bool = false
    private let audioQueue = DispatchQueue(label: "bridge.audio")

    init() {
        engine.attach(playerNode)
    }

    func findBuddyMicDevice() -> (AudioDeviceID, String)? {
        var propAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &devices) == noErr else {
            return nil
        }

        for dev in devices {
            var streamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(dev, &streamAddr, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue
            }

            let uid = getDeviceStringProperty(dev, selector: kAudioDevicePropertyDeviceUID) ?? ""
            let name = getDeviceStringProperty(dev, selector: kAudioObjectPropertyName) ?? ""
            if uid == kBuddyMicUID || name.localizedCaseInsensitiveContains("Remote Buddy Mic") {
                return (dev, name.isEmpty ? "Remote Buddy Mic" : name)
            }
        }
        return nil
    }

    private func getDeviceStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let str = cfStr?.takeRetainedValue() else { return nil }
        return str as String
    }

    private func ensureAudible(_ dev: AudioDeviceID) {
        for scope in [kAudioDevicePropertyScopeOutput, kAudioDevicePropertyScopeInput] {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var mute: UInt32 = 0
            let muteSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectSetPropertyData(dev, &muteAddr, 0, nil, muteSize, &mute)

            for ch: UInt32 in [0, 1, 2] {
                var volAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: ch
                )
                var vol: Float32 = 1.0
                let volSize = UInt32(MemoryLayout<Float32>.size)
                AudioObjectSetPropertyData(dev, &volAddr, 0, nil, volSize, &vol)
            }
        }
    }

    @discardableResult
    func configure(inputSampleRate: Double = 8000.0) -> Bool {
        audioQueue.sync {
            guard let (dev, name) = findBuddyMicDevice() else {
                isReady = false
                deviceName = "未检测到 Remote Buddy Mic"
                bridgeLog("[AUDIO] Remote Buddy Mic device not found!")
                return false
            }
            deviceID = dev
            deviceName = name
            ensureAudible(dev)

            if engine.isRunning {
                playerNode.stop()
                engine.stop()
            }

            guard let audioUnit = engine.outputNode.audioUnit else {
                isReady = false
                bridgeLog("[AUDIO] Missing outputNode audioUnit")
                return false
            }

            var targetID = dev
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                isReady = false
                bridgeLog("[AUDIO] Failed to bind output device \(name) (OSStatus=\(status))")
                return false
            }

            let hwFormat = engine.outputNode.outputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 else {
                isReady = false
                bridgeLog("[AUDIO] Invalid hwFormat: \(hwFormat)")
                return false
            }

            guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputSampleRate, channels: 1, interleaved: false),
                  let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hwFormat.sampleRate, channels: hwFormat.channelCount, interleaved: false) else {
                isReady = false
                return false
            }

            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: outFmt)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outFmt)
            engine.mainMixerNode.outputVolume = 1.0

            converter = AVAudioConverter(from: inFmt, to: outFmt)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            inputFormat = inFmt
            outputFormat = outFmt

            do {
                engine.prepare()
                try engine.start()
                playerNode.play()
                isReady = true
                bridgeLog("[AUDIO] Ready: \(name) (dev=\(dev), in=\(Int(inputSampleRate))Hz mono -> out=\(Int(outFmt.sampleRate))Hz \(outFmt.channelCount)ch)")
                return true
            } catch {
                isReady = false
                bridgeLog("[AUDIO] Failed to start AVAudioEngine: \(error)")
                return false
            }
        }
    }

    func ensureSampleRate(_ rate: Double) {
        if let current = inputFormat, abs(current.sampleRate - rate) < 1.0, isReady, engine.isRunning {
            if !playerNode.isPlaying { playerNode.play() }
            return
        }
        configure(inputSampleRate: rate)
    }

    func enqueue(samples: [Float]) {
        guard !samples.isEmpty else { return }
        audioQueue.async { [weak self] in
            guard let self = self, self.isReady,
                  let inFmt = self.inputFormat,
                  let outFmt = self.outputFormat,
                  let converter = self.converter else { return }

            if !self.engine.isRunning {
                try? self.engine.start()
            }
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }

            let inCount = AVAudioFrameCount(samples.count)
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCount) else { return }
            inBuf.frameLength = inCount
            if let ch0 = inBuf.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { ptr in
                    ch0.update(from: ptr.baseAddress!, count: samples.count)
                }
            }

            let ratio = outFmt.sampleRate / inFmt.sampleRate
            let outCapacity = AVAudioFrameCount(ceil(Double(inCount) * ratio)) + 16
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCapacity) else { return }

            var consumed = false
            var convError: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuf
            }
            let status = converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
            if status == .error || outBuf.frameLength == 0 {
                return
            }

            if outFmt.channelCount == 2,
               let ch0 = outBuf.floatChannelData?[0],
               let ch1 = outBuf.floatChannelData?[1] {
                let n = Int(outBuf.frameLength)
                var ch1Energy: Float = 0
                for i in 0..<min(n, 32) { ch1Energy += abs(ch1[i]) }
                if ch1Energy == 0 {
                    ch1.update(from: ch0, count: n)
                }
            }

            self.playerNode.scheduleBuffer(outBuf, completionHandler: nil)
        }
    }

    func playTestTone() {
        ensureSampleRate(8000.0)
        var samples = [Float](repeating: 0, count: 8000)
        for i in 0..<8000 {
            let t = Float(i) / 8000.0
            let env: Float = min(1.0, min(t * 20.0, (1.0 - t) * 20.0))
            samples[i] = sin(2.0 * Float.pi * 660.0 * t) * 0.25 * env
        }
        enqueue(samples: samples)
        bridgeLog("[AUDIO] Sent 1s 660Hz test tone to Remote Buddy Mic")
    }
}

// MARK: - Hotkey Trigger Engine

enum HotkeyPreset: String, CaseIterable {
    case fnKey       = "fn"
    case rightOption = "right_option"
    case rightCmd    = "right_command"
    case optSpace    = "option_space"
    case ctrlOptV    = "ctrl_opt_v"
    case ctrlShiftV  = "ctrl_shift_v"
    case cmdShiftSpc = "cmd_shift_space"
    case audioOnly   = "audio_only"

    var title: String {
        switch self {
        case .fnKey:       return "Fn / 🌐 键"
        case .rightOption: return "右 Option (⌥)"
        case .rightCmd:    return "右 Command (⌘)"
        case .optSpace:    return "Option (⌥) + Space"
        case .ctrlOptV:    return "Ctrl (⌃) + Option (⌥) + V"
        case .ctrlShiftV:  return "Ctrl (⌃) + Shift (⇧) + V"
        case .cmdShiftSpc: return "Command (⌘) + Shift (⇧) + Space"
        case .audioOnly:   return "仅传输音频（不自动触发快捷键）"
        }
    }
}

enum TriggerMode: String, CaseIterable {
    case hold       = "hold"
    case tap        = "tap"
    case doubleFn   = "double_fn"

    var title: String {
        switch self {
        case .hold:     return "按住模式（按住语音键=按住热键，松手=松开）"
        case .tap:      return "点按模式（按下点一次开始，松手再点一次结束）"
        case .doubleFn: return "macOS 听写（开始双击 Fn，结束单击 Fn）"
        }
    }
}

final class HotkeyController {
    private var isHolding = false
    private let source = CGEventSource(stateID: .hidSystemState)

    func checkAccessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func triggerStart(preset: HotkeyPreset, mode: TriggerMode) {
        guard preset != .audioOnly else { return }
        if !checkAccessibility(prompt: false) {
            bridgeLog("[HOTKEY] Accessibility not granted! Skipping CGEvent.")
            return
        }
        bridgeLog("[HOTKEY] START preset=\(preset.rawValue) mode=\(mode.rawValue)")
        switch mode {
        case .hold:
            sendPress(preset)
            isHolding = true
        case .tap:
            sendTap(preset)
            isHolding = false
        case .doubleFn:
            sendTap(.fnKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.sendTap(.fnKey)
            }
            isHolding = false
        }
    }

    func triggerStop(preset: HotkeyPreset, mode: TriggerMode) {
        guard preset != .audioOnly else { return }
        if !checkAccessibility(prompt: false) { return }
        bridgeLog("[HOTKEY] STOP preset=\(preset.rawValue) mode=\(mode.rawValue)")
        switch mode {
        case .hold:
            if isHolding {
                sendRelease(preset)
                isHolding = false
            }
        case .tap:
            sendTap(preset)
        case .doubleFn:
            sendTap(.fnKey)
        }
    }

    private func sendTap(_ preset: HotkeyPreset) {
        sendPress(preset)
        usleep(35_000)
        sendRelease(preset)
    }

    private func sendPress(_ preset: HotkeyPreset) {
        switch preset {
        case .fnKey:
            postFlags(keyCode: 63, flags: .maskSecondaryFn)
        case .rightOption:
            postFlags(keyCode: 61, flags: .maskAlternate)
        case .rightCmd:
            postFlags(keyCode: 54, flags: .maskCommand)
        case .optSpace:
            postComboDown(mods: [(58, .maskAlternate)], key: 49, allFlags: .maskAlternate)
        case .ctrlOptV:
            postComboDown(mods: [(59, .maskControl), (58, .maskAlternate)], key: 9, allFlags: [.maskControl, .maskAlternate])
        case .ctrlShiftV:
            postComboDown(mods: [(59, .maskControl), (56, .maskShift)], key: 9, allFlags: [.maskControl, .maskShift])
        case .cmdShiftSpc:
            postComboDown(mods: [(55, .maskCommand), (56, .maskShift)], key: 49, allFlags: [.maskCommand, .maskShift])
        case .audioOnly:
            break
        }
    }

    private func sendRelease(_ preset: HotkeyPreset) {
        switch preset {
        case .fnKey:
            postFlags(keyCode: 63, flags: [])
        case .rightOption:
            postFlags(keyCode: 61, flags: [])
        case .rightCmd:
            postFlags(keyCode: 54, flags: [])
        case .optSpace:
            postComboUp(mods: [58], key: 49, allFlags: .maskAlternate)
        case .ctrlOptV:
            postComboUp(mods: [58, 59], key: 9, allFlags: [.maskControl, .maskAlternate])
        case .ctrlShiftV:
            postComboUp(mods: [56, 59], key: 9, allFlags: [.maskControl, .maskShift])
        case .cmdShiftSpc:
            postComboUp(mods: [56, 55], key: 49, allFlags: [.maskCommand, .maskShift])
        case .audioOnly:
            break
        }
    }

    private func postFlags(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: !flags.isEmpty) else { return }
        ev.type = .flagsChanged
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }

    private func postComboDown(mods: [(CGKeyCode, CGEventFlags)], key: CGKeyCode, allFlags: CGEventFlags) {
        var acc: CGEventFlags = []
        for (code, flag) in mods {
            acc.insert(flag)
            postFlags(keyCode: code, flags: acc)
            usleep(10_000)
        }
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = allFlags
            down.post(tap: .cghidEventTap)
        }
    }

    private func postComboUp(mods: [CGKeyCode], key: CGKeyCode, allFlags: CGEventFlags) {
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = allFlags
            up.post(tap: .cghidEventTap)
        }
        usleep(10_000)
        for code in mods {
            postFlags(keyCode: code, flags: [])
            usleep(8_000)
        }
    }
}

// MARK: - Main Bridge Application Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var statusItem: NSStatusItem!
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var atvvTx: CBCharacteristic?
    private var atvvRx: CBCharacteristic?
    private var atvvCtl: CBCharacteristic?
    private var capsSent = false

    private let decoder = ATVVADPCMDecoder()
    private let audioPlayer = VirtualMicPlayer()
    private let hotkeyController = HotkeyController()

    private var frameBuffer = Data()
    private var expectedFrameSize = 134
    private var activeSampleRate: Double = 8000.0
    private var isStreaming = false
    private var sessionCounter: UInt64 = 0
    private var frameCount = 0
    private var batteryLevel: Int?
    private var connectionText = "正在初始化蓝牙..."
    private var watchdogTimer: Timer?
    private var reconnectTimer: Timer?
    private var lastAudioPacketTime = Date.distantPast

    private var lastPeripheralUUID: String? {
        get { UserDefaults.standard.string(forKey: "lastPeripheralUUID") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPeripheralUUID") }
    }

    private var selectedHotkey: HotkeyPreset {
        get {
            if let raw = UserDefaults.standard.string(forKey: "hotkey"),
               let p = HotkeyPreset(rawValue: raw) { return p }
            return .fnKey
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey")
            rebuildMenu()
        }
    }

    private var selectedTriggerMode: TriggerMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: "triggerMode"),
               let m = TriggerMode(rawValue: raw) { return m }
            return .hold
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "triggerMode")
            rebuildMenu()
        }
    }

    private var gain: Float {
        get {
            let v = UserDefaults.standard.float(forKey: "gain")
            return v > 0 ? v : 1.5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "gain")
            rebuildMenu()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bridgeLog("========== GoogleTVVoiceBridge Launching ==========")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()

        audioPlayer.configure(inputSampleRate: 8000.0)
        central = CBCentralManager(delegate: self, queue: nil)
        rebuildMenu()

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.tryAutoConnectIfNeeded()
        }
    }

    private func updateStatusIcon() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let btn = self.statusItem?.button else { return }
            if self.isStreaming {
                btn.title = "🔴 语音"
            } else if self.targetPeripheral?.state == .connected && self.atvvTx != nil {
                btn.title = "🎙️ 就绪"
            } else {
                btn.title = "⚪️ 遥控"
            }
        }
    }

    private func rebuildMenu() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let menu = NSMenu()

            let batStr = self.batteryLevel.map { " · 电量 \($0)%" } ?? ""
            let statusLine = NSMenuItem(title: "状态：\(self.connectionText)\(batStr)", action: nil, keyEquivalent: "")
            statusLine.isEnabled = false
            menu.addItem(statusLine)

            let micStatus = self.audioPlayer.isReady ? "就绪 (\(self.audioPlayer.deviceName))" : "未就绪 (\(self.audioPlayer.deviceName))"
            let micLine = NSMenuItem(title: "虚拟麦克风：\(micStatus)", action: nil, keyEquivalent: "")
            micLine.isEnabled = false
            menu.addItem(micLine)

            let axOK = self.hotkeyController.checkAccessibility(prompt: false)
            let axItem = NSMenuItem(
                title: axOK ? "辅助功能权限：已授权 ✅" : "辅助功能权限：未授权（点击前往授权）⚠️",
                action: axOK ? nil : #selector(self.requestAccessibility),
                keyEquivalent: ""
            )
            axItem.target = self
            menu.addItem(axItem)

            menu.addItem(.separator())

            let hotkeyMenu = NSMenu()
            for preset in HotkeyPreset.allCases {
                let item = NSMenuItem(title: preset.title, action: #selector(self.selectHotkey(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = preset.rawValue
                item.state = (preset == self.selectedHotkey) ? .on : .off
                hotkeyMenu.addItem(item)
            }
            let hotkeyParent = NSMenuItem(title: "语音热键：\(self.selectedHotkey.title)", action: nil, keyEquivalent: "")
            hotkeyParent.submenu = hotkeyMenu
            menu.addItem(hotkeyParent)

            let modeMenu = NSMenu()
            for mode in TriggerMode.allCases {
                let item = NSMenuItem(title: mode.title, action: #selector(self.selectTriggerMode(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = mode.rawValue
                item.state = (mode == self.selectedTriggerMode) ? .on : .off
                modeMenu.addItem(item)
            }
            let modeShort = self.selectedTriggerMode == .hold ? "按住模式" : (self.selectedTriggerMode == .tap ? "点按模式" : "双击 Fn")
            let modeParent = NSMenuItem(title: "触发方式：\(modeShort)", action: nil, keyEquivalent: "")
            modeParent.submenu = modeMenu
            menu.addItem(modeParent)

            let gainMenu = NSMenu()
            for g: Float in [1.0, 1.5, 2.0, 3.0] {
                let item = NSMenuItem(title: String(format: "%.1fx", g), action: #selector(self.selectGain(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = g
                item.state = abs(g - self.gain) < 0.05 ? .on : .off
                gainMenu.addItem(item)
            }
            let gainParent = NSMenuItem(title: String(format: "麦克风增益：%.1fx", self.gain), action: nil, keyEquivalent: "")
            gainParent.submenu = gainMenu
            menu.addItem(gainParent)

            menu.addItem(.separator())

            let testItem = NSMenuItem(title: "发送 1 秒测试音到 Remote Buddy Mic", action: #selector(self.sendTestTone), keyEquivalent: "")
            testItem.target = self
            menu.addItem(testItem)

            let reconnItem = NSMenuItem(title: "重新扫描并连接遥控器", action: #selector(self.manualReconnect), keyEquivalent: "r")
            reconnItem.target = self
            menu.addItem(reconnItem)

            let logItem = NSMenuItem(title: "打开运行日志", action: #selector(self.openLogFile), keyEquivalent: "")
            logItem.target = self
            menu.addItem(logItem)

            menu.addItem(.separator())
            let quitItem = NSMenuItem(title: "退出 GoogleTVVoiceBridge", action: #selector(self.quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)

            self.statusItem.menu = menu
            self.updateStatusIcon()
        }
    }

    // MARK: - Menu Actions

    @objc private func requestAccessibility() {
        _ = hotkeyController.checkAccessibility(prompt: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let preset = HotkeyPreset(rawValue: raw) {
            selectedHotkey = preset
            bridgeLog("[PREF] Hotkey changed to \(preset.rawValue)")
        }
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = TriggerMode(rawValue: raw) {
            selectedTriggerMode = mode
            bridgeLog("[PREF] Trigger mode changed to \(mode.rawValue)")
        }
    }

    @objc private func selectGain(_ sender: NSMenuItem) {
        if let g = sender.representedObject as? Float {
            gain = g
            bridgeLog("[PREF] Gain changed to \(g)")
        }
    }

    @objc private func sendTestTone() {
        audioPlayer.playTestTone()
    }

    @objc private func manualReconnect() {
        if let p = targetPeripheral {
            central.cancelPeripheralConnection(p)
        }
        targetPeripheral = nil
        atvvTx = nil; atvvRx = nil; atvvCtl = nil; capsSent = false
        connectionText = "正在重新扫描..."
        rebuildMenu()
        startDiscovery()
    }

    @objc private func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: kLogPath))
    }

    @objc private func quitApp() {
        if isStreaming {
            finishVoiceSession(reason: "app_quit")
        }
        NSApplication.shared.terminate(nil)
    }

    // MARK: - CoreBluetooth Discovery & Connection

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bridgeLog("[BLE] Central state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            startDiscovery()
        case .unauthorized:
            connectionText = "蓝牙未授权 ⚠️"
            rebuildMenu()
        case .poweredOff:
            connectionText = "蓝牙已关闭"
            rebuildMenu()
        default:
            connectionText = "等待蓝牙就绪..."
            rebuildMenu()
        }
    }

    private func tryAutoConnectIfNeeded() {
        guard central.state == .poweredOn else { return }
        if let p = targetPeripheral, p.state == .connected || p.state == .connecting {
            return
        }
        startDiscovery()
    }

    private func startDiscovery() {
        guard central.state == .poweredOn else { return }
        let svcs = [CBUUID(string: "1812"), CBUUID(string: "180A"), kBatterySvcUUID, kATVVServiceUUID]
        let connected = central.retrieveConnectedPeripherals(withServices: svcs)
        for p in connected {
            if isTargetRemote(p, advName: nil) {
                connect(p, via: "system_connected")
                return
            }
        }
        if let saved = lastPeripheralUUID, let uuid = UUID(uuidString: saved) {
            let known = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = known.first {
                connect(p, via: "saved_uuid")
                return
            }
        }
        connectionText = "正在扫描 Google TV Remote..."
        rebuildMenu()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func isTargetRemote(_ p: CBPeripheral, advName: String?) -> Bool {
        let name = p.name ?? advName ?? ""
        if name.localizedCaseInsensitiveContains("Google TV") || name.localizedCaseInsensitiveContains("Chromecast") {
            return true
        }
        if let saved = lastPeripheralUUID,
           p.identifier.uuidString.caseInsensitiveCompare(saved) == .orderedSame {
            return true
        }
        return false
    }

    private func connect(_ p: CBPeripheral, via source: String) {
        central.stopScan()
        targetPeripheral = p
        p.delegate = self
        capsSent = false
        lastPeripheralUUID = p.identifier.uuidString
        connectionText = "正在连接 \(p.name ?? "Google TV Remote")..."
        bridgeLog("[BLE] Connecting to '\(p.name ?? "?")' (\(p.identifier.uuidString)) via \(source)")
        rebuildMenu()
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if isTargetRemote(peripheral, advName: advName) {
            connect(peripheral, via: "scan")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        bridgeLog("[BLE] Connected to \(peripheral.name ?? "Google TV Remote")")
        connectionText = "已连接 \(peripheral.name ?? "Google TV Remote")（初始化中）"
        rebuildMenu()
        peripheral.discoverServices([kATVVServiceUUID, kBatterySvcUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        bridgeLog("[BLE] Failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectionText = "连接失败，等待重试..."
        targetPeripheral = nil
        rebuildMenu()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        bridgeLog("[BLE] Disconnected: \(error?.localizedDescription ?? "clean")")
        if isStreaming {
            finishVoiceSession(reason: "ble_disconnect")
        }
        atvvTx = nil; atvvRx = nil; atvvCtl = nil; capsSent = false
        connectionText = "遥控器已断开（按任意键自动重连）"
        rebuildMenu()
        central.connect(peripheral, options: nil)
    }

    // MARK: - GATT Services & ATVV Protocol

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            bridgeLog("[BLE] discoverServices error: \(error)")
            return
        }
        for s in peripheral.services ?? [] {
            if s.uuid == kATVVServiceUUID {
                peripheral.discoverCharacteristics([kATVVTxUUID, kATVVRxUUID, kATVVCtlUUID], for: s)
            } else if s.uuid == kBatterySvcUUID {
                peripheral.discoverCharacteristics([kBatteryCharUUID], for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            bridgeLog("[BLE] discoverCharacteristics error: \(error)")
            return
        }
        for c in service.characteristics ?? [] {
            if c.uuid == kATVVTxUUID {
                atvvTx = c
            } else if c.uuid == kATVVRxUUID {
                atvvRx = c
                peripheral.setNotifyValue(true, for: c)
            } else if c.uuid == kATVVCtlUUID {
                atvvCtl = c
                peripheral.setNotifyValue(true, for: c)
            } else if c.uuid == kBatteryCharUUID {
                peripheral.readValue(for: c)
                peripheral.setNotifyValue(true, for: c)
            }
        }

        if service.uuid == kATVVServiceUUID, !capsSent, let tx = atvvTx, atvvRx != nil, atvvCtl != nil {
            capsSent = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                let getCaps = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
                let wt: CBCharacteristicWriteType = tx.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(getCaps, for: tx, type: wt)
                self.connectionText = "已就绪 (\(peripheral.name ?? "Google TV Remote"))"
                bridgeLog("[ATVV] Sent GET_CAPS, ready for voice button!")
                self.rebuildMenu()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            bridgeLog("[BLE] didUpdateValue error: \(error)")
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }

        if characteristic.uuid == kBatteryCharUUID {
            batteryLevel = Int(data[0])
            rebuildMenu()
            return
        }

        if characteristic.uuid == kATVVCtlUUID {
            handleATVVControl(data)
        } else if characteristic.uuid == kATVVRxUUID {
            handleATVVAudio(data)
        }
    }

    private func handleATVVControl(_ data: Data) {
        let cmd = data[0]
        switch cmd {
        case 0x0B: // CAPS_RESP
            if data.count >= 7 {
                let codecs = data[3]
                let frameSize = (Int(data[5]) << 8) | Int(data[6])
                if frameSize >= 64 && frameSize <= 256 {
                    expectedFrameSize = frameSize
                }
                if (codecs & 0x02) != 0 && (codecs & 0x01) == 0 {
                    activeSampleRate = 16000.0
                } else {
                    activeSampleRate = 8000.0
                }
                audioPlayer.ensureSampleRate(activeSampleRate)
                bridgeLog("[ATVV] CAPS_RESP codecs=0x\(String(format: "%02X", codecs)) frameSize=\(expectedFrameSize) rate=\(Int(activeSampleRate))Hz")
            }

        case 0x04: // AUDIO_START
            if data.count >= 3 {
                let codec = data[2]
                let rate: Double = (codec == 0x02) ? 16000.0 : 8000.0
                activeSampleRate = rate
            }
            startVoiceSession()

        case 0x0A: // AUDIO_SYNC
            if !frameBuffer.isEmpty && frameBuffer.count < expectedFrameSize {
                frameBuffer.removeAll(keepingCapacity: true)
            }

        case 0x00: // AUDIO_STOP
            finishVoiceSession(reason: "remote_stop")

        case 0x08: // START_SEARCH
            if !isStreaming {
                startVoiceSession()
            }

        default:
            break
        }
    }

    private func startVoiceSession() {
        if isStreaming { return }
        isStreaming = true
        sessionCounter &+= 1
        frameCount = 0
        frameBuffer.removeAll(keepingCapacity: true)
        lastAudioPacketTime = Date()
        audioPlayer.ensureSampleRate(activeSampleRate)
        bridgeLog("[VOICE] Session START id=\(sessionCounter) (rate=\(Int(activeSampleRate))Hz, frameSize=\(expectedFrameSize), gain=\(gain))")
        updateStatusIcon()

        hotkeyController.triggerStart(preset: selectedHotkey, mode: selectedTriggerMode)

        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, self.isStreaming else { return }
            if Date().timeIntervalSince(self.lastAudioPacketTime) > 2.5 {
                bridgeLog("[VOICE] Watchdog timeout (no audio packets for 2.5s)")
                self.finishVoiceSession(reason: "watchdog")
            }
        }
    }

    private func handleATVVAudio(_ data: Data) {
        if !isStreaming {
            startVoiceSession()
        }
        lastAudioPacketTime = Date()
        frameBuffer.append(data)

        while frameBuffer.count >= expectedFrameSize {
            let frame = Data(frameBuffer.prefix(expectedFrameSize))
            frameBuffer.removeFirst(expectedFrameSize)
            let samples = decoder.decodeFrame(frame, gain: gain)
            audioPlayer.enqueue(samples: samples)
            frameCount += 1
        }
    }

    private func finishVoiceSession(reason: String) {
        guard isStreaming else { return }
        isStreaming = false
        let finishedSessionID = sessionCounter
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if frameBuffer.count > 6 {
            let samples = decoder.decodeFrame(frameBuffer, gain: gain)
            audioPlayer.enqueue(samples: samples)
        }
        frameBuffer.removeAll(keepingCapacity: true)

        let totalFrames = frameCount
        bridgeLog("[VOICE] Session STOP id=\(finishedSessionID) reason=\(reason) frames=\(totalFrames)")
        updateStatusIcon()

        let preset = selectedHotkey
        let mode = selectedTriggerMode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self = self, self.sessionCounter == finishedSessionID else { return }
            self.hotkeyController.triggerStop(preset: preset, mode: mode)
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
