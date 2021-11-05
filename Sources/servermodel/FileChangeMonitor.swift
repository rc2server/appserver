//
//  FileChangeMonitor.swift
//
//  Copyright ©2017 Mark Lilback. This file is licensed under the ISC license.
//

import Foundation
import Dispatch
import pgswift
import Rc2Model
import Logging

extension String {
	func after(integerIndex: Int) -> Substring {
		precondition(integerIndex < count && integerIndex > 0)
		let start = self.index(startIndex, offsetBy: integerIndex)
		return self[start...]
	}

	func to(integerIndex: Int) -> Substring {
		precondition(integerIndex < count && integerIndex >= 0)
		let end = self.index(startIndex, offsetBy: integerIndex)
		return self[startIndex...end]
	}

	func stringTo(integerIndex: Int) -> String {
		return String(self.to(integerIndex: integerIndex))
	}
}

internal protocol FileChangeMonitorDelegate: AnyObject {
	func getFile(id: Int, wspaceId: Int) throws -> File
}

class FileChangeMonitor {
	typealias Observer = (SessionResponse.FileChangedData) -> Void

	private var dbConnection: DBConnection
	private let queue: DispatchQueue
	private weak var delegate: FileChangeMonitorDelegate?

	private var observers = [(Int, Observer)]()
	// has to be var or can't pass a callback that is a method on this object in the initializer
	private var reader: DispatchSourceRead!

	init(connection: DBConnection, delegate: FileChangeMonitorDelegate, queue: DispatchQueue = .global()) throws {
		dbConnection = connection
		self.queue = queue
		self.delegate = delegate
		reader = try connection.makeListenDispatchSource(toChannel: "rcfile", queue: queue, callback: handleNotification)
		reader.activate()
	}

	deinit {
		reader.cancel()
	}

	func add(wspaceId: Int, observer: @escaping Observer) {
		logger.debug("adding file observer for workspace \(wspaceId)")
		observers.append((wspaceId, observer))
	}

	// internal to allow unit testing
	internal func handleNotification(notification: DBNotification?, error: Error?) {
		guard let delegate = delegate else { fatalError("delegate not set") }
		guard let msg = notification?.payload else {
			logger.warning("FileChangeMonitor got error from database: \(error!)")
			return
		}
		let msgParts = msg.after(integerIndex: 1).split(separator: "/")
		guard msgParts.count == 3,
			let wspaceId = Int(msgParts[1]),
			let fileId = Int(msgParts[0])
		else {
			logger.warning("received unknown message \(msg) from db on rcfile channel")
			return
		}
		let msgType = String(msg[msg.startIndex...msg.startIndex]) // a lot of work to get first character as string
		logger.info("received rcfile notification for file \(fileId) in wspace \(wspaceId)")
		guard let changeType = SessionResponse.FileChangedData.FileChangeType(rawValue: msgType)
			else { logger.warning("invalid change notifiction from db \(msg)"); return }
		do {
			let results = try dbConnection.execute(query: "select * from rcfile where id = \(fileId)", parameters: [])
			guard results.wasSuccessful else {
				logger.warning("file watch selection failed: \(results.errorMessage)")
				return
			}
			let file = try delegate.getFile(id: fileId, wspaceId: wspaceId)
			let changeData = SessionResponse.FileChangedData(type: changeType, file: file, fileId: fileId)
			observers.forEach { (anId, anAction) in
				if wspaceId == anId {
					anAction(changeData)
				} else {
					logger.info("skipping file observer for wspace \(anId)")
				}
			}
		} catch {
			logger.warning("error during handing notfication: \(error)")
		}
	}
}

extension String {
	func substring(to: Int) -> String {
		let idx = index(startIndex, offsetBy: to)
		return String(self[..<idx])
	}
}
