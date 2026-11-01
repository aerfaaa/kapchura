import SwiftUI
import AVFoundation
import Photos
import UIKit

@MainActor
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate {
    @Published var isReady = false
    @Published var isRecording = false
    @Published var recordingBusy = false
    @Published var stabilizationSupported = false
    @Published var stabilizationMessage = ""
    @Published var isManualFocus = false
    @Published var isTelephoto = false
    @Published var message = "Starting camera…"
    @Published var lensLabel = "1×"
    @Published var iso: Double = 100
    @Published var shutter: Double = 1.0 / 60.0
    @Published var focus: Double = 0.5
    @Published var temperature: Double = 5200
    @Published var rawStillAvailable = false
    @Published var rawPixelFormatCount = 0
    @Published var availableFormats: [String] = []
    @Published var recordingURL: URL?
    @Published var resolution = "1080p"
    @Published var frameRate = 24
    @Published var stabilization = "Off"
    @Published var settingsCollapsed = true
    @Published var isoAutomatic = true
    @Published var shutterAutomatic = true
    @Published var focusAutomatic = true
    @Published var whiteBalanceAutomatic = true
    @Published var supportedFrameRates: [Int] = [24]
    @Published var profileStatus = "1080p · 24 FPS"

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.aerfaaa.kapchura.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var activeDevice: AVCaptureDevice?
    private var wideDevice: AVCaptureDevice?
    private var teleDevice: AVCaptureDevice?

    override init() {
        super.init()
        requestPermissionsAndConfigure()
    }

    private func requestPermissionsAndConfigure() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                Task { @MainActor in self.message = "Camera permission is required." }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                // AVFoundation invokes permission callbacks on an arbitrary queue.
                // CameraEngine is MainActor-isolated, so hop back before touching it.
                Task { @MainActor in
                    self?.configureSession()
                }
            }
        }
    }

    private func configureSession() {
        // Keep all CameraEngine state and helper access on MainActor.
        // The previous implementation entered sessionQueue and then called
        // MainActor-isolated methods/properties from that background queue.
            self.session.beginConfiguration()
            self.session.sessionPreset = .inputPriority
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera],
                mediaType: .video,
                position: .back
            )
            self.wideDevice = discovery.devices.first { $0.deviceType == .builtInWideAngleCamera }
            self.teleDevice = discovery.devices.first { $0.deviceType == .builtInTelephotoCamera }
            guard let device = self.wideDevice ?? discovery.devices.first,
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                Task { @MainActor in self.message = "No compatible camera found." }
                return
            }
            self.session.addInput(input)
            self.activeDevice = device
            self.applyCaptureProfile(resolution: self.resolution, fps: self.frameRate, to: device)

            if let mic = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: mic),
               self.session.canAddInput(audioInput) {
                self.session.addInput(audioInput)
            }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            let rawTypes = self.photoOutput.availableRawPhotoPixelFormatTypes
            let formats = device.formats.map { format -> String in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return "\(dimensions.width)×\(dimensions.height) · up to \(Int(fps)) fps"
            }
            self.session.commitConfiguration()
            self.updateStabilizationSupport()
            self.session.startRunning()
            let rates = self.frameRates(for: device, resolution: self.resolution)
            Task { @MainActor in
                self.supportedFrameRates = rates
                self.rawPixelFormatCount = rawTypes.count
                self.rawStillAvailable = !rawTypes.isEmpty
                self.availableFormats = Array(Set(formats)).sorted()
                self.iso = Double(device.iso)
                self.focus = Double(device.lensPosition)
                self.isReady = true
                self.message = rawTypes.isEmpty ? "Camera ready · RAW still unavailable" : "Camera ready · RAW still supported"
            }
    }

    func switchLens(telephoto: Bool) {
        guard !isRecording else {
            message = "Stop recording before switching lenses."
            return
        }
        sessionQueue.async {
            guard let target = telephoto ? self.teleDevice : self.wideDevice else {
                Task { @MainActor in self.message = telephoto ? "Telephoto camera unavailable." : "Wide camera unavailable." }
                return
            }
            guard target.uniqueID != self.activeDevice?.uniqueID else { return }
            do {
                let newInput = try AVCaptureDeviceInput(device: target)
                self.session.beginConfiguration()
                guard let oldInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.hasMediaType(.video) }) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.activeDevice = target
                    self.applyCaptureProfile(resolution: self.resolution, fps: self.frameRate, to: target)
                    self.session.commitConfiguration()
                    self.updateStabilizationSupport()
                    let rawCount = self.photoOutput.availableRawPhotoPixelFormatTypes.count
                    let availableRates = self.frameRates(for: target, resolution: self.resolution)
                    Task { @MainActor in
                        self.isTelephoto = telephoto
                        self.supportedFrameRates = availableRates
                        self.lensLabel = telephoto ? "2× TELE" : "1× WIDE"
                        self.rawPixelFormatCount = rawCount
                        self.rawStillAvailable = rawCount > 0
                        self.iso = Double(target.iso)
                        self.focus = Double(target.lensPosition)
                        self.message = telephoto ? "Telephoto lens active" : "Wide lens active"
                    }
                } else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    Task { @MainActor in self.message = "Unable to switch camera lens." }
                }
            } catch {
                Task { @MainActor in self.message = "Lens switch failed: \(error.localizedDescription)" }
            }
        }
    }

    private func frameRates(for device: AVCaptureDevice, resolution: String) -> [Int] {
        let formats = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if resolution == "4K" { return d.width >= 3840 || d.height >= 2160 }
            if resolution == "1080p" { return d.width >= 1920 || d.height >= 1080 }
            return true
        }
        let cap = resolution == "1080p" ? 30 : 24
        let rates = Set(formats.flatMap { format in
            format.videoSupportedFrameRateRanges.flatMap { range in
                [24, 25, 30].filter { $0 <= cap && Double($0) >= range.minFrameRate && Double($0) <= range.maxFrameRate }
            }
        })
        return rates.sorted()
    }

    private func formatScore(_ format: AVCaptureDevice.Format, resolution: String) -> Double {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let width = Double(dimensions.width)
        let height = Double(dimensions.height)
        let area = width * height
        let aspect = width / max(height, 1)
        if resolution == "Open Gate" { return -area }
        let targetArea = resolution == "4K" ? 3840.0 * 2160.0 : 1920.0 * 1080.0
        let targetAspect = 16.0 / 9.0
        return abs(log(max(area, 1) / targetArea)) + abs(aspect - targetAspect) * 2.0
    }

    private func applyCaptureProfile(resolution: String, fps: Int, to device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let sizeOK = resolution == "Open Gate" || (resolution == "4K" ? (d.width >= 3840 || d.height >= 2160) : (d.width >= 1920 || d.height >= 1080))
            return sizeOK && format.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }
        let chosenFormat = candidates.min {
            formatScore($0, resolution: resolution) < formatScore($1, resolution: resolution)
        }
        guard let chosen = chosenFormat else {
            Task { @MainActor in self.message = "\(resolution) at \(fps) FPS is unavailable on this lens." }
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            // Avoid optional device-level HDR/low-light controls here.
            // On some iOS 18 devices these can trigger an internal
            // AVCaptureDevice.systemPressureState exception during startup.
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
            Task { @MainActor in
                self.profileStatus = "\(d.width)×\(d.height) · \(fps) FPS"
                self.message = "Capture profile: \(self.profileStatus)"
            }
        } catch {
            Task { @MainActor in self.message = "Could not apply format: \(error.localizedDescription)" }
        }
    }

    func setResolution(_ value: String) {
        guard !isRecording, let device = activeDevice else { message = "Stop recording before changing resolution."; return }
        let rates = frameRates(for: device, resolution: value)
        guard !rates.isEmpty else { message = "\(value) is unavailable on this lens."; return }
        let preferred = value == "1080p" ? 30 : 24
        let fps = rates.contains(preferred) ? preferred : (rates.last ?? 24)
        resolution = value
        frameRate = fps
        supportedFrameRates = rates
        applyCaptureProfile(resolution: value, fps: fps, to: device)
    }

    func setFrameRate(_ value: Int) {
        guard !isRecording, let device = activeDevice else { message = "Stop recording before changing FPS."; return }
        guard supportedFrameRates.contains(value) else { message = "\(value) FPS is unavailable."; return }
        frameRate = value
        applyCaptureProfile(resolution: resolution, fps: value, to: device)
    }

    private func updateStabilizationSupport() {
        guard let device = activeDevice else { return }
        let standard = device.activeFormat.isVideoStabilizationModeSupported(.standard)
        let cinematic = device.activeFormat.isVideoStabilizationModeSupported(.cinematic)
        Task { @MainActor in
            self.stabilizationSupported = standard || cinematic
            if !self.stabilizationSupported {
                self.stabilization = "Off"
                self.stabilizationMessage = "Stabilisation unsupported on this camera format."
            } else { self.stabilizationMessage = "" }
        }
    }

    private func applyStabilization(to connection: AVCaptureConnection, device: AVCaptureDevice) {
        // Never let AVFoundation silently re-enable stabilisation when the user chooses Off.
        if stabilization == "Off" {
            connection.preferredVideoStabilizationMode = .off
            stabilizationMessage = "Stabilisation disabled."
            return
        }
        guard connection.isVideoStabilizationSupported else {
            stabilization = "Off"
            connection.preferredVideoStabilizationMode = .off
            stabilizationMessage = "Stabilisation unsupported; left fully off."
            return
        }
        let requested: AVCaptureVideoStabilizationMode = stabilization == "Maximum" ? .cinematic : .standard
        let format = device.activeFormat
        let actual: AVCaptureVideoStabilizationMode
        if requested == .off || format.isVideoStabilizationModeSupported(requested) {
            actual = requested
        } else if requested == .cinematic && format.isVideoStabilizationModeSupported(.standard) {
            actual = .standard
            stabilizationMessage = "Maximum unavailable; using Standard."
        } else {
            actual = .off
            stabilization = "Off"
            stabilizationMessage = "Selected mode unavailable for this lens."
        }
        connection.preferredVideoStabilizationMode = actual
    }

    func setStabilization(_ value: String) {
        stabilization = value
        guard let device = activeDevice else {
            stabilizationMessage = "Camera is not ready."
            return
        }
        guard let connection = movieOutput.connection(with: .video) else {
            if value == "Off" {
                stabilizationMessage = "Stabilisation disabled for preview and next recording."
                return
            }
            stabilizationMessage = "Recording connection is not ready."
            return
        }
        applyStabilization(to: connection, device: device)
        let active = connection.preferredVideoStabilizationMode
        stabilizationMessage = active == .off ? "Stabilisation: Off" : (active == .standard ? "Stabilisation: Standard" : "Stabilisation: Cinematic")
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, 1), device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {
            message = "Unable to change zoom: \(error.localizedDescription)"
        }
    }

    func setISO(_ value: Double) {
        guard let device = activeDevice, device.isExposureModeSupported(.custom) else { return }
        let bounded = Float(min(max(value, Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO)))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: device.exposureDuration, iso: bounded, completionHandler: nil)
            isoAutomatic = false
            shutterAutomatic = false
            device.unlockForConfiguration()
            iso = Double(bounded)
        } catch { message = "ISO change failed." }
    }

    func setShutter(_ seconds: Double) {
        guard let device = activeDevice, device.isExposureModeSupported(.custom) else { return }
        let minDuration = CMTimeGetSeconds(device.activeFormat.minExposureDuration)
        let maxDuration = CMTimeGetSeconds(device.activeFormat.maxExposureDuration)
        let bounded = min(max(seconds, minDuration), maxDuration)
        let safeISO = Float(min(max(iso, Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO)))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: CMTime(seconds: bounded, preferredTimescale: 1_000_000),
                                         iso: safeISO, completionHandler: nil)
            isoAutomatic = false
            shutterAutomatic = false
            device.unlockForConfiguration()
            shutter = bounded
        } catch { message = "Shutter change failed." }
    }

    func setManualFocus(_ position: Float) {
        guard let device = activeDevice, device.isFocusModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            device.unlockForConfiguration()
            focusAutomatic = false
            isManualFocus = true
            focus = Double(position)
        } catch { message = "Manual focus change failed." }
    }

    func setAutofocus() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
            isManualFocus = false
            focusAutomatic = true
            message = "Continuous autofocus enabled"
        } catch { message = "Unable to enable autofocus." }
    }

    func enableManualFocus() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            guard device.isFocusModeSupported(.locked) else {
                device.unlockForConfiguration()
                message = "Manual focus unavailable on this camera."
                return
            }
            device.setFocusModeLocked(lensPosition: Float(focus), completionHandler: nil)
            device.unlockForConfiguration()
            isManualFocus = true
            message = "Manual focus enabled"
        } catch { message = "Unable to enable manual focus." }
    }

    func setWhiteBalance(_ kelvin: Double) {
        guard let device = activeDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            let values = device.deviceWhiteBalanceGains(for: .init(temperature: Float(kelvin), tint: 0))
            let maxGain = device.maxWhiteBalanceGain
            let gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(values.redGain, 1), maxGain),
                greenGain: min(max(values.greenGain, 1), maxGain),
                blueGain: min(max(values.blueGain, 1), maxGain)
            )
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
            whiteBalanceAutomatic = false
            temperature = kelvin
        } catch { message = "White balance change failed." }
    }

    func setWhiteBalanceAutomatic() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.unlockForConfiguration()
            whiteBalanceAutomatic = true
        } catch { message = "Unable to enable automatic white balance." }
    }

    func setExposureAutomatic() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
            isoAutomatic = true
            shutterAutomatic = true
        } catch { message = "Unable to enable automatic exposure." }
    }

    func captureRAWPhoto() {
        guard isReady, rawStillAvailable,
              let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            message = "RAW still capture is not supported by the active camera."
            return
        }
        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        photoOutput.capturePhoto(with: settings, delegate: self)
        message = "Capturing RAW photo…"
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        if let error {
            Task { @MainActor in self.message = "Photo capture failed: \(error.localizedDescription)" }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            Task { @MainActor in self.message = "Could not create photo file." }
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self.message = "Allow Photos access to save the captured image." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { success, saveError in
                Task { @MainActor in
                    self.message = success ? "RAW photo saved to Photos." :
                        "Photo save failed: \(saveError?.localizedDescription ?? "unknown error")"
                }
            }
        }
    }

    func startStopRecording() {
        guard isReady, !recordingBusy else { return }
        recordingBusy = true

        if isRecording {
            sessionQueue.async {
                if self.movieOutput.isRecording {
                    self.movieOutput.stopRecording()
                } else {
                    Task { @MainActor in self.recordingBusy = false }
                }
            }
            return
        }

        guard let connection = movieOutput.connection(with: .video),
              let device = activeDevice else {
            recordingBusy = false
            message = "Video recording connection is unavailable."
            return
        }
        // Configure the connection on the main actor before handing recording
        // start/stop operations to the serial capture queue.
        applyStabilization(to: connection, device: device)
        let output = movieOutput
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KAPCHURA-\(UUID().uuidString).mov")

        sessionQueue.async {
            guard !output.isRecording else {
                Task { @MainActor in
                    self.recordingBusy = false
                    self.message = "Recorder is already active."
                }
                return
            }
            output.startRecording(to: destination, recordingDelegate: self)
            Task { @MainActor in
                self.recordingURL = nil
                self.message = "Starting recording…"
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didStartRecordingTo fileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            self.isRecording = true
            self.recordingBusy = false
            self.message = "Recording · \(self.profileStatus)"
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // Keep finalisation small: do not begin a Photos transaction while AVFoundation
        // is completing the movie. The user can save the finished file explicitly.
        let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)
        let fileSize = (fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
        let nsError = error as NSError?
        let finishedSuccessfully = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true

        Task { @MainActor in
            self.isRecording = false
            self.recordingBusy = false

            guard fileExists, fileSize > 0 else {
                self.recordingURL = nil
                self.message = error.map { "Recording failed: \($0.localizedDescription)" }
                    ?? "Recording ended without a usable video file."
                return
            }

            self.recordingURL = outputFileURL
            if let error, !finishedSuccessfully {
                self.message = "Video recovered with a warning: \(error.localizedDescription)"
            } else {
                self.message = "Recording finished · video kept in KAPCHURA"
            }
        }
    }

    func saveFinishedRecordingToPhotos() {
        guard let url = recordingURL,
              FileManager.default.fileExists(atPath: url.path) else {
            message = "No finished video is available to save."
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in self?.message = "Allow Photos access to save this video." }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, saveError in
                Task { @MainActor in
                    guard let self else { return }
                    self.message = success
                        ? "Video saved to Photos."
                        : "Video remains in KAPCHURA files. Save failed: \(saveError?.localizedDescription ?? "unknown error")"
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let stabilization: String

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        applyPreviewStabilization(view.previewLayer.connection)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspectFill
        applyPreviewStabilization(uiView.previewLayer.connection)
    }

    private func applyPreviewStabilization(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        switch stabilization {
        case "Minimal":
            connection.preferredVideoStabilizationMode = connection.isVideoStabilizationSupported ? .standard : .off
        case "Maximum":
            connection.preferredVideoStabilizationMode = connection.isVideoStabilizationSupported ? .cinematic : .off
        default:
            connection.preferredVideoStabilizationMode = .off
        }
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraEngine()
    @State private var showQuickSettings = false
    @State private var gridEnabled = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let openGate = camera.resolution == "Open Gate"
            let previewRatio: CGFloat = landscape
                ? (openGate ? 4.0 / 3.0 : 16.0 / 9.0)
                : (openGate ? 3.0 / 4.0 : 9.0 / 16.0)

            ZStack {
                Color.black.ignoresSafeArea()

                // A second, enlarged and blurred preview fills the unused aspect-ratio
                // space so the viewfinder blends into the screen instead of hard black bars.
                CameraPreview(session: camera.session, stabilization: camera.stabilization)
                    .aspectRatio(previewRatio, contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .blur(radius: 34)
                    .scaleEffect(1.18)
                    .overlay(Color.black.opacity(0.34))
                    .ignoresSafeArea()

                CameraPreview(session: camera.session, stabilization: camera.stabilization)
                    .aspectRatio(previewRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(.spring(response: 0.38, dampingFraction: 0.88), value: camera.resolution)

                if gridEnabled {
                    CameraGridOverlay()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if landscape {
                    // Landscape gets a genuinely different control layout:
                    // status at the upper-left, shutter/settings dock on the right.
                    HStack(alignment: .top, spacing: 0) {
                        statusBar
                            .padding(.leading, 18)
                            .padding(.top, 7)

                        Spacer(minLength: 12)

                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            if !camera.settingsCollapsed {
                                settingsPanel(landscape: true)
                                    .frame(maxWidth: 300)
                                    .padding(.bottom, 12)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                            bottomCameraBar(landscape: true)
                                .padding(.trailing, 12)
                                .padding(.bottom, 10)
                        }
                        .frame(width: camera.settingsCollapsed ? 86 : 320)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        statusBar
                            .padding(.horizontal, 20)
                            .padding(.top, max(geometry.safeAreaInsets.top, 10) + 2)

                        Spacer(minLength: 12)

                        if !camera.settingsCollapsed {
                            settingsPanel(landscape: false)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 8)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }

                        bottomCameraBar(landscape: false)
                            .padding(.horizontal, 20)
                            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .ignoresSafeArea()
            .background(Color.black)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(isPresented: $showQuickSettings) {
            quickSettingsSheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .onAppear { camera.settingsCollapsed = true }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            HStack(spacing: 7) {
                Circle()
                    .fill(camera.isRecording ? Color.red : Color.white.opacity(0.72))
                    .frame(width: 6, height: 6)
                Text(camera.isRecording ? "REC" : camera.profileStatus)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .liquidGlassCapsule()

            HStack(spacing: 5) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("L")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Capsule().fill(camera.isRecording ? Color.green : Color.white.opacity(0.42))
                    .frame(width: 10, height: 3)
                Text("R")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                Capsule().fill(camera.isRecording ? Color.green : Color.white.opacity(0.42))
                    .frame(width: 10, height: 3)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .liquidGlassCapsule()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showQuickSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .liquidGlassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Additional camera settings")
        }
    }

    private var quickSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("Viewfinder") {
                    Toggle("Rule of thirds grid", isOn: $gridEnabled)
                }
                Section("Image rendering") {
                    Label("HDR recording is disabled where supported.", systemImage: "sun.max")
                    Label("Low-light boost is disabled where supported.", systemImage: "moon")
                    Text("iOS still applies sensor processing, including demosaicing, noise reduction and sharpening. These controls reduce some automatic processing, but cannot turn the iPhone camera into a completely unprocessed sensor feed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Camera Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showQuickSettings = false }
                }
            }
        }
    }

    private func bottomCameraBar(landscape: Bool) -> some View {
        Group {
            if landscape {
                VStack(spacing: 14) {
                    recordButton
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                            camera.settingsCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: camera.settingsCollapsed ? "chevron.left" : "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                            .liquidGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(camera.settingsCollapsed ? "Show camera settings" : "Hide camera settings")
                }
                .padding(.vertical, 14)
            } else {
                HStack(alignment: .center, spacing: 0) {
                    Color.clear.frame(width: 54, height: 54)
                    Spacer(minLength: 0)
                    recordButton
                    Spacer(minLength: 0)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                            camera.settingsCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: camera.settingsCollapsed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .liquidGlassCircle()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(camera.settingsCollapsed ? "Show camera settings" : "Hide camera settings")
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func settingsPanel(landscape: Bool) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("CAMERA SETTINGS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(.white.opacity(0.66))
                Spacer()
                Button("Done") {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                        camera.settingsCollapsed = true
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            }

            HStack(spacing: 8) {
                settingChip("1080p", selected: camera.resolution == "1080p") { camera.setResolution("1080p") }
                settingChip("4K", selected: camera.resolution == "4K") { camera.setResolution("4K") }
                settingChip("OPEN GATE", selected: camera.resolution == "Open Gate") { camera.setResolution("Open Gate") }

                Menu {
                    ForEach(camera.supportedFrameRates, id: \.self) { rate in
                        Button("\(rate) FPS") { camera.setFrameRate(rate) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("\(camera.frameRate) FPS")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .liquidGlassCapsule()
                }
                .disabled(camera.isRecording || camera.supportedFrameRates.isEmpty)
            }

            HStack(spacing: 10) {
                Menu {
                    Button("Off") { camera.setStabilization("Off") }
                    Button("Minimal") { camera.setStabilization("Minimal") }
                    Button("Maximum") { camera.setStabilization("Maximum") }
                } label: {
                    settingMenuLabel("STABILISATION", value: camera.stabilization)
                }
                .disabled(camera.isRecording)

                Menu {
                    Button("1× Wide") { camera.switchLens(telephoto: false) }
                    Button("2× Telephoto") { camera.switchLens(telephoto: true) }
                } label: {
                    settingMenuLabel("LENS", value: camera.isTelephoto ? "2× Tele" : "1× Wide")
                }
            }

            if landscape {
                HStack(spacing: 12) {
                    sliderRow("ISO", value: $camera.iso, range: 25...1600, valueText: String(Int(camera.iso)), automatic: camera.isoAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setISO($0) }
                    sliderRow("FOCUS", value: $camera.focus, range: 0...1, valueText: String(format: "%.2f", camera.focus), automatic: camera.focusAutomatic, autoAction: { camera.setAutofocus() }) { camera.setManualFocus(Float($0)) }
                }
                HStack(spacing: 12) {
                    sliderRow("SHUTTER", value: $camera.shutter, range: 1.0/1000...1.0/15, valueText: "1/\(Int(1 / max(camera.shutter, 0.001)))", automatic: camera.shutterAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setShutter($0) }
                    sliderRow("WHITE BAL.", value: $camera.temperature, range: 2500...8000, valueText: "\(Int(camera.temperature))K", automatic: camera.whiteBalanceAutomatic, autoAction: { camera.setWhiteBalanceAutomatic() }) { camera.setWhiteBalance($0) }
                }
            } else {
                VStack(spacing: 10) {
                    sliderRow("ISO", value: $camera.iso, range: 25...1600, valueText: String(Int(camera.iso)), automatic: camera.isoAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setISO($0) }
                    sliderRow("SHUTTER", value: $camera.shutter, range: 1.0/1000...1.0/15, valueText: "1/\(Int(1 / max(camera.shutter, 0.001)))", automatic: camera.shutterAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setShutter($0) }
                    sliderRow("FOCUS", value: $camera.focus, range: 0...1, valueText: String(format: "%.2f", camera.focus), automatic: camera.focusAutomatic, autoAction: { camera.setAutofocus() }) { camera.setManualFocus(Float($0)) }
                    sliderRow("WHITE BAL.", value: $camera.temperature, range: 2500...8000, valueText: "\(Int(camera.temperature))K", automatic: camera.whiteBalanceAutomatic, autoAction: { camera.setWhiteBalanceAutomatic() }) { camera.setWhiteBalance($0) }
                }
            }

            Text(camera.stabilizationMessage.isEmpty ? camera.message : camera.stabilizationMessage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if camera.recordingURL != nil {
                Button {
                    camera.saveFinishedRecordingToPhotos()
                } label: {
                    Label("Save last video to Photos", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .liquidGlassRounded()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: landscape ? 620 : .infinity)
        .liquidGlassPanel()
    }

    private func settingChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(selected ? .black : .white)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .background {
                    Capsule().fill(selected ? Color.white : Color.white.opacity(0.08))
                }
                .overlay(Capsule().stroke(.white.opacity(selected ? 0 : 0.18), lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
    }

    private func settingMenuLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.52))
            HStack(spacing: 6) {
                Text(value).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlassRounded()
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           valueText: String, automatic: Bool, autoAction: @escaping () -> Void,
                           changed: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 65, alignment: .leading)
            TactileDial(value: value, range: range, step: dialStep(for: title)) { newValue in
                changed(newValue)
            }
            .frame(height: 30)
            Text(valueText)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 42, alignment: .trailing)
            Button(action: autoAction) {
                Text("A")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(automatic ? .black : .white)
                    .frame(width: 22, height: 22)
                    .background(automatic ? Color.white : Color.white.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 28)
    }

    private func dialStep(for title: String) -> Double {
        switch title {
        case "ISO": return 5
        case "FOCUS": return 0.01
        case "SHUTTER": return 1.0 / 120
        default: return 50
        }
    }

    private var recordButton: some View {
        Button {
            camera.startStopRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 78, height: 78)
                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 2.2)
                    .frame(width: 66, height: 66)
                RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 30)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 24 : 52,
                           height: camera.isRecording ? 24 : 52)
                    .animation(.spring(response: 0.25, dampingFraction: 0.78), value: camera.isRecording)
            }
            .frame(width: 82, height: 82)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.isReady || camera.recordingBusy)
        .opacity(camera.isReady ? 1 : 0.45)
        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Start recording")
    }
}

private struct CameraGridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let thirdX = geometry.size.width / 3
                let thirdY = geometry.size.height / 3
                path.move(to: CGPoint(x: thirdX, y: 0))
                path.addLine(to: CGPoint(x: thirdX, y: geometry.size.height))
                path.move(to: CGPoint(x: thirdX * 2, y: 0))
                path.addLine(to: CGPoint(x: thirdX * 2, y: geometry.size.height))
                path.move(to: CGPoint(x: 0, y: thirdY))
                path.addLine(to: CGPoint(x: geometry.size.width, y: thirdY))
                path.move(to: CGPoint(x: 0, y: thirdY * 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: thirdY * 2))
            }
            .stroke(.white.opacity(0.58), style: StrokeStyle(lineWidth: 0.7, dash: [5, 4]))
        }
    }
}

private struct TactileDial: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let changed: (Double) -> Void

    @State private var dragStartValue: Double?
    @State private var lastHapticStep: Int = Int.min

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.055))

                Canvas { context, size in
                    let center = size.width / 2
                    let tickSpacing: CGFloat = 8
                    let count = Int(size.width / tickSpacing) + 2
                    for index in 0..<count {
                        let x = CGFloat(index) * tickSpacing
                        let relative = abs(x - center)
                        let major = Int(relative / tickSpacing).isMultiple(of: 5)
                        let height: CGFloat = major ? 13 : 7
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: size.height / 2 - height / 2))
                        path.addLine(to: CGPoint(x: x, y: size.height / 2 + height / 2))
                        context.stroke(path, with: .color(.white.opacity(major ? 0.85 : 0.38)), lineWidth: major ? 1.3 : 0.8)
                    }
                    var indicator = Path()
                    indicator.move(to: CGPoint(x: center, y: 2))
                    indicator.addLine(to: CGPoint(x: center, y: size.height - 2))
                    context.stroke(indicator, with: .color(.white), lineWidth: 1.8)
                }

                LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.5)],
                               startPoint: .leading, endPoint: .trailing)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil { dragStartValue = value }
                        guard let start = dragStartValue else { return }
                        let sensitivity = (range.upperBound - range.lowerBound) / 10
                        let raw = start + Double(gesture.translation.width / max(width, 1)) * sensitivity
                        let snapped = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
                        guard snapped != value else { return }
                        value = snapped
                        changed(snapped)
                        let hapticIndex = Int((snapped - range.lowerBound) / max(step, 0.000001))
                        if hapticIndex != lastHapticStep {
                            UISelectionFeedbackGenerator().selectionChanged()
                            lastHapticStep = hapticIndex
                        }
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        lastHapticStep = Int.min
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Adjust camera setting")
            .accessibilityValue(String(format: "%.3f", value))
        }
    }
}

