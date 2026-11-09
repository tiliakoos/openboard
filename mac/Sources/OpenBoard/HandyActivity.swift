import AppKit
import CoreAudio

/// Observes input activity only; never opens an audio stream or reads samples.
@MainActor
final class HandyActivity {
    private var task: Task<Void, Never>?

    func watch(_ changed: @escaping @MainActor (Bool) -> Void) {
        task?.cancel()
        task = Task {
            var previous: Bool?
            while !Task.isCancelled {
                let running = Self.isRunning()
                if running != previous {
                    previous = running
                    changed(running)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private static func isRunning() -> Bool {
        guard #available(macOS 14.2, *) else { return false }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.pais.handy")
            .map { UInt32($0.processIdentifier) })
        guard !pids.isEmpty else { return false }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
              size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return false }
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).contains { object in
            guard let pid = integer(object, kAudioProcessPropertyPID), pids.contains(pid) else { return false }
            return integer(object, kAudioProcessPropertyIsRunningInput) == 1
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
    }
}
