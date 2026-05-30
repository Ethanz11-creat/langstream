import CoreAudio

struct AudioDevice: Identifiable, Equatable {
    let id: String           // CoreAudio UID
    let name: String         // 显示名称
    let isDefault: Bool      // 是否为系统默认输入设备
    let audioObjectID: AudioObjectID // CoreAudio device ID for routing
}

enum AudioDeviceEnumerator {
    /// Returns all available audio input devices.
    static func availableInputDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []

        // Get default input device ID
        var defaultDeviceID: AudioObjectID = kAudioObjectUnknown
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)
        let defaultResult = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        if defaultResult != noErr {
            AppLogger.log("[AudioDevice] Failed to get default input device: \(defaultResult)")
        }

        // Get all audio devices
        propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeResult = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard sizeResult == noErr else {
            AppLogger.log("[AudioDevice] Failed to get device list size: \(sizeResult)")
            return devices
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        let devicesResult = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard devicesResult == noErr else {
            AppLogger.log("[AudioDevice] Failed to get device list: \(devicesResult)")
            return devices
        }

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputConfigAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inputConfigSize: UInt32 = 0
            let configSizeResult = AudioObjectGetPropertyDataSize(deviceID, &inputConfigAddress, 0, nil, &inputConfigSize)
            guard configSizeResult == noErr else { continue }

            let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferList.deallocate() }
            var mutableSize = inputConfigSize
            let configResult = AudioObjectGetPropertyData(deviceID, &inputConfigAddress, 0, nil, &mutableSize, bufferList)
            guard configResult == noErr else { continue }

            let bufferCount = Int(bufferList.pointee.mNumberBuffers)
            guard bufferCount > 0 else { continue }

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            var uid: CFString?
            let uidResult = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
            guard uidResult == noErr, let deviceUID = uid as String? else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var name: CFString?
            let nameResult = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
            let deviceName = (name as String?) ?? deviceUID

            let isDefault = (deviceID == defaultDeviceID)
            devices.append(AudioDevice(id: deviceUID, name: deviceName, isDefault: isDefault, audioObjectID: deviceID))
        }

        // Sort: default first, then alphabetically
        devices.sort { a, b in
            if a.isDefault != b.isDefault {
                return a.isDefault
            }
            return a.name < b.name
        }

        AppLogger.log("[AudioDevice] Found \(devices.count) input devices")
        return devices
    }

    /// Find device ID by UID for routing.
    static func findDeviceID(uid: String) -> AudioObjectID? {
        let devices = availableInputDevices()
        return devices.first(where: { $0.id == uid })?.audioObjectID
    }
}
