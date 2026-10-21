import Foundation

public enum SoundStation:String,Codable,Sendable {case phone,watch}
public struct SoundObservation:Codable,Equatable,Sendable {
    public let source:String
    public let sequence:UInt64
    public let station:SoundStation
    /// Onset time in the phone's wall-clock domain, not message arrival time.
    public let time:Double
    public let uncertainty:Double
    public init(source:String,sequence:UInt64,station:SoundStation,time:Double,uncertainty:Double=0){self.source=source;self.sequence=sequence;self.station=station;self.time=time;self.uncertainty=uncertainty}
    public var valid:Bool {!source.isEmpty && source.utf8.count<=128 && sequence>0 && time.isFinite && time>0 && uncertainty.isFinite && (0...0.025).contains(uncertainty)}
}
public enum SoundFusionResult:String,Sendable {case counted,paired,duplicate,gap,expired,invalid,suppressed}
public struct SoundClockEstimate:Sendable {
    public let offset:Double
    public let uncertainty:Double
    public let measuredAt:Double
    public init?(sent:Double,receivedByPhone:Double,repliedByPhone:Double,returned:Double){
        guard [sent,receivedByPhone,repliedByPhone,returned].allSatisfy(\.isFinite),returned>=sent,repliedByPhone>=receivedByPhone else{return nil}
        let delay=(returned-sent)-(repliedByPhone-receivedByPhone)
        guard delay>=0,delay<=0.05 else{return nil}
        offset=((receivedByPhone-sent)+(repliedByPhone-returned))/2
        uncertainty=delay/2;measuredAt=returned
    }
    public func valid(at now:Double)->Bool {now.isFinite && now>=measuredAt && now-measuredAt<=60}
}

/// Stored atomically with LocalAmmoLedger: an acknowledgment cannot precede its count.
/// Each station's sequence is processed in order. Pairing is one-to-one across stations.
public struct SoundFusionState:Codable,Equatable,Sendable {
    public struct Event:Codable,Equatable,Sendable {
        public let time:Double
        public let station:SoundStation
        public var paired:Bool
    }
    public let owner:String
    public private(set) var revision:UInt64=0
    public private(set) var nextSequence:UInt64=1
    public private(set) var pending:[SoundObservation]=[]
    public private(set) var processed:[String:UInt64]=[:]
    public private(set) var history:[Event]=[]
    public private(set) var historyFloor:Double=0
    public init(owner:String){self.owner=owner}
    public var valid:Bool {
        !owner.isEmpty && owner.utf8.count<=128 && nextSequence>0 && pending.count<=64 && pending.allSatisfy{$0.valid && $0.source==owner && $0.sequence<nextSequence} && Set(pending.map(\.sequence)).count==pending.count && processed.count<=16 && processed.keys.allSatisfy{!$0.isEmpty && $0.utf8.count<=128} && history.count<=2048 && history.allSatisfy{$0.time.isFinite && $0.time>0} && historyFloor.isFinite && historyFloor>=0
    }
    @discardableResult public mutating func enqueue(station:SoundStation,time:Double,uncertainty:Double=0)->SoundObservation? {
        guard valid,revision<UInt64.max,nextSequence<UInt64.max,pending.count<64 else{return nil}
        let observation=SoundObservation(source:owner,sequence:nextSequence,station:station,time:time,uncertainty:uncertainty)
        guard observation.valid else{return nil}
        nextSequence+=1;pending.append(observation);revision+=1;return observation
    }
    public mutating func acknowledge(through sequence:UInt64){
        guard valid,sequence<nextSequence,revision<UInt64.max,pending.contains(where:{$0.sequence<=sequence}) else{return}
        pending.removeAll{$0.sequence<=sequence};revision+=1
    }
    public mutating func accept(_ observation:SoundObservation,now:Double,counting:Bool=true)->SoundFusionResult {
        guard valid,observation.valid,now.isFinite,revision<UInt64.max else{return .invalid}
        let prior=processed[observation.source] ?? 0
        if observation.sequence<=prior {return .duplicate}
        guard prior<UInt64.max,observation.sequence==prior+1 else{return .gap}
        guard processed[observation.source] != nil || processed.count<16 else{return .invalid}
        // Consume stale IDs, but never count outside the retained pairing history.
        guard now-observation.time<=120,observation.time-now<=0.25,observation.time>historyFloor else{
            processed[observation.source]=observation.sequence;revision+=1;return .expired
        }
        processed[observation.source]=observation.sequence;revision+=1
        guard counting else{return .suppressed}
        // 75ms bounds onset alignment; same-station events are never collapsed.
        let candidates=history.indices.filter{!history[$0].paired && history[$0].station != observation.station && abs(history[$0].time-observation.time)<=0.075}
        if let index=candidates.min(by:{abs(history[$0].time-observation.time)<abs(history[$1].time-observation.time)}) {
            history[index].paired=true;return .paired
        }
        history.append(Event(time:observation.time,station:observation.station,paired:false))
        history.sort{$0.time<$1.time}
        if history.count>2048 {historyFloor=max(historyFloor,history.removeFirst().time)}
        return .counted
    }
}
