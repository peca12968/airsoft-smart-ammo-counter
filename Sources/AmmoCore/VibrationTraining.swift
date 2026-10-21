import Foundation

public enum CaptureLabel: UInt8, Codable, CaseIterable { case background = 0, positive = 1 }
public enum TrainingOpcode: UInt8 { case background = 1, positive = 2, stop = 3, enable = 4, disable = 5, preview = 6, stopPreview = 7 }
public struct TrainingCommand {
    public let opcode: TrainingOpcode
    public let value: UInt16
    public let requestID: UInt32
    public let boot: UInt32
    public let modelID: UInt32
    public init(opcode: TrainingOpcode, value: UInt16 = 0, requestID: UInt32, boot: UInt32, modelID: UInt32 = 0) {
        self.opcode = opcode; self.value = value; self.requestID = requestID; self.boot = boot; self.modelID = modelID
    }
    public var data: Data {
        var d = Data([1, opcode.rawValue]); d.put(value); d.put(requestID); d.put(boot); d.put(modelID); return d
    }
}
public struct VibrationFeature: Codable, Equatable {
    public let flags: UInt8
    public let captureID: UInt16
    public let sequence: UInt16
    public let samples: UInt8
    public let label: CaptureLabel
    public let timestamp: UInt32
    public let peakG: Double
    public let rmsG: Double
    public let gyroDps: Double
    public let clipped: UInt8
    public var isCandidate: Bool { flags & 1 != 0 }
    public var usable: Bool { flags & 14 == 0 && samples == 16 && clipped == 0 }
    public var values: [Double] { [peakG, rmsG, gyroDps] }
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count == 20, data[0] == 1, data[1] & 0xf0 == 0, data[6] == 16,
              let label = CaptureLabel(rawValue: data[7]), data[18] <= 16, data[19] == 0 else { throw AmmoError.malformedPacket }
        flags = data[1]; captureID = data.integer(UInt16.self, at: 2); sequence = data.integer(UInt16.self, at: 4)
        samples = data[6]; self.label = label; timestamp = data.integer(UInt32.self, at: 8)
        peakG = Double(data.integer(UInt16.self, at: 12))/1000
        rmsG = Double(data.integer(UInt16.self, at: 14))/1000
        gyroDps = Double(data.integer(UInt16.self, at: 16))/10; clipped = data[18]
        guard captureID != 0, sequence != 0, peakG <= 32, rmsG <= peakG + 0.002, gyroDps <= 3600,
              clipped == 0 || flags & 2 != 0 else { throw AmmoError.invalidValue }
    }
    public init(captureID: UInt16, sequence: UInt16, label: CaptureLabel, timestamp: UInt32, peakG: Double, rmsG: Double, gyroDps: Double, candidate: Bool = true) {
        flags = candidate ? 1:0; self.captureID = captureID; self.sequence = sequence; self.label = label
        self.timestamp = timestamp; self.peakG = peakG; self.rmsG = rmsG; self.gyroDps = gyroDps; samples = 16; clipped = 0
    }
    public var data: Data {
        var d = Data([1,flags]); d.put(captureID); d.put(sequence); d.append(samples); d.append(label.rawValue); d.put(timestamp)
        d.put(UInt16(clamping: Int((peakG*1000).rounded()))); d.put(UInt16(clamping: Int((rmsG*1000).rounded())))
        d.put(UInt16(clamping: Int((gyroDps*10).rounded()))); d.append(clipped); d.append(0); return d
    }
}
public struct TrainingStatus {
    public let mode: UInt8
    public let result: UInt8
    public let flags: UInt8
    public let requestID: UInt32
    public let modelID: UInt32
    public let sent: UInt16
    public let dropped: UInt16
    public let boot: UInt32
    public var hasModel: Bool { flags & 1 != 0 }
    public var isTestModel: Bool { flags & 2 != 0 }
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count == 20, data[0] == 1, data[1] <= 3, data[2] <= 4, data[3] & 0xf8 == 0 else { throw AmmoError.malformedPacket }
        mode = data[1]; result = data[2]; flags = data[3]; requestID = data.integer(UInt32.self, at: 4)
        modelID = data.integer(UInt32.self, at: 8); sent = data.integer(UInt16.self, at: 12)
        dropped = data.integer(UInt16.self, at: 14); boot = data.integer(UInt32.self, at: 16)
        guard boot != 0, !hasModel || modelID != 0 else { throw AmmoError.invalidValue }
    }
    public static func data(mode: UInt8, result: UInt8 = 0, modelID: UInt32 = 0, test: Bool = true, requestID: UInt32, sent: UInt16 = 0, dropped: UInt16 = 0, boot: UInt32) -> Data {
        let flags: UInt8 = 4 | (modelID != 0 ? 1:0) | (modelID != 0 && test ? 2:0)
        var d = Data([1,mode,result,flags])
        d.put(requestID); d.put(modelID); d.put(sent); d.put(dropped); d.put(boot); return d
    }
}
public enum VibrationCRC {
    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = .max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1 != 0) ? 0xedb88320:0) } }
        return ~crc
    }
}
public enum DetectionMode: UInt8, Codable {case matched=0, sensitive=1}
public struct DetectorProfile: Codable, Equatable {
    public let id: UInt32
    public let isTest: Bool
    public let detectionMode: DetectionMode
    public let refractoryMs: UInt16
    public let onsetG: Double
    public let means: [Double]
    public let scales: [Double]
    public let maximumDistance: Double
    public let minimumPeakG: Double
    public let rearmG: Double
    public let createdAt: UInt32
    public init(id: UInt32, isTest: Bool, refractoryMs: UInt16 = 200, detectionMode: DetectionMode = .matched, onsetG: Double = 0.03, means: [Double], scales: [Double], maximumDistance: Double = 9, minimumPeakG: Double, rearmG: Double = 0.015, createdAt: UInt32 = UInt32(Date().timeIntervalSince1970)) throws {
        guard id != 0, (50...2000).contains(refractoryMs), means.count == 3, scales.count == 3,
              means.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 3600 }), scales.allSatisfy({ $0.isFinite && $0 >= 0.0009999 && $0 <= 3600 }),
              means[0] <= 32, means[1] <= 32, onsetG.isFinite, (0.0019999...1).contains(onsetG),
              maximumDistance.isFinite, (0.5...100).contains(maximumDistance),
              minimumPeakG.isFinite, minimumPeakG >= onsetG && minimumPeakG <= 32, rearmG.isFinite, rearmG > 0, rearmG < onsetG else { throw AmmoError.invalidValue }
        self.id = id; self.isTest = isTest; self.detectionMode=detectionMode; self.refractoryMs = refractoryMs; self.onsetG = onsetG; self.means = means; self.scales = scales
        self.maximumDistance = maximumDistance; self.minimumPeakG = minimumPeakG; self.rearmG = rearmG; self.createdAt = createdAt
    }
    public init(data: Data) throws {
        let data = Data(data)
        guard data.count == 64, data.integer(UInt32.self, at: 0) == 0x31444d41,
              Array(data[4...7]) == [1,3,16,1], data[12] <= 1, data[13] <= 1,
              VibrationCRC.checksum(data.prefix(60)) == data.integer(UInt32.self, at: 60) else { throw AmmoError.malformedPacket }
        func f(_ at: Int) -> Double { Double(Float(bitPattern: data.integer(UInt32.self, at: at))) }
        try self.init(id: data.integer(UInt32.self, at: 8), isTest: data[12] == 1, refractoryMs: data.integer(UInt16.self, at: 14), detectionMode:DetectionMode(rawValue:data[13])!, onsetG: f(16), means: [f(20),f(24),f(28)], scales: [f(32),f(36),f(40)], maximumDistance: f(44), minimumPeakG: f(48), rearmG: f(52), createdAt: data.integer(UInt32.self, at: 56))
    }
    public var data: Data {
        var d = Data(); d.put(UInt32(0x31444d41)); d.append(contentsOf: [1,3,16,1]); d.put(id); d.append(isTest ? 1:0); d.append(detectionMode.rawValue); d.put(refractoryMs)
        for f in [onsetG] + means + scales + [maximumDistance,minimumPeakG,rearmG] { d.put(Float(f).bitPattern) }
        d.put(createdAt); d.put(VibrationCRC.checksum(d)); return d
    }
    public func accepts(_ feature: VibrationFeature) -> Bool {
        guard feature.usable, feature.isCandidate, feature.peakG >= minimumPeakG else { return false }
        if detectionMode == .sensitive { return true }
        let distance = zip(zip(feature.values,means),scales).reduce(0.0) { total, pair in
            let z = (pair.0.0-pair.0.1)/pair.1; return total + z*z
        }
        return distance <= maximumDistance
    }
    public func chunks(transferID: UInt16) -> [Data] {
        let bytes = data
        return (0..<4).map { index in var d = Data([1,UInt8(index)]); d.put(transferID); d.append(bytes[(index*16)..<(index*16+16)]); return d }
    }
}
public struct VibrationDataset: Codable {
    public let id: UUID
    public let deviceID: UInt64
    public let boot: UInt32
    public let captureID: UInt16
    public let label: CaptureLabel
    public let startedAt: Date
    public var duration: Double
    public var completed: Bool
    public var dropped: Int
    public var audioFeatures: [AudioSpectrum]?
    public var audioDropped: Int?
    public var features: [VibrationFeature]
    public init(deviceID: UInt64, boot: UInt32, captureID: UInt16, label: CaptureLabel) {
        id = UUID(); self.deviceID = deviceID; self.boot = boot; self.captureID = captureID; self.label = label
        startedAt = Date(); duration = 0; completed = false; dropped = 0; features = []
    }
    public var csv: String {
        "capture,sequence,timestamp_ms,label,flags,peak_g,rms_g,gyro_dps,clipped\n" + features.map {
            "\($0.captureID),\($0.sequence),\($0.timestamp),\($0.label.rawValue),\($0.flags),\($0.peakG),\($0.rmsG),\($0.gyroDps),\($0.clipped)"
        }.joined(separator: "\n") + "\n"
    }
}
public struct TrainingReport: Codable {
    public let profile: DetectorProfile
    public let sensitivity: Double
    public let specificity: Double
    public let positiveExamples: Int
    public let activeNegativeExamples: Int
    public let warnings: [String]
}
public enum TrainingFailure: String, Error { case incomplete, mixedDevices, insufficientSamples, poorQuality, notSeparable, noSignal }
public enum VibrationTrainer {
    public static func analyze(background: VibrationDataset, positive: VibrationDataset, isTest: Bool, relaxed: Bool = false, refractoryMs: UInt16 = 200, modelID: UInt32 = UInt32.random(in: 1...UInt32.max)) throws -> TrainingReport {
        guard background.completed, positive.completed, background.duration >= 4, positive.duration >= 4 else { throw TrainingFailure.incomplete }
        guard background.deviceID == positive.deviceID, background.boot == positive.boot, background.label == .background, positive.label == .positive else { throw TrainingFailure.mixedDevices }
        for dataset in [background,positive] {
            guard dataset.features.allSatisfy({ f in f.values.allSatisfy { $0.isFinite && $0 >= 0 } && f.peakG <= 32 && f.rmsG <= f.peakG + 0.002 && f.gyroDps <= 3600 && f.captureID == dataset.captureID && f.label == dataset.label }) else { throw TrainingFailure.poorQuality }
            let total = dataset.features.count + dataset.dropped
            guard total > 0, Double(dataset.dropped)/Double(total) <= 0.05,
                  Double(dataset.features.filter { $0.flags & 8 == 0 && !$0.usable }.count)/Double(max(1,dataset.features.filter { $0.flags & 8 == 0 }.count)) <= 0.1 else { throw TrainingFailure.poorQuality }
        }
        let baseline = try calibrate(background: background.features)
        let pos = events(positive.features, threshold: baseline.onsetG)
        let neg = background.features.filter(\.usable)
        let activeNeg = events(neg, threshold: baseline.onsetG)
        if pos.isEmpty { throw TrainingFailure.noSignal }
        guard pos.count >= (relaxed ? 3:(isTest ? 6:10)), neg.count >= 30, relaxed || isTest || activeNeg.count >= 6 else { throw TrainingFailure.insufficientSamples }
        let train = pos.enumerated().filter { $0.offset % 3 != 0 }.map(\.element)
        let validation = pos.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let means = (0..<3).map { axis in train.map { $0.values[axis] }.reduce(0,+)/Double(train.count) }
        let floors = [0.002,0.001,2.0]
        let scales = (0..<3).map { axis in
            max(floors[axis], sqrt(train.map { pow($0.values[axis]-means[axis],2) }.reduce(0,+)/Double(max(1,train.count-1))))
        }
        let minPeak = relaxed ? baseline.onsetG : max(baseline.onsetG, train.map(\.peakG).min()! * 0.4)
        let unrounded = try DetectorProfile(id: modelID, isTest: isTest, refractoryMs: refractoryMs, detectionMode:relaxed ? .sensitive:.matched, onsetG: baseline.onsetG, means: means, scales: scales, minimumPeakG: minPeak, rearmG: baseline.rearmG)
        let profile = try DetectorProfile(data: unrounded.data) // Match the exact Float32 wire model.
        let sensitivity = Double(validation.filter { profile.accepts($0) }.count)/Double(validation.count)
        let hardValidation = activeNeg.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)
        let negativeValidation = hardValidation.isEmpty ? Array(neg.enumerated().filter { $0.offset % 3 == 0 }.map(\.element)) : hardValidation
        let specificity = Double(negativeValidation.filter { !profile.accepts($0) }.count)/Double(max(1,negativeValidation.count))
        guard sensitivity >= 0.8, relaxed || specificity >= 0.9 else { throw TrainingFailure.notSeparable }
        var warnings = ["資料內的辨識結果不代表實際擊發準確率；仍需手動校正。"]
        if relaxed { warnings.append("快速收集模型，樣本較少，請以實際敲擊核對。") }
        if relaxed && specificity < 0.9 { warnings.append("容易誤計數：背景與目標特徵很像，仍依快速模式完成。") }
        if isTest { warnings.append("桌面敲擊測試模型，未驗證真實設備震動。") }
        if activeNeg.count < 6 { warnings.append("尚缺足夠移動／碰撞樣本，目前只驗證安靜與敲擊。") }
        return TrainingReport(profile: profile, sensitivity: sensitivity, specificity: specificity, positiveExamples: pos.count, activeNegativeExamples: activeNeg.count, warnings: warnings)
    }
}

