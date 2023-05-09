/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The root view controller that provides a button to start and stop recording, and which displays the speech recognition results.
*/

import UIKit
import Speech
import Foundation

public class ViewController: UIViewController, SFSpeechRecognizerDelegate {
    // MARK: Properties

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    
    private var recognitionTask: SFSpeechRecognitionTask?
    
    private let audioEngine = AVAudioEngine()

    @IBOutlet var textView: UITextView!
    
    @IBOutlet var recordButton: UIButton!

    @IBOutlet var connectionIndicator: UILabel!


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

    var finder: ServiceFinder?
    var connected = false
    var currentDest: Dest?

    func udpSetup() {
        finder = ServiceFinder("speech-receiver")

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            let dest = self.finder!.bestDest()
            if (dest != nil) {
                if (!self.connected) {
                    self.connected = true
                    self.connectionIndicator.text = "🟢"
                }
            } else {
                if (self.connected) {
                    self.connected = false
                    self.connectionIndicator.text = "🔴"
                }
                
            }
            self.udpSend("ping")
        }
    }

    func udpSend(_ textToSend: String) {
        let bestDest = finder!.bestDest()
        if (bestDest !== currentDest) {
            currentDest = bestDest
            if (currentDest != nil) {
                print("Connected to \(currentDest!.ip):\(currentDest!.port)")
            } else {
                print("No connection!")
            }
        }
        if (currentDest == nil) {
            return
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

