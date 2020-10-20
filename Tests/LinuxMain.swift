import XCTest

import appcoreTests

var tests = [XCTestCaseEntry]()
tests += appcoreTests.__allTests()

XCTMain(tests)
