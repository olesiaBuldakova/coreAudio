//
//  PlayerViewModel.swift
//  DemoCoreAudio
//
//  Created by Леся Булдакова on 16.09.2021.
//

import SwiftUI
import AVFoundation

class PlayerViewModel: NSObject, ObservableObject {
    // MARK: Public properties
    
    var isAudioPlaying = false
    var isPlayerReady = false {
        willSet {
            objectWillChange.send()
        }
    }
    var playbackRateIndex: Int = 1 {
        willSet {
            objectWillChange.send()
        }
        didSet {
            updateForRateSelection()
        }
    }
    var playbackPitchIndex: Int = 1 {
        willSet {
            objectWillChange.send()
        }
        didSet {
            updateForPitchSelection()
        }
    }
    var playerProgress: Double = 0 {
        willSet {
            objectWillChange.send()
        }
    }
    var playerTime: PlayerTime = .zero {
        willSet {
            objectWillChange.send()
        }
    }
    var meterLevel: Float = 0 {
        willSet {
            objectWillChange.send()
        }
    }
    
    let allPlaybackRates: [PlaybackValue] = [
        .init(value: 0.5, label: "0.5x"),
        .init(value: 1, label: "1x"),
        .init(value: 1.25, label: "1.25x"),
        .init(value: 2, label: "2x")
    ]
    
    let allPlaybackPitches: [PlaybackValue] = [
        .init(value: -0.5, label: "-½"),
        .init(value: 0, label: "0"),
        .init(value: 0.5, label: "+½")
    ]
    
    // MARK: Private properties
    
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var pinchNode = AVAudioUnitTimePitch()
    
    private var isAudioPlayingBeforeInterruption = false
    private var isHeadphonesConnected = false
    
    private var displayLink: CADisplayLink?
    
    private var needsFileScheduled = true
    
    private var audioFile: AVAudioFile!
    private var audioSampleRate: Double = 0
    private var audioLengthSeconds: Double = 0
    
    private var seekFrame: AVAudioFramePosition = 0
    private var currentPosition: AVAudioFramePosition = 0
    private var audioLengthSamples: AVAudioFramePosition = 0
    
    private var currentFrame: AVAudioFramePosition {
        guard
            let lastRenderTime = playerNode.lastRenderTime,
            let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime)
        else { return 0 }
        return playerTime.sampleTime
    }
    
    // MARK: - Public
    
    override init() {
        super.init()
        setupAudio()
        setupDisplayLink()
        configureAudioEngine()
        registerForNotifications()
    }
    
    func playOrPause() {
        if playerNode.isPlaying {
            displayLink?.isPaused = true
            disconnectVolumeTap()
            playerNode.pause()
            isAudioPlaying = false
        } else {
            displayLink?.isPaused = false
            connectVolumeTap()
            if needsFileScheduled {
                scheduleAudioFile()
            }
            play()
        }
    }
    
    func skip(forwards: Bool) {
        let timeToSeek: Double = forwards ? 10 : -10
        seek(to: timeToSeek)
    }
    
    // MARK: - Private
    
    private func setupAudio() {
        guard let fileURL = Bundle.main.url(forResource: "musicItem", withExtension: "mp3") else { return }
        do {
            let file = try AVAudioFile(forReading: fileURL)
            audioLengthSamples = file.length
            audioSampleRate = file.processingFormat.sampleRate
            audioLengthSeconds = Double(audioLengthSamples) / audioSampleRate
            audioFile = file
        } catch {
            print("Error reading the audio file: \(error.localizedDescription)")
        }
    }
    
    private func scheduleAudioFile() {
        guard let file = audioFile, needsFileScheduled else { return }
        needsFileScheduled = false
        seekFrame = 0
        playerNode.scheduleFile(file, at: nil) {
            self.needsFileScheduled = true
        }
    }
    
    // MARK: Audio adjustments
    
    private func seek(to time: Double) {
        guard let audioFile = audioFile else { return }
        
        let offset = AVAudioFramePosition(time * audioSampleRate)
        seekFrame = currentPosition + offset
        seekFrame = max(seekFrame, 0)
        seekFrame = min(seekFrame, audioLengthSamples)
        currentPosition = seekFrame
        
        let wasPlaying = playerNode.isPlaying
        playerNode.stop()
        
        if currentPosition < audioLengthSamples {
            updateDisplay()
            needsFileScheduled = false
            
            let frameCount = AVAudioFrameCount(audioLengthSamples - seekFrame)
            playerNode.scheduleSegment(
                audioFile,
                startingFrame: seekFrame,
                frameCount: frameCount,
                at: nil
            ) {
                self.needsFileScheduled = true
            }
            if wasPlaying {
                playerNode.play()
                isAudioPlaying = true
            }
        }
    }
    
    private func updateForRateSelection() {
        let selectedRate = allPlaybackRates[playbackRateIndex]
        pinchNode.rate = Float(selectedRate.value)
    }
    
    private func updateForPitchSelection() {
        let selectedPitch = allPlaybackPitches[playbackPitchIndex]
        // 1 octave = 1200 cents
        pinchNode.pitch = 1200 * Float(selectedPitch.value)
    }
    
    // MARK: - Audio metering
    
    private func scaledPower(power: Float) -> Float {
        guard power.isFinite else { return 0.0 }
        let minDb: Float = -80
        
        if power < minDb {
            return 0.0
        } else if power >= 1.0 {
            return 1.0
        } else {
            return (abs(minDb) - abs(power)) / abs(minDb)
        }
    }
    
    private func connectVolumeTap() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: format
        ) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            
            let channelDataValue = channelData.pointee
            let channelDataValueArray = stride(
                from: 0,
                to: Int(buffer.frameLength),
                by: buffer.stride)
                .map { channelDataValue[$0] }
            
            let rms = sqrt(channelDataValueArray.map {
                return $0 * $0
            }
            .reduce(0, +) / Float(buffer.frameLength))
            
            let avgPower = 20 * log10(rms)
            let meterLevel = self.scaledPower(power: avgPower)
            
            DispatchQueue.main.async {
                self.meterLevel = self.isAudioPlaying ? meterLevel : 0
            }
        }
    }
    
    private func disconnectVolumeTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
        meterLevel = 0
    }
    
    // MARK: - Display updates
    
    private func setupDisplayLink() {
        displayLink = CADisplayLink(
            target: self,
            selector: #selector(updateDisplay))
        displayLink?.add(to: .current, forMode: .default)
        displayLink?.isPaused = true
    }
    
    @objc private func updateDisplay() {
        currentPosition = currentFrame + seekFrame
        currentPosition = max(currentPosition, 0)
        currentPosition = min(currentPosition, audioLengthSamples)
        
        if currentPosition >= audioLengthSamples {
            playerNode.stop()
            seekFrame = 0
            currentPosition = 0
            isAudioPlaying = false
            displayLink?.isPaused = true
            disconnectVolumeTap()
        }
        
        playerProgress = Double(currentPosition) / Double(audioLengthSamples)
        let time = Double(currentPosition) / audioSampleRate
        playerTime = PlayerTime(
            elapsedTime: time,
            remainingTime: audioLengthSeconds - time)
    }
}

