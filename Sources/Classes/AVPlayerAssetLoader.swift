//
//  AVPlayerAssetLoader.swift
//  SZAVPlayer
//
//  Created by Vladislav Krasovsky on 12/1/20.
//

import UIKit
import AVFoundation
import CoreServices

/// AVPlayerItem custom schema
private let SZAVPlayerItemScheme = "SZAVPlayerItemScheme"

public class AVPlayerAssetLoader: NSObject {

    public var uniqueID: String = "defaultUniqueID"
    public let url: URL
    public var urlAsset: AVURLAsset?

    private let loaderQueue = DispatchQueue(label: "com.SZAVPlayer.loaderQueue")

    private var pendingRequests: [SZAVPlayerRequest] = []

    private var isCancelled: Bool = false

    public init(url: URL) {
        self.url = url
        super.init()
    }

    deinit {
        SZLogInfo("deinit")
    }

    public func loadAsset(shouldCacheResource: Bool, completion: @escaping (AVURLAsset) -> Void) {
        var asset: AVURLAsset
        if shouldCacheResource, let urlWithSchema = url.withScheme(SZAVPlayerItemScheme) {
            asset = AVURLAsset(url: urlWithSchema)
            asset.resourceLoader.setDelegate(self, queue: loaderQueue)
        } else {
            asset = AVURLAsset(url: url)
        }

        asset.loadValuesAsynchronously(forKeys: ["playable"]) {
            completion(asset)
        }

        urlAsset = asset
    }
}

// MARK: - Actions

extension AVPlayerAssetLoader {

    public func cleanup() {
        isCancelled = true
        pendingRequests.forEach { $0.cancel() }
    }

    private func handleContentInfoRequest(loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let infoRequest = loadingRequest.contentInformationRequest else {
            return false
        }

//        print("* informationRequest")
        
        // use cached info first
        if let contentInfo = SZAVPlayerDatabase.shared.contentInfo(uniqueID: self.uniqueID) {
            self.fillInWithLocalData(infoRequest, contentInfo: contentInfo)
//            print("* informationRequest finish (local))")
            loadingRequest.finishLoading()

            return true
        }

        let request = contentInfoRequest(loadingRequest: loadingRequest)
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        let task = session.downloadTask(with: request) { (_, response, error) in
            self.handleContentInfoResponse(loadingRequest: loadingRequest,
                                           infoRequest: infoRequest,
                                           response: response,
                                           error: error)
        }

        let pendingRequest = SZAVPlayerContentInfoRequest(
            resourceUrl: url,
            loadingRequest: loadingRequest,
            infoRequest: infoRequest,
            task: task
        )

        pendingRequests.append(pendingRequest)
        task.resume()

        return true
    }

    private func handleContentInfoResponse(
        loadingRequest: AVAssetResourceLoadingRequest,
        infoRequest: AVAssetResourceLoadingContentInformationRequest,
        response: URLResponse?,
        error: Error?
    ) {
        loaderQueue.async {
            if self.isCancelled || loadingRequest.isCancelled {
                return
            }

            if let error = error {
                SZLogError("Failed with error: \(String(describing: error))")
//                print("* informationRequest finish (error))")
                loadingRequest.finishLoading(with: error)
                return
            }

            if let response = response {
                if let mimeType = response.mimeType {
                    let info = SZAVPlayerContentInfo(uniqueID: self.uniqueID,
                                                     mimeType: mimeType,
                                                     contentLength: response.sz_expectedContentLength,
                                                     isByteRangeAccessSupported: response.sz_isByteRangeAccessSupported)
                    SZAVPlayerDatabase.shared.update(contentInfo: info)
                }
                self.fillInWithRemoteResponse(infoRequest, response: response)
//                print("* informationRequest finish (\(response.sz_expectedContentLength))")
                loadingRequest.finishLoading()
            }

            self.removePendingRequest(for: loadingRequest)
        }
    }

    private func handleDataRequest(loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        if self.isCancelled || loadingRequest.isCancelled {
            return false
        }

        guard let avDataRequest = loadingRequest.dataRequest else {
            return false
        }

        let lowerBound = avDataRequest.requestedOffset
        let length = Int64(avDataRequest.requestedLength)
        let upperBound = lowerBound + length
        let requestedRange = lowerBound..<upperBound
        
        let useCache = pendingRequests.isEmpty
//        print("* dataRequest \(requestedRange) (\(Unmanaged.passUnretained(avDataRequest).toOpaque())) \(useCache ? "" : "DON'T USE CACHE")")
        
        let loader = AVPlayerDataLoader(
            uniqueID: uniqueID,
            url: url,
            range: requestedRange,
            callbackQueue: loaderQueue,
            useCache: useCache
        ) { [weak self] event in
            guard let strongSelf = self, !loadingRequest.isCancelled, !loadingRequest.isFinished else { return }
            switch event {
            case .data(let data):
                avDataRequest.respond(with: data)
//                print("dataRequest loaded \(Int64(data.count)) (\(Unmanaged.passUnretained(avDataRequest).toOpaque()))")
            case .finish(let error):
                if let error = error {
//                    print("* dataRequest finish (error) (\(Unmanaged.passUnretained(loadingRequest.dataRequest!).toOpaque()))")
                    loadingRequest.finishLoading(with: error)
                } else {
//                    print("* dataRequest finish (\(Unmanaged.passUnretained(loadingRequest.dataRequest!).toOpaque()))")
                    loadingRequest.finishLoading()
                }
                strongSelf.removePendingRequest(for: loadingRequest)
            }
        }
        let dataRequest = AVPlayerDataRequest(
            resourceUrl: url,
            loadingRequest: loadingRequest,
            dataRequest: avDataRequest,
            loader: loader,
            range: requestedRange
        )

        pendingRequests.append(dataRequest)
        loader.start()

        return true
    }

