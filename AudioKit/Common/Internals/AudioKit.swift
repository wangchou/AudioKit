//
//  AudioKit.swift
//  AudioKit
//
//  Created by Aurelius Prochazka, revision history on Github.
//  Copyright © 2018 AudioKit. All rights reserved.
//

#if !os(tvOS)
import CoreAudioKit
#endif

#if !os(macOS)
import UIKit
#endif
import Dispatch

public typealias AKCallback = () -> Void

/// Top level AudioKit managing class
@objc open class AudioKit: NSObject {

    // MARK: Global audio format (44.1K, Stereo)

    /// Format of AudioKit Nodes
    @objc open static var format = AKSettings.audioFormat

    // MARK: - Internal audio engine mechanics

    /// Reference to the AV Audio Engine
    @objc open static var engine = AVAudioEngine()

    /// Reference to singleton MIDI

    #if !os(tvOS)
    open static let midi = AKMIDI()
    #endif

    @objc static var shouldBeRunning = false

    @objc static var finalMixer = AKMixer()

    /// Notification observers
    fileprivate static var notificationObservers: [Any] = []

    /// An audio output operation that most applications will need to use last
    @objc open static var output: AKNode? {
        didSet {
            do {
                try updateSessionCategoryAndOptions()
                output?.connect(to: finalMixer)
                engine.connect(finalMixer.avAudioNode, to: engine.outputNode)
            } catch {
                AKLog("Could not set output: \(error)")
            }
        }
    }

    // MARK: - Device Management

    /// Enumerate the list of available input devices.
    @objc open static var inputDevices: [AKDevice]? {
        #if os(macOS)
            EZAudioUtilities.setShouldExitOnCheckResultFail(false)
            return EZAudioDevice.inputDevices().map {
                AKDevice(name: ($0 as AnyObject).name, deviceID: ($0 as AnyObject).deviceID)
            }
        #else
            var returnDevices = [AKDevice]()
            if let devices = AVAudioSession.sharedInstance().availableInputs {
                for device in devices {
                    if device.dataSources == nil || device.dataSources!.isEmpty {
                        returnDevices.append(AKDevice(name: device.portName, deviceID: device.uid))
                    } else {
                        for dataSource in device.dataSources! {
                            returnDevices.append(AKDevice(name: device.portName,
                                                          deviceID: "\(device.uid) \(dataSource.dataSourceName)"))
                        }
                    }
                }
                return returnDevices
            }
            return nil
        #endif
    }

    /// Enumerate the list of available output devices.
    @objc open static var outputDevices: [AKDevice]? {
        #if os(macOS)
            EZAudioUtilities.setShouldExitOnCheckResultFail(false)
            return EZAudioDevice.outputDevices().map {
                AKDevice(name: ($0 as AnyObject).name, deviceID: ($0 as AnyObject).deviceID)
            }
        #else
            let devs = AVAudioSession.sharedInstance().currentRoute.outputs
            if devs.isNotEmpty {
                var outs = [AKDevice]()
                for dev in devs {
                    outs.append(AKDevice(name: dev.portName, deviceID: dev.uid))
                }
                return outs
            }
            return nil
        #endif
    }

    /// The name of the current input device, if available.
    @objc open static var inputDevice: AKDevice? {
        #if os(macOS)
            if let dev = EZAudioDevice.currentInput() {
                return AKDevice(name: dev.name, deviceID: dev.deviceID)
            }
        #else
            if let dev = AVAudioSession.sharedInstance().preferredInput {
                return AKDevice(name: dev.portName, deviceID: dev.uid)
            } else {
                let inputDevices = AVAudioSession.sharedInstance().currentRoute.inputs
                if inputDevices.isNotEmpty {
                    for device in inputDevices {
                        let dataSourceString = device.selectedDataSource?.description ?? ""
                        let id = "\(device.uid) \(dataSourceString)".trimmingCharacters(in: [" "])
                        return AKDevice(name: device.portName, deviceID: id)
                    }
                }
            }
        #endif
        return nil
    }

