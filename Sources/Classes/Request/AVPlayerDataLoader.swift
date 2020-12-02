//
//  AVPlayerDataLoader.swift
//  SZAVPlayer
//
//  Created by Vladislav Krasovsky on 12/1/20.
//

import UIKit
import ReactiveSwift

protocol AVPlayerDataLoaderDelegate: AnyObject {
    func dataLoader(_ loader: AVPlayerDataLoader, didReceive data: Data)
    func dataLoaderDidFinish(_ loader: AVPlayerDataLoader)
    func dataLoader(_ loader: AVPlayerDataLoader, didFailWithError error: Error)
}

class AVPlayerDataLoader: NSObject {

    public weak var delegate: AVPlayerDataLoaderDelegate?

    private let callbackQueue: DispatchQueue
    private let uniqueID: String
    private let url: URL
    private let requestedRange: SZAVPlayerRange
    private var mediaData: Data?
    
    private var cancelled: Bool = false
    private var failed: Bool = false
    var disposable: Disposable?
    
    init(uniqueID: String, url: URL, range: SZAVPlayerRange, callbackQueue: DispatchQueue) {
        self.uniqueID = uniqueID
        self.url = url
        self.requestedRange = range
        self.callbackQueue = callbackQueue
        super.init()
    }

    deinit {
        SZLogInfo("deinit")
    }

    public func start() {
        guard !cancelled && !failed else { return }

        var signalProducers: [SignalProducer<Data, Error>] = []

        let localFileInfos = SZAVPlayerDatabase.shared.localFileInfos(uniqueID: uniqueID)
        let ranges = localFileInfos.map { $0.startOffset ..< $0.startOffset + $0.loadedByteLength }
        print("stored local ranges: \(ranges)")
        if localFileInfos.isEmpty {
            signalProducers.append(remoteRequestProducer(range: requestedRange))
        } else {
            var startOffset = requestedRange.lowerBound
            let endOffset = requestedRange.upperBound
            for fileInfo in localFileInfos {
                if SZAVPlayerDataLoader.isOutOfRange(startOffset: startOffset, endOffset: endOffset, fileInfo: fileInfo) {
                    continue
                }

                let localFileStartOffset = fileInfo.startOffset
                if startOffset >= localFileStartOffset {
                    signalProducers.append(localRequestProducer(startOffset: &startOffset, endOffset: endOffset, fileInfo: fileInfo))
                } else {
                    signalProducers.append(remoteRequestProducer(startOffset: startOffset, endOffset: localFileStartOffset))
                    signalProducers.append(localRequestProducer(startOffset: &startOffset, endOffset: endOffset, fileInfo: fileInfo))
                }
            }

            let notEnded = startOffset < endOffset
            if notEnded {
                signalProducers.append(remoteRequestProducer(startOffset: startOffset, endOffset: endOffset))
            }
        }
        
        let compositionProducer = SignalProducer(signalProducers).flatten(.concat)
        disposable = compositionProducer.start { [weak self, callbackQueue] action in
            callbackQueue.async { [weak self] in
                guard let strongSelf = self else { return }
                switch action {
                case .value(let data):
                    strongSelf.delegate?.dataLoader(strongSelf, didReceive: data)
                case .completed, .interrupted:
                    strongSelf.delegate?.dataLoaderDidFinish(strongSelf)
                case .failed(let error):
                    strongSelf.delegate?.dataLoader(strongSelf, didFailWithError: error)
                }
            }
        }
    }

    public func cancel() {
        cancelled = true
        disposable?.dispose()
    }

    public static func isOutOfRange(startOffset: Int64, endOffset: Int64, fileInfo: SZAVPlayerLocalFileInfo) -> Bool {
        let localFileStartOffset = fileInfo.startOffset
        let localFileEndOffset = fileInfo.startOffset + fileInfo.loadedByteLength
        let remainRange = startOffset..<endOffset

        let isIntersectionWithRange = remainRange.contains(localFileStartOffset) || remainRange.contains(localFileEndOffset - 1)
        let isContainsRange = localFileStartOffset <= startOffset && localFileEndOffset >= endOffset

        return !(isIntersectionWithRange || isContainsRange)
    }

}

extension AVPlayerDataLoader {
    func localRequestProducer(startOffset: inout Int64, endOffset: Int64, fileInfo: SZAVPlayerLocalFileInfo) -> SignalProducer<Data, Error> {
        let requestedLength = endOffset - startOffset
        guard requestedLength > 0 else { return .empty }

        let localFileStartOffset = max(0, startOffset - fileInfo.startOffset)
        let localFileUsefulLength = min(fileInfo.loadedByteLength - localFileStartOffset, requestedLength)
        let localFileRequestRange = localFileStartOffset..<localFileStartOffset + localFileUsefulLength
        print("addLocalRequest \(localFileStartOffset + fileInfo.startOffset ..< localFileStartOffset + fileInfo.startOffset + localFileUsefulLength)")

        startOffset = localFileStartOffset + fileInfo.startOffset + localFileUsefulLength
        return localRequestProducer(range: localFileRequestRange, fileInfo: fileInfo)
    }
    
    func localRequestProducer(range: SZAVPlayerRange, fileInfo: SZAVPlayerLocalFileInfo) -> SignalProducer<Data, Error> {
        return SignalProducer { (observer, _) in
            let fileURL = SZAVPlayerFileSystem.localFilePath(fileName: fileInfo.localFileName)
            if let data = SZAVPlayerFileSystem.read(url: fileURL, range: range) {
                observer.send(value: data)
                observer.sendCompleted()
            } else {
                observer.send(error: SZAVPlayerError.localFileNotExist)
            }
        }
    }
}

extension AVPlayerDataLoader {
    func remoteRequestProducer(startOffset: Int64, endOffset: Int64) -> SignalProducer<Data, Error> {
        guard startOffset < endOffset else { return .empty}
        let range = startOffset..<endOffset
        return remoteRequestProducer(range: range)
    }

    func remoteRequestProducer(range: SZAVPlayerRange) -> SignalProducer<Data, Error> {
        print("addRemoteRequest \(range)")
        return SignalProducer { [url] observer, lifetime in
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let sessionDelegate = URLSessionDataDelegateProxy()
            let session = URLSession(configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
            
            sessionDelegate.didReceiveData = { data in
                observer.send(value: data)
            }
            sessionDelegate.didCompleteWithError = { [weak session] error in
                if let error = error {
                    observer.send(error: error)
                } else {
                    observer.sendCompleted()
                }
                session?.finishTasksAndInvalidate()
            }

            var request = URLRequest(url: url)
            let rangeHeader = "bytes=\(range.lowerBound)-\(range.upperBound)"
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            
            let task = session.dataTask(with: request)
            
            lifetime.observeEnded {
                task.cancel()
            }
            task.resume()
        }.on { [weak self] in
            self?.mediaData = Data()
        } terminated: { [weak self] in
            guard let strongSelf = self, let mediaData = strongSelf.mediaData, mediaData.count > 0 else {
                return
            }
            SZAVPlayerCache.shared.save(uniqueID: strongSelf.uniqueID, mediaData: mediaData, startOffset: range.lowerBound)
            self?.mediaData = nil
        } value: { [weak self] data in
            self?.mediaData?.append(data)
        }
    }
}
