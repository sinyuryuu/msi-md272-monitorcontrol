//  MSI MD272UPH/MD272UPHW special control path.
//  This display reads volume via DDC 0x62, but ignores DDC writes.
//  Hardware volume writes are exposed through MSI's USB HID "Gaming Controller".

import AppKit
import Foundation
import os.log
import SimplyCoreAudio

func msiMD272DebugLog(_ message: String) {
  let formatter = ISO8601DateFormatter()
  let line = "\(formatter.string(from: Date())) \(message)\n"
  let url = URL(fileURLWithPath: "/tmp/msi-md272-monitorcontrol.log")
  if let data = line.data(using: .utf8) {
    if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      handle.closeFile()
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }
}

enum MSIMD272HIDVolume {
  static let helperName = "msi-hid-volume-set"

  static func syncSystemVolumeForOSD(_ value: Float) {
    let clampedValue = Float32(min(max(value, 0), 1))
    guard let defaultOutputDevice = app.coreAudio.defaultOutputDevice else {
      msiMD272DebugLog("system OSD volume sync skipped: no default output device")
      return
    }
    let didSet = defaultOutputDevice.setVirtualMainVolume(clampedValue, scope: .output)
    msiMD272DebugLog("system OSD volume sync value=\(clampedValue) didSet=\(didSet) device=\(defaultOutputDevice.name)")
  }

  static func setVolume(_ value: UInt16) -> Bool {
    let clampedValue = min(max(Int(value), 0), 100)
    guard let helperPath = Bundle.main.path(forResource: Self.helperName, ofType: nil) else {
      os_log("MSI HID volume helper not found in app bundle.", type: .error)
      return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: helperPath)
    process.arguments = [String(clampedValue)]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      os_log("Failed to run MSI HID volume helper: %{public}@", type: .error, error.localizedDescription)
      return false
    }

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if process.terminationStatus == 0 {
      os_log("MSI HID volume set to %{public}d. %{public}@", type: .info, clampedValue, output.trimmingCharacters(in: .whitespacesAndNewlines))
      return true
    }

    os_log("MSI HID volume helper failed with status %{public}d. %{public}@ %{public}@", type: .error, process.terminationStatus, output, errorOutput)
    return false
  }
}

enum MSIMD272InputSource: Int, CaseIterable {
  case hdmi1 = 0
  case hdmi2 = 1
  case dp = 2
  case typec = 3

  var helperArgument: String {
    switch self {
    case .hdmi1: return "hdmi1"
    case .hdmi2: return "hdmi2"
    case .dp: return "dp"
    case .typec: return "typec"
    }
  }

  var menuTitle: String {
    switch self {
    case .hdmi1: return "HDMI 1"
    case .hdmi2: return "HDMI 2"
    case .dp: return "DP"
    case .typec: return "Type-C"
    }
  }
}

struct MSIMD272OSDOption {
  let rawValue: Int
  let menuTitle: String
}

struct MSIMD272OSDSetting {
  let command: String
  let menuTitle: String
  let options: [MSIMD272OSDOption]
  let isExperimental: Bool
}

struct MSIMD272OSDAction {
  let command: String
  let menuTitle: String
  let value: Int
}

