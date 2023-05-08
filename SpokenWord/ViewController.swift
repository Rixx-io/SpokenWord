/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The root view controller that provides a button to start and stop recording, and which displays the speech recognition results.
*/

import UIKit
import Speech
import Foundation
import dnssd
//import Network

public class ViewController: UIViewController, SFSpeechRecognizerDelegate {
    // MARK: Properties

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioEngine = AVAudioEngine()

    @IBOutlet var textView: UITextView!
    
    @IBOutlet var recordButton: UIButton!

    class ServiceHost {
        var view: ViewController
        var host: String
        var port: UInt16
        var sd: DNSServiceRef?
        var error: DNSServiceErrorType = 0
        var queryTimer: Timer?

        init(_ inview: ViewController, _ inhost: String, _ inport: UInt16) {
            view = inview
            host = inhost
            port = inport
            resolve()
        }

        deinit {
            if (queryTimer != nil) {
                queryTimer!.invalidate()
            }
            if (sd != nil) {
                DNSServiceRefDeallocate(sd)
            }
        }

        let queryReply: DNSServiceQueryRecordReply = { _, _, _, error, _, _, _, rdlen, rdata, _, context in
            let this: ServiceHost = Unmanaged.fromOpaque(context!).takeUnretainedValue()
            guard error == kDNSServiceErr_NoError else {
                this.error = error
                return
            }
            guard var offsetPointer = rdata else { return }

            let a = offsetPointer.load(as: UInt8.self)
            offsetPointer += 1
            let b = offsetPointer.load(as: UInt8.self)
            offsetPointer += 1
            let c = offsetPointer.load(as: UInt8.self)
            offsetPointer += 1
            let d = offsetPointer.load(as: UInt8.self)
            let addr = "\(a).\(b).\(c).\(d)"

            print("resolved \(this.host) -> \(addr)")

            var dt = this.view.dests.first(where: { return ($0.ip == addr && $0.port == this.port && $0.host == this.host) })
            if (dt == nil) {
                dt = Dest(addr, this.port, this.host)
                this.view.dests.append(dt!)
            }
        }

        func resolve() {
            DNSServiceQueryRecord(&sd, 0, 0, host, UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), queryReply, Unmanaged.passUnretained(self).toOpaque())

            queryTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                guard let sd = self.sd else { return }
                let sfd = DNSServiceRefSockFD(sd)
                guard sfd >= 0 else { return }
                let ev = Int16(POLLIN)
                var pollFD = pollfd(fd: sfd, events: ev, revents: 0)
                guard poll(&pollFD, 1, 0) > 0 else { return }
                let error = DNSServiceProcessResult(sd)
                if (error != 0) {
                    print("DNSServiceProcessResult(resolve) error: \(error)")
                }
            }
        }
    }
    
    class Dest {
        var ip = ""
        var port: UInt16 = 0
        var host = ""
        var sock: sockaddr_in
        var fd: Int32 = 0
        var createTime: Double = 0

        init(_ inip: String, _ inport: UInt16, _ inhost: String) {
            ip = inip
            host = inhost
            port = inport
            sock = sockaddr_in()
            createTime = Date().timeIntervalSince1970

            var ep = port
            if (NSHostByteOrder() == NS_LittleEndian) {
                ep = NSSwapShort(ep)
            }
            sock.sin_len = UInt8(MemoryLayout.size(ofValue: sock))
            sock.sin_family = sa_family_t(AF_INET)
            sock.sin_addr.s_addr = inet_addr(ip)
            sock.sin_port = ep

            fd = socket(AF_INET, SOCK_DGRAM, 0)  // DGRAM makes it UDP
        }

        deinit {
            if (fd != 0) {
                close(fd)
            }
        }
    }

    var hosts: [ServiceHost] = []
    var dests: [Dest] = []
    var currentDest: Dest?
