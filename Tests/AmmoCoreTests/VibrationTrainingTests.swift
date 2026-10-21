import XCTest
@testable import AmmoCore
final class VibrationTrainingTests: XCTestCase {
    let golden = "414d4431010310012a0000000100c8008fc2f53ccdcc4c3e0ad7a33d0000a0408fc2f53c0ad7233c00000040000010410ad7a33d8fc2753cd20400005000784f"
    func bytes() -> Data { Data(stride(from: 0, to: golden.count, by: 2).map { i in let a = golden.index(golden.startIndex, offsetBy: i); return UInt8(golden[a..<golden.index(a, offsetBy: 2)], radix:16)! }) }
    func fixture(_ label: CaptureLabel) -> VibrationDataset {
        var d = VibrationDataset(deviceID: 1, boot: 1, captureID: label == .background ? 1:2, label: label)
        d.completed = true; d.duration = 12
        d.features = (1...300).map { i in
            let candidate = i % 25 == 0, positive = candidate && label == .positive
            return VibrationFeature(captureID: d.captureID, sequence: UInt16(i), label: label, timestamp: UInt32(i*40), peakG: positive ? 0.20+Double(i%3)*0.002 : (candidate ? 0.065:0.004), rmsG: positive ? 0.08:0.002, gyroDps: label == .background && candidate ? 35:5, candidate: candidate)
        }; return d
    }
    func testGoldenModelCrossLanguageRoundTripAndCorruption() throws {
        let p = try DetectorProfile(data: bytes()); XCTAssertEqual(p.id,42); XCTAssertEqual(p.data,bytes())
        XCTAssertEqual(p.chunks(transferID: 3).map(\.count),[20,20,20,20])
        var bad = bytes(); bad[20] ^= 1; XCTAssertThrowsError(try DetectorProfile(data: bad))
        bad = bytes(); bad.replaceSubrange(20..<24,with:[0,0,128,127]); let crc = VibrationCRC.checksum(bad.prefix(60)); for i in 0..<4 { bad[60+i] = UInt8(truncatingIfNeeded:crc >> (8*i)) }
        XCTAssertThrowsError(try DetectorProfile(data: bad))
    }
    func testPacketSlicesBoundsAndUnknownFlags() throws {
        let f = fixture(.positive).features.last!; let packet = f.data
        XCTAssertEqual(try VibrationFeature(data: packet), f)
        let wrapped = Data([9,9])+packet; XCTAssertEqual(try VibrationFeature(data: wrapped.dropFirst(2)), f)
        var b = packet; b[1] = 128; XCTAssertThrowsError(try VibrationFeature(data:b))
        b = packet; b[14] = 255; b[15] = 255; XCTAssertThrowsError(try VibrationFeature(data:b))
        for length in [0,1,19,21] { XCTAssertThrowsError(try VibrationFeature(data:Data(repeating:0,count:length))) }
        XCTAssertEqual(TrainingCommand(opcode:.positive,value:12,requestID:1,boot:2).data.count,16)
    }
    func testTrainingAcceptsSeparatedTestAndRealExamples() throws {
        for test in [true,false] {
            let r = try VibrationTrainer.analyze(background:fixture(.background),positive:fixture(.positive),isTest:test,modelID:42)
            XCTAssertEqual(r.profile.isTest,test); XCTAssertEqual(r.sensitivity,1); XCTAssertEqual(r.specificity,1)
            XCTAssertTrue(r.profile.accepts(fixture(.positive).features.last!)); XCTAssertFalse(r.profile.accepts(fixture(.background).features.last!))
        }
    }
    func testTrainingRejectsIndistinguishableImpacts() {
        var n = fixture(.background); n.features = fixture(.positive).features.map { VibrationFeature(captureID:n.captureID,sequence:$0.sequence,label:.background,timestamp:$0.timestamp,peakG:$0.peakG,rmsG:$0.rmsG,gyroDps:$0.gyroDps,candidate:$0.isCandidate) }
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:fixture(.positive),isTest:true))
    }
    func testIncompleteLostOrInsufficientSamplesNeverProduceModel() {
        var n = fixture(.background); n.completed = false
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:fixture(.positive),isTest:true))
        n = fixture(.background); n.dropped = 40
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:fixture(.positive),isTest:true))
        var p = fixture(.positive); p.features = Array(p.features.prefix(40))
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:fixture(.background),positive:p,isTest:true))
    }
    func testMultipleShortCapturesCombineWithoutMixingOrigins() throws {
        var first = fixture(.positive); first.features = Array(first.features.prefix(100)); first.duration = 4
        var second = fixture(.positive); second.features = Array(second.features.suffix(100)); second.duration = 4
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:fixture(.background),positive:first,isTest:true))
        let report = try VibrationTrainer.analyzeSeries(background:[fixture(.background)],positive:[first,second],isTest:true)
        XCTAssertEqual(report.positiveExamples,8)
        XCTAssertThrowsError(try VibrationTrainer.analyzeSeries(background:[],positive:[first],isTest:true))
        first.completed = false
        XCTAssertThrowsError(try VibrationTrainer.analyzeSeries(background:[fixture(.background)],positive:[first,second],isTest:true))
    }
    func testQuickTrainingAcceptsOverlappingBackgroundWithExplicitWarning() throws {
        var n = fixture(.background); let p = fixture(.positive)
        n.features = p.features.map { VibrationFeature(captureID:n.captureID,sequence:$0.sequence,label:.background,timestamp:$0.timestamp,peakG:$0.peakG,rmsG:$0.rmsG,gyroDps:$0.gyroDps,candidate:$0.isCandidate) }
        let report = try VibrationTrainer.analyze(background:n,positive:p,isTest:true,relaxed:true)
        XCTAssertEqual(report.specificity,0)
        XCTAssertTrue(report.warnings.contains { $0.contains("容易誤計數") })
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:p,isTest:true))
    }
    func testQuickTrainingNeedsThreeValidEventsAndKeepsDataQualityChecks() throws {
        var p = fixture(.positive); p.features = Array(p.features.prefix(75)); p.duration = 4
        let n = fixture(.background)
        XCTAssertEqual(try VibrationTrainer.analyzeSeries(background:[n],positive:[p],isTest:true,relaxed:true).positiveExamples,3)
        p.features = Array(p.features.prefix(50))
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:p,isTest:true,relaxed:true))
        p = fixture(.positive); p.dropped = 100
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:p,isTest:true,relaxed:true))
    }
    func testWeakTapsBelowOldThresholdAreCollectedBeforeClassification() throws {
        var n = fixture(.background), p = fixture(.positive)
        n.features = (1...150).map { VibrationFeature(captureID:n.captureID,sequence:UInt16($0),label:.background,timestamp:UInt32($0*40),peakG:0.002,rmsG:0.001,gyroDps:1,candidate:false) }
        p.features = (1...150).map { i in let tap = i % 25 == 0; return VibrationFeature(captureID:p.captureID,sequence:UInt16(i),label:.positive,timestamp:UInt32(i*40),peakG:tap ? 0.012:0.002,rmsG:tap ? 0.006:0.001,gyroDps:1,candidate:false) }
        let baseline = try VibrationTrainer.calibrate(background:n.features)
        XCTAssertLessThan(baseline.onsetG,0.012)
        let report = try VibrationTrainer.analyze(background:n,positive:p,isTest:true,relaxed:true)
        XCTAssertEqual(report.positiveExamples,6); XCTAssertLessThan(report.profile.onsetG,0.03)
        XCTAssertTrue(report.profile.accepts(VibrationTrainer.events(p.features,threshold:baseline.onsetG)[0]))
    }
    func testObservedGapFailureRemainsRejectedWithZeroPacketLoss() throws {
        // Regression: phone audit found 54 received frames, 53 gaps and zero loss.
        // A visible live envelope must not bypass continuous sampling validation.
        var target=fixture(.positive);target.duration=8.16;target.dropped=0
        target.features=try Array(target.features.prefix(54)).enumerated().map { index,f in
            var packet=f.data;packet[1]=(index<53 ? 4:0) | (index<26 ? 8:0)
            return try VibrationFeature(data:packet)
        }
        for relaxed in [false,true] {
            XCTAssertThrowsError(try VibrationTrainer.analyze(background:fixture(.background),positive:target,isTest:true,relaxed:relaxed)) { XCTAssertEqual($0 as? TrainingFailure,.poorQuality) }
        }
    }
    func testQuietOrConstantMotionIsNotInventedAsThreeTaps() throws {
        var n = fixture(.background),p = fixture(.positive)
        n.features = (1...150).map { VibrationFeature(captureID:n.captureID,sequence:UInt16($0),label:.background,timestamp:UInt32($0*40),peakG:0.002,rmsG:0.001,gyroDps:1,candidate:false) }
        p.features = (1...150).map { VibrationFeature(captureID:p.captureID,sequence:UInt16($0),label:.positive,timestamp:UInt32($0*40),peakG:0.002,rmsG:0.001,gyroDps:1,candidate:false) }
        XCTAssertThrowsError(try VibrationTrainer.analyze(background:n,positive:p,isTest:true,relaxed:true)) { XCTAssertEqual($0 as? TrainingFailure,.noSignal) }
        let continuous = (1...150).map { VibrationFeature(captureID:2,sequence:UInt16($0),label:.positive,timestamp:UInt32($0*40),peakG:0.015,rmsG:0.007,gyroDps:1,candidate:false) }
        XCTAssertEqual(VibrationTrainer.events(continuous,threshold:0.004).count,1)
    }
    func testRingingFramesAreGroupedAndClippedFramesExcluded() throws {
        let features = [0,40,80,1000,1040,1080,2000,2040].enumerated().map { VibrationFeature(captureID:2,sequence:UInt16($0.offset+1),label:.positive,timestamp:UInt32($0.element),peakG:0.01,rmsG:0.005,gyroDps:1,candidate:false) }
        XCTAssertEqual(VibrationTrainer.events(features,threshold:0.004).count,3)
        var bytes = features[0].data;bytes[1] = 2;bytes[18] = 1
        XCTAssertTrue(VibrationTrainer.events([try VibrationFeature(data:bytes)],threshold:0.004).isEmpty)
    }
    func testLiveSignalBoundsSlicesAndUnknownFlags() throws {
        let d = LiveSignal.data(sequence:1,timestamp:100,rms:100,peak:200,vibrationMG:8,samples:1600,boot:1)
        let live = try LiveSignal(data:(Data([9])+d).dropFirst());XCTAssertTrue(live.microphoneActive);XCTAssertEqual(live.vibrationG,0.008)
        var bad = d;bad[1] = 128;XCTAssertThrowsError(try LiveSignal(data:bad))
        bad = d;bad[8] = 255;bad[9] = 255;XCTAssertThrowsError(try LiveSignal(data:bad))
        XCTAssertFalse(try LiveSignal(data:LiveSignal.data(sequence:2,timestamp:200,rms:0,peak:0,vibrationMG:0,samples:0,boot:1)).microphoneActive)
        XCTAssertThrowsError(try LiveSignal(data:Data()))
    }
    @MainActor func testDemoAudioPreviewStreamsAndStops() async throws {
        let d = DemoDevice();var count = 0
        d.onEvent = {if case .liveSignal(let bytes) = $0, (try? LiveSignal(data:bytes)) != nil {count += 1}}
        d.start();d.train(TrainingCommand(opcode:.preview,value:20,requestID:1,boot:d.snapshot.boot).data)
        try await Task.sleep(nanoseconds:350_000_000);XCTAssertGreaterThanOrEqual(count,2)
        d.train(TrainingCommand(opcode:.stopPreview,requestID:2,boot:d.snapshot.boot).data);let stopped = count
        try await Task.sleep(nanoseconds:200_000_000);XCTAssertEqual(count,stopped)
    }
    @MainActor func testDemoModelACKEnablePauseAndLifetimeCount() throws {
        let demo = DemoDevice(); var s: TrainingStatus?; demo.onEvent = { if case .trainingStatus(let d) = $0 { s = try? TrainingStatus(data:d) } }; demo.start()
        demo.uploadProfile(try DetectorProfile(data:bytes()).chunks(transferID:7)); XCTAssertEqual(s?.requestID,7); XCTAssertEqual(s?.mode,0)
        demo.train(TrainingCommand(opcode:.enable,requestID:9,boot:demo.snapshot.boot,modelID:42).data)
        XCTAssertEqual(s?.mode,3); let total = demo.snapshot.counter.totalEvents; demo.simulateTrainedEvent(); XCTAssertEqual(demo.snapshot.counter.totalEvents,total+1)
        demo.train(TrainingCommand(opcode:.disable,requestID:10,boot:demo.snapshot.boot,modelID:42).data)
        demo.simulateTrainedEvent(); XCTAssertEqual(demo.snapshot.counter.totalEvents,total+1)
        demo.send(DeviceCommand(opcode:.reload,value:300,requestID:12,expectedSequence:demo.snapshot.sequence,boot:demo.snapshot.boot).data)
        XCTAssertEqual(demo.snapshot.counter.totalEvents,total+1)
    }
    func testTrainingStatusRejectsMalformedAndSupportsSlices() throws {
        let b = TrainingStatus.data(mode:3,modelID:42,requestID:1,boot:4)
        XCTAssertTrue(try TrainingStatus(data:(Data([0])+b).dropFirst()).hasModel)
        var bad = b; bad[1] = 4; XCTAssertThrowsError(try TrainingStatus(data:bad))
        bad = b; bad[16] = 0; XCTAssertThrowsError(try TrainingStatus(data:bad))
    }
}

