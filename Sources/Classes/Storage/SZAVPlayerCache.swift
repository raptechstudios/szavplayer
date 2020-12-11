//
//  SZAVPlayerCache.swift
//
//  Created by CaiSanze on 2019/11/27.
//

import UIKit

public class SZAVPlayerCache: NSObject {

    public static let shared: SZAVPlayerCache = SZAVPlayerCache()

    private var maxCacheSize: Int64 = 500

    override init() {
        super.init()
        SZAVPlayerFileSystem.createCacheDirectory()
    }

    /// Setup
    /// - Parameter maxCacheSize: Unit: MB
    public func setup(maxCacheSize: Int64) {
        self.maxCacheSize = maxCacheSize
        trimCache()
    }

    public func save(uniqueID: String, mediaData: Data, startOffset: Int64) {
        let newFileName = SZAVPlayerLocalFileInfo.newFileName(uniqueID: uniqueID)
        let localFilePath = SZAVPlayerFileSystem.localFilePath(fileName: newFileName)
        if SZAVPlayerFileSystem.write(data: mediaData, url: localFilePath) {
            let fileInfo = SZAVPlayerLocalFileInfo(uniqueID: uniqueID,
                                                   startOffset: startOffset,
                                                   loadedByteLength: Int64(mediaData.count),
                                                   localFileName: newFileName)
            SZAVPlayerDatabase.shared.update(fileInfo: fileInfo)
        }

        trimCache()
    }

    public func cacheSize() -> Int64 {
        return SZAVPlayerFileSystem.sizeForDirectory(SZAVPlayerFileSystem.cacheDirectory)
    }
    
    public func cleanCache() {
        SZAVPlayerDatabase.shared.cleanData()
        SZAVPlayerFileSystem.cleanCachedFiles()
    }

    public func trimCache() {
        DispatchQueue.global(qos: .background).async {
            let directory = SZAVPlayerFileSystem.cacheDirectory
            var totalFileSize = SZAVPlayerFileSystem.sizeForDirectory(directory)
            totalFileSize /= 1024 * 1024
            if totalFileSize >= self.maxCacheSize {
                SZAVPlayerDatabase.shared.trimData()
            }
        }
    }
}

// MARK: - Getter

extension SZAVPlayerCache {

    public static func dataExist(uniqueID: String) -> Bool {
        return SZAVPlayerFileSystem.isExist(url: fileURL(uniqueID: uniqueID))
    }

    private static func fileURL(uniqueID: String) -> URL {
        return SZAVPlayerFileSystem.cacheDirectory.appendingPathComponent(uniqueID)
    }

}
