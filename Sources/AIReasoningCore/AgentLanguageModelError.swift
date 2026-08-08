import Foundation

public enum AgentLanguageModelUnavailableReason: Error, Sendable, Equatable {
    case executableUnavailable(String)
}

public enum AgentLanguageModelError: Error, LocalizedError, Sendable, Equatable {
    case unavailable(AgentLanguageModelUnavailableReason)
    case unsupportedTools
    case unsupportedGenerationOptions
    case unsupportedStructuredOutput(driver: String)
    case unsupportedTranscriptToolEntry
    case invalidImageMIMEType(String)
    case invalidImageData(mimeType: String)
    case emptyImageData
    case imageTooLarge(actualBytes: Int, maximumBytes: Int)
    case imageDownloadFailed(String)
    case artifactCleanupFailed(String)
    case incompatibleExecutableVersion(
        executable: String,
        found: String,
        minimum: String
    )
    case malformedProtocolMessage(driver: String, message: String)
    case protocolFailure(driver: String, message: String)
    case missingProtocolResult(driver: String)
    case structuredOutputDecodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "Language model unavailable: \(reason)"
        case .unsupportedTools:
            "Agent-backed language models do not accept LanguageModelSession tools in v1"
        case .unsupportedGenerationOptions:
            "The selected agent model cannot losslessly map these GenerationOptions"
        case .unsupportedStructuredOutput(let driver):
            "\(driver) cannot losslessly map structured output through its selected protocol"
        case .unsupportedTranscriptToolEntry:
            "The Swift session transcript contains tool calls or tool output, which agent models do not accept in v1"
        case .invalidImageMIMEType(let mimeType):
            "Invalid image MIME type: \(mimeType)"
        case .invalidImageData(let mimeType):
            "Image data is corrupt or does not match its declared MIME type \(mimeType)"
        case .emptyImageData:
            "Image data is empty"
        case .imageTooLarge(let actualBytes, let maximumBytes):
            "Image is \(actualBytes) bytes; maximum is \(maximumBytes) bytes"
        case .imageDownloadFailed(let message):
            "Image download failed: \(message)"
        case .artifactCleanupFailed(let message):
            "Temporary image cleanup failed: \(message)"
        case .incompatibleExecutableVersion(let executable, let found, let minimum):
            "\(executable) \(found) is older than required version \(minimum)"
        case .malformedProtocolMessage(let driver, let message):
            "\(driver) emitted a malformed protocol message: \(message)"
        case .protocolFailure(let driver, let message):
            "\(driver) protocol failed: \(message)"
        case .missingProtocolResult(let driver):
            "\(driver) ended without a protocol result"
        case .structuredOutputDecodingFailed(let message):
            "Structured output decoding failed: \(message)"
        }
    }
}
