// AgentToolSummary.swift
// Calyx
//
// The tool-specific human-readable string derived from a hook payload's
// tool-input object, shared by the approval banner
// (AgentHookToolCall.summary) and the Agents sidebar's subagent child
// row (AgentEvent.toolSummary). One derivation, so a banner and a row
// describing the same tool call can never disagree about what it is.

import Foundation

enum AgentToolSummary {

    /// A derived summary's cap, in `Character`s. `derive` itself returns
    /// the full string, so a caller that also needs the untruncated value
    /// (or a different cap) is not forced through this one; the cap is
    /// applied by the caller, and by `singleLineSummary` and
    /// `readableArguments`, which stop building at it rather than
    /// trimming afterwards.
    static let maxSummaryLength = 500

    /// `tool_name`s whose summary is the string at `tool_input.file_path`.
    /// `NotebookEdit` is deliberately NOT in this set -- Claude Code's
    /// actual PreToolUse schema for it is `tool_input.notebook_path`, a
    /// distinct key of its own (see `derive`'s own `NotebookEdit` case).
    private static let filePathToolNames: Set<String> = ["Write", "Edit", "Read"]

    /// Tool names whose summary is the string at `tool_input.command`:
    /// Claude Code's and Codex's `Bash`, and Grok's own shell tool
    /// `run_terminal_command`.
    private static let commandToolNames: Set<String> = ["Bash", "run_terminal_command"]

    /// What `readableArguments` writes between two `key: value` pairs.
    private static let pairSeparator = ", "

    /// What `appendCompactJSON` writes between two array elements and
    /// between two object members.
    private static let jsonElementSeparator = ","

    /// The compact JSON of a tool-input object, empty when it holds a
    /// value JSONSerialization cannot encode.
    static func compactJSON(_ toolInput: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: toolInput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// The well-known key per tool name (the command for `Bash` and
    /// Grok's `run_terminal_command`, the file path for
    /// `Write`/`Edit`/`Read`, the notebook path for `NotebookEdit` -- its
    /// own distinct `notebook_path` key, never `file_path` -- the URL for
    /// `WebFetch`), falling back to `fallback` when `toolName` isn't one
    /// of these, or the expected key is absent/not a string.
    ///
    /// `fallback` is the caller's own rendering of the whole tool input
    /// (the approval banner's compact JSON, the sidebar row's readable
    /// `key: value` pairs), and an autoclosure so it is only built when it
    /// is actually the answer: a `Write`'s `tool_input.content` runs to
    /// hundreds of kilobytes while its summary is just the file path.
    static func derive(
        toolName: String,
        toolInput: [String: Any],
        fallback: @autoclosure () -> String
    ) -> String {
        switch toolName {
        case _ where commandToolNames.contains(toolName):
            return (toolInput["command"] as? String) ?? fallback()
        case _ where filePathToolNames.contains(toolName):
            return (toolInput["file_path"] as? String) ?? fallback()
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String) ?? fallback()
        case "WebFetch":
            return (toolInput["url"] as? String) ?? fallback()
        default:
            return fallback()
        }
    }

    /// A derived summary rendered as one line, capped at
    /// `maxSummaryLength` characters: every run of whitespace (spaces,
    /// tabs, newlines, carriage returns) becomes a single space, and
    /// leading and trailing whitespace is dropped. The sidebar's child
    /// row draws its tool line as a single `Text` with `.lineLimit(1)`
    /// and joins its help/accessibility fields with newlines, so a hard
    /// line break inside a summary (a heredoc command, routinely) would
    /// cut the row short of the available width and break the
    /// one-field-per-line structure VoiceOver reads. The approval banner
    /// does not go through this: an operator approving a script sees the
    /// command as written.
    ///
    /// The cap counts characters that survive the collapse, so whitespace
    /// never spends it. That bounds what is emitted, not what is read:
    /// whitespace is walked in full, so a run of a million spaces costs
    /// its own length.
    static func singleLineSummary(_ text: String) -> String {
        var line = BoundedText(limit: maxSummaryLength)
        var pendingSpace = false
        for character in text {
            guard !character.isWhitespace else {
                pendingSpace = !line.value.isEmpty
                continue
            }
            if pendingSpace {
                // The separating space is only worth its budget when the
                // character it separates still fits after it.
                guard line.remaining > 1 else { break }
                line.append(" ")
                pendingSpace = false
            }
            line.append(String(character))
            if line.isFull { break }
        }
        return line.value
    }

