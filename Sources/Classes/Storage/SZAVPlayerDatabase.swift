//
//  SZAVPlayerDatabase.swift
//  SZAVPlayer
//
//  Created by CaiSanze on 2019/11/28.
//

import UIKit

public class SZAVPlayerDatabase: NSObject {

    public static let shared = SZAVPlayerDatabase()

    private let dbQueue = SZDatabase()
    private let dbFileName = SZAVPlayerFileSystem.documentsDirectory.appendingPathComponent("SZAVPlayer.sqlite").absoluteString

    override init() {
        super.init()

        guard dbQueue.open(dbPath: dbFileName) else { return }

        createContentInfoTable()
        createLocalFileInfoTable()
    }

    deinit {
        dbQueue.closeDB()
    }

    public func cleanData() {
        dbQueue.inTransaction { (db, rollback) in
            let needDeleteTableNames: [String] = [
                SZAVPlayerContentInfo.tableName,
                SZAVPlayerLocalFileInfo.tableName,
            ]
            needDeleteTableNames.forEach { (tableName) in
                let sql = "DELETE FROM \(tableName)"
                db.execute(sql: sql)
            }
        }
    }

    public func trimOwnData() {
        DispatchQueue.global(qos: .background).async {
            let infos = self.expiredOwnContentInfos()
            self.deleteAllData(for: infos)
        }
    }
    public func trimOthersData() {
        DispatchQueue.global(qos: .background).async {
            let infos = self.expiredOthersContentInfos()
            self.deleteAllData(for: infos)
        }
    }
    
    private func deleteAllData(for infos: [SZAVPlayerContentInfo]) {
        for info in infos {
            self.deleteContentInfo(uniqueID: info.uniqueID)

            let fileInfos = self.localFileInfos(uniqueID: info.uniqueID)
            for fileInfo in fileInfos {
                let fileURL = SZAVPlayerFileSystem.localFilePath(fileName: fileInfo.localFileName)
                SZAVPlayerFileSystem.delete(url: fileURL)
            }
            self.deleteLocalFileInfo(uniqueID: info.uniqueID)
        }
    }
}

// MARK: - ContentInfo

extension SZAVPlayerDatabase {

    /// Returns the cached content length for `uniqueID`, if known.
    public func contentLength(uniqueID: String) -> Int64? {
        return contentInfo(uniqueID: uniqueID)?.contentLength
    }

    /// Returns true when a contiguous prefix of at least `byteLength` bytes (capped to known content length)
    /// is already cached for `uniqueID`. Mirrors `AVPlayerAssetLoader.prefetch` fast-exit logic.
    public func hasCachedPrefix(uniqueID: String, byteLength: Int64) -> Bool {
        let infos = localFileInfos(uniqueID: uniqueID)
        let knownLength = contentInfo(uniqueID: uniqueID)?.contentLength
        let needed = min(byteLength, knownLength ?? Int64.max)
        return infos.contains(where: { $0.startOffset == 0 && $0.loadedByteLength >= needed })
    }

    /// Returns true when the requested byte range is already covered by a single contiguous cached chunk.
    public func hasCachedRange(uniqueID: String, range: Range<Int64>) -> Bool {
        guard !range.isEmpty else { return true }
        let infos = localFileInfos(uniqueID: uniqueID)
        return infos.contains(where: {
            $0.startOffset <= range.lowerBound && $0.startOffset + $0.loadedByteLength >= range.upperBound
        })
    }

    /// Detects whether the cached MP4/MOV file has its `moov` atom at the front (faststart).
    /// Returns nil when not enough cached prefix is available to decide.
    public func isFaststart(uniqueID: String) -> Bool? {
        let infos = localFileInfos(uniqueID: uniqueID)
        guard let head = infos.first(where: { $0.startOffset == 0 }), head.loadedByteLength >= 16 else {
            return nil
        }
        let url = SZAVPlayerFileSystem.localFilePath(fileName: head.localFileName)
        let readLength = min(head.loadedByteLength, 64)
        guard let data = SZAVPlayerFileSystem.read(url: url, range: 0..<readLength) else { return nil }
        return Self.detectMoovBeforeMdat(in: data)
    }

