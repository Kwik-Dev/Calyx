// AgentPermissionOffer.swift
// Calyx
//
// One entry of Claude Code's PermissionRequest hook payload's top-level
// `permission_suggestions` array (hooks.md), a sibling of `tool_input`
// rather than a key inside it: "the always-allow choices
// the CLI's own dialog itself offers." Decoded by `AgentHookToolCall`
// into `permissionOffers`, rendered by `ApprovalBannerView.
// agentHookMenuItems(toolName:offers:)` as one choice row per offer, and
// echoed back through `ApprovalDecision.
// allowedWithPermissions(_:)` -> `AgentHookPermissionResponse` exactly
// as received -- accepting one is documented to behave the same as
// picking that same choice in the CLI's own dialog.
//
// `label(for:)` is the ONLY place that turns a raw suggestion entry into
// the string a button shows -- derived from the entry's own structured
// fields (`type`/`rules`/`directories`/`mode`/`destination`), never from
// the CLI's own dialog strings or implementation. Kept a pure function,
// independent of `AgentHookToolCall.decode`'s own kind-gated
// `acceptsPermissionUpdates(kind:)` check, so it is directly unit-testable.
// Returns `nil` for an entry with nothing to offer -- see its own doc
// comment for the full contract -- which `AgentHookToolCall.
// decodePermissionOffers` treats as a per-element drop, mirroring Claude
// Code's own dialog intake, which shows no row for a suggestion whose
// label would render empty.

import Foundation

/// One `permission_suggestions` entry, decoded leniently (an entry with
/// nothing to offer is dropped individually, same contract as
/// `AgentHookToolCall.decodeQuestions`'s own per-element leniency) -- see
/// `AgentHookToolCall.permissionOffers`'s own doc comment for the full
/// decode contract.
struct AgentPermissionOffer: Sendable, Equatable {
    /// The choice row's own label -- `label(for:)`'s output, computed
    /// once at decode time.
    let label: String
    /// The suggestion entry, re-serialized verbatim with
    /// `JSONSerialization` -- unknown keys survive, and
    /// `AgentHookPermissionResponse` echoes this back byte-for-byte
    /// (parsed, not re-derived) as the sole element of `updatedPermissions`
    /// when this offer is accepted.
    let entryJSON: Data

    /// Derives one suggestion entry's button label from its own
    /// structured fields alone. `scope`, appended as a trailing " from
    /// this project"/"for this user"/"for this session" suffix wherever
    /// the case below carries one, comes from `destination`
    /// (`projectSettings`/`localSettings` -> "from this project",
    /// `userSettings` -> "for this user", `session` -> "for this
    /// session"; anything else, including a missing or non-string value,
    /// -> no suffix at all, with no trailing space left behind).
    ///
    /// - `addDirectories`: "Yes, and always allow access to <directories
    ///   joined by ", "> <scope>".
    /// - `addRules`: when every rule shares one `toolName` AND every rule
    ///   carries a `ruleContent`, "Yes, and don't ask again for
    ///   <toolName>: <ruleContents joined by ", "> <scope>"; when every
    ///   rule shares one `toolName` and NONE carries a `ruleContent`,
    ///   "Yes, and always allow <toolName> <scope>"; otherwise (more than
    ///   one distinct `toolName`, OR one `toolName` with a mix of rules
    ///   that do and don't carry `ruleContent`) the per-rule form, "Yes,
    ///   and always allow <toolName>(<ruleContent>)|<toolName> joined by
    ///   ", "> <scope>" -- a rule with no `ruleContent` renders as its
    ///   bare `toolName`, never `ToolName()`.
    /// - `setMode`: "Yes, and switch to <mode> mode", `mode` rendered
    ///   verbatim for every value (hooks.md documents that the mode
    ///   labeled Manual arrives on the wire as `"default"`, never as
    ///   `"manual"`, so no value the wire ever carries needs remapping) --
    ///   NEVER carries a scope suffix, even when `destination` is present,
    ///   since a mode switch is session-wide by definition.
    /// - `replaceRules`/`removeRules`: "Yes, and <type> <the per-rule
    ///   form above> <scope>" -- always the per-rule form, regardless of
    ///   how many distinct `toolName`s or how many rules carry
    ///   `ruleContent`.
    /// - `removeDirectories`: "Yes, and removeDirectories <directories
    ///   joined by ", "> <scope>".
    /// - any other non-empty `type`: "Yes, and apply the <type> permission
    ///   update <scope>" -- a forward-compatible label for a suggestion
    ///   type this app doesn't yet special-case; `entryJSON` still echoes
    ///   the entry verbatim, so accepting it still works.
    ///
    /// `nil` -- nothing to offer -- when: `type` is missing, non-`String`,
    /// or empty; for `addRules`/`replaceRules`/`removeRules`, `rules` is
    /// missing, non-array, empty, or any element is not an object with a
    /// non-empty `String` `toolName` and a `ruleContent` that, when
    /// present and not an explicit JSON null, is a non-empty `String` (an
    /// explicit null `ruleContent` counts as absent, not malformed); for
    /// `addDirectories`/`removeDirectories`, `directories` is missing,
    /// non-array, empty, or any element is not a non-empty `String`; for
    /// `setMode`, `mode` is missing, non-`String`, or empty.
    static func label(for entry: [String: Any]) -> String? {
        guard let type = entry["type"] as? String, !type.isEmpty else { return nil }
        let scope = scopeSuffix(for: entry)
        switch type {
        case "addDirectories":
            guard let directories = wellFormedDirectories(entry) else { return nil }
            return "Yes, and always allow access to \(directories.joined(separator: ", "))\(scope)"
        case "addRules":
            guard let rules = wellFormedRules(entry) else { return nil }
            return "Yes, and \(addRulesBody(rules))\(scope)"
        case "setMode":
            guard let mode = entry["mode"] as? String, !mode.isEmpty else { return nil }
            return "Yes, and switch to \(mode) mode"
        case "replaceRules", "removeRules":
            guard let rules = wellFormedRules(entry) else { return nil }
            return "Yes, and \(type) \(mixedRulesForm(rules))\(scope)"
        case "removeDirectories":
            guard let directories = wellFormedDirectories(entry) else { return nil }
            return "Yes, and removeDirectories \(directories.joined(separator: ", "))\(scope)"
        default:
            return "Yes, and apply the \(type) permission update\(scope)"
        }
    }