enum MSIMD272OSDSettings {
  static let stable: [MSIMD272OSDSetting] = [
    MSIMD272OSDSetting(command: "00510", menuTitle: "自動掃描來源", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "關閉"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "開啟"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "00300", menuTitle: "螢幕模式", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "節能"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "使用者"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "sRGB"),
      MSIMD272OSDOption(rawValue: 3, menuTitle: "Display P3"),
      MSIMD272OSDOption(rawValue: 4, menuTitle: "抗藍光"),
      MSIMD272OSDOption(rawValue: 5, menuTitle: "電影"),
      MSIMD272OSDOption(rawValue: 6, menuTitle: "辦公室"),
      MSIMD272OSDOption(rawValue: 7, menuTitle: "黑白模式"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "00310", menuTitle: "Eye Saver", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "關閉"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "開啟"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "00220", menuTitle: "Response Time", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "Normal"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "Fast"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "Fastest"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "002:0", menuTitle: "Screen Size", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "Auto"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "4:3"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "16:9"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "008>0", menuTitle: "KVM", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "自動"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "USB 上行"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "Type-C"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "00820", menuTitle: "OSD Timeout", options: [
      MSIMD272OSDOption(rawValue: 5, menuTitle: "5 秒"),
      MSIMD272OSDOption(rawValue: 10, menuTitle: "10 秒"),
      MSIMD272OSDOption(rawValue: 15, menuTitle: "15 秒"),
      MSIMD272OSDOption(rawValue: 20, menuTitle: "20 秒"),
      MSIMD272OSDOption(rawValue: 30, menuTitle: "30 秒"),
    ], isExperimental: false),
    MSIMD272OSDSetting(command: "008:0", menuTitle: "HDMI CEC", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "關閉"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "開啟"),
    ], isExperimental: false),
  ]

  static let experimental: [MSIMD272OSDSetting] = [
    MSIMD272OSDSetting(command: "00600", menuTitle: "PIP/PBP 模式", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "關閉"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "PIP"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "PBP"),
    ], isExperimental: true),
    MSIMD272OSDSetting(command: "00610", menuTitle: "PIP 輸入", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "HDMI 1"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "HDMI 2"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "DP"),
      MSIMD272OSDOption(rawValue: 3, menuTitle: "Type-C"),
    ], isExperimental: true),
    MSIMD272OSDSetting(command: "00620", menuTitle: "PBP 輸入", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "HDMI 1"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "HDMI 2"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "DP"),
      MSIMD272OSDOption(rawValue: 3, menuTitle: "Type-C"),
    ], isExperimental: true),
    MSIMD272OSDSetting(command: "00630", menuTitle: "PIP 大小", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "Small"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "Medium"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "Large"),
    ], isExperimental: true),
    MSIMD272OSDSetting(command: "00640", menuTitle: "PIP 位置", options: [
      MSIMD272OSDOption(rawValue: 0, menuTitle: "左上"),
      MSIMD272OSDOption(rawValue: 1, menuTitle: "右上"),
      MSIMD272OSDOption(rawValue: 2, menuTitle: "左下"),
      MSIMD272OSDOption(rawValue: 3, menuTitle: "右下"),
    ], isExperimental: true),
  ]

  static let experimentalActions: [MSIMD272OSDAction] = [
    MSIMD272OSDAction(command: "00650", menuTitle: "切換顯示", value: 1),
    MSIMD272OSDAction(command: "00660", menuTitle: "切換音訊", value: 1),
  ]
}

enum MSIMD272HIDInput {
  static let helperName = "msi-hid-input-set"

