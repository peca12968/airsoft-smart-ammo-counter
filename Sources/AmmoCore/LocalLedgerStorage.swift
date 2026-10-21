import Foundation

/// Never replace an unreadable existing counter with an empty ledger.
public enum LocalLedgerStorage {
    public static func load(from folder:URL) throws -> LocalAmmoLedger? {
        var result:LocalAmmoLedger?,failure:Error?
        for name in ["local-counter.json","local-counter.json.backup"] {
            do {
                let value=try JSONDecoder().decode(LocalAmmoLedger.self,from:Data(contentsOf:folder.appendingPathComponent(name)))
                guard value.valid else{throw AmmoError.invalidValue}
                if result==nil {result=value}else{result?.merge(value)}
            }catch {
                let error=error as NSError
                if !(error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError) {failure=error}
            }
        }
        if let result {return result}
        if let failure {throw failure}
        return nil
    }
    public static func save(_ ledger:LocalAmmoLedger,to folder:URL) throws {
        guard ledger.valid else{throw AmmoError.invalidValue}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(ledger)
        var options:Data.WritingOptions=[.atomic]
        #if os(iOS) || os(watchOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        for name in ["local-counter.json.backup","local-counter.json"] {
            try data.write(to:folder.appendingPathComponent(name),options:options)
        }
    }
}

public enum WatchAutoStartPolicy {
    public static func shouldStart(phoneActive:Bool,watchSource:Bool,suppressed:Bool,
                                   pending:Bool,receiving:Bool,status:WatchControlStatus?)->Bool {
        guard phoneActive,watchSource,!suppressed,!pending,!receiving,let status else{return false}
        return status.canStart==true && status.hasModel && !status.busy
    }
}