    /// A tool input's arguments rendered as `key: value` pairs joined by
    /// `, `, keys sorted so the same call always reads the same way. A
    /// string value is rendered verbatim, a number or a boolean by its
    /// natural spelling, and anything structured (array, object, null) as
    /// the compact JSON of that one value.
    ///
    /// Built incrementally and stopped the moment it reaches
    /// `maxSummaryLength` characters, so a caller on the main actor never
    /// pays for serializing a tool input whose values run to hundreds of
    /// kilobytes: a value that alone exceeds the remaining budget is cut
    /// at the budget instead of being rendered in full first. The budget
    /// bounds the rendering, not the key count: every key is sorted before
    /// the first pair is written, so a tool input with a great many keys
    /// costs that sort whatever the budget is.
    ///
    /// An empty tool input yields an empty string.
    static func readableArguments(_ toolInput: [String: Any]) -> String {
        var text = BoundedText(limit: maxSummaryLength)
        for (index, key) in toolInput.keys.sorted().enumerated() {
            if index > 0 {
                // The separator is only worth its budget when at least
                // one character of the pair behind it still fits, so a
                // summary never ends on a dangling ", ".
                guard text.remaining > pairSeparator.count else { break }
                text.append(pairSeparator)
            }
            text.append(key)
            text.append(": ")
            appendValue(toolInput[key] ?? NSNull(), to: &text)
        }
        return text.value
    }

    /// One argument value: a string verbatim, a number or boolean by its
    /// natural spelling, anything structured as its own compact JSON.
    private static func appendValue(_ value: Any, to text: inout BoundedText) {
        switch value {
        case let string as String:
            text.append(string)
        case let number as NSNumber where isBoolean(number):
            text.append(number.boolValue ? "true" : "false")
        case let number as NSNumber:
            text.append(number.description)
        default:
            appendCompactJSON(value, to: &text)
        }
    }

    /// The compact JSON of one value, written straight into the bounded
    /// buffer: object keys sorted for a stable rendering, and every append
    /// a no-op once the budget is spent, so an oversized value ends up cut
    /// mid-render rather than serialized in full and trimmed.
    private static func appendCompactJSON(_ value: Any, to text: inout BoundedText) {
        guard !text.isFull else { return }
        switch value {
        case is NSNull:
            text.append("null")
        case let number as NSNumber where isBoolean(number):
            text.append(number.boolValue ? "true" : "false")
        case let number as NSNumber:
            text.append(number.description)
        case let string as String:
            appendJSONString(string, to: &text)
        case let array as NSArray:
            text.append("[")
            for (index, element) in array.enumerated() {
                guard !text.isFull else { break }
                if index > 0 {
                    // The separator is only worth its budget when at
                    // least one character of the element behind it still
                    // fits, so a value never ends on a dangling ",".
                    guard text.remaining > jsonElementSeparator.count else { break }
                    text.append(jsonElementSeparator)
                }
                appendCompactJSON(element, to: &text)
            }
            text.append("]")
        case let object as NSDictionary:
            guard let keys = object.allKeys as? [String] else { break }
            text.append("{")
            for (index, key) in keys.sorted().enumerated() {
                guard !text.isFull else { break }
                if index > 0 {
                    // The separator is only worth its budget when at
                    // least one character of the member behind it still
                    // fits, so a value never ends on a dangling ",".
                    guard text.remaining > jsonElementSeparator.count else { break }
                    text.append(jsonElementSeparator)
                }
                appendJSONString(key, to: &text)
                text.append(":")
                appendCompactJSON(object[key] ?? NSNull(), to: &text)
            }
            text.append("}")
        default:
            break
        }
    }

    /// A JSON string literal, escaped one character at a time so a long
    /// string is never escaped past the budget.
    private static func appendJSONString(_ string: String, to text: inout BoundedText) {
        text.append("\"")
        for character in string {
            guard !text.isFull else { return }
            text.append(escaped(character))
        }
        text.append("\"")
    }

    /// One character's JSON spelling inside a string literal.
    private static func escaped(_ character: Character) -> String {
        switch character {
        case "\"": return "\\\""
        case "\\": return "\\\\"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "\t": return "\\t"
        default:
            guard let scalar = character.unicodeScalars.first,
                  character.unicodeScalars.count == 1, scalar.value < 0x20 else {
                return String(character)
            }
            return String(format: "\\u%04x", scalar.value)
        }
    }

    /// Whether a JSON number is really a boolean. `JSONSerialization`
    /// decodes both as `NSNumber`, and an integer one casts to `Bool` just
    /// as happily, so the underlying type is what distinguishes them.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A string that accepts appends until it holds `limit` characters and
    /// ignores every one after that, so a caller can write a rendering out
    /// piece by piece without ever measuring what it skipped.
    private struct BoundedText {
        let limit: Int
        private(set) var value = ""
        private var length = 0

        init(limit: Int) {
            self.limit = limit
        }

        var isFull: Bool { remaining <= 0 }

        /// How many more characters this buffer will accept.
        var remaining: Int { limit - length }

        mutating func append(_ piece: String) {
            for character in piece {
                guard length < limit else { return }
                value.append(character)
                length += 1
            }
        }
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` in half -- backs off to the last whole
    /// character that still fits under `cap`.
    static func truncatedToByteCap(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= cap else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
