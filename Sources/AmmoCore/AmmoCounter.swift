import Foundation

public enum AmmoError: Error, Equatable { case invalidCapacity, invalidValue, malformedPacket, unsupportedVersion }
public struct AmmoCounter: Codable, Equatable {
    public static let presets = [30,130,150,300]
    public private(set) var capacity: Int
    public private(set) var remaining: Int
    public private(set) var totalEvents: UInt32
    public var fraction: Double { Double(remaining)/Double(capacity) }
    public var isLow: Bool { fraction < 0.15 }
    public init(capacity: Int = 300, remaining: Int? = nil, totalEvents: UInt32 = 0) throws {
        guard (1...9999).contains(capacity) else { throw AmmoError.invalidCapacity }
        let left = remaining ?? capacity
        guard (0...capacity).contains(left) else { throw AmmoError.invalidValue }
        self.capacity = capacity; self.remaining = left; self.totalEvents = totalEvents
    }
    public mutating func correct(by delta: Int) {
        if delta >= 0 { remaining += min(delta,capacity-remaining) }
        else { remaining = delta < -remaining ? 0:remaining+delta }
    }
    public mutating func setCapacity(_ value: Int) throws {
        guard (1...9999).contains(value) else { throw AmmoError.invalidCapacity }
        capacity = value; remaining = min(remaining,value)
    }
    public mutating func reload(capacity value: Int? = nil) throws {
        if let value { try setCapacity(value) }; remaining = capacity
    }
    public mutating func recordEvent() {
        remaining = max(0,remaining-1)
        if totalEvents < .max { totalEvents += 1 }
    }
}

public struct LocalAmmoLedger: Codable, Equatable {
    public var seed: UInt64
    public var events: [String:UInt64]
    public var capacity: Int
    public var anchorRemaining: Int
    public var anchorLifetime: UInt64
    public var revision: UInt64
    public var editor: String
    public var resetBaseline: UInt64
    public var resetRevision: UInt64
    public var sensorOwner:String?
    public var sensorRevision:UInt64?
    public var resetEditor: String
    public init(seed:UInt64=0,capacity:Int=300,remaining:Int=300,editor:String) {
        self.seed=seed;events=[:];self.capacity=capacity;anchorRemaining=min(capacity,max(0,remaining));anchorLifetime=seed;revision=0;self.editor=editor;resetBaseline=0;resetRevision=0;resetEditor=editor
    }
    public var lifetime:UInt64 {events.values.reduce(seed){a,b in let (v,overflow)=a.addingReportingOverflow(b);return overflow ? .max:v}}
    public var total:UInt64 {lifetime>=resetBaseline ? lifetime-resetBaseline:0}
    public var remaining:Int {let used=lifetime>=anchorLifetime ? lifetime-anchorLifetime:0;return used>=UInt64(anchorRemaining) ? 0:anchorRemaining-Int(used)}
    public var valid:Bool {(1...9999).contains(capacity) && (0...capacity).contains(anchorRemaining) && anchorLifetime<=lifetime && resetBaseline<=lifetime && !editor.isEmpty && !resetEditor.isEmpty && events.count<=64 && events.keys.allSatisfy{!$0.isEmpty}}
    public mutating func event(origin:String) {let old=events[origin] ?? 0;if old<UInt64.max {events[origin]=old+1}}
    private mutating func revise(origin:String){revision=max(revision,resetRevision);if revision<UInt64.max {revision+=1};editor=origin}
    public mutating func reload(capacity:Int?=nil,origin:String){if let capacity,(1...9999).contains(capacity){self.capacity=capacity};revise(origin:origin);anchorRemaining=self.capacity;anchorLifetime=lifetime}
    public mutating func correct(_ delta:Int,origin:String){let current=remaining;revise(origin:origin);anchorRemaining=delta>=0 ? current+min(delta,capacity-current):(delta < -current ? 0:current+delta);anchorLifetime=lifetime}
    public mutating func setCapacity(_ value:Int,origin:String){guard (1...9999).contains(value) else{return};let left=remaining;revise(origin:origin);capacity=value;anchorRemaining=min(value,left);anchorLifetime=lifetime}
    public mutating func resetFromPhone(origin:String){resetBaseline=lifetime;resetRevision=max(resetRevision,revision);if resetRevision<UInt64.max {resetRevision+=1};resetEditor=origin}
    public mutating func claimSensor(origin:String){sensorOwner=origin;let current=max(sensorRevision ?? 0,max(revision,resetRevision));sensorRevision=current<UInt64.max ? current+1:current}
    public mutating func merge(_ other:Self) {
        guard other.valid else{return}
        if let owner=other.sensorOwner,let version=other.sensorRevision,version>(sensorRevision ?? 0) || (version==(sensorRevision ?? 0) && owner>(sensorOwner ?? "")){sensorOwner=owner;sensorRevision=version}
        seed=max(seed,other.seed)
        for (origin,count) in other.events {events[origin]=max(events[origin] ?? 0,count)}
        if other.revision>revision || (other.revision==revision && other.editor>editor){capacity=other.capacity;anchorRemaining=other.anchorRemaining;anchorLifetime=other.anchorLifetime;revision=other.revision;editor=other.editor}
        if other.resetRevision>resetRevision || (other.resetRevision==resetRevision && other.resetEditor>resetEditor){resetBaseline=other.resetBaseline;resetRevision=other.resetRevision;resetEditor=other.resetEditor}
    }
}

public struct LocalTriggerGate {
    private var armed=false
    private var quietSince:Double?
    private var lastEvent:Double = -.infinity
    public init(){}
    public mutating func update(match:Bool,quiet:Bool,time:Double,refractory:Double=0.14,quietDuration:Double=0.05)->Bool {
        guard time.isFinite else{return false}
        if quiet {if quietSince==nil {quietSince=time};if time-(quietSince ?? time)>=quietDuration {armed=true}} else {quietSince=nil}
        guard match,armed,time-lastEvent>=refractory else{return false}
        armed=false;lastEvent=time;return true
    }
}