public extension VibrationTrainer {
    /// Original captures remain archived; normalized IDs exist only in the analysis corpus.
    static func analyzeSeries(background: [VibrationDataset], positive: [VibrationDataset], isTest: Bool, relaxed: Bool = false) throws -> TrainingReport {
        guard !background.isEmpty, !positive.isEmpty, background.count <= 6, positive.count <= 6 else { throw TrainingFailure.insufficientSamples }
        let all = background + positive
        guard all.allSatisfy({ $0.deviceID == all[0].deviceID && $0.boot == all[0].boot }) else { throw TrainingFailure.mixedDevices }
        func combine(_ captures: [VibrationDataset], label: CaptureLabel) throws -> VibrationDataset {
            var merged = captures[0]; merged.duration = 0; merged.features = []; merged.dropped = 0
            for capture in captures {
                guard capture.completed, capture.label == label else { throw TrainingFailure.incomplete }
                merged.duration += capture.duration; merged.dropped += capture.dropped
                for feature in capture.features {
                    guard feature.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 3600 }), feature.peakG <= 32, feature.rmsG <= feature.peakG + 0.002, feature.captureID == capture.captureID, feature.label == label, merged.features.count < 3600 else { throw TrainingFailure.poorQuality }
                    var bytes = feature.data
                    bytes[2] = UInt8(truncatingIfNeeded:merged.captureID); bytes[3] = UInt8(truncatingIfNeeded:merged.captureID >> 8)
                    let sequence = UInt16(merged.features.count + 1); bytes[4] = UInt8(truncatingIfNeeded:sequence); bytes[5] = UInt8(truncatingIfNeeded:sequence >> 8)
                    merged.features.append(try VibrationFeature(data:bytes))
                }
            }
            return merged
        }
        return try analyze(background:combine(background,label:.background),positive:combine(positive,label:.positive),isTest:isTest,relaxed:relaxed)
    }
}