    /// The name of the current output device, if available.
    @objc open static var outputDevice: AKDevice? {
        #if os(macOS)
            if let dev = EZAudioDevice.currentOutput() {
                return AKDevice(name: dev.name, deviceID: dev.deviceID)
            }
        #else
            let devs = AVAudioSession.sharedInstance().currentRoute.outputs
            if devs.isNotEmpty {
                return AKDevice(name: devs[0].portName, deviceID: devs[0].uid)
            }

        #endif
        return nil
    }

    /// Change the preferred input device, giving it one of the names from the list of available inputs.
    @objc open static func setInputDevice(_ input: AKDevice) throws {
        #if os(macOS)
            try AKTry {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMaster)
                var devid = input.deviceID
                AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &devid)
            }
        #else
            if let devices = AVAudioSession.sharedInstance().availableInputs {
                for device in devices {
                    if device.dataSources == nil || device.dataSources!.isEmpty {
                        if device.uid == input.deviceID {
                            do {
                                try AVAudioSession.sharedInstance().setPreferredInput(device)
                            } catch {
                                AKLog("Could not set the preferred input to \(input)")
                            }
                        }
                    } else {
                        for dataSource in device.dataSources! {
                            if input.deviceID == "\(device.uid) \(dataSource.dataSourceName)" {
                                do {
                                    try AVAudioSession.sharedInstance().setInputDataSource(dataSource)
                                } catch {
                                    AKLog("Could not set the preferred input to \(input)")
                                }
                            }
                        }
                    }
                }
            }

            if let devices = AVAudioSession.sharedInstance().availableInputs {
                for dev in devices {
                    if dev.uid == input.deviceID {
                        do {
                            try AVAudioSession.sharedInstance().setPreferredInput(dev)
                        } catch {
                            AKLog("Could not set the preferred input to \(input)")
                        }
                    }
                }
            }
        #endif
    }

    /// Change the preferred output device, giving it one of the names from the list of available output.
    @objc open static func setOutputDevice(_ output: AKDevice) throws {
        #if os(macOS)
            try AKTry {
                var id = output.deviceID
                if let audioUnit = AudioKit.engine.outputNode.audioUnit {
                    AudioUnitSetProperty(audioUnit,
                                         kAudioOutputUnitProperty_CurrentDevice,
                                         kAudioUnitScope_Global, 0,
                                         &id,
                                         UInt32(MemoryLayout<DeviceID>.size))
                }
            }
        #else
            //not available on ios
        #endif
    }

    // MARK: - Start/Stop

    /// Start up the audio engine with periodic functions
    open static func start(withPeriodicFunctions functions: AKPeriodicFunction...) throws {
        for function in functions {
            function.connect(to: finalMixer)
        }
        try start()
    }

    /// Start up the audio engine
    @objc open static func start() throws {
        if output == nil {
            AKLog("No output node has been set yet, no processing will happen.")
        }
        // Start the engine.
        try AKTry {
            engine.prepare()
        }

        #if os(iOS)

            if AKSettings.enableRouteChangeHandling {

                let routeChangeObserver = NotificationCenter.default.addObserver(forName: .AVAudioSessionRouteChange,
                                                                                 object: nil,
                                                                                 queue: OperationQueue.main,
                                                                                 using: { (notification) in
                                                                                    AudioKit.restartEngineAfterRouteChange(notification)
                })
                notificationObservers.append(routeChangeObserver)

            }

            if AKSettings.enableCategoryChangeHandling {
                let configurationChangeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                                         object: engine,
                                                                                         queue: OperationQueue.main,
                                                                                         using: { (notification) in
                                                                                            AudioKit.restartEngineAfterConfigurationChange(notification)
                })
                notificationObservers.append(configurationChangeObserver)
            }
            try updateSessionCategoryAndOptions()
            try AVAudioSession.sharedInstance().setActive(true)
        #endif

        try AKTry {
            try engine.start()
        }
        shouldBeRunning = true
    }

    @objc fileprivate static func updateSessionCategoryAndOptions() throws {
        #if !os(macOS)
            let sessionCategory = AKSettings.computedSessionCategory()

            #if os(iOS)
                let sessionOptions = AKSettings.computedSessionOptions()
                try AKSettings.setSession(category: sessionCategory,
                                          with: sessionOptions)
            #elseif os(tvOS)
                try AKSettings.setSession(category: sessionCategory)
            #endif
        #endif
    }

    /// Stop the audio engine
    @objc open static func stop() throws {
        // Stop the engine.
        try AKTry {
            engine.stop()
        }
        shouldBeRunning = false

        #if os(iOS)
        notificationObservers.forEach { (observer) in
            NotificationCenter.default.removeObserver(observer)
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            AKLog("couldn't stop session \(error)")
            throw error
        }
        #endif
    }

    // MARK: - Testing

    /// Testing AKNode
    @objc open static var tester: AKTester?

    /// Test the output of a given node
    ///
    /// - Parameters:
    ///   - node: AKNode to test
    ///   - duration: Number of seconds to test (accurate to the sample)
    ///
    @objc open static func test(node: AKNode, duration: Double, afterStart: () -> Void = {}) throws {
        #if swift(>=3.2)
            if #available(iOS 11, macOS 10.13, tvOS 11, *) {
                let samples = Int(duration * AKSettings.sampleRate)

                tester = AKTester(node, samples: samples)
                output = tester

                // maximum number of frames the engine will be asked to render in any single render call
                let maxNumberOfFrames: AVAudioFrameCount = 4_096
                try AKTry {
                    engine.reset()
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxNumberOfFrames)
                    try engine.start()
                }

                afterStart()
                tester?.play()

                let buffer: AVAudioPCMBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                                frameCapacity: engine.manualRenderingMaximumFrameCount)!

                while engine.manualRenderingSampleTime < samples {
                    let framesToRender = buffer.frameCapacity
                    let status = try engine.renderOffline(framesToRender, to: buffer)
                    switch status {
                    case .success:
                        // data rendered successfully
                        break

                    case .insufficientDataFromInputNode:
                        // applicable only if using the input node as one of the sources
                        break

                    case .cannotDoInCurrentContext:
                        // engine could not render in the current render call, retry in next iteration
                        break

                    case .error:
                        // error occurred while rendering
                        fatalError("render failed")
                    }
                }
                tester?.stop()
            }
        #endif
    }

    /// Audition the test to hear what it sounds like
    ///
    /// - Parameters:
    ///   - node: AKNode to test
    ///   - duration: Number of seconds to test (accurate to the sample)
    ///
    @objc open static func auditionTest(node: AKNode, duration: Double) throws {
        output = node
        try start()
        if let playableNode = node as? AKToggleable {
            playableNode.play()
        }
        usleep(UInt32(duration * 1_000_000))
        try stop()
        try start()
    }

    // MARK: - Configuration Change Response

    // Listen to changes in audio configuration
    // and restart the audio engine if it stops and should be playing
    @objc fileprivate static func restartEngineAfterConfigurationChange(_ notification: Notification) {
        do {
            if shouldBeRunning && !engine.isRunning {
                #if !os(macOS)
                    let appIsNotActive = UIApplication.shared.applicationState != .active
                    let appDoesNotSupportBackgroundAudio = !AKSettings.appSupportsBackgroundAudio

                    if appIsNotActive && appDoesNotSupportBackgroundAudio {
                        AKLog("engine not restarted after configuration change since app was not active and does not support background audio")
                        return
                    }
                #endif

                try engine.start()

                // Sends notification after restarting the engine, so it is safe to resume AudioKit functions.
                if AKSettings.notificationsEnabled {
                    NotificationCenter.default.post(
                        name: .AKEngineRestartedAfterConfigurationChange,
                        object: nil,
                        userInfo: notification.userInfo)
                }
            }
        } catch {
            AKLog("error restarting engine after route change")
            // Note: doesn't throw since this is called from a notification observer
        }
    }

    // Restarts the engine after audio output has been changed, like headphones plugged in.
    @objc fileprivate static func restartEngineAfterRouteChange(_ notification: Notification) {
        if shouldBeRunning && !engine.isRunning {
            do {
                #if !os(macOS)
                    let appIsNotActive = UIApplication.shared.applicationState != .active
                    let appDoesNotSupportBackgroundAudio = !AKSettings.appSupportsBackgroundAudio

                    if appIsNotActive && appDoesNotSupportBackgroundAudio {
                        AKLog("engine not restarted after route change since app was not active and does not support background audio")
                        return
                    }
                #endif

                try engine.start()

                // Sends notification after restarting the engine, so it is safe to resume AudioKit functions.
                if AKSettings.notificationsEnabled {
                    NotificationCenter.default.post(
                        name: .AKEngineRestartedAfterRouteChange,
                        object: nil,
                        userInfo: notification.userInfo)
                }
            } catch {
                AKLog("error restarting engine after route change")
                // Note: doesn't throw since this is called from a notification observer
            }
        }
    }

    // MARK: - Disconnect node inputs

    /// Disconnect all inputs
    @objc open static func disconnectAllInputs() {
        engine.disconnectNodeInput(finalMixer.avAudioNode)
    }

    // MARK: - Deinitialization

    deinit {
        #if os(iOS)
            NotificationCenter.default.removeObserver(
                self,
                name: .AKEngineRestartedAfterRouteChange,
                object: nil)
        #endif
    }
}