    private static func detectMoovBeforeMdat(in data: Data) -> Bool? {
        var offset = 0
        while offset + 8 <= data.count {
            let size32: UInt32 = data.subdata(in: offset..<offset+4).withUnsafeBytes { ptr in
                UInt32(bigEndian: ptr.load(as: UInt32.self))
            }
            let typeData = data.subdata(in: offset+4..<offset+8)
            let type = String(data: typeData, encoding: .ascii) ?? ""
            if type == "moov" { return true }
            if type == "mdat" { return false }

            let advance: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { return nil }
                let size64: UInt64 = data.subdata(in: offset+8..<offset+16).withUnsafeBytes { ptr in
                    UInt64(bigEndian: ptr.load(as: UInt64.self))
                }
                advance = Int(size64)
            } else if size32 >= 8 {
                advance = Int(size32)
            } else {
                return nil
            }
            guard advance >= 8 else { return nil }
            offset += advance
        }
        return nil
    }

    public func contentInfo(uniqueID: String) -> SZAVPlayerContentInfo? {
        var info: SZAVPlayerContentInfo?
        dbQueue.inQueue { (db) in
            let sql = "SELECT * FROM \(SZAVPlayerContentInfo.tableName) WHERE uniqueID = ?"
            let infos = db.query(sql: sql, params: [uniqueID])
            if let infoDict = infos.first,
                let tmpInfo = SZAVPlayerContentInfo.deserialize(data: infoDict)
            {
                info = tmpInfo
            }
        }

        // Here we should update accessed field to support LRU cache mechanism
        if let contentInfo = info {
//            print("previous access date: \(Date(timeIntervalSince1970: TimeInterval(contentInfo.accessed)))")
            dbQueue.inQueue { (db) in
                let sql = "UPDATE \(SZAVPlayerContentInfo.tableName) SET accessed = ? WHERE uniqueID = ?"
                let accessed = Int64(Date().timeIntervalSince1970)
                let params: [Any] = [accessed, contentInfo.uniqueID]
                db.execute(sql: sql, params: params)
            }
        }
        return info
    }

    public func update(contentInfo: SZAVPlayerContentInfo) {
        dbQueue.inQueue { (db) in
            let sql = "INSERT OR REPLACE INTO \(SZAVPlayerContentInfo.tableName) " +
            "(uniqueID, mimeType, contentLength, updated, accessed, isByteRangeAccessSupported, isOwn) " +
            "values(?, ?, ?, ?, ?, ?, ?)"
            let updated = Int64(Date().timeIntervalSince1970)
            let accessed = Int64(Date().timeIntervalSince1970)
            let params: [Any] = [contentInfo.uniqueID, contentInfo.mimeType, contentInfo.contentLength, updated, accessed, contentInfo.isByteRangeAccessSupported, contentInfo.isOwn]
            db.execute(sql: sql, params: params)
        }
    }

    public func deleteContentInfo(uniqueID: String) {
        dbQueue.inQueue { (db) in
            let sql = "DELETE FROM \(SZAVPlayerContentInfo.tableName) WHERE uniqueID = ?"
            let params = [
                uniqueID
            ]
            db.execute(sql: sql, params: params)
        }
    }

    private func expiredOwnContentInfos() -> [SZAVPlayerContentInfo] {
        var expiredInfos: [SZAVPlayerContentInfo] = []
        dbQueue.inQueue { (db) in
            let sql = "SELECT * FROM \(SZAVPlayerContentInfo.tableName) WHERE isOwn = 1 ORDER BY accessed ASC LIMIT 5"
            let infos = db.query(sql: sql)
            if let infoDict = infos.first,
                let tmpInfo = SZAVPlayerContentInfo.deserialize(data: infoDict)
            {
                expiredInfos.append(tmpInfo)
            }
        }

        return expiredInfos
    }

    private func expiredOthersContentInfos() -> [SZAVPlayerContentInfo] {
        var expiredInfos: [SZAVPlayerContentInfo] = []
        dbQueue.inQueue { (db) in
            let sql = "SELECT * FROM \(SZAVPlayerContentInfo.tableName) WHERE isOwn = 0 ORDER BY accessed ASC LIMIT 5"
            let infos = db.query(sql: sql)
            if let infoDict = infos.first,
                let tmpInfo = SZAVPlayerContentInfo.deserialize(data: infoDict)
            {
                expiredInfos.append(tmpInfo)
            }
        }

        return expiredInfos
    }
    
    func ownContentInfos() -> [SZAVPlayerContentInfo] {
        var ownContentInfos: [SZAVPlayerContentInfo] = []
        dbQueue.inQueue { (db) in
            let sql = "SELECT * FROM \(SZAVPlayerContentInfo.tableName) WHERE isOwn = 1"
            let infos = db.query(sql: sql)
            ownContentInfos = infos.flatMap(SZAVPlayerContentInfo.deserialize(data:))
        }

        return ownContentInfos
    }
    
    private func createContentInfoTable() {
        let tableName = SZAVPlayerContentInfo.tableName
        let sqlQuerys = [
            "CREATE TABLE IF NOT EXISTS \(tableName) (" +
            "id INTEGER PRIMARY KEY ASC, " +
            "uniqueID TEXT, " +
            "mimeType TEXT, " +
            "contentLength INTEGER, " +
            "updated INTEGER, " +
            "accessed INTEGER" +
            ");\n",
            "CREATE UNIQUE INDEX IF NOT EXISTS \(tableName)_uniqueID " +
            "ON \(tableName)(" +
            "uniqueID" +
            ");\n",
        ]

        createTable(sqlQuerys: sqlQuerys)

        if !dbQueue.columnExist(columnName: "isByteRangeAccessSupported", tableName: SZAVPlayerContentInfo.tableName) {
            let sql = "ALTER TABLE \(SZAVPlayerContentInfo.tableName) ADD COLUMN isByteRangeAccessSupported INTEGER DEFAULT 1"
            dbQueue.execute(sql: sql)
        }
        if !dbQueue.columnExist(columnName: "isOwn", tableName: SZAVPlayerContentInfo.tableName) {
            let sql = "ALTER TABLE \(SZAVPlayerContentInfo.tableName) ADD COLUMN isOwn INTEGER DEFAULT 0"
            dbQueue.execute(sql: sql)
        }
    }

}

