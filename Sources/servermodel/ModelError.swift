//
//  ModelError.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation

public enum ModelError: Error {
	case duplicateObject
	case notFound
	case dbError
	case failedToOpenConnection
	case invalidData
}
