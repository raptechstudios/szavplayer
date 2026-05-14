//
//  URLSessionDataDelegateProxy.swift
//  SZAVPlayer
//
//  Created by Vladislav Krasovsky on 12/2/20.
//

import Foundation

class URLSessionDataDelegateProxy: NSObject, URLSessionDataDelegate {

    var didReceiveResponse: ((URLResponse) -> Void)?
    var didReceiveData: ((Data) -> Void)?
    var didCompleteWithError: ((Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        didReceiveResponse?(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        didReceiveData?(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        didCompleteWithError?(error)
    }
}