  private static func runHelper(arguments: [String]) -> (status: Int32, output: String, error: String)? {
    guard let helperPath = Bundle.main.path(forResource: helperName, ofType: nil) else {
      os_log("MSI HID input helper not found in app bundle.", type: .error)
      return nil
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: helperPath)
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      os_log("Failed to run MSI HID input helper: %{public}@", type: .error, error.localizedDescription)
      return nil
    }

    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, output, errorOutput)
  }

  static func getInputSource() -> MSIMD272InputSource? {
    guard let result = self.runHelper(arguments: ["--get-input"]) else {
      return nil
    }
    guard result.status == 0 else {
      msiMD272DebugLog("input get failed status=\(result.status) output=\(result.output) error=\(result.error)")
      return nil
    }
    for line in result.output.components(separatedBy: .newlines) {
      let parts = line.components(separatedBy: "\t")
      if parts.count >= 2, parts[0] == "目前來源", let rawValue = Int(parts[1]) {
        let source = MSIMD272InputSource(rawValue: rawValue)
        msiMD272DebugLog("input get source=\(source?.helperArgument ?? "unknown") raw=\(rawValue)")
        return source
      }
    }
    msiMD272DebugLog("input get parse failed output=\(result.output)")
    return nil
  }

  static func setInputSource(_ source: MSIMD272InputSource) -> Bool {
    guard let result = self.runHelper(arguments: ["--input", source.helperArgument]) else {
      return false
    }
    let success = result.status == 0 && result.output.contains("5600+")
    msiMD272DebugLog("input set source=\(source.helperArgument) success=\(success) status=\(result.status) output=\(result.output) error=\(result.error)")
    return success
  }

  static func getCommand(_ command: String) -> Int? {
    guard let result = self.runHelper(arguments: ["--get", command]) else {
      return nil
    }
    guard result.status == 0 else {
      msiMD272DebugLog("osd get failed command=\(command) status=\(result.status) output=\(result.output) error=\(result.error)")
      return nil
    }
    for line in result.output.components(separatedBy: .newlines) {
      let parts = line.components(separatedBy: "\t")
      if parts.count >= 3, parts[0] == "目前值", parts[1] == command, let rawValue = Int(parts[2]) {
        msiMD272DebugLog("osd get command=\(command) raw=\(rawValue)")
        return rawValue
      }
    }
    msiMD272DebugLog("osd get parse failed command=\(command) output=\(result.output)")
    return nil
  }

  static func setCommand(_ command: String, value: Int) -> Bool {
    guard let result = self.runHelper(arguments: ["--set", command, String(value)]) else {
      return false
    }
    var success = result.status == 0 && result.output.contains("5600+")
    if !success, result.status == 0 {
      for attempt in 1 ... 5 {
        Thread.sleep(forTimeInterval: command.hasPrefix("006") ? 0.45 : 0.2)
        let verifiedValue = self.getCommand(command)
        msiMD272DebugLog("osd set verify command=\(command) attempt=\(attempt) expected=\(value) actual=\(verifiedValue.map(String.init) ?? "nil")")
        if verifiedValue == value {
          success = true
          break
        }
      }
    }
    msiMD272DebugLog("osd set command=\(command) value=\(value) success=\(success) status=\(result.status) output=\(result.output) error=\(result.error)")
    return success
  }
}

extension OtherDisplay {
  var isMSIMD272SpecialDisplay: Bool {
    let normalizedName = self.name.uppercased()
    return normalizedName.contains("MSI MD272UPH") || normalizedName.contains("MSI MD272UPHW")
  }

  func convertMSIMD272MuteReadValue(_ value: Int) -> Int {
    guard self.isMSIMD272SpecialDisplay else {
      return value
    }
    switch value {
    case 1: return 2 // MSI raw 1 = unmuted; MonitorControl internal 2 = unmuted.
    case 2: return 1 // MSI raw 2 = muted; MonitorControl internal 1 = muted.
    default: return value
    }
  }

  func convertMSIMD272MuteWriteValue(_ value: UInt16) -> UInt16 {
    guard self.isMSIMD272SpecialDisplay else {
      return value
    }
    switch value {
    case 1: return 2 // MonitorControl mute -> MSI raw muted.
    case 2: return 1 // MonitorControl unmute -> MSI raw unmuted.
    default: return value
    }
  }

  func refreshMSIMD272BrightnessFromDisplay() {
    guard self.isMSIMD272SpecialDisplay, !self.isSw(), !app.safeMode else {
      return
    }
    let delay = self.readPrefAsBool(key: .longerDelay) ? UInt64(40 * kMillisecondScale) : nil
    guard let brightnessValues = self.readDDCValues(for: .brightness, tries: UInt(max(self.pollingCount, 3)), minReplyDelay: delay) else {
      msiMD272DebugLog("brightness refresh failed")
      return
    }
    let brightnessValue = self.convDDCToValue(for: .brightness, from: brightnessValues.current)
    self.savePref(brightnessValue, for: .brightness)
    self.smoothBrightnessTransient = brightnessValue
    self.brightnessSyncSourceValue = brightnessValue
    if let slider = self.sliderHandler[.brightness] {
      DispatchQueue.main.async {
        slider.setValue(brightnessValue, displayID: self.identifier)
      }
    }
    msiMD272DebugLog("brightness refresh current=\(brightnessValues.current) internal=\(brightnessValue)")
  }