    /// `entry["directories"]`, well-formed: a non-empty array whose every
    /// element is a non-empty `String`; `nil` otherwise.
    private static func wellFormedDirectories(_ entry: [String: Any]) -> [String]? {
        guard let directories = entry["directories"] as? [Any], !directories.isEmpty else { return nil }
        var result: [String] = []
        for directory in directories {
            guard let directory = directory as? String, !directory.isEmpty else { return nil }
            result.append(directory)
        }
        return result
    }

    /// `entry["rules"]`, well-formed: a non-empty array whose every
    /// element is an object with a non-empty `String` `toolName`, and
    /// whose `ruleContent`, when present and not an explicit JSON null,
    /// is a non-empty `String`; `nil` otherwise. An explicit JSON null
    /// `ruleContent` decodes to `nil` in the returned tuple (absent, not
    /// malformed).
    private static func wellFormedRules(_ entry: [String: Any]) -> [(toolName: String, ruleContent: String?)]? {
        guard let rules = entry["rules"] as? [Any], !rules.isEmpty else { return nil }
        var result: [(toolName: String, ruleContent: String?)] = []
        for rule in rules {
            guard let rule = rule as? [String: Any],
                  let toolName = rule["toolName"] as? String, !toolName.isEmpty else { return nil }
            let ruleContentValue = rule["ruleContent"]
            if ruleContentValue == nil || ruleContentValue is NSNull {
                result.append((toolName: toolName, ruleContent: nil))
            } else if let ruleContent = ruleContentValue as? String, !ruleContent.isEmpty {
                result.append((toolName: toolName, ruleContent: ruleContent))
            } else {
                return nil
            }
        }
        return result
    }

    /// `addRules`'s own three-way body (see `label(for:)`'s own doc
    /// comment): the collapsed "don't ask again"/"always allow <tool>"
    /// forms apply only when every rule shares one `toolName` AND every
    /// rule's `ruleContent` presence agrees (all present or all absent);
    /// anything else -- including more than one distinct `toolName`, even
    /// when every rule individually carries a `ruleContent` -- falls
    /// through to the same per-rule form `replaceRules`/`removeRules`
    /// always use.
    private static func addRulesBody(_ rules: [(toolName: String, ruleContent: String?)]) -> String {
        let toolNames = rules.map(\.toolName)
        let distinctToolNames = Set(toolNames)
        let ruleContents = rules.map(\.ruleContent)

        if distinctToolNames.count == 1, let toolName = toolNames.first {
            if ruleContents.allSatisfy({ $0 != nil }) {
                let contents = ruleContents.compactMap { $0 }
                return "don't ask again for \(toolName): \(contents.joined(separator: ", "))"
            }
            if ruleContents.allSatisfy({ $0 == nil }) {
                return "always allow \(toolName)"
            }
        }
        return "always allow \(mixedRulesForm(rules))"
    }

    /// One rule per element: `"<toolName>(<ruleContent>)"` when that
    /// rule carries a `ruleContent`, its bare `toolName` otherwise,
    /// joined with ", ".
    private static func mixedRulesForm(_ rules: [(toolName: String, ruleContent: String?)]) -> String {
        rules.map { rule -> String in
            if let content = rule.ruleContent {
                return "\(rule.toolName)(\(content))"
            }
            return rule.toolName
        }.joined(separator: ", ")
    }

    /// `destination` -> trailing scope suffix, WITH its own leading
    /// space, so a caller can simply append this to its base string --
    /// empty (no leading space either) for a missing, non-string, or
    /// unrecognized value.
    private static func scopeSuffix(for entry: [String: Any]) -> String {
        switch entry["destination"] as? String {
        case "projectSettings", "localSettings": return " from this project"
        case "userSettings": return " for this user"
        case "session": return " for this session"
        default: return ""
        }
    }
}