public struct VibrationBaseline {
    public let medianG: Double
    public let onsetG: Double
    public let rearmG: Double
}
public extension VibrationTrainer {
    static func calibrate(background: [VibrationFeature]) throws -> VibrationBaseline {
        let peaks = background.filter { $0.usable && $0.peakG.isFinite }.map(\.peakG).sorted()
        guard peaks.count >= 30 else { throw TrainingFailure.insufficientSamples }
        let median = peaks[peaks.count/2]
        let deviations = peaks.map { abs($0-median) }.sorted()
        let mad = deviations[deviations.count/2]*1.4826
        // Feature transport is quantized to 1mg. Retain a measurable margin over noise.
        let onset = max(0.003, median + max(0.002,4*mad))
        guard onset <= 1 else { throw TrainingFailure.poorQuality }
        let quiet = peaks[Int(Double(peaks.count-1)*0.9)]
        return VibrationBaseline(medianG:median,onsetG:onset,rearmG:min(onset*0.85,max(0.001,quiet*0.8)))
    }
    /// Segment full captured windows AFTER measuring noise. Firmware candidate flags
    /// are diagnostic only during collection; they cannot censor training examples.
    static func events(_ features: [VibrationFeature], threshold: Double) -> [VibrationFeature] {
        guard threshold.isFinite, threshold >= 0.002 else { return [] }
        var result = [VibrationFeature](), best: VibrationFeature?, lastAbove: UInt32 = 0
        func appendBest() {
            if let best { var d = best.data; d[1] |= 1; if let marked = try? VibrationFeature(data:d) { result.append(marked) } }
        }
        for f in features where f.usable && f.peakG >= threshold && f.peakG.isFinite {
            if best != nil && f.timestamp &- lastAbove > 200 { appendBest(); best = nil }
            if best == nil || f.peakG > best!.peakG { best = f }
            lastAbove = f.timestamp
        }
        appendBest(); return result
    }
}