extension VibrationTrainingTests {
    func testSensitiveTriggerAcceptsWeakerAndDifferentIntensityWithoutCountingNoise() throws {
        let report=try VibrationTrainer.analyze(background:fixture(.background),positive:fixture(.positive),isTest:true,relaxed:true)
        let p=report.profile;XCTAssertEqual(p.detectionMode,.sensitive)
        let weak=VibrationFeature(captureID:2,sequence:1,label:.positive,timestamp:1000,peakG:0.012,rmsG:0.003,gyroDps:0,candidate:true)
        XCTAssertTrue(p.accepts(weak))
        let noise=VibrationFeature(captureID:2,sequence:2,label:.positive,timestamp:2000,peakG:0.002,rmsG:0.001,gyroDps:0,candidate:true)
        XCTAssertFalse(p.accepts(noise))
        XCTAssertEqual(try DetectorProfile(data:p.data).detectionMode,.sensitive)
        let strict=try VibrationTrainer.analyze(background:fixture(.background),positive:fixture(.positive),isTest:true).profile
        XCTAssertFalse(strict.accepts(weak))
    }
}

extension VibrationTrainingTests {
    func audio(_ i:Int,target:Bool,rms:Double?=nil)->AudioSpectrum {
        let bands=target ? [0.02,0.04,0.08,0.4,0.3,0.1,0.04,0.02]:Array(repeating:0.125,count:8)
        return try! AudioSpectrum(data:AudioSpectrum.data(sequence:UInt16(i+1),captureID:1,rms:rms ?? (target ? 0.05:0.002),bands:bands,dominantHz:target ? 1500:400,timestamp:UInt16(i*40)))
    }
    func testAudioSpectrumWireAndMalformedPackets() throws {
        let f=audio(1,target:true);XCTAssertEqual(f.dominantHz,1500);XCTAssertTrue(f.usable)
        var d=AudioSpectrum.data(sequence:1,captureID:1,rms:0.1,bands:Array(repeating:0.125,count:8),dominantHz:1000,timestamp:4)
        XCTAssertEqual(d.count,20);d[1]=128;XCTAssertThrowsError(try AudioSpectrum(data:d))
        XCTAssertThrowsError(try AudioSpectrum(data:Data()))
    }
    func testFrequencyTemplateRejectsDifferentTrackAtEqualVolume() throws {
        let background=(0..<100).map{audio($0,target:false)}
        let positive=(0..<200).map{audio($0,target:$0%25==0)}
        let report=try AudioTrainer.analyze(background:background,positive:positive)
        XCTAssertEqual(report.events,8)
        XCTAssertTrue(report.profile.accepts(audio(1,target:true,rms:0.01)))
        let different=try AudioSpectrum(data:AudioSpectrum.data(sequence:1,captureID:1,rms:0.05,bands:[0.7,0.2,0.1,0,0,0,0,0],dominantHz:125,timestamp:1000))
        XCTAssertFalse(report.profile.accepts(different))
        XCTAssertEqual(try AudioProfile(data:report.profile.data).template.count,8)
        var corrupt=report.profile.data;corrupt[25]^=1;XCTAssertThrowsError(try AudioProfile(data:corrupt))
    }
    func testAudioSilenceAndSustainedSoundDoNotInventThreeEvents() throws {
        let quiet=(0..<100).map{audio($0,target:false)}
        XCTAssertThrowsError(try AudioTrainer.analyze(background:quiet,positive:quiet))
        let sustained=(0..<100).map{audio($0,target:true)}
        XCTAssertThrowsError(try AudioTrainer.analyze(background:quiet,positive:sustained))
    }
    @MainActor func testDemoAcceptsAndPersistsAudioModel() throws {
        let background=(0..<100).map{audio($0,target:false)},positive=(0..<200).map{audio($0,target:$0%25==0)}
        let profile=try AudioTrainer.analyze(background:background,positive:positive).profile
        let d=DemoDevice();var status:TrainingStatus?
        d.onEvent={if case .trainingStatus(let p)=$0 {status=try? TrainingStatus(data:p)}}
        d.start();d.uploadProfile(profile.chunks(transferID:9));XCTAssertEqual(status?.modelID,profile.id)
        d.train(TrainingCommand(opcode:.enable,requestID:20,boot:d.snapshot.boot,modelID:profile.id).data)
        XCTAssertEqual(status?.mode,3)
    }
}