// MARK: - LocalFileInfo

extension SZAVPlayerDatabase {

    public func localFileInfos(uniqueID: String) -> [SZAVPlayerLocalFileInfo] {
        var fileInfos: [SZAVPlayerLocalFileInfo] = []
        dbQueue.inQueue { (db) in
            let sql = "SELECT * FROM \(SZAVPlayerLocalFileInfo.tableName) WHERE uniqueID = ? AND loadedByteLength > 0 ORDER BY startOffset ASC"
            let params = [
                uniqueID
            ]
            let infos = db.query(sql: sql, params: params)
            infos.forEach { (info) in
                if let fileInfo = SZAVPlayerLocalFileInfo.deserialize(data: info) {
                    fileInfos.append(fileInfo)
                }
            }
        }

        return fileInfos
    }

    public func update(fileInfo: SZAVPlayerLocalFileInfo) {
        dbQueue.inQueue { (db) in
            let sql = "INSERT OR REPLACE INTO \(SZAVPlayerLocalFileInfo.tableName) " +
            "(uniqueID, startOffset, loadedByteLength, localFileName, updated) " +
            "values(?, ?, ?, ?, ?)"
            let updated = Int64(Date().timeIntervalSince1970)
            let params: [Any] = [
                fileInfo.uniqueID,
                fileInfo.startOffset,
                fileInfo.loadedByteLength,
                fileInfo.localFileName,
                updated
            ]
            db.execute(sql: sql, params: params)
        }
    }

    public func deleteLocalFileInfo(uniqueID: String) {
        dbQueue.inQueue { (db) in
            let sql = "DELETE FROM \(SZAVPlayerLocalFileInfo.tableName) WHERE uniqueID = ?"
            let params = [
                uniqueID
            ]
            db.execute(sql: sql, params: params)
        }
    }
    public func deleteLocalFileInfo(id: Int64) {
        dbQueue.inQueue { (db) in
            let sql = "DELETE FROM \(SZAVPlayerLocalFileInfo.tableName) WHERE id = ?"
            let params = [
                id
            ]
            db.execute(sql: sql, params: params)
        }
    }

    private func createLocalFileInfoTable() {
        let tableName = SZAVPlayerLocalFileInfo.tableName
        let sqlQuerys = [
            "CREATE TABLE IF NOT EXISTS \(tableName) (" +
            "id INTEGER PRIMARY KEY ASC, " +
            "uniqueID TEXT, " +
            "startOffset INTEGER, " +
            "loadedByteLength INTEGER, " +
            "localFileName TEXT, " +
            "updated INTEGER" +
            ");\n",
            "CREATE UNIQUE INDEX IF NOT EXISTS \(tableName)_uniqueID_startOffset " +
            "ON \(tableName)(" +
            "uniqueID, startOffset" +
            ");\n",
        ]

        createTable(sqlQuerys: sqlQuerys)
    }

}

// MARK: - Private

private extension SZAVPlayerDatabase {

    func createTable(sqlQuerys: [String]) {
        dbQueue.inTransaction { (db, rollback) in
            for sql in sqlQuerys {
                if db.execute(sql: sql) == SQLITE_RESULT_FAILED {
                    rollback = true
                    break
                }
            }
        }
    }

}
