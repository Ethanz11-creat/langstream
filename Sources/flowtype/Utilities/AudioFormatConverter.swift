import Foundation
import AVFoundation

enum AudioFormatConverter {
    static func convertToWAV(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Int32(buffer.format.sampleRate)
        let channels = UInt16(buffer.format.channelCount)

        // Convert float to Int16
        var int16Data = Data()
        int16Data.reserveCapacity(frameLength * 2)

        for i in 0..<frameLength {
            let sample = max(-1.0, min(1.0, channelData[i]))
            let int16Sample = Int16(sample * 32767.0)
            int16Data.append(withUnsafeBytes(of: int16Sample.littleEndian) { Data($0) })
        }

        // WAV header
        let header = createWAVHeader(dataSize: int16Data.count, sampleRate: sampleRate, channels: channels)
        return header + int16Data
    }

    /// Normalize peak amplitude to target level, then convert to WAV.
    /// If peak < 0.1 (-20 dB), gain is applied to reach targetPeak.
    static func normalizeAndConvertToWAV(_ buffer: AVAudioPCMBuffer, targetPeak: Float = 0.95) -> Data? {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return nil }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Int32(buffer.format.sampleRate)
        let channels = UInt16(buffer.format.channelCount)

        // Compute peak amplitude
        var peak: Float = 0.0
        for i in 0..<frameLength {
            peak = max(peak, abs(channelData[i]))
        }

        let gain: Float
        if peak < 0.1 {
            // Low amplitude: normalize up to targetPeak
            gain = targetPeak / max(peak, 0.0001)
        } else {
            gain = 1.0
        }

        var int16Data = Data()
        int16Data.reserveCapacity(frameLength * 2)

        for i in 0..<frameLength {
            var sample = channelData[i] * gain
            sample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(sample * 32767.0)
            int16Data.append(withUnsafeBytes(of: int16Sample.littleEndian) { Data($0) })
        }

        let header = createWAVHeader(dataSize: int16Data.count, sampleRate: sampleRate, channels: channels)
        return header + int16Data
    }

    /// Energy-based silence trimming with padding.
    /// Scans for first/last frame above threshold and keeps paddingFrames around them.
    static func trimSilence(_ buffer: AVAudioPCMBuffer, threshold: Float = 0.01, paddingFrames: Int = 800) -> AVAudioPCMBuffer {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return buffer }
        let frameLength = Int(buffer.frameLength)

        var firstSpeech = frameLength
        var lastSpeech = 0

        for i in 0..<frameLength {
            if abs(channelData[i]) >= threshold {
                if firstSpeech == frameLength {
                    firstSpeech = i
                }
                lastSpeech = i
            }
        }

        if firstSpeech == frameLength {
            // All silent — return original to avoid empty buffer
            return buffer
        }

        let start = max(0, firstSpeech - paddingFrames)
        let end = min(frameLength, lastSpeech + paddingFrames + 1)
        let newLength = end - start

        guard newLength > 0,
              let newBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(newLength))
        else {
            return buffer
        }

        if let newData = newBuffer.floatChannelData?[0] {
            for i in 0..<newLength {
                newData[i] = channelData[start + i]
            }
            newBuffer.frameLength = AVAudioFrameCount(newLength)
        }

        return newBuffer
    }

    /// Merge multiple WAV files (all same format: 16kHz mono 16-bit PCM) into one.
    /// Each segment's 44-byte header is stripped and a new header is written.
    static func mergeWAVSegments(_ segments: [Data], final: Data?) -> Data? {
        var allPayload = Data()
        for segment in segments {
            if segment.count > 44 {
                allPayload.append(segment.subdata(in: 44..<segment.count))
            }
        }
        if let final = final, final.count > 44 {
            allPayload.append(final.subdata(in: 44..<final.count))
        }
        guard !allPayload.isEmpty else { return nil }
        let header = createWAVHeader(dataSize: allPayload.count, sampleRate: 16000, channels: 1)
        return header + allPayload
    }

    static func createWAVHeader(dataSize: Int, sampleRate: Int32, channels: UInt16) -> Data {
        var header = Data()
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * Int32(channels) * Int32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let totalSize = UInt32(36 + dataSize)

        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: totalSize.littleEndian, { Data($0) }))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian, { Data($0) })) // PCM
        header.append(withUnsafeBytes(of: channels.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: sampleRate.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: byteRate.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: blockAlign.littleEndian, { Data($0) }))
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian, { Data($0) }))
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(dataSize).littleEndian, { Data($0) }))

        return header
    }
}