// Use native Liquid Glass on iOS 26, with a visually similar material treatment on older iOS.
private func fallbackGlass<S: Shape>(_ content: some View, shape: S) -> some View {
    content
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
}

private struct LiquidGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            fallbackGlass(content, shape: Capsule())
        }
        #else
        fallbackGlass(content, shape: Capsule())
        #endif
    }
}

private struct LiquidGlassCircleModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            fallbackGlass(content, shape: Circle())
        }
        #else
        fallbackGlass(content, shape: Circle())
        #endif
    }
}

private struct LiquidGlassRoundedModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            fallbackGlass(content, shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        #else
        fallbackGlass(content, shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
    }
}

private struct LiquidGlassPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        } else {
            fallbackGlass(content, shape: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
        #else
        fallbackGlass(content, shape: RoundedRectangle(cornerRadius: 26, style: .continuous))
        #endif
    }
}

private extension View {
    func liquidGlassCapsule() -> some View { modifier(LiquidGlassCapsuleModifier()) }
    func liquidGlassCircle() -> some View { modifier(LiquidGlassCircleModifier()) }
    func liquidGlassRounded() -> some View { modifier(LiquidGlassRoundedModifier()) }
    func liquidGlassPanel() -> some View { modifier(LiquidGlassPanelModifier()) }
}
