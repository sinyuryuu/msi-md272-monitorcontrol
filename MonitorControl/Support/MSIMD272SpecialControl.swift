//  MSI MD272UPH/MD272UPHW special control path.
//  This display reads volume via DDC 0x62, but ignores DDC writes.
//  Hardware volume writes are exposed through MSI's USB HID "Gaming Controller".

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
