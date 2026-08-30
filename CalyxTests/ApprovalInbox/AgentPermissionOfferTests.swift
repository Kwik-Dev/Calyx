//
//  AgentPermissionOfferTests.swift
//  CalyxTests
//
//  Covers AgentPermissionOffer.label(for:): the human-readable button
//  label the approval banner shows for one entry of Claude Code's
//  PermissionRequest `permission_suggestions` array, decoded by
//  AgentHookToolCall into AgentHookToolCall.permissionOffers -- see
//  hooks.md's own documented `permission_suggestions` shapes.
//
//  Coverage:
//  - addDirectories: "Yes, and always allow access to <dirs> <scope>"
//  - addRules (allow): single toolName with ruleContent on every rule
//    (the hooks.md example) / single toolName with no ruleContent on any
//    rule / mixed toolNames or partial ruleContent
//  - setMode: "Yes, and switch to <mode> mode", rendered verbatim for
//    every mode value -- including "manual", a value hooks.md documents
//    the wire as never actually sending (the mode labeled Manual arrives
//    as "default", never as "manual"); there is no remapping of "manual"
//    to "default" (never carries a scope suffix)
//  - replaceRules / removeRules / removeDirectories: "Yes, and <type>
//    <items> <scope>"
//  - an unrecognized type: "Yes, and apply the <type> permission update
//    <scope>"
//  - scope suffix from destination: projectSettings/localSettings ->
//    "from this project", userSettings -> "for this user", session ->
//    "for this session"; missing/unrecognized destination -> no suffix,
//    with no trailing space left behind
//  - nil contract: an entry with nothing to offer (missing/empty/non-
//    string type; for addRules/replaceRules/removeRules, a malformed or
//    empty `rules` array or a malformed rule element; for
//    addDirectories/removeDirectories, a malformed or empty `directories`
//    array or a non-string element; for setMode, a missing/empty/non-
//    string `mode`) returns nil rather than a label
//

import XCTest
@testable import Calyx

final class AgentPermissionOfferTests: XCTestCase {

    // MARK: - addDirectories

    func test_label_addDirectories_singleDirectory_withProjectScope() {
        let entry: [String: Any] = [
            "type": "addDirectories", "directories": ["/tmp/project"], "destination": "localSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and always allow access to /tmp/project from this project")
    }

