import Foundation
import GobyDomain

enum PromptAttachmentPromptRenderer {
    static func render(_ prompt: String, attachments: [PromptAttachment]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let context = attachments.map { attachment in
            switch attachment.source {
            case .localFile:
                let label = attachment.kind == .image ? "Image" : "File"
                return "- \(label): \(attachment.displayName) (verified local attachment)"
            case let .text(text):
                let language = attachment.typeHint?.lowercased() ?? "text"
                return "- \(attachment.displayName):\n```\(language)\n\(text)\n```"
            case nil:
                return "- \(attachment.displayName) (source unavailable)"
            }
        }.joined(separator: "\n")
        return "\(prompt)\n\nAttached context:\n\(context)"
    }
}
