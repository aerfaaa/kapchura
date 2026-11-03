import AVFoundation
import Combine
import Foundation

final class CameraEngine: NSObject, ObservableObject {
    enum CaptureMode: String, CaseIterable {
        case photo = "PHOTO"
        case video = "VIDEO"
    }

    let session = AVCaptureSession()

    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var status = "REQUESTING CAMERA ACCESS"
    @Published private(set) var latestMediaURL: URL?
    @Published private(set) var supportedFrameRates: [Double] = []
    @Published private(set) var rawPhotoSupported = false
    @Published var mode: CaptureMode = .video

    @Published var iso: Double = 100
    @Published var shutterSeconds: Double = 1.0 / 60.0
    @Published var focusPosition: Double = 0.5
    @Published var whiteBalanceKelvin: Double = 5200
    @Published var zoom: Double = 1

    private let sessionQueue = DispatchQueue(label: "com.aerfaaa.kapchura.capture")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var activeDevice: AVCaptureDevice?
    private var photoDelegate: PhotoCaptureDelegate?

    override init() {
        super.init()
        requestAccessAndConfigure()
    }

    private func requestAccessAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.publishStatus("CAMERA PERMISSION DENIED")
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.configureSession()
            }
        }
    }

    private func publishStatus(_ value: String) {
        DispatchQueue.main.async { self.status = value }
    }

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera],
                mediaType: .video,
                position: .back
            )
            guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
                    ?? discovery.devices.first,
                  let videoInput = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(videoInput) else {
                self.session.commitConfiguration()
                self.publishStatus("NO COMPATIBLE CAMERA FOUND")
                return
            }

            self.activeDevice = device
            self.session.addInput(videoInput)

            if let microphone = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: microphone),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
            }

            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }

            let rawAvailable = !self.photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
            let rates = Set(device.formats.flatMap { format in
                format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }
            }).sorted()

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.rawPhotoSupported = rawAvailable
                self.supportedFrameRates = rates
                self.iso = Double(device.iso)
                self.isReady = true
                self.status = rawAvailable ? "CAMERA READY · RAW PHOTO AVAILABLE" : "CAMERA READY"
            }
        }
    }

    func setZoom(_ value: Double) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            let bounded = min(max(value, 1), Double(device.activeFormat.videoMaxZoomFactor))
            device.videoZoomFactor = CGFloat(bounded)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoom = bounded }
        } catch {
            publishStatus("ZOOM CHANGE FAILED")
        }
    }

    func setISO(_ value: Double) {
        guard let device = activeDevice, device.isExposureModeSupported(.custom) else { return }
        let bounded = min(max(value, Double(device.activeFormat.minISO)),
                          Double(device.activeFormat.maxISO))
        applyExposure(device: device, duration: device.exposureDuration, iso: Float(bounded))
        DispatchQueue.main.async { self.iso = bounded }
    }

    func setShutter(_ seconds: Double) {
        guard let device = activeDevice, device.isExposureModeSupported(.custom) else { return }
        let minTime = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxTime = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let bounded = min(max(seconds, minTime), maxTime)
        let safeISO = min(max(iso, Double(device.activeFormat.minISO)),
                          Double(device.activeFormat.maxISO))
        let duration = CMTime(seconds: bounded, preferredTimescale: 1_000_000)
        applyExposure(device: device, duration: duration, iso: Float(safeISO))
        DispatchQueue.main.async { self.shutterSeconds = bounded }
    }

    private func applyExposure(device: AVCaptureDevice, duration: CMTime, iso: Float) {
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            publishStatus("EXPOSURE CHANGE FAILED")
        }
    }

    func setFocus(_ position: Double) {
        guard let device = activeDevice, device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: Float(min(max(position, 0), 1)),
                                      completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.focusPosition = position }
        } catch {
            publishStatus("FOCUS CHANGE FAILED")
        }
    }

    func setWhiteBalance(_ kelvin: Double) {
        guard let device = activeDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            let values = device.deviceWhiteBalanceGains(
                for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(kelvin), tint: 0
                )
            )
            let limit = device.maxWhiteBalanceGain
            let gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(values.redGain, 1), limit),
                greenGain: min(max(values.greenGain, 1), limit),
                blueGain: min(max(values.blueGain, 1), limit)
            )
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.whiteBalanceKelvin = kelvin }
        } catch {
            publishStatus("WHITE BALANCE CHANGE FAILED")
        }
    }

    func capture() {
        guard isReady else { return }
        if mode == .photo {
            let settings = AVCapturePhotoSettings()
            let delegate = PhotoCaptureDelegate { [weak self] url, error in
                DispatchQueue.main.async {
                    self?.photoDelegate = nil
                    if let url {
                        self?.latestMediaURL = url
                        self?.status = "PHOTO CAPTURED"
                    } else {
                        self?.status = error ?? "PHOTO CAPTURE FAILED"
                    }
                }
            }
            photoDelegate = delegate
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        } else {
            toggleRecording()
        }
    }

    private func toggleRecording() {
        guard !movieOutput.isRecording else {
            movieOutput.stopRecording()
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KAPCHURA-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        DispatchQueue.main.async {
            self.isRecording = true
            self.status = "RECORDING"
        }
    }
}

extension CameraEngine: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            if let error {
                self.status = "RECORDING FAILED · \(error.localizedDescription)"
            } else {
                self.latestMediaURL = outputFileURL
                self.status = "RECORDING COMPLETE"
            }
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (URL?, String?) -> Void

    init(completion: @escaping (URL?, String?) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            completion(nil, error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            completion(nil, "PHOTO DATA UNAVAILABLE")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KAPCHURA-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url, options: .atomic)
            completion(url, nil)
        } catch {
            completion(nil, error.localizedDescription)
        }
    }
}