//This extension makes connect calls shorter, and safer by attaching nodes if not already attached.
extension AudioKit {

    // Attaches nodes if node.engine == nil
    private static func safeAttach(_ nodes: [AVAudioNode]) {
        _ = nodes.filter { $0.engine == nil }.map { engine.attach($0) }
    }

    // AVAudioMixer will crash if engine is started and connection is made to a bus exceeding mixer's
    // numberOfInputs. The crash only happens when using the AVAudioEngine function that connects a node to an array
    // of AVAudioConnectionPoints and the mixer is one of those points. When AVAudioEngine uses a different function
    // that connects a node's output to a single AVAudioMixerNode, the mixer's inputs are incremented to accommodate
    // the new connection. So the workaround is to create dummy nodes, make a connections to the mixer using the
    // function that makes the mixer create new inputs, then remove the dummy nodes so that there is an available
    // bus to connect to.
    //
    private static func checkMixerInputs(_ connectionPoints: [AVAudioConnectionPoint]) {

        if !engine.isRunning { return }

        for connection in connectionPoints {
            if let mixer = connection.node as? AVAudioMixerNode,
                connection.bus >= mixer.numberOfInputs {

                var dummyNodes = [AVAudioNode]()
                while connection.bus >= mixer.numberOfInputs {
                    let dummyNode = AVAudioUnitSampler()
                    dummyNode.setOutput(to: mixer)
                    dummyNodes.append(dummyNode)
                }
                for dummyNode in dummyNodes {
                    dummyNode.disconnectOutput()
                }

            }
        }
    }

