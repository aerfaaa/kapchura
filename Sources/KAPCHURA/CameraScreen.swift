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
            self.session.sessionPreset = .high
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
            Task { @MainActor in
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
            temperature = kelvin
        } catch { message = "White balance change failed." }
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
            movieOutput.startRecording(to: url, recordingDelegate: self)
            isRecording = true
            message = "Recording…"
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
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraScreen: View {
    @StateObject private var camera = CameraEngine()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                CameraPreview(session: camera.session)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topLeading) {
                        Text(camera.lensLabel)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .padding(8).background(.black.opacity(0.65), in: Capsule()).padding(12)
                    }
                lensControls
                focusModeControls
                controls
                HStack(spacing: 24) {
                    Button { camera.captureRAWPhoto() } label: {
                        Label("RAW PHOTO", systemImage: "camera")
                    }
                    .disabled(!camera.isReady || !camera.rawStillAvailable || camera.isRecording)
                    recordButton
                }
                Text(camera.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(3).multilineTextAlignment(.center)
                if let url = camera.recordingURL {
                    ShareLink(item: url) {
                        Label("Export last recording", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("KAPCHURA").font(.system(size: 22, weight: .black, design: .rounded)).tracking(2)
                Text("COMPUTATIONAL IMAGING").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text("REC").font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(camera.isRecording ? .red : .white.opacity(0.3))
        }.foregroundStyle(.white)
    }

    private var lensControls: some View {
        HStack(spacing: 12) {
            Button("1× WIDE") { camera.switchLens(telephoto: false) }
                .disabled(!camera.isReady)
            Button("2× TELE") { camera.switchLens(telephoto: true) }
                .disabled(!camera.isReady)
            Spacer()
            Text(camera.rawStillAvailable ? "RAW ✓" : "RAW —")
                .foregroundStyle(camera.rawStillAvailable ? .green : .orange)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .buttonStyle(.bordered).tint(.white)
    }

    private var focusModeControls: some View {
        HStack {
            Text("FOCUS MODE").foregroundStyle(.white.opacity(0.55))
            Spacer()
            Button("AUTO") { camera.setAutofocus() }
                .tint(camera.isManualFocus ? .white : .green)
            Button("MANUAL") { camera.enableManualFocus() }
                .tint(camera.isManualFocus ? .green : .white)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .buttonStyle(.bordered)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            sliderRow("ISO", value: $camera.iso, range: 25...1600, valueText: "\(Int(camera.iso))") { camera.setISO($0) }
            sliderRow("SHUTTER", value: $camera.shutter, range: 1.0/1000...1.0/15,
                      valueText: "1/\(Int(1 / max(camera.shutter, 0.0001)))") { camera.setShutter($0) }
            if camera.isManualFocus {
                sliderRow("FOCUS", value: $camera.focus, range: 0...1,
                          valueText: String(format: "%.2f", camera.focus)) { camera.setManualFocus(Float($0)) }
            }
            sliderRow("WB", value: $camera.temperature, range: 2500...8000,
                      valueText: "\(Int(camera.temperature))K") { camera.setWhiteBalance($0) }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           valueText: String, changed: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 62, alignment: .leading).foregroundStyle(.white.opacity(0.65))
            Slider(value: value, in: range) { editing in
                if !editing { changed(value.wrappedValue) }
            }
            Text(valueText).frame(width: 65, alignment: .trailing).foregroundStyle(.white)
        }.tint(.white)
    }

    private var recordButton: some View {
        Button { camera.startStopRecording() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.8), lineWidth: 2).frame(width: 62, height: 62)
                Circle().fill(camera.isRecording ? .red : .white)
                    .frame(width: camera.isRecording ? 24 : 48, height: camera.isRecording ? 24 : 48)
                    .clipShape(RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 30))
            }
        }
        .disabled(!camera.isReady).padding(.top, 2)
    }
}