  func stepMSIMD272HardwareBrightness(isUp: Bool) {
    guard self.isMSIMD272SpecialDisplay, !self.isSw(), !app.safeMode else {
      return
    }
    let delay = self.readPrefAsBool(key: .longerDelay) ? UInt64(40 * kMillisecondScale) : nil
    guard let brightnessValues = self.readDDCValues(for: .brightness, tries: UInt(max(self.pollingCount, 5)), minReplyDelay: delay) else {
      msiMD272DebugLog("brightness key raw read failed")
      return
    }
    let maxRaw = max(Int(brightnessValues.max), 100)
    let currentRaw = min(max(Int(brightnessValues.current), 0), maxRaw)
    let currentValue = Float(currentRaw) / Float(maxRaw)
    let nextValue = self.calcNewValue(currentValue: currentValue, isUp: isUp, isSmallIncrement: false)
    let nextRaw = UInt16(min(max(Int(round(nextValue * Float(maxRaw))), 0), maxRaw))
    self.writeDDCValues(command: .brightness, value: nextRaw)
    self.savePref(nextValue, for: .brightness)
    self.smoothBrightnessTransient = nextValue
    self.brightnessSyncSourceValue = nextValue
    if let slider = self.sliderHandler[.brightness] {
      slider.setValue(nextValue, displayID: self.identifier)
    }
    MSIMD272ControlHUD.shared.show(displayID: self.identifier, title: "亮度", value: nextValue)
    msiMD272DebugLog("brightness key raw current=\(currentRaw) max=\(maxRaw) next=\(nextRaw) value=\(nextValue)")
  }

  func powerOffMSIMD272Display() {
    guard self.isMSIMD272SpecialDisplay, !self.isSw(), !app.safeMode else {
      return
    }
    self.writeDDCValues(command: .powerMode, value: 4)
    msiMD272DebugLog("power off sent via DDC 0xD6 value=4")
  }
}

extension DisplayManager {
  func getMSIMD272SpecialDisplays() -> [OtherDisplay] {
    self.getOtherDisplays().filter { $0.isMSIMD272SpecialDisplay && !$0.readPrefAsBool(key: .isDisabled) }
  }
}

final class MSIMD272ControlHUD {
  static let shared = MSIMD272ControlHUD()

  private var panel: NSPanel?
  private var titleLabel: NSTextField?
  private var valueLabel: NSTextField?
  private var segments: [NSBox] = []
  private var hideWorkItem: DispatchWorkItem?

  private init() {}

  func show(displayID: CGDirectDisplayID, title: String, value: Float, muted: Bool = false) {
    DispatchQueue.main.async {
      self.ensurePanel(displayID: displayID)
      self.update(title: title, value: value, muted: muted)
      self.panel?.orderFrontRegardless()
      self.scheduleHide()
    }
  }

  private func ensurePanel(displayID: CGDirectDisplayID) {
    if self.panel == nil {
      self.createPanel()
    }
    self.positionPanel(displayID: displayID)
  }