public extension TrainingReport {
    func withSensitiveTrigger(onsetG requested: Double = 0.006) throws -> TrainingReport {
        let p=try DetectorProfile(id:UInt32.random(in:1...UInt32.max),isTest:profile.isTest,refractoryMs:profile.refractoryMs,detectionMode:.sensitive,onsetG:requested,means:profile.means,scales:profile.scales,maximumDistance:profile.maximumDistance,minimumPeakG:requested,rearmG:min(profile.rearmG,requested*0.6))
        return TrainingReport(profile:try DetectorProfile(data:p.data),sensitivity:sensitivity,specificity:specificity,positiveExamples:positiveExamples,activeNegativeExamples:activeNegativeExamples,warnings:["高靈敏：高於底噪門檻的震動即可計數；碰撞也可能觸發，請實測核對。"])
    }
}

// XIAO PDM spectrum, 16 kHz / 128-point FFT. Only band energies leave the sensor.
public struct AudioSpectrum: Codable, Equatable, Sendable {
    public static let bandLabels=["125–250","250–500","500–1k","1–2k","2–3k","3–4k","4–6k","6–8k"]
    public var dense:DenseAudioDescriptor? = nil
    public let flags: UInt8
    public let sequence: UInt16
    public let captureID: UInt16
    public let rms: Double
    public let bands: [Double]
    public let dominantHz: UInt16
    public let timestamp: UInt16
    public var usable: Bool { flags & 14 == 0 && bands.reduce(0,+)>0 && rms>0 }
    public init(data: Data) throws {
        let d=Data(data)
        guard d.count==20,d[0]==1,d[1]&0xF1==0 else {throw AmmoError.malformedPacket}
        flags=d[1];sequence=d.integer(UInt16.self,at:2);captureID=d.integer(UInt16.self,at:4)
        let raw=d.integer(UInt16.self,at:6);guard raw<=32768 else {throw AmmoError.invalidValue};rms=Double(raw)/32768
        bands=Array(d[8..<16]).map{Double($0)/255};dominantHz=d.integer(UInt16.self,at:16);timestamp=d.integer(UInt16.self,at:18)
        guard dominantHz<=8000,bands.reduce(0,+)<=1.01 else {throw AmmoError.invalidValue}
    }
    public static func data(sequence:UInt16,captureID:UInt16,rms:Double,bands:[Double],dominantHz:UInt16,timestamp:UInt16,flags:UInt8=0) -> Data {
        var d=Data([1,flags]);d.put(sequence);d.put(captureID);d.put(UInt16(min(32768,max(0,(rms*32768).rounded()))))
        d.append(contentsOf:bands.map{UInt8(min(255,max(0,floor($0*255))))});d.put(dominantHz);d.put(timestamp);return d
    }
}
public struct AudioProfile: Codable, Equatable, Sendable {
    public let id: UInt32
    public let isTest: Bool
    public let onset: Double
    public let rearm: Double
    public let template: [Double]
    public let minimumSimilarity: Double
    public let refractoryMs: UInt16
    public init(id:UInt32=UInt32.random(in:1...UInt32.max),isTest:Bool=true,onset:Double,rearm:Double,template:[Double],minimumSimilarity:Double=0.85,refractoryMs:UInt16=140) throws {
        guard id>0,onset.isFinite,(0.0001...0.9).contains(onset),rearm.isFinite,rearm>0,rearm<onset,template.count==8,template.allSatisfy({$0.isFinite && (0...1).contains($0)}),template.reduce(0,+)>0.9,template.reduce(0,+)<1.1,minimumSimilarity.isFinite,(0.5...0.99).contains(minimumSimilarity),(80...2000).contains(refractoryMs) else {throw AmmoError.invalidValue}
        self.id=id;self.isTest=isTest;self.onset=onset;self.rearm=rearm;self.template=template;self.minimumSimilarity=minimumSimilarity;self.refractoryMs=refractoryMs
    }
    public init(data:Data) throws {
        let d=Data(data);guard d.count==64,d.integer(UInt32.self,at:0)==0x32444D41,Array(d[4..<8])==[1,8,7,16],d[12]<=1,d[13]==0,VibrationCRC.checksum(d.prefix(60))==d.integer(UInt32.self,at:60) else {throw AmmoError.malformedPacket}
        func f(_ at:Int)->Double {Double(Float(bitPattern:d.integer(UInt32.self,at:at)))}
        try self.init(id:d.integer(UInt32.self,at:8),isTest:d[12]==1,onset:f(16),rearm:f(56),template:(0..<8).map{f(20+4*$0)},minimumSimilarity:f(52),refractoryMs:d.integer(UInt16.self,at:14))
    }
    public var data:Data {
        var d=Data();d.put(UInt32(0x32444D41));d.append(contentsOf:[1,8,7,16]);d.put(id);d.append(contentsOf:[isTest ? 1:0,0]);d.put(refractoryMs)
        for f in [onset]+template+[minimumSimilarity,rearm] {d.put(Float(f).bitPattern)}
        d.put(VibrationCRC.checksum(d));return d
    }
    public func similarity(_ frame:AudioSpectrum)->Double {
        let dot=zip(template,frame.bands).map(*).reduce(0,+)
        let norm=sqrt(template.map{$0*$0}.reduce(0,+)*frame.bands.map{$0*$0}.reduce(0,+))
        return norm>0 ? dot/norm:0
    }
    public func accepts(_ frame:AudioSpectrum)->Bool {frame.usable && frame.rms>=onset && similarity(frame)>=minimumSimilarity}
    public func chunks(transferID:UInt16)->[Data] {(0..<4).map {i in var d=Data([1,UInt8(i)]);d.put(transferID);d.append(data[(i*16)..<(i*16+16)]);return d}}
}
public struct AudioTrainingReport: Codable {
    public let profile: AudioProfile
    public let events: Int
    public let validationSimilarity: Double
    public let backgroundRMS: Double
}
public enum AudioTrainer {
    public static func analyze(background:[AudioSpectrum],positive:[AudioSpectrum],isTest:Bool=true) throws -> AudioTrainingReport {
        let quiet=background.filter(\.usable).map(\.rms).sorted()
        guard quiet.count>=30 else {throw TrainingFailure.insufficientSamples}
        let median=quiet[quiet.count/2],p90=quiet[Int(Double(quiet.count-1)*0.9)]
        let deviations=quiet.map{abs($0-median)}.sorted(),mad=deviations[deviations.count/2]*1.4826
        let onset=max(0.001,median+max(0.0007,4*mad),p90*1.6)
        guard onset<0.9 else {throw TrainingFailure.poorQuality}
        var events=[AudioSpectrum](),best:AudioSpectrum?,last:UInt16=0
        for frame in positive where frame.usable && frame.rms>=onset {
            if best != nil && frame.timestamp &- last>160 {events.append(best!);best=nil}
            if best == nil || frame.rms>best!.rms {best=frame};last=frame.timestamp
        }
        if let best {events.append(best)}
        guard events.count>=3 else {throw events.isEmpty ? TrainingFailure.noSignal:TrainingFailure.insufficientSamples}
        let training=events.enumerated().filter{$0.offset%3 != 0}.map(\.element)
        let validation=events.enumerated().filter{$0.offset%3 == 0}.map(\.element)
        var template=(0..<8).map{axis in training.map{$0.bands[axis]}.reduce(0,+)/Double(training.count)}
        let sum=template.reduce(0,+);template=template.map{$0/sum}
        let model=try AudioProfile(onset:onset,rearm:max(0.0001,min(onset*0.7,p90*1.2)),template:template)
        let profile=try AudioProfile(data:model.data)
        let similarity=validation.map{profile.similarity($0)}.min() ?? 0
        guard similarity>=0.75 else {throw TrainingFailure.notSeparable}
        let fitted=try AudioProfile(id:profile.id,isTest:isTest,onset:onset,rearm:profile.rearm,template:template,minimumSimilarity:max(0.75,min(0.90,similarity*0.95)))
        return AudioTrainingReport(profile:try AudioProfile(data:fitted.data),events:events.count,validationSimilarity:similarity,backgroundRMS:median)
    }
}

