import Foundation

public struct WatchAudioFrame:Codable,Sendable {
    public let spectrum:AudioSpectrum
    public let motion:Double
    public let time:Double
    public init(spectrum:AudioSpectrum,motion:Double,time:Double) {self.spectrum=spectrum;self.motion=motion;self.time=time}
    public var valid:Bool {
        time.isFinite && time>=0 && motion.isFinite && (0...100).contains(motion)
        && spectrum.rms.isFinite && (0...1).contains(spectrum.rms) && spectrum.bands.count==8
        && spectrum.bands.allSatisfy{$0.isFinite && (0...1).contains($0)}
        && spectrum.bands.reduce(0,+)<=1.01 && spectrum.dominantHz<=8000
        && spectrum.flags & 0xF1 == 0 && (spectrum.dense == nil || spectrum.dense!.valid)
    }
}
public struct WatchAudioStart:Codable,Sendable {
    public var version=1
    public let id:UUID
    public let model:RefinedAcousticModel
    public let settings:LocalDetectionSettings
    public let validation:Bool
    public let expected:Int
    public init(model:RefinedAcousticModel,settings:LocalDetectionSettings,validation:Bool,expected:Int=5) {
        id=UUID();self.model=model;self.settings=settings;self.validation=validation;self.expected=expected
    }
    public var valid:Bool {version==1 && model.valid && settings.valid && [0,5].contains(expected)}
}
public struct WatchAudioBatch:Codable,Sendable {
    public let id:UUID
    public let sequence:UInt64
    public let frames:[WatchAudioFrame]
    public let finished:Bool
    public init(id:UUID,sequence:UInt64,frames:[WatchAudioFrame],finished:Bool=false) {
        self.id=id;self.sequence=sequence;self.frames=frames;self.finished=finished
    }
}
public struct WatchAudioResult:Codable,Sendable {
    public let sequence:UInt64
    public let totalHits:Int
    public let newHits:Int
    public let gaps:Int
    public let decision:String
    public let finished:Bool
}

/// Classification uses the watch's sample clock, never packet arrival time.
/// A repeated acknowledged batch cannot create additional ledger events.
public struct WatchAudioReceiver {
    public let session:WatchAudioStart
    private var nextSequence:UInt64=0
    private var detector=LocalAcousticDetector()
    private var motionGate=LocalTriggerGate()
    private var lastTime:Double?
    private var hits=0,gaps=0
    private var lastResult:WatchAudioResult?
    private var ended=false
    public init?(session:WatchAudioStart) {guard session.valid else{return nil};self.session=session}
    public mutating func accept(_ batch:WatchAudioBatch) throws -> WatchAudioResult {
        guard batch.id==session.id else{throw AmmoError.invalidValue}
        if let previous=lastResult,batch.sequence==previous.sequence {
            return WatchAudioResult(sequence:previous.sequence,totalHits:previous.totalHits,newHits:0,gaps:previous.gaps,decision:previous.decision,finished:previous.finished)
        }
        guard !ended,batch.sequence==nextSequence,nextSequence<UInt64.max,
              batch.frames.count<=24,(!batch.frames.isEmpty || batch.finished),batch.frames.allSatisfy(\.valid) else{throw AmmoError.invalidValue}
        var prior=lastTime
        for frame in batch.frames {
            if let prior,frame.time<=prior {throw AmmoError.invalidValue}
            prior=frame.time
        }
        let before=hits
        var model=session.model;model.minimumScore=session.settings.similarity
        for frame in batch.frames {
            if let lastTime,frame.time-lastTime>0.15 {detector=LocalAcousticDetector();motionGate=LocalTriggerGate();gaps+=1}
            lastTime=frame.time
            let hit:Bool
            if session.settings.mode==2 {
                hit=motionGate.update(match:frame.motion>=session.settings.motionThreshold,quiet:frame.motion<session.settings.motionThreshold*0.45,time:frame.time)
            }else{
                hit=detector.update(frame.spectrum,time:frame.time,model:model,needsMotion:session.settings.mode==1,motionOK:frame.motion>=session.settings.motionThreshold)
            }
            if hit {hits+=1}
        }
        nextSequence+=1;ended=batch.finished
        let result=WatchAudioResult(sequence:batch.sequence,totalHits:hits,newHits:hits-before,gaps:gaps,decision:detector.decision.text,finished:ended)
        lastResult=result;return result
    }
}