//    var destIP = ""
//    var destPort: UInt16 = 0
//    var dest = sockaddr_in()
//    var fd: Int32 = 0
//    var destResolvedCount = 0

    // MARK: View Controller Lifecycle
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        
        // Disable the record buttons until authorization has been granted.
        recordButton.isEnabled = false
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Configure the SFSpeechRecognizer object already
        // stored in a local member variable.
        speechRecognizer.delegate = self
        
        // Asynchronously make the authorization request.
        SFSpeechRecognizer.requestAuthorization { authStatus in

            // Divert to the app's main thread so that the UI
            // can be updated.
            OperationQueue.main.addOperation {
                switch authStatus {
                case .authorized:
                    self.recordButton.isEnabled = true
                    
                case .denied:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("User denied access to speech recognition", for: .disabled)
                    
                case .restricted:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("Speech recognition restricted on this device", for: .disabled)
                    
                case .notDetermined:
                    self.recordButton.isEnabled = false
                    self.recordButton.setTitle("Speech recognition not yet authorized", for: .disabled)
                    
                default:
                    self.recordButton.isEnabled = false
                }
            }
        }

        self.udpSetup()
        do {
            try startRecording()
        } catch {
            recordButton.setTitle("Microphone Not Available", for: [])
        }
    }
    
    var utteranceID: Int32 = 0
    var lastString = ""
    var lastSpeakTime = Date()
    var lastSentWasFull = false
    var lastFullString = ""

    private func startRecording() throws {
        
        // Cancel the previous task if it's running.
        recognitionTask?.cancel()
        self.recognitionTask = nil

        recordButton.setTitle("Stop Listening", for: [])

        self.utteranceID += 1
        self.lastString = ""
        self.lastSpeakTime = Date()
        self.lastSentWasFull = false
        self.lastFullString = ""

        // Configure the audio session for the app.
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        let inputNode = audioEngine.inputNode

        // Create and configure the speech recognition request.
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else { fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object") }
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.contextualStrings = ["Bee Dee Two", "Judy", "meow", "Grogu"]

       if #available(iOS 16, *) {
           recognitionRequest.addsPunctuation = true
       }
        
        // Keep speech recognition data on device
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = true
        }
        
        // Configure the microphone input.
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self.recognitionRequest?.append(buffer)
        }

        // Create a recognition task for the speech recognition session.
        // Keep a reference to the task so that it can be canceled.
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { result, error in
            var isFinal = false

            if let result = result {
                isFinal = result.isFinal
    
                // use jitter and shimmer to determine if background noise, multiple people talking, and ignore
                // https://developer.apple.com/documentation/speech/sfvoiceanalytics
                // result.speechRecognitionMetadata.voiceAnalytics.jitter.acousticFeatureValuePerFrame[Double, ...]

                // result.bestTranscription.segments[SFTranscriptionSegment, ...]
                // https://developer.apple.com/documentation/speech/sftranscriptionsegment

                // can use speechRecognitionMetadata == null to detect partials
                if !isFinal {  // happens when listening stopped

//                    let now = Date()
//                    let elapsedSince = now.timeIntervalSince(self.lastSpeakTime)
                    self.lastSpeakTime = Date()

                    var thisIsFull = true
                    if #available(iOS 14, *) {
                        thisIsFull = result.speechRecognitionMetadata != nil
                    }

                    // print("elapsedSince \(elapsedSince)")
                    print("thisIsFull \(thisIsFull)")
                    print("bestTranscription \(result.bestTranscription.formattedString)")

                    // new phrase because enough time has passed since the last
                    var send = false
                    // if (elapsedSince >= 2) {
                    //     send = true
                    // }
                    // not much time but the phrase has changed
                    if (result.bestTranscription.formattedString != self.lastString) {
                        send = true
                    // } else {
                    //     // phrase hasn't changed, but edge case repeated short phrase; eg, "Yes." "Yes."
                    //     if (thisIsFull && result.bestTranscription.formattedString == self.lastFullString) {
                    //         send = true
                    //     }
                    }

                    if (send) {
                        // Update the text view with the results.
                        self.textView.text = result.bestTranscription.formattedString
                        print(result.bestTranscription.formattedString)
                        self.udpSend(self.udpDescription(id: self.utteranceID, transcription: result.bestTranscription.formattedString))
                        self.lastSentWasFull = thisIsFull
                    }

                    if (thisIsFull) {
                        self.lastString = ""
                        // self.lastFullString = result.bestTranscription.formattedString
                    } else {
                        self.lastString = result.bestTranscription.formattedString
                    }
                }
            }

            if error != nil || isFinal {
                // Stop recognizing speech if there is a problem.
                self.audioEngine.stop()
                inputNode.removeTap(onBus: 0)

                self.recognitionRequest = nil
                self.recognitionTask = nil

                self.recordButton.isEnabled = true
                self.recordButton.setTitle("Start Listening", for: [])
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        
        // Let the user know to start talking.
        textView.text = "(Start speaking)"
    }
    
    // MARK: SFSpeechRecognizerDelegate
    
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        if available {
            recordButton.isEnabled = true
            recordButton.setTitle("Start Listening", for: [])
        } else {
            recordButton.isEnabled = false
            recordButton.setTitle("Recognition Not Available", for: .disabled)
        }
    }
    
    // MARK: Interface Builder actions
    
    @IBAction func recordButtonTapped() {
        if audioEngine.isRunning {
            audioEngine.stop()
            recognitionRequest?.endAudio()
            recordButton.isEnabled = false
            recordButton.setTitle("Stopping", for: .disabled)
        } else {
            do {
                try startRecording()
            } catch {
                recordButton.setTitle("Microphone Not Available", for: [])
            }
        }
    }

    // UDP export
    func udpDescription(id: Int32, transcription: String) -> String {
        var d: [String: Any] = [:]

        d["utteranceID"] = id
        d["text"] = transcription

        let j = try! JSONSerialization.data(withJSONObject: d, options: [])
        return String(data: j, encoding: .utf8)!
    }

    var resolvedError: Int = 0

    private let _resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, port, _, _, context in
        let this: ViewController = Unmanaged.fromOpaque(context!).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError else {
            this.resolvedError = Int(error)
            print("_resolveReply error: \(error)")
            return
        }
        
        let host = String(cString: host!)
        let port = UInt16(bigEndian: port)
        var h = this.hosts.first(where: { return ($0.host == host && $0.port == port) })
        if (h == nil) {
            h = ServiceHost(this, host, port)
            this.hosts.append(h!)
        }
    }

    var resolveSR: DNSServiceRef?

    func udpSetup() {
        let error = DNSServiceResolve(&resolveSR, 0, 0, "speech-receiver", "_x-plane9._udp", "local", _resolveReply, Unmanaged.passUnretained(self).toOpaque())
        if error != 0 {
            print("error looking for proxy: \(error)")
        }

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            guard let sd = self.resolveSR else { return }
            let sfd = DNSServiceRefSockFD(sd)
            guard sfd >= 0 else { return }
            let ev = Int16(POLLIN)
            var pollFD = pollfd(fd: sfd, events: ev, revents: 0)
            guard poll(&pollFD, 1, 0) > 0 else { return }
            let error = DNSServiceProcessResult(sd)
            if (error != 0) {
                print("DNSServiceProcessResult error: \(error)")
            }
        }