  private func createPanel() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 280, height: 132),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary, .transient]

    let hudView = NSView(frame: panel.contentView?.bounds ?? .zero)
    hudView.translatesAutoresizingMaskIntoConstraints = false
    hudView.wantsLayer = true
    hudView.layer?.cornerRadius = 18
    hudView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
    hudView.layer?.borderWidth = 1
    hudView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

    let titleLabel = NSTextField(labelWithString: "音量")
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.alignment = .center
    titleLabel.textColor = .white
    titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)

    let valueLabel = NSTextField(labelWithString: "0%")
    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.alignment = .center
    valueLabel.textColor = .white
    valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .bold)

    let segmentStack = NSStackView()
    segmentStack.translatesAutoresizingMaskIntoConstraints = false
    segmentStack.orientation = .horizontal
    segmentStack.alignment = .centerY
    segmentStack.distribution = .fillEqually
    segmentStack.spacing = 4

    var segments: [NSBox] = []
    for _ in 0 ..< 16 {
      let segment = NSBox()
      segment.translatesAutoresizingMaskIntoConstraints = false
      segment.boxType = .custom
      segment.borderType = .noBorder
      segment.cornerRadius = 2
      segment.fillColor = NSColor.white.withAlphaComponent(0.2)
      segmentStack.addArrangedSubview(segment)
      segment.heightAnchor.constraint(equalToConstant: 14).isActive = true
      segments.append(segment)
    }

    panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
    panel.contentView?.addSubview(hudView)
    hudView.addSubview(titleLabel)
    hudView.addSubview(valueLabel)
    hudView.addSubview(segmentStack)

    NSLayoutConstraint.activate([
      hudView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
      hudView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
      hudView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
      hudView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),

      titleLabel.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 18),
      titleLabel.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -18),
      titleLabel.topAnchor.constraint(equalTo: hudView.topAnchor, constant: 18),

      valueLabel.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 18),
      valueLabel.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -18),
      valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

      segmentStack.leadingAnchor.constraint(equalTo: hudView.leadingAnchor, constant: 22),
      segmentStack.trailingAnchor.constraint(equalTo: hudView.trailingAnchor, constant: -22),
      segmentStack.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 14),
      segmentStack.heightAnchor.constraint(equalToConstant: 14),
    ])

    self.panel = panel
    self.titleLabel = titleLabel
    self.valueLabel = valueLabel
    self.segments = segments
  }

  private func positionPanel(displayID: CGDirectDisplayID) {
    guard let panel = self.panel else {
      return
    }
    let targetScreen = NSScreen.screens.first { $0.displayID == displayID } ?? NSScreen.main
    guard let screen = targetScreen else {
      return
    }
    let frame = screen.visibleFrame
    let origin = NSPoint(
      x: frame.midX - panel.frame.width / 2,
      y: frame.midY - panel.frame.height / 2
    )
    panel.setFrameOrigin(origin)
  }

  private func update(title: String, value: Float, muted: Bool) {
    let clampedValue = min(max(value, 0), 1)
    let filledSegments = muted ? 0 : Int(round(clampedValue * 16))
    self.titleLabel?.stringValue = title
    self.valueLabel?.stringValue = muted ? "靜音" : "\(Int(round(clampedValue * 100)))%"
    for (index, segment) in self.segments.enumerated() {
      segment.fillColor = index < filledSegments ? NSColor.white.withAlphaComponent(1) : NSColor.white.withAlphaComponent(0.16)
    }
  }

  private func scheduleHide() {
    self.hideWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.panel?.orderOut(nil)
    }
    self.hideWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
  }
}

final class MSIMD272MediaKeyInterceptor {
  static let shared = MSIMD272MediaKeyInterceptor()

  private let runLoopQueue = DispatchQueue(label: "MSI MD272 media key interceptor")
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var runLoop: CFRunLoop?
  private var callback: ((CGEventType, CGEvent) -> CGEvent?)?

  private init() {}

  func update() {
    let displays = DisplayManager.shared.getMSIMD272SpecialDisplays()
    for display in displays {
      display.refreshMSIMD272BrightnessFromDisplay()
    }
    if !displays.isEmpty, !AXIsProcessTrusted() {
      let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
    let isTrusted = AXIsProcessTrusted()
    let shouldRun = isTrusted && !displays.isEmpty && app.sleepID == 0 && app.reconfigureID == 0
    NSLog(
      "MSI MD272 media key interceptor update. shouldRun=%@ trusted=%@ displays=%d sleepID=%d reconfigureID=%d",
      String(shouldRun),
      String(isTrusted),
      displays.count,
      app.sleepID,
      app.reconfigureID
    )
    msiMD272DebugLog("interceptor update shouldRun=\(shouldRun) trusted=\(isTrusted) displays=\(displays.count) names=\(displays.map(\.name).joined(separator: ",")) sleepID=\(app.sleepID) reconfigureID=\(app.reconfigureID)")
    os_log("MSI MD272 media key interceptor update. shouldRun=%{public}@", type: .info, String(shouldRun))
    if shouldRun {
      self.start()
    } else {
      self.stop()
    }
  }

  private func start() {
    guard self.eventTap == nil else {
      return
    }

    let callback: (CGEventType, CGEvent) -> CGEvent? = { type, event in
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
          self.stop()
          self.start()
        }
        return event
      }
      return DispatchQueue.main.sync {
        self.handle(type: type, event: event)
      }
    }
    self.callback = callback

