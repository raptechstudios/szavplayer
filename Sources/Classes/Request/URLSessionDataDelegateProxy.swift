//
//  URLSessionDataDelegateProxy.swift
//  SZAVPlayer
//
//  Created by Vladislav Krasovsky on 12/2/20.
//

import Foundation

class URLSessionDataDelegateProxy: NSObject, URLSessionDataDelegate {

    var didReceiveData: ((Data) -> Void)?
    var didCompleteWithError: ((Error?) -> Void)?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        didReceiveData?(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        didCompleteWithError?(error)
    }
}
