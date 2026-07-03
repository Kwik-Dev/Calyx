//
//  CalyxCLI.swift
//  CalyxCLI
//
//  Entry point for the Calyx command-line tool.
//

import ArgumentParser

@main
struct CalyxCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calyx",
        abstract: "Calyx terminal CLI",
        subcommands: [BrowserCommand.self, IPCCommand.self]
    )
}

struct BrowserCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Browser automation commands",
        subcommands: [
            BrowserList.self,
            BrowserOpen.self,
            BrowserNavigate.self,
            BrowserSnapshot.self,
            BrowserScreenshot.self,
            BrowserClick.self,
            BrowserFill.self,
            BrowserType.self,
            BrowserPress.self,
            BrowserSelect.self,
            BrowserCheck.self,
            BrowserUncheck.self,
            BrowserGetText.self,
            BrowserGetHTML.self,
            BrowserEval.self,
            BrowserWait.self,
            BrowserBack.self,
            BrowserForward.self,
            BrowserReload.self,
            BrowserGetAttribute.self,
            BrowserGetLinks.self,
            BrowserGetInputs.self,
            BrowserIsVisible.self,
            BrowserHover.self,
            BrowserScroll.self,
        ]
    )
}