    @discardableResult
    private func removePendingRequest(for loadingRequest: AVAssetResourceLoadingRequest) -> SZAVPlayerRequest? {
        guard let requestIndex = pendingRequests.firstIndex(where: { $0.loadingRequest === loadingRequest }) else {
            assertionFailure("trying to remove loadingRequest, which is not in pendingRequests")
            return nil
        }
        return pendingRequests.remove(at: requestIndex)
    }
    
    private func fillInWithLocalData(_ request: AVAssetResourceLoadingContentInformationRequest, contentInfo: SZAVPlayerContentInfo) {
        if let contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, contentInfo.mimeType as CFString, nil) {
            request.contentType = contentType.takeRetainedValue() as String
        }

        request.contentLength = contentInfo.contentLength
        request.isByteRangeAccessSupported = contentInfo.isByteRangeAccessSupported
    }

    private func fillInWithRemoteResponse(_ request: AVAssetResourceLoadingContentInformationRequest, response: URLResponse) {
        if let mimeType = response.mimeType,
            let contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, mimeType as CFString, nil)
        {
            request.contentType = contentType.takeRetainedValue() as String
        }
        request.contentLength = response.sz_expectedContentLength
        request.isByteRangeAccessSupported = response.sz_isByteRangeAccessSupported
    }

}

// MARK: - AVAssetResourceLoaderDelegate

extension AVPlayerAssetLoader: AVAssetResourceLoaderDelegate {

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
    {
        if let _ = loadingRequest.contentInformationRequest {
            return handleContentInfoRequest(loadingRequest: loadingRequest)
        } else if let _ = loadingRequest.dataRequest {
            return handleDataRequest(loadingRequest: loadingRequest)
        } else {
            return false
        }
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest)
    {
//        print("resourceLoader didCancel loadingRequest (offset: \(loadingRequest.dataRequest!.currentOffset)) (\(Unmanaged.passUnretained(loadingRequest.dataRequest!).toOpaque()))")
        let request = removePendingRequest(for: loadingRequest)
        request?.cancel()
//        print("resourceLoader didCancel after")
    }

}

// MARK: - Extensions

fileprivate extension URL {

    func withScheme(_ scheme: String) -> URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.scheme = scheme
        return components.url
    }

}

fileprivate extension URLResponse {

    var sz_expectedContentLength: Int64 {
        guard let response = self as? HTTPURLResponse else {
            return expectedContentLength
        }

        let contentRangeKeys: [String] = [
            "Content-Range",
            "content-range",
            "Content-range",
            "content-Range",
        ]
        var rangeString: String?
        for key in contentRangeKeys {
            if let value = response.allHeaderFields[key] as? String {
                rangeString = value
                break
            }
        }

        if let rangeString = rangeString,
            let bytesString = rangeString.split(separator: "/").map({String($0)}).last,
            let bytes = Int64(bytesString)
        {
            return bytes
        } else {
            return expectedContentLength
        }
    }

    var sz_isByteRangeAccessSupported: Bool {
        guard let response = self as? HTTPURLResponse else {
            return false
        }

        let rangeAccessKeys: [String] = [
            "Accept-Ranges",
            "accept-ranges",
            "Accept-ranges",
            "accept-Ranges",
        ]

        for key in rangeAccessKeys {
            if let value = response.allHeaderFields[key] as? String,
                value == "bytes"
            {
                return true
            }
        }

        return false
    }

}

// MARK: - Getter

extension AVPlayerAssetLoader {

    private static func isNetworkError(code: Int) -> Bool {
        let errorCodes = [
            NSURLErrorNotConnectedToInternet,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
        ]

        return errorCodes.contains(code)
    }

    private func contentInfoRequest(loadingRequest: AVAssetResourceLoadingRequest) -> URLRequest {
        var request = URLRequest(url: url)
        if let dataRequest = loadingRequest.dataRequest {
            let lowerBound = Int(dataRequest.requestedOffset)
            let upperBound = lowerBound + Int(dataRequest.requestedLength) - 1
            let rangeHeader = "bytes=\(lowerBound)-\(upperBound)"
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        return request
    }

}