    // If an AVAudioMixerNode's output connection is made while engine is running, and there are no input connections
    // on the mixer, subsequent connections made to the mixer will silently fail.  A workaround is to connect a dummy
    // node to the mixer prior to making a connection, then removing the dummy node after the connection has been made.
    //
    private static func addDummyOnEmptyMixer(_ node: AVAudioNode) -> AVAudioNode? {

        // Only an issue if engine is running, node is a mixer, and mixer has no inputs
        guard let mixer = node as? AVAudioMixerNode,
            engine.isRunning,
            !engine.mixerHasInputs(mixer: mixer) else {
                return nil
        }

        let dummy = AVAudioUnitSampler()
        engine.attach(dummy)
        engine.connect(dummy, to: mixer, format: AudioKit.format)
        return dummy
    }

    @objc open static func connect(_ sourceNode: AVAudioNode,
                                   to destNodes: [AVAudioConnectionPoint],
                                   fromBus sourceBus: AVAudioNodeBus,
                                   format: AVAudioFormat?) {

        let connectionsWithNodes = destNodes.filter { $0.node != nil }
        safeAttach([sourceNode] + connectionsWithNodes.map { $0.node! })
        // See addDummyOnEmptyMixer for dummyNode explanation.
        let dummyNode = addDummyOnEmptyMixer(sourceNode)
        checkMixerInputs(connectionsWithNodes)
        engine.connect(sourceNode, to: connectionsWithNodes, fromBus: sourceBus, format: format)
        dummyNode?.disconnectOutput()
    }

