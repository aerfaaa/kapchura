import SwiftUI
import AVFoundation
import Photos
import UIKit

@MainActor
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate {
    @Published var isReady = false
    @Published var isRecording = false
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
    @Published var settingsCollapsed = false
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
            AVCaptureDevice.requestAccess(for: .audio) { _ in self.configureSession() }
        }
    }

    private func configureSession() {
        sessionQueue.async {
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
                    let rawCount = self.photoOutput.availableRawPhotoPixelFormatTypes.count
                    Task { @MainActor in
                        self.isTelephoto = telephoto
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

    private func applyCaptureProfile(resolution: String, fps: Int, to device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let sizeOK = resolution == "Open Gate" || (resolution == "4K" ? (d.width >= 3840 || d.height >= 2160) : (d.width >= 1920 || d.height >= 1080))
            return sizeOK && format.videoSupportedFrameRateRanges.contains { Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate }
        }
        let chosenFormat: AVCaptureDevice.Format?
        if resolution == "Open Gate" {
            chosenFormat = candidates.max {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }
        } else if resolution == "1080p" {
            chosenFormat = candidates.min {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return abs(Int(a.width * a.height) - 1920 * 1080) < abs(Int(b.width * b.height) - 1920 * 1080)
            }
        } else {
            chosenFormat = candidates.max {
                let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                return Int64(a.width) * Int64(a.height) < Int64(b.width) * Int64(b.height)
            }
        }
        guard let chosen = chosenFormat else {
            Task { @MainActor in self.message = "\(resolution) at \(fps) FPS is unavailable on this lens." }
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
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

    func setStabilization(_ value: String) {
        stabilization = value
        guard let connection = movieOutput.connection(with: .video) else { return }
        guard connection.isVideoStabilizationSupported else { message = "Stabilization unavailable for this format."; return }
        switch value {
        case "Minimal": connection.preferredVideoStabilizationMode = .standard
        case "Maximum": connection.preferredVideoStabilizationMode = .cinematic
        default: connection.preferredVideoStabilizationMode = .off
        }
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
        guard isReady else { return }
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = documents.appendingPathComponent("KAPCHURA-\(Int(Date().timeIntervalSince1970)).mov")
            try? FileManager.default.removeItem(at: url)
            guard let connection = movieOutput.connection(with: .video) else { message = "Video connection unavailable."; return }
            if connection.isVideoStabilizationSupported {
                switch stabilization {
                case "Minimal": connection.preferredVideoStabilizationMode = .standard
                case "Maximum": connection.preferredVideoStabilizationMode = .cinematic
                default: connection.preferredVideoStabilizationMode = .off
                }
            }
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = movieOutput.isRecording
            message = isRecording ? "Recording · \(profileStatus)" : "Could not start recording."
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            if let error {
                self.message = "Recording failed: \(error.localizedDescription)"
                return
            }
            guard FileManager.default.fileExists(atPath: outputFileURL.path) else {
                self.message = "Recording ended without a video file."
                return
            }
            self.recordingURL = outputFileURL
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    Task { @MainActor in self.message = "Recording kept in KAPCHURA files. Allow Photos access to save it to Photos." }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
                }) { success, saveError in
                    Task { @MainActor in
                        self.message = success ? "Video saved to Photos." :
                            "Video kept in KAPCHURA files. Photos save failed: \(saveError?.localizedDescription ?? "unknown error")"
                    }
                }
            }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = .resizeAspectFill
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraEngine()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                CameraPreview(session: camera.session)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                // A subtle readability gradient; the live image remains the main surface.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.62), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [.clear, .black.opacity(0.28), .black.opacity(0.88)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 310)
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.top, max(geometry.safeAreaInsets.top, 8) + 5)
                    Spacer(minLength: 12)
                    bottomPanel
                        .frame(maxHeight: geometry.size.height * (geometry.size.width > geometry.size.height ? 0.82 : 0.72))
                        .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8) + 8)
                }
                .padding(.horizontal, 20)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(.black)
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                camera.switchLens(telephoto: false)
            } label: {
                lensPill("1×", selected: !camera.isTelephoto)
            }
            .disabled(!camera.isReady)

            Button {
                camera.switchLens(telephoto: true)
            } label: {
                lensPill("2×", selected: camera.isTelephoto)
            }
            .disabled(!camera.isReady)

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(camera.isRecording ? Color.red : Color.white.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(camera.isRecording ? "REC" : "STANDBY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
            }
            .foregroundStyle(.white.opacity(0.9))

            Text(camera.rawStillAvailable ? "RAW" : "HEVC")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(camera.rawStillAvailable ? .white : .white.opacity(0.65))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.38), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.7))
        }
    }

    private func lensPill(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? .black : .white)
            .frame(width: 42, height: 34)
            .background(selected ? Color.white : Color.black.opacity(0.38), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(selected ? 0 : 0.35), lineWidth: 0.7))
    }

    private var bottomPanel: some View {
        ScrollView(.vertical) {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { camera.settingsCollapsed.toggle() }
                } label: {
                    Image(systemName: camera.settingsCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.12), in: Circle())
                }
                Button("AUTO") { camera.setAutofocus() }
                    .foregroundStyle(!camera.isManualFocus ? .black : .white)
                    .background(!camera.isManualFocus ? Color.white : Color.white.opacity(0.12), in: Capsule())
                Button("MF") { camera.enableManualFocus() }
                    .foregroundStyle(camera.isManualFocus ? .black : .white)
                    .background(camera.isManualFocus ? Color.white : Color.white.opacity(0.12), in: Capsule())
                Spacer()
                Text(camera.lensLabel)
                    .foregroundStyle(.white.opacity(0.75))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(1)
                if camera.rawStillAvailable {
                    Text("RAW STILL READY")
                        .foregroundStyle(.white.opacity(0.6))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
            }
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .buttonStyle(.plain)
            .padding(.bottom, 2)

            if !camera.settingsCollapsed {
                VStack(spacing: 7) {
                    profilePickerRow
                    sliderRow("ISO", value: $camera.iso, range: 25...1600, valueText: String(Int(camera.iso)), automatic: camera.isoAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setISO($0) }
                    sliderRow("SHUTTER", value: $camera.shutter, range: 1.0/1000...1.0/15, valueText: "1/\(Int(1 / max(camera.shutter, 0.0001)))", automatic: camera.shutterAutomatic, autoAction: { camera.setExposureAutomatic() }) { camera.setShutter($0) }
                    sliderRow("FOCUS", value: $camera.focus, range: 0...1, valueText: String(format: "%.2f", camera.focus), automatic: camera.focusAutomatic, autoAction: { camera.setAutofocus() }) { camera.setManualFocus(Float($0)) }
                    sliderRow("WB", value: $camera.temperature, range: 2500...8000, valueText: "\(Int(camera.temperature))K", automatic: camera.whiteBalanceAutomatic, autoAction: { camera.setWhiteBalanceAutomatic() }) { camera.setWhiteBalance($0) }
                }
            }

            HStack(alignment: .center) {
                Button {
                    camera.captureRAWPhoto()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "camera")
                            .font(.system(size: 19, weight: .regular))
                        Text("RAW")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundStyle(camera.rawStillAvailable ? .white : .white.opacity(0.35))
                    .frame(width: 58, height: 58)
                }
                .disabled(!camera.isReady || !camera.rawStillAvailable || camera.isRecording)

                Spacer()

                recordButton

                Spacer()

                if let url = camera.recordingURL {
                    ShareLink(item: url) {
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18))
                            Text("EXPORT")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .tracking(1)
                        }
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                    }
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18))
                        Text("EXPORT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1)
                    }
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 58, height: 58)
                }
            }
            .padding(.top, 2)

            Text(camera.message)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 0.8)
                }
        }
    }

    private var profilePickerRow: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Text("FORMAT").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.65)).frame(width: 58, alignment: .leading)
                Picker("Resolution", selection: Binding(get: { camera.resolution }, set: { camera.setResolution($0) })) {
                    Text("1080p").tag("1080p")
                    Text("4K").tag("4K")
                    Text("OPEN GATE").tag("Open Gate")
                }.pickerStyle(.segmented).disabled(camera.isRecording)
            }
            HStack(spacing: 7) {
                Text("FPS").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.65)).frame(width: 58, alignment: .leading)
                Picker("FPS", selection: Binding(get: { camera.frameRate }, set: { camera.setFrameRate($0) })) {
                    ForEach(camera.supportedFrameRates, id: \.self) { Text("\($0)").tag($0) }
                }.pickerStyle(.segmented).disabled(camera.isRecording || camera.supportedFrameRates.isEmpty)
                Text("STAB").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.white.opacity(0.65))
                Picker("Stabilization", selection: Binding(get: { camera.stabilization }, set: { camera.setStabilization($0) })) {
                    Text("OFF").tag("Off")
                    Text("MIN").tag("Minimal")
                    Text("MAX").tag("Maximum")
                }.pickerStyle(.menu).tint(.white).disabled(camera.isRecording)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           valueText: String, automatic: Bool, autoAction: @escaping () -> Void,
                           changed: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 58, alignment: .leading)
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { newValue in
                    value.wrappedValue = newValue
                    changed(newValue)
                }
            ), in: range)
            .tint(.white)
            Text(valueText).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.white).frame(width: 45, alignment: .trailing)
            Button("A", action: autoAction)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(automatic ? .black : .white)
                .frame(width: 22, height: 22)
                .background(automatic ? Color.white : Color.white.opacity(0.12), in: Circle())
                .buttonStyle(.plain)
        }
        .frame(height: 26)
    }

    private var recordButton: some View {
        Button {
            camera.startStopRecording()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.95), lineWidth: 2)
                    .frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 30)
                    .fill(.red)
                    .frame(width: camera.isRecording ? 25 : 54,
                           height: camera.isRecording ? 25 : 54)
                    .animation(.easeInOut(duration: 0.18), value: camera.isRecording)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.isReady)
        .opacity(camera.isReady ? 1 : 0.45)
    }
}
