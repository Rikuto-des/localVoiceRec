import Foundation

/// AudioTapKit 内部で発生するエラー。
///
/// - `Contracts.AudioCaptureError` とは別物。`AudioCapture` モジュール側で
///   このエラーを受けて `AudioCaptureError` に翻訳する想定。
public enum AudioTapError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case engineStartFailed(String)
    case tapUIDUnavailable(OSStatus)
    case streamFormatUnavailable(OSStatus)
    case defaultOutputDeviceUnavailable(OSStatus)
    case outputDeviceUIDUnavailable(OSStatus)
    case fileCreationFailed(String)
    case alreadyRunning
    case notRunning

    public var description: String {
        switch self {
        case .osStatus(let label, let s):
            return "\(label) failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .tapCreationFailed(let s):
            return "AudioHardwareCreateProcessTap failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .aggregateDeviceCreationFailed(let s):
            return "AudioHardwareCreateAggregateDevice failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .ioProcCreationFailed(let s):
            return "AudioDeviceCreateIOProcID failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .deviceStartFailed(let s):
            return "AudioDeviceStart failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .engineStartFailed(let m):
            return "AVAudioEngine.start failed: \(m)"
        case .tapUIDUnavailable(let s):
            return "Tap UID property read failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .streamFormatUnavailable(let s):
            return "Stream format property read failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .defaultOutputDeviceUnavailable(let s):
            return "Default output device read failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .outputDeviceUIDUnavailable(let s):
            return "Output device UID read failed: OSStatus=\(s) (\(Self.fourCC(s)))"
        case .fileCreationFailed(let m):
            return "WAV file creation failed: \(m)"
        case .alreadyRunning:
            return "Capture is already running"
        case .notRunning:
            return "Capture is not running"
        }
    }

    /// OSStatus を 4-char-code 文字列に変換する。たとえば `'!obj'` のようにエラー名が
    /// `<CoreAudio/AudioHardwareBase.h>` から判別できることがある。
    public static func fourCC(_ s: OSStatus) -> String {
        let v = UInt32(bitPattern: s)
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xff),
            UInt8((v >> 16) & 0xff),
            UInt8((v >> 8) & 0xff),
            UInt8(v & 0xff),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
        }
        return "raw=\(s)"
    }
}