#if canImport(Accelerate)
extension VibrationTrainingTests {
    func testProductionFFTIdentifiesFrequencyAndRejectsDifferentTrackAtSameVolume() throws {
        let fft=try XCTUnwrap(RealtimeSpectrumAnalyzer(sampleRate:48000))
        func sine(_ hz:Double)->[Float] {(0..<fft.size).map{Float(0.1*sin(2*Double.pi*hz*Double($0)/48000))}}
        let target=try XCTUnwrap(fft.analyze(sine(1250),timestamp:1000))
        let other=try XCTUnwrap(fft.analyze(sine(5000),timestamp:2000))
        XCTAssertLessThan(abs(Int(target.dominantHz)-1250),50);XCTAssertLessThan(abs(Int(other.dominantHz)-5000),50)
        let sum=target.bands.reduce(0,+),template=target.bands.map{$0/sum}
        let profile=try AudioProfile(onset:0.002,rearm:0.001,template:template)
        XCTAssertTrue(profile.accepts(target));XCTAssertFalse(profile.accepts(other))
        XCTAssertNil(fft.analyze([Float](repeating:.nan,count:fft.size),timestamp:0))
    }
}
#endif

#if canImport(Accelerate)
extension VibrationTrainingTests {
    func refinedTone(_ hz:Double,_ amplitude:Double=0.04,_ timestamp:Int=0,_ phase:Double=0)->AudioSpectrum {
        let fft=RealtimeSpectrumAnalyzer(sampleRate:48000)!
        return fft.analyze((0..<fft.size).map{Float(amplitude*sin(2*Double.pi*hz*Double($0)/48000+phase))},timestamp:UInt16(timestamp))!
    }
    func refinedFixture(outlier:Bool=false) throws -> RefinedAcousticReport {
        let quiet=(0..<60).map{refinedTone(250,0.0004,$0*20)}
        var target=[AudioSpectrum]()
        for index in 0..<180 {
            let event=index%40<3 && index>=40
            target.append(refinedTone(event ? (outlier && index>=160 ? 4000:1250):250,event ? 0.04:0.0004,index*20))
        }
        return try RefinedAcousticTrainer.analyze(background:quiet,positive:target)
    }
    func testTrainingSelectsMechanicalPeaksInsteadOfLowFrequencyForegroundNoise() throws {
        let quiet=(0..<60).map{refinedTone(250,0.0004,$0*20)}
        let capture=(0..<300).map{index in
            let active=index>=40 && index%50<4
            return refinedTone(active ? 1250:250,active ? 0.06:0.006,index*20)
        }
        let report=try RefinedAcousticTrainer.analyze(background:quiet,positive:capture)
        XCTAssertEqual(report.events,5)
        XCTAssertGreaterThan(report.model.scores(refinedTone(1250)).target,0.98)
        XCTAssertLessThan(report.model.scores(refinedTone(250,0.006)).target,report.model.minimumScore)
        XCTAssertEqual(report.backgroundRMS,quiet[0].rms,accuracy:0.00001)
    }

