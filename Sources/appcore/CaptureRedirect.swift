//
//  CaptureRedirect.swift
//  appcore
//
//  Created by Mark Lilback on 2/22/21.
//

import Foundation

public class CaptureRedirect: NSObject {
	public typealias RedirectCallback = (HTTPURLResponse?, URLRequest?, Error?) -> Void
	private var session: URLSession?
	private var callback: RedirectCallback?
	private var madeCallback = false
	
	public override init() {
		super.init()
		session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
	}
	
	/// Makes request, then callsback with first two values if a redirect was received, the first and third params if there was an error, and the first if a success w/o a redirect
	public func perform(request: URLRequest, callback: @escaping RedirectCallback) {
		self.callback = callback
		let task = session?.dataTask(with: request, completionHandler: { [weak self] (_, rsp, err) in
			guard let me = self else { return }
			if me.madeCallback {
				return
			}
			guard err == nil else {
				me.callback?(rsp as? HTTPURLResponse, nil, err)
				me.callback = nil
				return
			}
			me.callback?(rsp as? HTTPURLResponse, nil, nil)
			me.callback = nil
		})
		task?.resume()
	}
}

extension CaptureRedirect: URLSessionTaskDelegate {
	public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
	{
		callback?(response, request, nil)
		callback = nil
		madeCallback = true
		completionHandler(nil)
	}
}