    func test_label_addDirectories_multipleDirectories_joinedByCommaSpace() {
        let entry: [String: Any] = [
            "type": "addDirectories", "directories": ["/tmp", "/var/log"], "destination": "session",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and always allow access to /tmp, /var/log for this session")
    }

    func test_label_addDirectories_projectSettingsDestination_alsoMapsToFromThisProject() {
        let entry: [String: Any] = [
            "type": "addDirectories", "directories": ["/tmp"], "destination": "projectSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and always allow access to /tmp from this project")
    }

    // MARK: - addRules (allow): the hooks.md example -- single toolName, every rule has ruleContent

    /// The exact `permission_suggestions` entry hooks.md documents.
    func test_label_addRules_hooksMdExample_singleToolNameEveryRuleHasContent() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [["toolName": "Bash", "ruleContent": "rm -rf node_modules"]],
            "behavior": "allow",
            "destination": "localSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and don't ask again for Bash: rm -rf node_modules from this project")
    }

    func test_label_addRules_singleToolName_multipleRuleContents_joinedByCommaSpace() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [
                ["toolName": "Bash", "ruleContent": "rm -rf node_modules"],
                ["toolName": "Bash", "ruleContent": "npm install"],
            ],
            "behavior": "allow",
            "destination": "userSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and don't ask again for Bash: rm -rf node_modules, npm install for this user")
    }

    // MARK: - addRules (allow): single toolName, no ruleContent on any rule

    func test_label_addRules_singleToolName_noRuleContentOnAnyRule() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [["toolName": "Read"], ["toolName": "Read"]],
            "behavior": "allow",
            "destination": "userSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and always allow Read for this user")
    }

    func test_label_addRules_singleToolName_noRuleContentOnAnyRule_noDestination() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [["toolName": "Read"]],
            "behavior": "allow",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and always allow Read",
                       "an absent destination must leave no scope suffix and no trailing space")
    }

    // MARK: - addRules (allow): mixed toolNames or partial ruleContent

    func test_label_addRules_mixedToolNamesAndRuleContent() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [
                ["toolName": "Bash", "ruleContent": "rm -rf *"],
                ["toolName": "Read"],
            ],
            "behavior": "allow",
            "destination": "session",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and always allow Bash(rm -rf *), Read for this session")
    }

    func test_label_addRules_multipleToolNames_allHavingRuleContent_stillUsesMixedForm() {
        let entry: [String: Any] = [
            "type": "addRules",
            "rules": [
                ["toolName": "Bash", "ruleContent": "rm -rf *"],
                ["toolName": "Write", "ruleContent": "/etc/*"],
            ],
            "behavior": "allow",
            "destination": "localSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and always allow Bash(rm -rf *), Write(/etc/*) from this project",
                       "more than one distinct toolName must always use the per-rule mixed form, even " +
                       "though every rule individually carries a ruleContent")
    }

    // MARK: - setMode

    func test_label_setMode_acceptEdits_neverCarriesScopeSuffix() {
        let entry: [String: Any] = ["type": "setMode", "mode": "acceptEdits", "destination": "session"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and switch to acceptEdits mode",
                       "setMode's label must never carry a scope suffix, even with a destination present")
    }

    func test_label_setMode_default_isRenderedVerbatim() {
        let entry: [String: Any] = ["type": "setMode", "mode": "default"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and switch to default mode")
    }

    func test_label_setMode_auto_isRenderedVerbatim() {
        let entry: [String: Any] = ["type": "setMode", "mode": "auto"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and switch to auto mode")
    }

    func test_label_setMode_manual_isRenderedVerbatim_noRemapping() {
        let entry: [String: Any] = ["type": "setMode", "mode": "manual"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and switch to manual mode",
                       "hooks.md documents that the mode labeled Manual arrives on the wire as \"default\", " +
                       "never as \"manual\" -- so no remapping of a literal \"manual\" value exists")
    }

    func test_label_setMode_plan_isDecodedVerbatim() {
        let entry: [String: Any] = ["type": "setMode", "mode": "plan"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and switch to plan mode")
    }

    // MARK: - replaceRules / removeRules / removeDirectories

    func test_label_removeDirectories_singleDirectory_withProjectScope() {
        let entry: [String: Any] = [
            "type": "removeDirectories", "directories": ["/tmp"], "destination": "projectSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and removeDirectories /tmp from this project")
    }

    func test_label_removeRules_ruleWithContent_noDestination() {
        let entry: [String: Any] = [
            "type": "removeRules", "rules": [["toolName": "Bash", "ruleContent": "rm -rf *"]],
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and removeRules Bash(rm -rf *)",
                       "an absent destination must leave no scope suffix and no trailing space")
    }

    func test_label_replaceRules_ruleWithoutContent_withSessionScope() {
        let entry: [String: Any] = [
            "type": "replaceRules", "rules": [["toolName": "Write"]], "destination": "session",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and replaceRules Write for this session",
                       "a rule with no ruleContent must render as its bare toolName, never Write()")
    }

    func test_label_replaceRules_multipleRules_joinedByCommaSpace() {
        let entry: [String: Any] = [
            "type": "replaceRules",
            "rules": [["toolName": "Bash", "ruleContent": "rm -rf *"], ["toolName": "Write"]],
            "destination": "userSettings",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and replaceRules Bash(rm -rf *), Write for this user")
    }

    // MARK: - unrecognized type

    func test_label_unknownType_withScope() {
        let entry: [String: Any] = ["type": "someFutureType", "destination": "userSettings"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry),
                       "Yes, and apply the someFutureType permission update for this user")
    }

    func test_label_unknownType_noDestination_noTrailingSpace() {
        let entry: [String: Any] = ["type": "someFutureType"]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and apply the someFutureType permission update",
                       "an absent destination must leave no scope suffix and no trailing space")
    }

    // MARK: - destination: missing / unrecognized

    func test_label_unrecognizedDestinationValue_isTreatedAsNoScope() {
        let entry: [String: Any] = [
            "type": "addDirectories", "directories": ["/tmp"], "destination": "someFutureDestination",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and always allow access to /tmp",
                       "an unrecognized destination value must be treated the same as a missing one -- no " +
                       "scope suffix, no trailing space")
    }

    func test_label_nonStringDestinationValue_isTreatedAsNoScope() {
        let entry: [String: Any] = ["type": "addDirectories", "directories": ["/tmp"], "destination": 42]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and always allow access to /tmp")
    }

    // MARK: - nothing to offer -> nil

    func test_label_missingType_isNil() {
        let entry: [String: Any] = ["directories": ["/tmp"]]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an entry with no type at all offers nothing")
    }

    func test_label_emptyType_isNil() {
        let entry: [String: Any] = ["type": "", "directories": ["/tmp"]]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty type string offers nothing")
    }

    func test_label_nonStringType_isNil() {
        let entry: [String: Any] = ["type": 42, "directories": ["/tmp"]]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a non-string type offers nothing")
    }

    func test_label_addRules_rulesMissing_isNil() {
        let entry: [String: Any] = ["type": "addRules", "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "addRules with no rules array offers nothing")
    }

    func test_label_addRules_rulesNonArray_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": "x", "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a non-array rules value offers nothing")
    }

    func test_label_addRules_rulesEmpty_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": [], "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty rules array offers nothing")
    }

    func test_label_addRules_nonObjectRuleElement_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": ["Bash"], "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a rule element that is not an object offers nothing")
    }

    func test_label_addRules_ruleMissingToolName_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": [["ruleContent": "rm -rf *"]], "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a rule missing toolName offers nothing")
    }

    func test_label_addRules_ruleEmptyToolName_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": [["toolName": ""]], "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a rule with an empty toolName offers nothing")
    }

    func test_label_addRules_ruleNonStringToolName_isNil() {
        let entry: [String: Any] = ["type": "addRules", "rules": [["toolName": 7]], "behavior": "allow"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a rule with a non-string toolName offers nothing")
    }

    func test_label_addRules_ruleNonStringRuleContent_isNil() {
        let entry: [String: Any] = [
            "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": 7]], "behavior": "allow",
        ]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a rule with a non-string ruleContent offers nothing")
    }

    func test_label_addRules_ruleEmptyStringRuleContent_isNil() {
        let entry: [String: Any] = [
            "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": ""]], "behavior": "allow",
        ]
        XCTAssertNil(AgentPermissionOffer.label(for: entry),
                     "a rule with an empty-string ruleContent offers nothing")
    }

    func test_label_addDirectories_directoriesMissing_isNil() {
        let entry: [String: Any] = ["type": "addDirectories"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "addDirectories with no directories array offers nothing")
    }

    func test_label_addDirectories_directoriesNonArray_isNil() {
        let entry: [String: Any] = ["type": "addDirectories", "directories": "x"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a non-array directories value offers nothing")
    }

    func test_label_addDirectories_directoriesEmpty_isNil() {
        let entry: [String: Any] = ["type": "addDirectories", "directories": []]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty directories array offers nothing")
    }

    func test_label_addDirectories_nonStringElement_isNil() {
        let entry: [String: Any] = ["type": "addDirectories", "directories": [1]]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a non-string directories element offers nothing")
    }

    func test_label_addDirectories_emptyStringElement_isNil() {
        let entry: [String: Any] = ["type": "addDirectories", "directories": [""]]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty-string directories element offers nothing")
    }

    func test_label_setMode_modeMissing_isNil() {
        let entry: [String: Any] = ["type": "setMode"]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "setMode with no mode offers nothing")
    }

    func test_label_setMode_modeEmpty_isNil() {
        let entry: [String: Any] = ["type": "setMode", "mode": ""]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty mode string offers nothing")
    }

    func test_label_setMode_modeNonString_isNil() {
        let entry: [String: Any] = ["type": "setMode", "mode": 3]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "a non-string mode offers nothing")
    }

    func test_label_replaceRules_rulesEmpty_isNil() {
        let entry: [String: Any] = ["type": "replaceRules", "rules": []]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty rules array offers nothing for replaceRules")
    }

    func test_label_removeRules_rulesEmpty_isNil() {
        let entry: [String: Any] = ["type": "removeRules", "rules": []]
        XCTAssertNil(AgentPermissionOffer.label(for: entry), "an empty rules array offers nothing for removeRules")
    }

    func test_label_removeDirectories_directoriesEmpty_isNil() {
        let entry: [String: Any] = ["type": "removeDirectories", "directories": []]
        XCTAssertNil(AgentPermissionOffer.label(for: entry),
                     "an empty directories array offers nothing for removeDirectories")
    }

    // MARK: - explicit null ruleContent counts as absent, not malformed

    func test_label_addRules_explicitNullRuleContent_isTreatedAsAbsent() {
        let entry: [String: Any] = [
            "type": "addRules", "rules": [["toolName": "Bash", "ruleContent": NSNull()]],
            "behavior": "allow", "destination": "session",
        ]
        XCTAssertEqual(AgentPermissionOffer.label(for: entry), "Yes, and always allow Bash for this session",
                       "an explicit JSON null ruleContent is well-formed and absent, not malformed")
    }
}
