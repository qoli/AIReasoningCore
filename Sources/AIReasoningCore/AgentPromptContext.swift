import AnyLanguageModel
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

package struct AgentPromptContext: Sendable {
    package enum Image: Sendable {
        case data(Data, mimeType: String)
        case url(URL)
    }

    package let transcriptText: String
    package let images: [Image]

    package init(transcriptText: String, images: [Image]) {
        self.transcriptText = transcriptText
        self.images = images
    }

    package init(session: LanguageModelSession, maximumImageBytes: Int) throws {
        guard session.tools.isEmpty else {
            throw AgentLanguageModelError.unsupportedTools
        }

        var lines: [String] = []
        var collectedImages: [Image] = []
        var imageIndex = 0

        for entry in session.transcript {
            switch entry {
            case .instructions(let instructions):
                lines.append("[instructions]")
                try Self.append(
                    instructions.segments,
                    to: &lines,
                    images: &collectedImages,
                    imageIndex: &imageIndex,
                    maximumImageBytes: maximumImageBytes
                )
            case .prompt(let prompt):
                lines.append("[user]")
                try Self.append(
                    prompt.segments,
                    to: &lines,
                    images: &collectedImages,
                    imageIndex: &imageIndex,
                    maximumImageBytes: maximumImageBytes
                )
            case .response(let response):
                lines.append("[assistant]")
                try Self.append(
                    response.segments,
                    to: &lines,
                    images: &collectedImages,
                    imageIndex: &imageIndex,
                    maximumImageBytes: maximumImageBytes
                )
            case .toolCalls, .toolOutput:
                throw AgentLanguageModelError.unsupportedTranscriptToolEntry
            }
        }

        self.transcriptText = lines.joined(separator: "\n")
        self.images = collectedImages
    }

    private static func append(
        _ segments: [Transcript.Segment],
        to lines: inout [String],
        images: inout [Image],
        imageIndex: inout Int,
        maximumImageBytes: Int
    ) throws {
        for segment in segments {
            switch segment {
            case .text(let text):
                lines.append(text.content)
            case .structure(let structure):
                lines.append(structure.content.jsonString)
            case .image(let image):
                imageIndex += 1
                lines.append("<image:\(imageIndex)>")
                switch image.source {
                case .data(let data, let mimeType):
                    try validateImage(data: data, mimeType: mimeType, maximumBytes: maximumImageBytes)
                    images.append(.data(data, mimeType: mimeType.lowercased()))
                case .url(let url):
                    guard let scheme = url.scheme?.lowercased(),
                          ["https", "http", "file"].contains(scheme)
                    else {
                        throw AgentLanguageModelError.imageDownloadFailed(
                            "Unsupported image URL scheme: \(url.absoluteString)"
                        )
                    }
                    images.append(.url(url))
                }
            }
        }
    }

    package static func validateImage(
        data: Data,
        mimeType: String,
        maximumBytes: Int
    ) throws {
        guard !data.isEmpty else {
            throw AgentLanguageModelError.emptyImageData
        }
        guard mimeType.lowercased().hasPrefix("image/") else {
            throw AgentLanguageModelError.invalidImageMIMEType(mimeType)
        }
        guard data.count <= maximumBytes else {
            throw AgentLanguageModelError.imageTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumBytes
            )
        }
        let normalizedMIMEType = mimeType.lowercased() == "image/jpg"
            ? "image/jpeg"
            : mimeType.lowercased()
        guard let declaredType = UTType(mimeType: normalizedMIMEType),
              declaredType.conforms(to: .image),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let actualIdentifier = CGImageSourceGetType(source),
              let actualType = UTType(actualIdentifier as String),
              actualType.conforms(to: declaredType)
                || declaredType.conforms(to: actualType)
        else {
            throw AgentLanguageModelError.invalidImageData(
                mimeType: normalizedMIMEType
            )
        }
    }
}

package struct ResolvedImage: Sendable {
    package let data: Data
    package let mimeType: String
}

package enum AgentImageResolver {
    package static func resolve(
        _ image: AgentPromptContext.Image,
        maximumBytes: Int
    ) async throws -> ResolvedImage {
        switch image {
        case .data(let data, let mimeType):
            try AgentPromptContext.validateImage(
                data: data,
                mimeType: mimeType,
                maximumBytes: maximumBytes
            )
            return ResolvedImage(data: data, mimeType: mimeType)
        case .url(let url) where url.isFileURL:
            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw AgentLanguageModelError.imageDownloadFailed(String(describing: error))
            }
            let mimeType = mimeType(forPathExtension: url.pathExtension)
            try AgentPromptContext.validateImage(
                data: data,
                mimeType: mimeType,
                maximumBytes: maximumBytes
            )
            return ResolvedImage(data: data, mimeType: mimeType)
        case .url(let url):
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(from: url)
            } catch {
                throw AgentLanguageModelError.imageDownloadFailed(String(describing: error))
            }
            guard let http = response as? HTTPURLResponse else {
                throw AgentLanguageModelError.imageDownloadFailed(
                    "Image URL did not return an HTTP response"
                )
            }
            guard (200...299).contains(http.statusCode) else {
                throw AgentLanguageModelError.imageDownloadFailed(
                    "HTTP status \(http.statusCode)"
                )
            }
            if http.expectedContentLength > Int64(maximumBytes) {
                throw AgentLanguageModelError.imageTooLarge(
                    actualBytes: Int(http.expectedContentLength),
                    maximumBytes: maximumBytes
                )
            }
            guard let mimeType = http.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first.map({
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                })
            else {
                throw AgentLanguageModelError.imageDownloadFailed(
                    "Missing Content-Type response header"
                )
            }
            try AgentPromptContext.validateImage(
                data: data,
                mimeType: mimeType,
                maximumBytes: maximumBytes
            )
            return ResolvedImage(data: data, mimeType: mimeType.lowercased())
        }
    }

    package static func mimeType(forPathExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic": "image/heic"
        default: "application/octet-stream"
        }
    }
}