private extension PlayerViewModel {
    
    // MARK: - Notifications
    
    func registerForNotifications() {
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruptions), name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesWereReset), name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance())
    }
    
    @objc func handleInterruptions(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        // состояние прерывания
        switch type {
        case .began:
            isAudioPlayingBeforeInterruption = isAudioPlaying
            if isAudioPlayingBeforeInterruption {
                stop()
            }
        case .ended:
            guard let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume), isAudioPlayingBeforeInterruption {
                play()
            }
        default: break
        }
        print("Interruption handled")
    }
    
    @objc func handleMediaServicesWereReset(_ notification: Notification) {
        stop()
        engine.stop()
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        pinchNode = AVAudioUnitTimePitch()
        needsFileScheduled = true
        print("media server reset handled")
        configureAudioEngine()
        startAudioEngine()
    }
    
    @objc func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            stop()
        default: break
        }
        isHeadphonesConnected = isHeadphonesConnected(route: AVAudioSession.sharedInstance().currentRoute)
        print("is headphones connected", isHeadphonesConnected)
    }
}

// MARK: - private
private extension PlayerViewModel {
    
    func play() {
        configureAudioSession()
        if !engine.isRunning {
            configureAudioEngine()
            startAudioEngine()
        }
        playerNode.scheduleFile(audioFile, at: AVAudioTime(hostTime: 0)) { // если хотим зациклить аудио, то используем буффер
            // file ended
            DispatchQueue.main.async {
                self.isAudioPlaying = false
            }
        }
        playerNode.play()
        isAudioPlaying = true
    }
    
    func stop() {
        playerNode.stop()
        isAudioPlaying = false
    }
    
    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch let error {
            fatalError("failed to set session: \(error.localizedDescription)")
        }
    }
    
    func configureAudioEngine() {
        engine.attach(playerNode)
        engine.attach(pinchNode)
        engine.connect(playerNode, to: pinchNode, format: nil)
        engine.connect(pinchNode, to: engine.mainMixerNode, format: nil)
        engine.prepare()
        isPlayerReady = true
    }
    
    func startAudioEngine() {
        do {
            try engine.start()
            scheduleAudioFile()
            isPlayerReady = true
        } catch let error {
            fatalError("failed to start engine: \(error.localizedDescription)")
        }
    }
    
    func isHeadphonesConnected(route: AVAudioSessionRouteDescription) -> Bool {
        let headphonesIndex = route.outputs.first { $0.portType == AVAudioSession.Port.bluetoothA2DP }
        return headphonesIndex != nil
    }
    
    //example of equalizer node for Pasha)
    func equalizer() {
        let EQNode = AVAudioUnitEQ(numberOfBands: 2)
        EQNode.globalGain = 1
        engine.attach(EQNode)
    }
}