public struct AudioAnalysisWindow {
    public let samples:[Float]
    public let endingAt:Double
}

/// Half-window overlap preserves short attacks that fall on an FFT boundary.
public struct AudioWindowStream {
    public let sampleRate:Double
    public let size:Int
    public var hopSize:Int {size/2}
    public private(set) var discontinuities=0
    private var pending=[Float]()
    private var startTime:Double?
    private var expectedEnd:Double?
    public init?(sampleRate:Double,size:Int) {
        guard sampleRate.isFinite,(16000...192000).contains(sampleRate),(32...16384).contains(size),size%2==0 else{return nil}
        self.sampleRate=sampleRate;self.size=size
    }
    public mutating func append(_ samples:[Float],endingAt:Double)->[AudioAnalysisWindow] {
        guard !samples.isEmpty else{return []}
        guard samples.count<=65536,endingAt.isFinite,samples.allSatisfy(\.isFinite) else {
            pending=[];startTime=nil;expectedEnd=nil;discontinuities+=1;return []
        }
        let duration=Double(samples.count)/sampleRate
        if let expectedEnd,abs(endingAt-(expectedEnd+duration))>0.15 {
            pending=[];startTime=nil;self.expectedEnd=nil;discontinuities+=1
        }
        if startTime==nil {startTime=endingAt-duration}
        expectedEnd=(expectedEnd ?? (endingAt-duration))+duration
        pending.append(contentsOf:samples)
        var result=[AudioAnalysisWindow](),offset=0
        while pending.count-offset>=size {
            result.append(AudioAnalysisWindow(samples:Array(pending[offset..<(offset+size)]),endingAt:startTime!+Double(offset+size)/sampleRate))
            offset+=hopSize
        }
        if offset>0 {pending.removeFirst(offset);startTime!+=Double(offset)/sampleRate}
        return result
    }
}

#if canImport(Accelerate)
import Accelerate
public final class RealtimeSpectrumAnalyzer {
    public let sampleRate:Double
    public let size:Int
    private let setup:FFTSetup
    private let hann:[Float]
    private var sequence:UInt16=0
    public init?(sampleRate:Double) {
        guard sampleRate.isFinite,(16000...192000).contains(sampleRate) else{return nil}
        self.sampleRate=sampleRate;let n=sampleRate<=24000 ? 512:1024;size=n
        guard let fft=vDSP_create_fftsetup(vDSP_Length(log2(Double(size))),FFTRadix(kFFTRadix2)) else{return nil};setup=fft
        hann=(0..<n).map{Float(0.5-0.5*cos(2*Double.pi*Double($0)/Double(n-1)))}
    }
    deinit {vDSP_destroy_fftsetup(setup)}
    public func analyze(_ samples:[Float],timestamp:UInt16)->AudioSpectrum? {
        guard samples.count==size,samples.allSatisfy(\.isFinite) else{return nil}
        let mean=samples.reduce(0,+)/Float(size)
        let rms=sqrt(samples.reduce(0.0){$0+Double(($1-mean)*($1-mean))}/Double(size))
        var real=zip(samples,hann).map{($0.0-mean)*$0.1},imag=[Float](repeating:0,count:size)
        var bands=[Double](repeating:0,count:8),dense=[Double](repeating:0,count:24),dominant=0.0,maximum=0.0,weightedHz=0.0,logPower=0.0,powerSum=0.0,binCount=0
        real.withUnsafeMutableBufferPointer {r in imag.withUnsafeMutableBufferPointer {i in
            var split=DSPSplitComplex(realp:r.baseAddress!,imagp:i.baseAddress!)
            vDSP_fft_zip(setup,&split,1,vDSP_Length(log2(Double(size))),FFTDirection(kFFTDirection_Forward))
            let edges=[125.0,250,500,1000,2000,3000,4000,6000,8001]
            for bin in 1..<(size/2) {
                let hz=Double(bin)*sampleRate/Double(size)
                guard let band=(0..<8).first(where:{hz>=edges[$0] && hz<edges[$0+1]}) else{continue}
                let power=Double(r[bin]*r[bin]+i[bin]*i[bin]);bands[band]+=power
                weightedHz+=hz*power;powerSum+=power;logPower+=log(max(1e-18,power));binCount+=1
                for filter in 0..<24 {
                    let left=DenseAudioDescriptor.edges[filter],center=DenseAudioDescriptor.edges[filter+1],right=DenseAudioDescriptor.edges[filter+2]
                    if hz>=left && hz<=right {dense[filter]+=power*(hz<center ? (hz-left)/(center-left):(right-hz)/(right-center))}
                }
                if power>maximum {maximum=power;dominant=hz}
            }
        }}
        let sum=bands.reduce(0,+);if sum>0 {bands=bands.map{$0/sum}}
        sequence &+= 1
        guard var result=try? AudioSpectrum(data:AudioSpectrum.data(sequence:sequence,captureID:1,rms:min(1,rms),bands:bands,dominantHz:UInt16(min(8000,dominant)),timestamp:timestamp,flags:samples.contains{abs($0)>=0.999} ? 2:0)) else{return nil}
        let denseSum=dense.reduce(0,+)
        if denseSum>0 && powerSum>0 && rms>0 {
            let crossings=zip(samples,samples.dropFirst()).filter{($0<0) != ($1<0)}.count
            result.dense=DenseAudioDescriptor(spectrum:dense.map{$0/denseSum},centroid:weightedHz/powerSum,flatness:min(1,exp(logPower/Double(max(1,binCount)))/(powerSum/Double(max(1,binCount)))),zeroCrossing:Double(crossings)/Double(size),crest:max(1,Double(samples.map{abs($0-mean)}.max() ?? 0)/rms))
        }
        return result

    }
}
#endif