    @objc open static func connect(_ node1: AVAudioNode,
                                   to node2: AVAudioNode,
                                   fromBus bus1: AVAudioNodeBus,
                                   toBus bus2: AVAudioNodeBus,
                                   format: AVAudioFormat?) {

        safeAttach([node1, node2])
        // See addDummyOnEmptyMixer for dummyNode explanation.
        let dummyNode = addDummyOnEmptyMixer(node1)
        engine.connect(node1, to: node2, fromBus: bus1, toBus: bus2, format: format)
        dummyNode?.disconnectOutput()
    }

    @objc open static func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {
        connect(node1, to: node2, fromBus: 0, toBus: 0, format: format)
    }

    //Convenience
    @objc open static func detach(nodes: [AVAudioNode]) {
        for node in nodes {
            engine.detach(node)
        }
    }

    /// Render output to an AVAudioFile for a duration.
    ///     - Parameters
    ///         - audioFile: An file initialized for writing
    ///         - seconds: Duration to render
    ///         - prerender: A closure called before rendering starts, use this to start players, set initial parameters, etc...
    ///
    @available(iOS 11, macOS 10.13, tvOS 11, *)
    @objc open static func renderToFile(_ audioFile: AVAudioFile, seconds: Double, prerender: (() -> Void)? = nil) throws {
        try engine.renderToFile(audioFile, seconds: seconds, prerender: prerender)
    }

}

extension AVAudioEngine {

    /// Adding connection between nodes with default format
    open func connect(_ node1: AVAudioNode, to node2: AVAudioNode) {
        connect(node1, to: node2, format: AudioKit.format)
    }

    /// Render output to an AVAudioFile for a duration.
    ///     - Parameters
    ///         - audioFile: An file initialized for writing
    ///         - seconds: Duration to render
    ///         - prerender: A closure called before rendering starts, use this to start players, set initial parameters, etc...
    ///
    @available(iOS 11.0, macOS 10.13, tvOS 11.0, *)
    public func renderToFile(_ audioFile: AVAudioFile, seconds: Double, prerender: (() -> Void)? = nil) throws {
        guard seconds >= 0 else {
            throw NSError(domain: "AVAudioEngine ext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Seconds needs to be a positive value"])
        }
        try AKTry {
            // Engine can't be running when switching to offline render mode.
            if self.isRunning { self.stop() }
            try self.enableManualRenderingMode(.offline, format: audioFile.processingFormat, maximumFrameCount: 4_096)

            // This resets the sampleTime of offline rendering to 0.
            self.reset()
            try self.start()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: manualRenderingFormat, frameCapacity: manualRenderingMaximumFrameCount) else {
            throw NSError(domain: "AVAudioEngine ext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't create buffer in renderToFile"])
        }

        // This is for users to prepare the nodes for playing, i.e player.play()
        prerender?()

        // Render until file contains >= target samples
        let targetSamples = AVAudioFramePosition(seconds * manualRenderingFormat.sampleRate)
        while audioFile.framePosition < targetSamples {
            let framesToRender = min(buffer.frameCapacity, AVAudioFrameCount( targetSamples - audioFile.framePosition))
            let status = try renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                try audioFile.write(from: buffer)
            case .cannotDoInCurrentContext:
                AKLog("renderToFile cannotDoInCurrentContext")
                continue
            case .error, .insufficientDataFromInputNode:
                throw NSError(domain: "AVAudioEngine ext", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "renderToFile render error"])
            }
        }

        try AKTry {
            self.stop()
            self.disableManualRenderingMode()
        }
    }
}

extension AVAudioEngine {
    fileprivate func mixerHasInputs(mixer: AVAudioMixerNode) -> Bool {
        return (0..<mixer.numberOfInputs).contains {
            self.inputConnectionPoint(for: mixer, inputBus: $0) != nil
        }
    }
}
