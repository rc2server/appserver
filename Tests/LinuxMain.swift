import XCTest

import appcoreTests
import kappserverTests
import servermodelTests

var tests = [XCTestCaseEntry]()
tests += appcoreTests.__allTests()
tests += kappserverTests.__allTests()
tests += servermodelTests.__allTests()

XCTMain(tests)
