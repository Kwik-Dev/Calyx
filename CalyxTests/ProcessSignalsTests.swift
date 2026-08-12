//
//  ProcessSignalsTests.swift
//  CalyxTests
//
//  Pins ignoreSIGPIPE()'s only observable effect: SIGPIPE's process-wide
//  disposition reads back as SIG_IGN afterward.
//

import XCTest
import Darwin
@testable import Calyx

final class ProcessSignalsTests: XCTestCase {
    func test_ignoreSIGPIPE_setsDispositionToSIGIGN() {
        ignoreSIGPIPE()

        var existing = sigaction()
        sigaction(SIGPIPE, nil, &existing)
        let handler = existing.__sigaction_u.__sa_handler

        XCTAssertEqual(
            unsafeBitCast(handler, to: Int.self), unsafeBitCast(SIG_IGN, to: Int.self),
            "ignoreSIGPIPE() must set SIGPIPE's disposition to SIG_IGN"
        )
    }
}