public struct DenseAudioDescriptor: Codable,Equatable,Sendable {
    public let spectrum:[Double]
    public let centroid:Double
    public let flatness:Double
    public let zeroCrossing:Double
    public let crest:Double
    public var valid:Bool {spectrum.count==24 && spectrum.allSatisfy{$0.isFinite && $0>=0 && $0<=1} && (0.98...1.02).contains(spectrum.reduce(0,+)) && centroid.isFinite && (0...8000).contains(centroid) && flatness.isFinite && (0...1.001).contains(flatness) && zeroCrossing.isFinite && (0...1).contains(zeroCrossing) && crest.isFinite && (1...500).contains(crest)}
    public static let edges:[Double]=(0..<26).map {i in
        let low=2595*log10(1+125.0/700),high=2595*log10(1+8000.0/700)
        return 700*(pow(10,(low+(high-low)*Double(i)/25)/2595)-1)
    }
}
public enum RefinedTrainingFailure:Error {case insufficientEvents,inconsistentEvents,noDenseFeatures,indistinguishableBackground}
public struct RefinedAcousticModel:Codable,Sendable {
    public let version:Int
    public let base:AudioProfile
    public let noisePower:[Double]
    public let prototypes:[DenseAudioDescriptor]
    public let prototypeGroups:[Int]?
    public var negatives:[DenseAudioDescriptor]
    public var minimumScore:Double
    public let minimumRise:Double
    public init(version:Int,base:AudioProfile,noisePower:[Double],prototypes:[DenseAudioDescriptor],negatives:[DenseAudioDescriptor],minimumScore:Double,minimumRise:Double,prototypeGroups:[Int]?=nil){self.version=version;self.base=base;self.noisePower=noisePower;self.prototypes=prototypes;self.negatives=negatives;self.minimumScore=minimumScore;self.minimumRise=minimumRise;self.prototypeGroups=prototypeGroups}
    public var valid:Bool {version==2 && (try? AudioProfile(data:base.data)) != nil && noisePower.count==24 && noisePower.allSatisfy{$0.isFinite && (0...1).contains($0)} && (3...24).contains(prototypes.count) && prototypes.allSatisfy(\.valid) && (prototypeGroups == nil || (prototypeGroups!.count==prototypes.count && prototypeGroups!.allSatisfy{(0...23).contains($0)})) && negatives.count<=12 && negatives.allSatisfy(\.valid) && minimumScore.isFinite && (0.65...0.99).contains(minimumScore) && minimumRise.isFinite && (1.1...4).contains(minimumRise)}
    public func cleaned(_ frame:AudioSpectrum)->DenseAudioDescriptor? {
        guard frame.usable,let d=frame.dense,d.valid else{return nil}
        let power=frame.rms*frame.rms
        let residual=zip(d.spectrum,noisePower).map {max(0,$0.0*power-$0.1*1.1)}
        let total=residual.reduce(0,+);guard total>1e-14 else{return nil}
        let bands=residual.map{$0/total}
        let centroid=(0..<24).map{bands[$0]*DenseAudioDescriptor.edges[$0+1]}.reduce(0,+)
        return DenseAudioDescriptor(spectrum:bands,centroid:centroid,flatness:d.flatness,zeroCrossing:d.zeroCrossing,crest:d.crest)
    }
    public static func score(_ a:DenseAudioDescriptor,_ b:DenseAudioDescriptor)->Double {
        guard a.valid,b.valid else{return 0}
        let overlap=zip(a.spectrum,b.spectrum).map{sqrt($0*$1)}.reduce(0,+)
        func scalar(_ delta:Double,_ scale:Double)->Double {exp(-0.5*pow(delta/scale,2))}
        return min(1,0.78*overlap+0.07*scalar(a.centroid-b.centroid,max(250,b.centroid*0.22))+0.05*scalar(a.flatness-b.flatness,0.12)+0.04*scalar(a.zeroCrossing-b.zeroCrossing,0.07)+0.06*scalar(log(a.crest/b.crest),0.65))
    }
    public func scores(_ frame:AudioSpectrum)->(target:Double,background:Double) {
        guard let d=cleaned(frame) else{return (0,0)}
        return (prototypes.map{Self.score(d,$0)}.max() ?? 0,negatives.map{Self.score(d,$0)}.max() ?? 0)
    }
    public func supportsAcrossEvents(_ frame:AudioSpectrum)->Bool {
        guard prototypeGroups == nil || prototypeGroups?.count==prototypes.count,let d=cleaned(frame) else{return false}
        var groups=[Int:Double]()
        for (index,prototype) in prototypes.enumerated() {
            let group=prototypeGroups?[index] ?? index/2
            groups[group]=max(groups[group] ?? 0,Self.score(d,prototype))
        }
        return groups.values.filter{$0>=minimumScore-0.02}.count>=2
    }
    public func addingBackground(_ frames:[AudioSpectrum]) throws -> Self {
        let candidates=frames.filter{$0.rms>=base.rearm}.compactMap{cleaned($0)}.sorted {a,b in
            (prototypes.map{Self.score(a,$0)}.max() ?? 0)>(prototypes.map{Self.score(b,$0)}.max() ?? 0)
        }
        var result=self,added=0
        for d in candidates {
            let target=prototypes.map{Self.score(d,$0)}.max() ?? 0
            guard target<0.98 else{continue}
            guard !result.negatives.contains(where:{Self.score(d,$0)>0.97}) else{continue}
            result.negatives.append(d);added+=1
            if result.negatives.count>12 {result.negatives.removeFirst()}
            if added>=8 {break}
        }
        guard added>0 else{throw RefinedTrainingFailure.indistinguishableBackground};return result
    }
}
public struct RefinedAcousticReport:Codable,Sendable {
    public let model:RefinedAcousticModel
    public let events:Int
    public let excludedEvents:Int
    public let crossEventSimilarity:Double
    public let backgroundRMS:Double
    public init(model:RefinedAcousticModel,events:Int,excludedEvents:Int,crossEventSimilarity:Double,backgroundRMS:Double){self.model=model;self.events=events;self.excludedEvents=excludedEvents;self.crossEventSimilarity=crossEventSimilarity;self.backgroundRMS=backgroundRMS}
    public var legacyReport:AudioTrainingReport {AudioTrainingReport(profile:model.base,events:events,validationSimilarity:crossEventSimilarity,backgroundRMS:backgroundRMS)}
}
public enum RefinedAcousticTrainer {
    private struct Event {var frames:[AudioSpectrum];var rise:Double}
    public static func analyze(background:[AudioSpectrum],positive:[AudioSpectrum]) throws -> RefinedAcousticReport {
        let quiet=background.filter{$0.flags & 14 == 0 && ($0.dense?.valid==true || ($0.rms==0 && $0.bands.allSatisfy{$0==0}))}
        guard quiet.count>=30 else{throw RefinedTrainingFailure.noDenseFeatures}
        func median(_ x:[Double])->Double {let a=x.sorted();return a[a.count/2]}
        let noise=median(quiet.map(\.rms)),deviation=median(quiet.map{abs($0.rms-noise)})*1.4826
        let onset=max(0.0004,noise+max(0.00025,2*deviation),quiet.map(\.rms).sorted()[Int(Double(quiet.count-1)*0.75)]*1.2)
        guard onset<0.9 else{throw TrainingFailure.poorQuality}
        let power=(0..<24).map{band in median(quiet.map{($0.dense?.spectrum[band] ?? 0)*$0.rms*$0.rms})}
        var events=[Event](),active=[AudioSpectrum](),rise=1.0,lastAbove:UInt16=0,previousRMS=noise
        func finish(){if let first=active.first,let last=active.last,last.timestamp &- first.timestamp<=420 {events.append(Event(frames:active,rise:rise))};active=[]}
        for frame in positive where frame.flags & 14 == 0 {
            if !active.isEmpty && frame.timestamp &- lastAbove>100 {finish()}
            defer {previousRMS=frame.rms}
            guard frame.usable,frame.dense?.valid==true else{continue}
            if frame.rms>=onset {
                if active.isEmpty {rise=frame.rms/max(0.00001,previousRMS)}
                active.append(frame);lastAbove=frame.timestamp
            }
        }
        finish();guard events.count>=3 else{throw RefinedTrainingFailure.insufficientEvents}
        let raw=events.map{$0.frames.max(by:{$0.rms<$1.rms})!}
        var eight=(0..<8).map{band in raw.map{$0.bands[band]}.reduce(0,+)/Double(raw.count)}
        let sum=eight.reduce(0,+);eight=eight.map{$0/sum}
        let base=try AudioProfile(onset:onset,rearm:max(0.0001,min(onset*0.92,max(onset*0.75,noise*1.4))),template:eight,minimumSimilarity:0.86,refractoryMs:100)
        var model=RefinedAcousticModel(version:2,base:base,noisePower:power,prototypes:[],negatives:[],minimumScore:0.88,minimumRise:1.3)
        let descriptors=raw.compactMap{model.cleaned($0)}
        guard descriptors.count==events.count else{throw RefinedTrainingFailure.noDenseFeatures}
        let coherence=descriptors.indices.map{i in descriptors.indices.filter{$0 != i}.map{RefinedAcousticModel.score(descriptors[i],descriptors[$0])}.max() ?? 0}
        let center=median(coherence),spread=median(coherence.map{abs($0-center)})*1.4826
        let retained=coherence.indices.filter{coherence[$0]>=max(0.65,center-max(0.08,3*spread))}
        guard retained.count>=3 else{throw RefinedTrainingFailure.inconsistentEvents}
        let weakest=retained.map{coherence[$0]}.min() ?? 0
        guard weakest>=0.70 else{throw RefinedTrainingFailure.inconsistentEvents}
        var prototypes=[DenseAudioDescriptor](),groups=[Int]()
        for (group,i) in retained.enumerated() {
            let event=events[i],peak=event.frames.max(by:{$0.rms<$1.rms})!
            for frame in [event.frames.first!,peak] {
                if let d=model.cleaned(frame),prototypes.count<24 {prototypes.append(d);groups.append(group)}
            }
        }
        let rises=retained.map{events[$0].rise}.sorted()
        model=RefinedAcousticModel(version:2,base:base,noisePower:power,prototypes:prototypes,negatives:[],minimumScore:max(0.80,min(0.92,weakest*0.94)),minimumRise:max(1.15,min(1.6,rises[0]*0.4)),prototypeGroups:groups)
        guard model.valid else{throw TrainingFailure.poorQuality}
        return RefinedAcousticReport(model:model,events:retained.count,excludedEvents:events.count-retained.count,crossEventSimilarity:weakest,backgroundRMS:noise)
    }
}
public enum AcousticDecision:String,Sendable {
    case quiet,lowEnergy,weakAttack,differentSpectrum,background,confirming,accepted,cooldown,invalid,sustained
    public var text:String {switch self {
        case .quiet:return "等待下一次起音"
        case .lowEnergy:return "聲音低於底噪門檻"
        case .weakAttack:return "持續聲／起音不符合"
        case .differentSpectrum:return "頻譜或音色不符合"
        case .background:return "符合已排除的背景聲"
        case .confirming:return "確認瞬間特徵中"
        case .accepted:return "特徵符合，已計數"
        case .cooldown:return "同一聲音的餘響"
        case .invalid:return "聲音資料不足或飽和"
        case .sustained:return "持續聲，未計數"
    }}
}
public struct RefinedEventDetector {
    private var gate=LocalTriggerGate()
    private var previousRMS=0.0,previousScore=0.0,attack=0.0,candidateAt:Double?,support=0
    private var spectralAttack=false
    private var eventPeak=0.0,lastAcceptedAt:Double = -.infinity
    private var pendingMotion:Double?
    private var pendingPeak=0.0
    public private(set) var decision:AcousticDecision = .quiet
    public private(set) var score=0.0
    public init(){}
    public mutating func update(_ frame:AudioSpectrum,time:Double,model:RefinedAcousticModel,needsMotion:Bool=false,motionOK:Bool=true)->Bool {
        guard time.isFinite,frame.flags & 14 == 0 else{decision = .invalid;return false}
        // Digital silence has no spectral shape, but is valid quiet input.
        if frame.rms<model.base.rearm {
            _ = gate.update(match:false,quiet:true,time:time,refractory:Double(model.base.refractoryMs)/1000,quietDuration:0.025)
            previousRMS=frame.rms;previousScore=0;score=0
            candidateAt=nil;support=0;spectralAttack=false;pendingMotion=nil;eventPeak=0
            decision = .quiet;return false
        }
        guard frame.usable,frame.dense?.valid==true else{decision = .invalid;return false}
        let oldRMS=previousRMS,oldScore=previousScore;previousRMS=frame.rms
        let match=model.scores(frame);score=match.target;previousScore=match.target
        let unrelated=match.target<model.minimumScore-0.12
        let refractory=Double(model.base.refractoryMs)/1000
        // A decayed tabletop resonance need not return to the original noise floor.
        // Require a deep valley after the refractory period, then a fresh attack.
        let relativeValley=eventPeak>0 && frame.rms<eventPeak*0.35 && time-lastAcceptedAt>=refractory
        let isQuiet=frame.rms<model.base.rearm || unrelated || relativeValley
        _ = gate.update(match:false,quiet:isQuiet,time:time,refractory:Double(model.base.refractoryMs)/1000,quietDuration:0.025)
        if isQuiet {candidateAt=nil;support=0;spectralAttack=false;pendingMotion=nil;if !relativeValley {eventPeak=0};decision = .quiet;return false}
        guard frame.rms>=model.base.onset else{decision = .lowEnergy;return false}
        if candidateAt==nil {candidateAt=time;attack=frame.rms/max(model.base.rearm,oldRMS);support=0;spectralAttack=false}
        let spectralOnset=oldScore<model.minimumScore-0.10 && match.target>=model.minimumScore+0.015
        spectralAttack = spectralAttack || spectralOnset
        attack=max(attack,frame.rms/max(model.base.rearm,oldRMS))
        guard time-(candidateAt ?? time)<=0.10,(attack>=model.minimumRise || spectralAttack) else{decision = .weakAttack;return false}
        guard match.target>=model.minimumScore else{support=0;decision = .differentSpectrum;return false}
        guard model.supportsAcrossEvents(frame) else{support=0;decision = .differentSpectrum;return false}
        guard model.negatives.isEmpty || match.target>match.background+0.025 else{support=0;decision = .background;return false}
        support+=1
        guard match.target>=min(0.98,model.minimumScore+0.035) || support>=2 else{decision = .confirming;return false}
        if needsMotion && !motionOK {pendingMotion=time;pendingPeak=frame.rms;decision = .confirming;return false}
        let hit=gate.update(match:true,quiet:false,time:time,refractory:Double(model.base.refractoryMs)/1000,quietDuration:0.025)
        if hit {lastAcceptedAt=time;eventPeak=frame.rms}
        pendingMotion=nil;decision=hit ? .accepted:.cooldown;return hit
    }
    public mutating func confirmMotion(time:Double,refractory:Double)->Bool {
        guard let pending=pendingMotion,time>=pending,time-pending<=0.08 else{return false}
        pendingMotion=nil
        let hit=gate.update(match:true,quiet:false,time:time,refractory:refractory)
        if hit {lastAcceptedAt=time;eventPeak=pendingPeak}
        decision=hit ? .accepted:.cooldown;return hit
    }
}