    func testRefinedClassifierFindsDifferencesInsideSameOldFrequencyBand() throws {
        let result=try refinedFixture(),target=refinedTone(1250),nearby=refinedTone(1800)
        XCTAssertTrue(result.model.valid);XCTAssertEqual(result.events,4)
        XCTAssertGreaterThan(result.model.scores(target).target,0.98)
        XCTAssertLessThan(result.model.scores(nearby).target,result.model.minimumScore)
        XCTAssertTrue(result.model.base.accepts(nearby)) // Old 8-band matcher cannot separate this pair.
    }
    func testRefinedMatcherKeepsWeakPhaseShiftedTapsAndRearmsOverAmbientSound() throws {
        let model=try refinedFixture().model;var detector=RefinedEventDetector();var hits=0
        for event in 0..<3 {
            let start=Double(event)*0.3
            _ = detector.update(refinedTone(3000,0.06),time:start,model:model)
            _ = detector.update(refinedTone(3000,0.06),time:start+0.04,model:model)
            if detector.update(refinedTone(1250,0.006,0,0.7),time:start+0.08,model:model){hits+=1}
        }
        XCTAssertEqual(hits,3)
    }
    func testRefinedFusionAcceptsMotionArrivingAfterAudioOnlyOnce() throws {
        let model=try refinedFixture().model;var detector=RefinedEventDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        XCTAssertFalse(detector.update(refinedTone(1250),time:0.08,model:model,needsMotion:true,motionOK:false))
        XCTAssertTrue(detector.confirmMotion(time:0.12,refractory:0.1))
        XCTAssertFalse(detector.confirmMotion(time:0.13,refractory:0.1))
    }
    func testRefinedRingingCountsOneAndNextQuickTapIsNotLost() throws {
        let model=try refinedFixture().model;var detector=RefinedEventDetector();var hits=0
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.03,model:model)
        for time in [0.05,0.07,0.09] {if detector.update(refinedTone(1250),time:time,model:model){hits+=1}}
        _ = detector.update(refinedTone(250,0.0004),time:0.12,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.15,model:model)
        if detector.update(refinedTone(1250,0.008),time:0.18,model:model){hits+=1}
        XCTAssertEqual(hits,2)
    }
    func testRefinedTrainingExcludesAnUnrelatedOutlier() throws {
        let report=try refinedFixture(outlier:true)
        XCTAssertEqual(report.events,3);XCTAssertEqual(report.excludedEvents,1)
    }
    func testRefinedBackgroundFeedbackAndModelPersistence() throws {
        let model=try refinedFixture().model
        var distractor=refinedTone(1250)
        let d=distractor.dense!
        distractor.dense=DenseAudioDescriptor(spectrum:d.spectrum.map{$0*0.92+0.08/24},centroid:d.centroid,flatness:d.flatness,zeroCrossing:d.zeroCrossing,crest:d.crest)
        let updated=try model.addingBackground([distractor])
        XCTAssertEqual(updated.negatives.count,1)
        let scores=updated.scores(distractor);XCTAssertGreaterThan(scores.background,scores.target)
        let restored=try JSONDecoder().decode(RefinedAcousticModel.self,from:JSONEncoder().encode(updated))
        XCTAssertTrue(restored.valid);XCTAssertEqual(restored.negatives.count,1)
        var gate=RefinedEventDetector()
        _ = gate.update(refinedTone(250,0.0004),time:0,model:restored)
        _ = gate.update(refinedTone(250,0.0004),time:0.04,model:restored)
        XCTAssertFalse(gate.update(distractor,time:0.08,model:restored))
        XCTAssertEqual(gate.decision,.background)
    }

    func testSpectralAttackSurvivesSecondConfirmationFrameOverLouderAmbient() throws {
        let model=try refinedFixture().model
        var moderate=refinedTone(1250,0.006)
        let target=moderate.dense!,other=refinedTone(1800).dense!
        var found=false
        for step in 1..<100 {
            let mix=Double(step)/100
            moderate.dense=DenseAudioDescriptor(spectrum:zip(target.spectrum,other.spectrum).map{$0*(1-mix)+$1*mix},centroid:target.centroid,flatness:target.flatness,zeroCrossing:target.zeroCrossing,crest:target.crest)
            let score=model.scores(moderate).target
            if score>=model.minimumScore+0.016 && score<model.minimumScore+0.034 {found=true;break}
        }
        XCTAssertTrue(found,"Fixture must require two confirmation frames")
        var detector=RefinedEventDetector()
        _ = detector.update(refinedTone(3000,0.06),time:0,model:model)
        _ = detector.update(refinedTone(3000,0.06),time:0.04,model:model)
        XCTAssertFalse(detector.update(moderate,time:0.08,model:model))
        XCTAssertEqual(detector.decision,.confirming)
        XCTAssertTrue(detector.update(moderate,time:0.10,model:model))
        XCTAssertFalse(detector.update(moderate,time:0.12,model:model))
    }

    func testDistinctTapsCountBeforeTableResonanceReturnsToAbsoluteSilence() throws {
        let model=try refinedFixture().model;var detector=RefinedEventDetector();var hits=0
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        for (time,amplitude) in [(0.06,0.04),(0.12,0.009),(0.16,0.009),(0.20,0.009),(0.23,0.035),(0.29,0.007),(0.33,0.007),(0.37,0.007),(0.40,0.03)] {
            let frame=refinedTone(1250,amplitude)
            XCTAssertGreaterThan(frame.rms,model.base.onset)
            if detector.update(frame,time:time,model:model){hits+=1}
        }
        XCTAssertEqual(hits,3)
    }

    func testDecayingResonanceAndSustainedTargetToneRemainOneEvent() throws {
        let model=try refinedFixture().model;var detector=RefinedEventDetector();var hits=0
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        for index in 0..<80 {
            let amplitude=max(0.008,0.04*exp(-Double(index)*0.15))
            if detector.update(refinedTone(1250,amplitude),time:0.06+Double(index)*0.02,model:model){hits+=1}
        }
        XCTAssertEqual(hits,1)
    }

    func testAudioWindowsKeepSampleOrderAndSampleClockAcrossUnevenCallbacks() throws {
        let samples=(0..<96).map{Float($0)}
        var stream=try XCTUnwrap(AudioWindowStream(sampleRate:16000,size:32))
        var windows=[AudioAnalysisWindow](),cursor=0
        for length in [7,19,3,41,26] {
            let end=cursor+length
            windows+=stream.append(Array(samples[cursor..<end]),endingAt:1+Double(end)/16000)
            cursor=end
        }
        XCTAssertEqual(windows.count,5)
        for (index,window) in windows.enumerated() {
            XCTAssertEqual(window.samples,Array(samples[(index*16)..<(index*16+32)]))
            XCTAssertEqual(window.endingAt,1+Double(index*16+32)/16000,accuracy:0.0000001)
        }
        XCTAssertEqual(stream.discontinuities,0)
    }

    func testAudioGapAndInvalidSamplesNeverBlendOldAndNewAudio() throws {
        var stream=try XCTUnwrap(AudioWindowStream(sampleRate:16000,size:32))
        XCTAssertTrue(stream.append([Float](repeating:1,count:16),endingAt:1).isEmpty)
        let afterGap=stream.append([Float](repeating:2,count:32),endingAt:2)
        XCTAssertEqual(afterGap.count,1);XCTAssertTrue(afterGap[0].samples.allSatisfy{$0==2})
        XCTAssertEqual(stream.discontinuities,1)
        XCTAssertTrue(stream.append([.nan],endingAt:2.001).isEmpty)
        XCTAssertEqual(stream.discontinuities,2)
        let fresh=stream.append([Float](repeating:3,count:32),endingAt:3)
        XCTAssertEqual(fresh.count,1);XCTAssertTrue(fresh[0].samples.allSatisfy{$0==3})
    }

    func testOverlappingFFTRecoversShortAttackAcrossOriginalWindowBoundary() throws {
        let fft=try XCTUnwrap(RealtimeSpectrumAnalyzer(sampleRate:48000))
        func pulse(center:Int,count:Int)->[Float] {(0..<count).map{i in
            abs(i-center)<192 ? Float(0.05*sin(2*Double.pi*1250*Double(i-center)/48000)):0
        }}
        let reference=try XCTUnwrap(fft.analyze(pulse(center:512,count:1024),timestamp:0))
        let samples=pulse(center:1024,count:2048)
        var stream=try XCTUnwrap(AudioWindowStream(sampleRate:48000,size:fft.size))
        let windows=stream.append(samples,endingAt:1+Double(samples.count)/48000)
        let centered=try XCTUnwrap(windows.first{$0.samples==pulse(center:512,count:1024)})
        let recovered=try XCTUnwrap(fft.analyze(centered.samples,timestamp:0))
        XCTAssertEqual(recovered.dense,reference.dense)
        XCTAssertEqual(recovered.rms,reference.rms)
        XCTAssertEqual(windows.count,3)
        XCTAssertEqual(centered.endingAt,1+1536.0/48000,accuracy:0.0000001)
    }

    func testDigitalSilenceRearmsForFirstAndNextTap() throws {
        let fft=try XCTUnwrap(RealtimeSpectrumAnalyzer(sampleRate:48000))
        let silence=try XCTUnwrap(fft.analyze([Float](repeating:0,count:fft.size),timestamp:0))
        XCTAssertEqual(silence.rms,0);XCTAssertNil(silence.dense)
        let model=try refinedFixture().model;var detector=RefinedEventDetector()
        _ = detector.update(silence,time:0,model:model)
        _ = detector.update(silence,time:0.04,model:model)
        XCTAssertTrue(detector.update(refinedTone(1250),time:0.08,model:model))
        _ = detector.update(silence,time:0.12,model:model)
        _ = detector.update(silence,time:0.16,model:model)
        XCTAssertTrue(detector.update(refinedTone(1250),time:0.20,model:model))
    }

    func testSilentBackgroundIsValidNoiseCalibrationWithoutInventingEvents() throws {
        func silence(_ timestamp:Int) throws -> AudioSpectrum {
            try AudioSpectrum(data:AudioSpectrum.data(sequence:0,captureID:1,rms:0,bands:[Double](repeating:0,count:8),dominantHz:0,timestamp:UInt16(timestamp)))
        }
        let quiet=try (0..<60).map{try silence($0*20)}
        let target=try (0..<150).map{index in
            index>=40 && index%40<3 ? refinedTone(1250,0.04,index*20):try silence(index*20)
        }
        let report=try RefinedAcousticTrainer.analyze(background:quiet,positive:target)
        XCTAssertEqual(report.events,3);XCTAssertTrue(report.model.valid)
        XCTAssertTrue(report.model.noisePower.allSatisfy{$0==0})
    }

    func testSpeechLikeSustainedSyllablesCannotUseInstantSpectrumMatchToCount() throws {
        let model=try refinedFixture().model
        var instant=RefinedEventDetector(),verified=LocalAcousticDetector()
        var instantHits=0,verifiedHits=0
        for index in 0..<120 {
            let within=index%40
            // A voiced harmonic near a target resonance, held over a syllable.
            let active=(5...25).contains(within)
            let frame=refinedTone(active ? 1250:250,active ? 0.02:0.0004)
            let time=Double(index)*0.01
            if instant.update(frame,time:time,model:model){instantHits+=1}
            if verified.update(frame,time:time,model:model){verifiedHits+=1}
        }
        XCTAssertEqual(instantHits,3)
        XCTAssertEqual(verifiedHits,0)
    }

    func clippedTone(_ hz:Double=1250,_ amplitude:Double=0.4,flags:UInt8=2) throws -> AudioSpectrum {
        let frame=refinedTone(hz,amplitude)
        var clipped=try AudioSpectrum(data:AudioSpectrum.data(sequence:frame.sequence,captureID:frame.captureID,rms:frame.rms,bands:frame.bands,dominantHz:frame.dominantHz,timestamp:frame.timestamp,flags:flags))
        clipped.dense=frame.dense;return clipped
    }

    func testMatchedOnsetSurvivesBriefClippedPeakAndCountsOnceOnValidDecay() throws {
        let model=try refinedFixture().model;var detector=LocalAcousticDetector(),hits=0
        for index in 0..<5 {
            let start=Double(index)*0.8
            _ = detector.update(refinedTone(250,0.0004),time:start,model:model)
            _ = detector.update(refinedTone(250,0.0004),time:start+0.04,model:model)
            XCTAssertFalse(detector.update(refinedTone(1250,0.02),time:start+0.08,model:model))
            XCTAssertFalse(detector.update(try clippedTone(),time:start+0.10,model:model))
            XCTAssertFalse(detector.update(try clippedTone(),time:start+0.11,model:model))
            if detector.update(refinedTone(1250,0.08),time:start+0.13,model:model){hits+=1}
            XCTAssertFalse(detector.update(refinedTone(1250,0.04),time:start+0.15,model:model))
        }
        XCTAssertEqual(hits,5)
    }

    func testClippingCannotAuthorizeUnmatchedSoundOrExtendConfirmationDeadline() throws {
        let model=try refinedFixture().model
        for mode in 0..<4 {
            var detector=LocalAcousticDetector()
            _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
            _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
            if mode != 0 {XCTAssertFalse(detector.update(refinedTone(1250,0.02),time:0.08,model:model))}
            XCTAssertFalse(detector.update(try clippedTone(flags:mode==2 ? 6:2),time:0.10,model:model))
            if mode==3 {XCTAssertFalse(detector.update(try clippedTone(),time:0.20,model:model))}
            XCTAssertFalse(detector.update(refinedTone(250,0.0004),time:mode==1 ? 0.21:0.22,model:model))
        }
    }

    func testShortWeakTapsStillConfirmOnceAfterDecay() throws {
        let model=try refinedFixture().model;var detector=LocalAcousticDetector();var hits=0
        for index in 0..<3 {
            let start=Double(index)*0.4
            _ = detector.update(refinedTone(250,0.0004),time:start,model:model)
            _ = detector.update(refinedTone(250,0.0004),time:start+0.04,model:model)
            XCTAssertFalse(detector.update(refinedTone(1250,0.006),time:start+0.08,model:model))
            if detector.update(refinedTone(1250,0.002),time:start+0.10,model:model){hits+=1}
            XCTAssertFalse(detector.update(refinedTone(1250,0.001),time:start+0.12,model:model))
        }
        XCTAssertEqual(hits,3)
    }

    func testOneContaminatedTrainingEventCannotAuthorizeUnrelatedSound() throws {
        let base=try refinedFixture().model,voice=refinedTone(4000)
        let extra=try XCTUnwrap(base.cleaned(voice))
        let prototypes=base.prototypes+[extra,extra]
        let groups=prototypes.indices.map{$0/2}
        let model=RefinedAcousticModel(version:2,base:base.base,noisePower:base.noisePower,prototypes:prototypes,negatives:[],minimumScore:0.8,minimumRise:1.15,prototypeGroups:groups)
        XCTAssertTrue(model.valid)
        XCTAssertGreaterThan(model.scores(voice).target,0.99)
        XCTAssertFalse(model.supportsAcrossEvents(voice))
        var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        XCTAssertFalse(detector.update(voice,time:0.08,model:model))
        XCTAssertFalse(detector.update(refinedTone(4000,0.004),time:0.10,model:model))
    }

    func testGroupedModelsRoundTripAndExistingModelsWithoutGroupsStillWork() throws {
        let model=try refinedFixture().model
        let data=try JSONEncoder().encode(model)
        let restored=try JSONDecoder().decode(RefinedAcousticModel.self,from:data)
        XCTAssertTrue(restored.valid);XCTAssertEqual(restored.prototypeGroups,model.prototypeGroups)
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        old.removeValue(forKey:"prototypeGroups")
        let legacy=try JSONDecoder().decode(RefinedAcousticModel.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertNil(legacy.prototypeGroups);XCTAssertTrue(legacy.valid)
        XCTAssertTrue(legacy.supportsAcrossEvents(refinedTone(1250)))
        let malformed=RefinedAcousticModel(version:2,base:model.base,noisePower:model.noisePower,prototypes:model.prototypes,negatives:[],minimumScore:model.minimumScore,minimumRise:model.minimumRise,prototypeGroups:[0])
        XCTAssertFalse(malformed.valid);XCTAssertFalse(malformed.supportsAcrossEvents(refinedTone(1250)))
    }

    func testBackgroundVetoAppliesBeforeShortSoundCanBeCommitted() throws {
        let base=try refinedFixture().model;var sound=refinedTone(1250)
        let d=try XCTUnwrap(sound.dense)
        sound.dense=DenseAudioDescriptor(spectrum:d.spectrum.map{$0*0.92+0.08/24},centroid:d.centroid,flatness:d.flatness,zeroCrossing:d.zeroCrossing,crest:d.crest)
        let model=try base.addingBackground([sound]);var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        XCTAssertFalse(detector.update(sound,time:0.08,model:model))
        XCTAssertFalse(detector.update(refinedTone(250,0.0004),time:0.10,model:model))
    }

    func testInterruptedCandidateCannotBecomeAnEventAfterLongAudioGap() throws {
        let model=try refinedFixture().model;var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model)
        XCTAssertFalse(detector.update(refinedTone(1250),time:0.08,model:model))
        XCTAssertFalse(detector.update(refinedTone(250,0.0004),time:0.4,model:model))
        XCTAssertEqual(detector.decision,.sustained)
    }

    func testMotionConfirmedPathStillCountsOneWhenAudioCallbackComesFirst() throws {
        let model=try refinedFixture().model;var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:model,needsMotion:true,motionOK:false)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:model,needsMotion:true,motionOK:false)
        XCTAssertFalse(detector.update(refinedTone(1250),time:0.08,model:model,needsMotion:true,motionOK:false))
        XCTAssertTrue(detector.confirmMotion(time:0.12,refractory:0.1))
        XCTAssertFalse(detector.confirmMotion(time:0.13,refractory:0.1))
    }

    func testPrimaryFeatureRestoreDropsAutomaticVetoAndKeepsRecordedModel() throws {
        let original=try refinedFixture()
        var model=original.model
        model.negatives=[try XCTUnwrap(model.cleaned(refinedTone(3000)))]
        let target=refinedTone(1250)
        model.adaptiveNegatives=[try XCTUnwrap(model.cleaned(target))]
        let saved=RefinedAcousticReport(model:model,events:original.events,excludedEvents:2,crossEventSimilarity:original.crossEventSimilarity,backgroundRMS:original.backgroundRMS)
        let restored=saved.withoutAutomaticBackground()
        XCTAssertGreaterThan(saved.model.scores(target).background,0.99)
        XCTAssertLessThan(restored.model.scores(target).background,model.minimumScore)
        XCTAssertEqual(restored.model.scores(target).target,saved.model.scores(target).target)
        XCTAssertEqual(restored.model.prototypes,model.prototypes)
        XCTAssertEqual(restored.model.prototypeGroups,model.prototypeGroups)
        XCTAssertEqual(restored.model.negatives,model.negatives)
        XCTAssertEqual(restored.model.base,model.base)
        XCTAssertEqual(restored.model.noisePower,model.noisePower)
        XCTAssertEqual(restored.model.minimumScore,model.minimumScore)
        XCTAssertEqual(restored.model.minimumRise,model.minimumRise)
        XCTAssertEqual(restored.events,saved.events);XCTAssertEqual(restored.excludedEvents,2)
        XCTAssertEqual(restored.crossEventSimilarity,saved.crossEventSimilarity)
        XCTAssertEqual(restored.backgroundRMS,saved.backgroundRMS)
        XCTAssertTrue(restored.model.valid)
        var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:restored.model)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:restored.model)
        XCTAssertFalse(detector.update(refinedTone(1250,0.006),time:0.08,model:restored.model))
        XCTAssertTrue(detector.update(refinedTone(1250,0.002),time:0.10,model:restored.model))
    }

    func testPrimaryFeatureRestoreIsIdempotentForLegacyAndBackupModels() throws {
        let original=try refinedFixture()
        var model=original.model
        model.adaptiveNegatives=[try XCTUnwrap(model.cleaned(refinedTone(5000)))]
        for candidate in [original,RefinedAcousticReport(model:model,events:original.events,excludedEvents:0,crossEventSimilarity:original.crossEventSimilarity,backgroundRMS:original.backgroundRMS)] {
            let decoded=try JSONDecoder().decode(RefinedAcousticReport.self,from:JSONEncoder().encode(candidate))
            let restored=decoded.withoutAutomaticBackground()
            let reloaded=try JSONDecoder().decode(RefinedAcousticReport.self,from:JSONEncoder().encode(restored)).withoutAutomaticBackground()
            XCTAssertTrue(reloaded.model.valid);XCTAssertEqual(reloaded.model.adaptiveNegatives,[])
            XCTAssertEqual(reloaded.model.prototypes,original.model.prototypes)
            XCTAssertEqual(reloaded.legacyReport.profile,original.legacyReport.profile)
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            XCTAssertEqual(try encoder.encode(restored),try encoder.encode(reloaded))
        }
    }

    func testAdaptiveLearnerRequiresSustainedUnrelatedAudioAndPreservesAnchors() throws {
        let model=try refinedFixture().model,background=refinedTone(5000,0.02)
        var learner=AdaptiveBackgroundLearner(),learned:RefinedAcousticModel?
        for index in 0..<80 {
            let next=learner.observe(background,time:Double(index)*0.01,decision:.quiet,model:learned ?? model)
            if index<50 {XCTAssertNil(next)}
            if let next {learned=next}
        }
        let updated=try XCTUnwrap(learned)
        XCTAssertEqual(updated.adaptiveNegatives?.count,1)
        XCTAssertEqual(updated.prototypes,model.prototypes);XCTAssertEqual(updated.prototypeGroups,model.prototypeGroups)
        XCTAssertEqual(updated.base,model.base);XCTAssertEqual(updated.noisePower,model.noisePower)
        XCTAssertEqual(updated.minimumScore,model.minimumScore);XCTAssertEqual(updated.minimumRise,model.minimumRise)
        XCTAssertEqual(updated.negatives,model.negatives)
    }

    func testAdaptiveLearnerNeverLabelsTargetOrNearbyEventAsBackground() throws {
        let model=try refinedFixture().model,target=refinedTone(1250),background=refinedTone(5000)
        var learner=AdaptiveBackgroundLearner()
        for index in 0..<100 {XCTAssertNil(learner.observe(target,time:Double(index)*0.01,decision:.quiet,model:model))}
        for index in 100..<200 {XCTAssertNil(learner.observe(background,time:Double(index)*0.01,decision:.quiet,model:model))}
        XCTAssertNil(model.addingAdaptiveBackground(try XCTUnwrap(model.cleaned(target))))
    }

    func testAdaptiveLearningPausesAroundAcceptedEventsAndAudioGaps() throws {
        let model=try refinedFixture().model,background=refinedTone(5000)
        var learner=AdaptiveBackgroundLearner()
        for index in 0..<40 {XCTAssertNil(learner.observe(background,time:Double(index)*0.01,decision:.quiet,model:model))}
        XCTAssertNil(learner.observe(background,time:0.4,decision:.accepted,model:model))
        for index in 41..<140 {XCTAssertNil(learner.observe(background,time:Double(index)*0.01,decision:.quiet,model:model))}
        XCTAssertNil(learner.observe(background,time:3,decision:.quiet,model:model))
        for index in 301..<450 {XCTAssertNil(learner.observe(background,time:Double(index)*0.01,decision:.quiet,model:model))}
    }

    func testAdaptiveBankIsBoundedKeepsManualNegativesAndCanBeRemoved() throws {
        var model=try refinedFixture().model
        var manual=refinedTone(1250);let d=try XCTUnwrap(manual.dense)
        manual.dense=DenseAudioDescriptor(spectrum:d.spectrum.map{$0*0.92+0.08/24},centroid:d.centroid,flatness:d.flatness,zeroCrossing:d.zeroCrossing,crest:d.crest)
        model=try model.addingBackground([manual]);let anchored=model
        var accepted=0
        for index in 0..<24 {
            var spectrum=[Double](repeating:0,count:24);spectrum[index]=1
            let descriptor=DenseAudioDescriptor(spectrum:spectrum,centroid:DenseAudioDescriptor.edges[index+1],flatness:0.03,zeroCrossing:0.05,crest:2)
            if let next=model.addingAdaptiveBackground(descriptor){model=next;accepted+=1}
        }
        XCTAssertGreaterThan(accepted,8);XCTAssertEqual(model.adaptiveNegatives?.count,8)
        XCTAssertEqual(model.negatives,anchored.negatives)
        let restored=model.removingAdaptiveBackground()
        XCTAssertTrue(restored.valid);XCTAssertTrue(restored.adaptiveNegatives?.isEmpty==true)
        XCTAssertEqual(restored.prototypes,anchored.prototypes);XCTAssertEqual(restored.negatives,anchored.negatives)
    }

    func testAdaptiveModelsPersistAndOldJSONWithoutAdaptiveBankStillLoads() throws {
        let model=try refinedFixture().model
        let updated=try XCTUnwrap(model.addingAdaptiveBackground(try XCTUnwrap(model.cleaned(refinedTone(5000)))))
        let restored=try JSONDecoder().decode(RefinedAcousticModel.self,from:JSONEncoder().encode(updated))
        XCTAssertTrue(restored.valid);XCTAssertEqual(restored.adaptiveNegatives,updated.adaptiveNegatives)
        var old=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(model)) as? [String:Any])
        old.removeValue(forKey:"adaptiveNegatives")
        let legacy=try JSONDecoder().decode(RefinedAcousticModel.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertTrue(legacy.valid);XCTAssertNil(legacy.adaptiveNegatives)
        var detector=LocalAcousticDetector()
        _ = detector.update(refinedTone(250,0.0004),time:0,model:restored)
        _ = detector.update(refinedTone(250,0.0004),time:0.04,model:restored)
        XCTAssertFalse(detector.update(refinedTone(1250,0.006),time:0.08,model:restored))
        XCTAssertTrue(detector.update(refinedTone(1250,0.002),time:0.10,model:restored))
    }

    func testAdaptiveLearningRateLimitAndCorruptDataDoNotPromoteSamples() throws {
        var model=try refinedFixture().model;var learner=AdaptiveBackgroundLearner()
        let first=refinedTone(5000),second=refinedTone(3000)
        var additions=0
        for index in 0..<1500 {
            let frame=index<100 ? first:second
            if let next=learner.observe(frame,time:Double(index)*0.01,decision:.quiet,model:model){model=next;additions+=1}
        }
        XCTAssertEqual(additions,1)
        XCTAssertNil(learner.observe(second,time:.nan,decision:.quiet,model:model))
        var invalid=model;invalid.adaptiveNegatives=Array(repeating:try XCTUnwrap(first.dense),count:9)
        XCTAssertFalse(invalid.valid)
        XCTAssertNil(learner.observe(second,time:16,decision:.quiet,model:invalid))
    }
}
#endif
