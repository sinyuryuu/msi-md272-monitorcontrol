//  MSI MD272UPH/MD272UPHW special control path.
//  This display reads volume via DDC 0x62, but ignores DDC writes.
//  Hardware volume writes are exposed through MSI's USB HID "Gaming Controller".

import AppKit
import Foundation
import os.log

enum MSIMD272HIDVolume {
  static let helperName = "msi-hid-volume-set"

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
}

extension DisplayManager {
  func getMSIMD272SpecialDisplays() -> [OtherDisplay] {
    self.getOtherDisplays().filter { $0.isMSIMD272SpecialDisplay && !$0.readPrefAsBool(key: .isDisabled) }
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
    let shouldRun = AXIsProcessTrusted() && !DisplayManager.shared.getMSIMD272SpecialDisplays().isEmpty && app.sleepID == 0 && app.reconfigureID == 0
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
    case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
      os_log("MSI MD272 media key volume event. key=%{public}d repeat=%{public}@", type: .info, keyCode, String(isRepeat))
      for display in displays {
        display.stepVolume(isUp: keyCode == NX_KEYTYPE_SOUND_UP, isSmallIncrement: false)
      }
      return nil
    case NX_KEYTYPE_MUTE:
      guard !isRepeat else {
        return nil
      }
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