/// Verify an acoustic candidate's short decay before committing a sound-only event.
/// This is a transient filter, not a general-purpose speech recognition model.
public struct LocalAcousticDetector {
    private var matcher=RefinedEventDetector()
    private var pendingAt:Double?
    private var peak=0.0
    public private(set) var decision:AcousticDecision = .quiet
    public private(set) var score=0.0
    public init(){}
    public mutating func update(_ frame:AudioSpectrum,time:Double,model:RefinedAcousticModel,needsMotion:Bool=false,motionOK:Bool=true)->Bool {
        let candidate=matcher.update(frame,time:time,model:model,needsMotion:needsMotion,motionOK:motionOK)
        score=matcher.score;decision=matcher.decision
        if needsMotion {pendingAt=nil;return candidate}
        guard time.isFinite,frame.flags & 14 == 0 else{pendingAt=nil;return false}
        if candidate {pendingAt=time;peak=frame.rms}
        guard let start=pendingAt else{return false}
        let elapsed=time-start
        if elapsed<0 || elapsed>0.10 {pendingAt=nil;decision = .sustained;return false}
        if matcher.decision == .background {pendingAt=nil;decision = .background;return false}
        peak=max(peak,frame.rms)
        if elapsed>=0.015 && frame.rms<=peak*0.55 {
            pendingAt=nil;decision = .accepted;return true
        }
        decision = .confirming;return false
    }
    public mutating func confirmMotion(time:Double,refractory:Double)->Bool {
        let hit=matcher.confirmMotion(time:time,refractory:refractory)
        decision=matcher.decision;return hit
    }
}

public struct LocalAcousticValidation:Codable {
    public let modelID:UInt32
    public let expected:Int
    public let detected:Int
    public let lifetimeBefore:UInt64
    public let lifetimeAfter:UInt64
    public let frames:[AudioSpectrum]
    public init(modelID:UInt32,expected:Int,detected:Int,lifetimeBefore:UInt64,lifetimeAfter:UInt64,frames:[AudioSpectrum]){self.modelID=modelID;self.expected=expected;self.detected=detected;self.lifetimeBefore=lifetimeBefore;self.lifetimeAfter=lifetimeAfter;self.frames=frames}
}