    let eventMask = CGEventMask(1 << UInt32(NX_SYSDEFINED)) | CGEventMask(1 << UInt32(NX_KEYDOWN))
    guard let eventTap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: eventMask,
      callback: { _, type, event, refcon in
        let callback = Unmanaged<CallbackBox>.fromOpaque(refcon!).takeUnretainedValue().callback
        return callback(type, event).map(Unmanaged.passUnretained)
      },
      userInfo: Unmanaged.passUnretained(CallbackBox.shared).toOpaque()
    ) else {
      msiMD272DebugLog("interceptor failed to create event tap")
      NSLog("MSI MD272 media key interceptor failed to create event tap.")
      os_log("MSI MD272 media key interceptor failed to create event tap.", type: .error)
      self.callback = nil
      return
    }

    CallbackBox.shared.callback = callback
    self.eventTap = eventTap
    self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    guard let runLoopSource = self.runLoopSource else {
      os_log("MSI MD272 media key interceptor failed to create run loop source.", type: .error)
      self.stop()
      return
    }

    self.runLoopQueue.async {
      self.runLoop = CFRunLoopGetCurrent()
      CFRunLoopAddSource(self.runLoop, runLoopSource, .commonModes)
      CGEvent.tapEnable(tap: eventTap, enable: true)
      msiMD272DebugLog("interceptor started")
      NSLog("MSI MD272 media key interceptor started.")
      os_log("MSI MD272 media key interceptor started.", type: .info)
      CFRunLoopRun()
    }
  }

  private func stop() {
    if let runLoopSource = self.runLoopSource {
      CFRunLoopSourceInvalidate(runLoopSource)
    }
    if let runLoop = self.runLoop {
      CFRunLoopStop(runLoop)
    }
    if let eventTap = self.eventTap {
      CFMachPortInvalidate(eventTap)
    }
    self.runLoopSource = nil
    self.runLoop = nil
    self.eventTap = nil
    self.callback = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
    guard type.rawValue == UInt32(NX_SYSDEFINED), let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
      return event
    }

    let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
    let keyFlags = Int32(nsEvent.data1 & 0x0000_FFFF)
    let isPressed = ((keyFlags & 0xFF00) >> 8) == 0xA
    let isRepeat = (keyFlags & 0x1) == 0x1

    guard isPressed else {
      return nil
    }

    let displays = DisplayManager.shared.getMSIMD272SpecialDisplays()
    guard !displays.isEmpty else {
      return event
    }

    switch keyCode {
    case NX_KEYTYPE_BRIGHTNESS_UP, NX_KEYTYPE_BRIGHTNESS_DOWN:
      msiMD272DebugLog("brightness event key=\(keyCode) repeat=\(isRepeat)")
      for display in displays {
        display.stepMSIMD272HardwareBrightness(isUp: keyCode == NX_KEYTYPE_BRIGHTNESS_UP)
      }
      return nil
    case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
      msiMD272DebugLog("volume event key=\(keyCode) repeat=\(isRepeat)")
      NSLog("MSI MD272 media key volume event. key=%d repeat=%@", keyCode, String(isRepeat))
      os_log("MSI MD272 media key volume event. key=%{public}d repeat=%{public}@", type: .info, keyCode, String(isRepeat))
      for display in displays {
        display.stepVolume(isUp: keyCode == NX_KEYTYPE_SOUND_UP, isSmallIncrement: false)
      }
      return nil
    case NX_KEYTYPE_MUTE:
      guard !isRepeat else {
        return nil
      }
      msiMD272DebugLog("mute event")
      NSLog("MSI MD272 media key mute event.")
      os_log("MSI MD272 media key mute event.", type: .info)
      for display in displays {
        display.toggleMute()
      }
      return nil
    default:
      return event
    }
  }

  private final class CallbackBox {
    static let shared = CallbackBox()
    var callback: (CGEventType, CGEvent) -> CGEvent? = { _, event in event }
  }
}
