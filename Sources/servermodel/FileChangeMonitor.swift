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

class FileChangeMonitor {
	typealias Observer = (SessionResponse.FileChangedData) -> Void

	private var dbConnection: DBConnection
	private let queue: DispatchQueue
	private var observers = [(Int, Observer)]()
	// has to be var or can't pass a callback that is a method on this object in the initializer
	private var reader: DispatchSourceRead!

	init(connection: DBConnection, queue: DispatchQueue = .global()) throws {
		dbConnection = connection
		self.queue = queue
		reader = try connection.makeListenDispatchSource(toChannel: "rcfile", queue: queue, callback: handleNotification)
		reader.activate()
	}

	deinit {
		reader.cancel()
	}

	func add(wspaceId: Int, observer: @escaping Observer) {
		logger.info("adding file observer for workspace \(wspaceId)")
		observers.append((wspaceId, observer))
	}

	// internal to allow unit testing
	internal func handleNotification(notification: DBNotification?, error: Error?) {
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
			var file: Rc2Model.File?
			let results = try dbConnection.execute(query: "select * from rcfile where id = \(fileId)", values: [])
			guard results.wasSuccessful else {
				logger.warning("file watch selection failed: \(results.errorMessage)")
				return
			}
			let row = 0
			file = File(id: try Rc2DAO.value(columnName: "id", results: results, row: row),
						wspaceId: try Rc2DAO.value(columnName: "wspaceId", results: results, row: row),
						name: try Rc2DAO.value(columnName: "name", results: results, row: row),
						version: try Rc2DAO.value(columnName: "version", results: results, row: row),
						dateCreated: try Rc2DAO.value(columnName: "datecreated", results: results, row: row),
						lastModified: try Rc2DAO.value(columnName: "lastmodified", results: results, row: row),
						fileSize: try Rc2DAO.value(columnName: "filesize", results: results, row: row))
			let changeData = SessionResponse.FileChangedData(type: changeType, file: file, fileId: fileId)
			observers.forEach {
				if wspaceId == $0.0 {
					$0.1(changeData)
				} else {
					logger.info("skipping file observer for wspace \($0.0)")
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
