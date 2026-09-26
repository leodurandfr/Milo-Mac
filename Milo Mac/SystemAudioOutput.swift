import CoreAudio
import Foundation

/// The system's default output device, read and set by UID.
///
/// Why this exists: roc-vad cannot change a device in place, so every change to the Milō
/// device is a delete and a re-create — and the re-created device has a new UID, which macOS
/// does not select again on its own: the coreaudiod log of 2026-09-25 shows the output falling
/// back to the Mac's speakers and staying there until someone picked Milō by hand. Re-creating
/// under the *same* UID is not the fix either: done right after the delete, it hung roc-vad's
/// driver inside coreaudiod (2026-09-26) until coreaudiod was restarted.
///
/// So the device is re-created under a fresh UID, and whoever deleted it puts the output
/// back. Plain CoreAudio calls, safe from any thread.
enum SystemAudioOutput {

    /// The UID of the current default output device, or nil if it cannot be read.
    static func defaultOutputUID() -> String? {
        var device = AudioObjectID(0)
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != 0 else { return nil }
        return deviceUID(device)
    }

    /// Makes the device with this UID the default output. False when no such device is
    /// published (yet) or CoreAudio refuses.
    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard var device = allDevices().first(where: { deviceUID($0) == uid }) else { return false }
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          size, &device) == noErr
    }

    private static func allDevices() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = globalAddress(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
