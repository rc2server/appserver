//
//  KituraExtensions.swift
//  kappserver
//
//  Created by Mark Lilback on 9/8/19.
//

import Foundation
import Kitura
import Rc2Model

extension RouterRequest {
	/// the model object representing the user
	var user: User? {
		get { return userInfo["rc2.user"] as? User}
		set { userInfo["rc2.user"] = newValue }
	}
}
