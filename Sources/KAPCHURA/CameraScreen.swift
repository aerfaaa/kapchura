import SwiftUI
import AVFoundation

@MainActor
final class CameraEngine: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var isReady = false
    @Published var isRecording = false
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
    private var currentPosition: AVCaptureDevice.Position = .back
    private var devices: [AVCaptureDevice] = []

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
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.configureSession()
            }
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
            self.devices = discovery.devices
            guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? discovery.devices.first,
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

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }

            let rawTypes = self.photoOutput.availableRawPhotoPixelFormatTypes
            let formats = device.formats.map { format -> String in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return "\(d.width)×\(d.height) · up to \(Int(maxFPS)) fps"
            }
            self.session.commitConfiguration()
            self.session.startRunning()

            Task { @MainActor in
                self.rawPixelFormatCount = rawTypes.count
                self.rawStillAvailable = !rawTypes.isEmpty
                self.availableFormats = Array(Set(formats)).sorted()
                self.iso = Double(device.iso)
                self.isReady = true
                self.message = rawTypes.isEmpty
                    ? "Camera ready · RAW still unavailable"
                    : "Camera ready · RAW still supported"
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, 1), device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
            lensLabel = factor >= 1.8 ? "2×" : "1×"
        } catch {
            message = "Unable to change zoom: \(error.localizedDescription)"
        }
    }

    func setISO(_ value: Double) {
        guard let device = activeDevice, device.isExposureModeSupported(.custom) else { return }
        let bounded = Float(min(max(value, Double(device.activeFormat.minISO)),
                                Double(device.activeFormat.maxISO)))
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
        let isoValue = Float(min(max(iso, Double(device.activeFormat.minISO)),
                                 Double(device.activeFormat.maxISO)))
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: CMTime(seconds: bounded, preferredTimescale: 1_000_000),
                                          iso: isoValue, completionHandler: nil)
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
        } catch { message = "Focus change failed." }
    }

    func setWhiteBalance(_ kelvin: Double) {
        guard let device = activeDevice, device.isWhiteBalanceModeSupported(.locked) else { return }
        do {
            try device.lockForConfiguration()
            let gains = device.deviceWhiteBalanceGains(
                for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(kelvin), tint: 0
                )
            )
            let maxGain = device.maxWhiteBalanceGain
            let safe = AVCaptureDevice.WhiteBalanceGains(
                redGain: min(max(gains.redGain, 1), maxGain),
                greenGain: min(max(gains.greenGain, 1), maxGain),
                blueGain: min(max(gains.blueGain, 1), maxGain)
            )
            device.setWhiteBalanceModeLocked(with: safe, completionHandler: nil)
            device.unlockForConfiguration()
            temperature = kelvin
        } catch { message = "White balance change failed." }
    }

    func toggleFocusMode() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
            message = "Autofocus enabled"
        } catch { message = "Unable to enable autofocus." }
    }

    func startStopRecording() {
        guard isReady else { return }
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("KAPCHURA-\(Int(Date().timeIntervalSince1970)).mov")
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
            } else {
                self.recordingURL = outputFileURL
                self.message = "Saved in app temporary storage: \(outputFileURL.lastPathComponent)"
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
                            .padding(8)
                            .background(.black.opacity(0.65), in: Capsule())
                            .padding(12)
                    }
                lensControls
                controls
                recordButton
                Text(camera.message)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let url = camera.recordingURL {
                    ShareLink(item: url) {
                        Label("Export last recording", systemImage: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
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
            Text("REC")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(camera.isRecording ? .red : .white.opacity(0.3))
        }
        .foregroundStyle(.white)
    }

    private var lensControls: some View {
        HStack(spacing: 12) {
            Button("1×") { camera.setZoom(1) }
            Button("2×") { camera.setZoom(2) }
            Spacer()
            Text(camera.rawStillAvailable ? "RAW PHOTO ✓" : "RAW PHOTO —")
                .foregroundStyle(camera.rawStillAvailable ? .green : .orange)
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            sliderRow("ISO", value: $camera.iso, range: 25...1600,
                      valueText: "\(Int(camera.iso))") { camera.setISO($0) }
            sliderRow("SHUTTER", value: $camera.shutter, range: 1.0/1000...1.0/15,
                      valueText: "1/\(Int(1 / max(camera.shutter, 0.0001)))") { camera.setShutter($0) }
            sliderRow("FOCUS", value: $camera.focus, range: 0...1,
                      valueText: String(format: "%.2f", camera.focus)) { camera.setManualFocus(Float($0)) }
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
        }
        .tint(.white)
    }

    private var recordButton: some View {
        Button { camera.startStopRecording() } label: {
            ZStack {
                Circle().stroke(.white.opacity(0.8), lineWidth: 2).frame(width: 62, height: 62)
                Circle().fill(camera.isRecording ? .red : .white).frame(width: camera.isRecording ? 24 : 48,
                                                                        height: camera.isRecording ? 24 : 48)
                    .clipShape(RoundedRectangle(cornerRadius: camera.isRecording ? 5 : 30))
            }
        }
        .disabled(!camera.isReady)
        .padding(.top, 2)
    }
}