//        fd = socket(AF_INET, SOCK_DGRAM, 0) // DGRAM makes it UDP

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            self.udpSend("ping")
        }
    }

    deinit {
        if (resolveSR != nil) {
            DNSServiceRefDeallocate(resolveSR)
        }
    }

    func udpSend(_ textToSend: String) {
        if (dests.count == 0) {
            print("no dests")
            return
        }
        
        var bestDest = dests[0]
        for dst in dests {
            let timediff = dst.createTime - bestDest.createTime
            // consider them registered at the same time if within a small delta
            if (abs(timediff) < 2) {
                // prefer link local
                if (dst.ip.starts(with: "169.254")) {
                    bestDest = dst
                }
                // if this one's newer then take it
            } else if (timediff > 0) {
                bestDest = dst
            }
        }

        if (bestDest !== currentDest) {
            currentDest = bestDest
            print("sending to \(currentDest!.ip):\(currentDest!.port)")
        }
        
        textToSend.withCString { cstr -> () in
            var dst = currentDest!.sock
            withUnsafePointer(to: &dst) { pointer -> () in
                let memory = UnsafeRawPointer(pointer).bindMemory(to: sockaddr.self, capacity: 1)
                sendto(currentDest!.fd, cstr, strlen(cstr), 0, memory, socklen_t(currentDest!.sock.sin_len))
            }
        }
    }

}

