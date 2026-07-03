import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "AutoIntelService")

/// On-device auto-title + auto-categorize via Apple's Foundation Models framework.
/// Fully gated behind macOS 26 + model availability; degrades gracefully when unavailable.
/// Runs off the main actor and never blocks capture; results surface through the review toast.
final class AutoIntelService {
    static let shared = AutoIntelService()

    private init() {}

    /// Proposed metadata from the model (or a fallback).
    struct Suggestion {
        let title: String
        let category: String
    }

    /// Process a freshly-captured note. If the model is available it proposes a title and
    /// category and shows the review toast; otherwise it does nothing (the note already has
    /// a sensible default filename and category from capture).
    func process(note: Note, body: String) {
        guard PreferencesManager.shared.autoIntelEnabled else { return }

        #if canImport(FoundationModels)
        if #available(macOS 26, *), isModelAvailable {
            Task.detached(priority: .utility) { [weak self] in
                guard let self = self else { return }
                if let suggestion = await self.generate(body: body) {
                    await MainActor.run {
                        self.presentReview(note: note, suggestion: suggestion)
                    }
                }
            }
            return
        }
        #endif

        // Unavailable: feature simply off, no toast nag (capture already produced sane defaults).
        log.debug("Auto-intel unavailable; using capture defaults")
    }

    // MARK: - Availability

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private var isModelAvailable: Bool {
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
    }

    /// Run guided generation for a {title, category} pair against the on-device model.
    @available(macOS 26, *)
    private func generate(body: String) async -> Suggestion? {
        let categories = currentCategoryList()
        let categoryHint = categories.isEmpty
            ? "Pick a short, general one-or-two word category."
            : "You MUST reuse one of these existing categories whenever the note plausibly fits it, copying its exact spelling: \(categories.joined(separator: ", ")). Only invent a short new category when none of them fit."

        let instructions = """
        You generate metadata for a quick note. Produce a concise title (max 6 words, no quotes) \
        that summarizes the note, and a single category. \(categoryHint)
        """

        let prompt = "Note content:\n\(body.prefix(2000))"

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: NoteMeta.self)
            let meta = response.content
            let title = meta.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = meta.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let resolved = category.isEmpty
                ? Note.uncategorized
                : Self.matchExistingCategory(category, in: categories)
            return Suggestion(title: title, category: resolved)
        } catch {
            log.error("Foundation Models generation failed: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    private func currentCategoryList() -> [String] {
        NoteStore.shared.categories()
    }

    /// Snap a model-proposed category onto an existing one when it matches case-insensitively,
    /// so "work"/"Work" reuse the same folder instead of creating a near-duplicate. Returns the
    /// existing category's exact spelling on a match, otherwise the proposed name unchanged.
    static func matchExistingCategory(_ proposed: String, in existing: [String]) -> String {
        existing.first { $0.localizedCaseInsensitiveCompare(proposed) == .orderedSame } ?? proposed
    }

    // MARK: - Review

    @MainActor
    private func presentReview(note: Note, suggestion: Suggestion) {
        // Re-resolve the note in case it moved; only proceed if it still exists.
        guard FileManager.default.fileExists(atPath: note.url.path),
              let root = NoteStore.shared.rootURL,
              let current = Note.from(url: note.url, storeRoot: root) else {
            return
        }

        ReviewToast.shared.show(
            note: current,
            suggestedTitle: suggestion.title,
            suggestedCategory: suggestion.category,
            timeout: PreferencesManager.shared.toastTimeout
        )
    }

    /// Apply a reviewed suggestion to a note (rename + move). Used by the review toast on accept.
    /// Validation (rule #7):
    /// - If `title` slugifies to empty, skip the rename (no `note-<timestamp>` clobber).
    /// - If `category` is empty/whitespace, KEEP the note's current category.
    /// - Sanitize the category (rule #1) before moving.
    /// - Re-resolve the note's existence before each filesystem op (rule #6); abort if gone.
    @discardableResult
    func apply(title: String, category: String, to note: Note) -> Note? {
        // Abort if the file vanished externally between capture and review.
        guard FileManager.default.fileExists(atPath: note.url.path) else {
            return nil
        }
        var working = note

        // Rename only when the new title differs AND produces a non-empty slug.
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle != note.title, !NoteStore.slug(trimmedTitle).isEmpty {
            if let renamed = NoteStore.shared.rename(working, to: trimmedTitle) {
                working = renamed
            }
        }

        // Category: empty field => keep current; otherwise sanitize and move if it changed.
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCategory.isEmpty {
            let targetCategory = NoteStore.sanitizeCategory(trimmedCategory) // nil => Uncategorized
            if targetCategory != working.category,
               FileManager.default.fileExists(atPath: working.url.path),
               let moved = NoteStore.shared.move(working, to: targetCategory) {
                working = moved
            }
        }
        return working
    }
}

#if canImport(FoundationModels)
/// Structured output for guided generation.
@available(macOS 26, *)
@Generable
struct NoteMeta {
    @Guide(description: "A concise note title, max 6 words, no surrounding quotes.")
    var title: String

    @Guide(description: "A single short category name for the note.")
    var category: String
}
#endif
