import SwiftUI

struct CameraScreen: View {
    @StateObject private var camera = CameraEngine()
    @State private var showSettings = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    CameraPreview(session: camera.session)
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.size.height * 0.48)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            Text(camera.status)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(12)
                        }
                    zoomControl
                    if showSettings {
                        exposureControls
                    }
                    Spacer(minLength: 8)
                    bottomControls
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, max(geometry.safeAreaInsets.bottom == 0 ? 12 : 4, 4))
            }
        }
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("KAPCHURA")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .tracking(2.5)
                Text("CAMERA / 01")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Circle()
                .fill(camera.isRecording ? Color.red : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
            Text(camera.isRecording ? "REC" : "STANDBY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(camera.isRecording ? .red : .white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .frame(height: 48)
    }

    private var zoomControl: some View {
        HStack(spacing: 22) {
            zoomButton("1×", value: 1)
            zoomButton("2×", value: 2)
            Spacer()
            Text(camera.rawPhotoSupported ? "RAW CAPABLE" : "STANDARD PHOTO")
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 14)
    }

    private func zoomButton(_ title: String, value: Double) -> some View {
        Button {
            camera.setZoom(value)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: camera.zoom == value ? .bold : .regular,
                              design: .monospaced))
                .foregroundStyle(camera.zoom == value ? .white : .white.opacity(0.45))
        }
        .buttonStyle(.plain)
    }

    private var exposureControls: some View {
        VStack(spacing: 13) {
            controlRow("ISO", value: $camera.iso, range: 25...1600,
                       display: "\(Int(camera.iso))") { camera.setISO($0) }
            controlRow("SHUTTER", value: $camera.shutterSeconds, range: 1.0/1000...1.0/15,
                       display: "1/\(Int(1 / max(camera.shutterSeconds, 0.0001)))") {
                camera.setShutter($0)
            }
            controlRow("FOCUS", value: $camera.focusPosition, range: 0...1,
                       display: String(format: "%.2f", camera.focusPosition)) {
                camera.setFocus($0)
            }
            controlRow("WB", value: $camera.whiteBalanceKelvin, range: 2500...8000,
                       display: "\(Int(camera.whiteBalanceKelvin))K") {
                camera.setWhiteBalance($0)
            }
        }
        .padding(.vertical, 8)
    }

    private func controlRow(_ title: String, value: Binding<Double>,
                            range: ClosedRange<Double>, display: String,
                            changed: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 58, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if !editing { changed(value.wrappedValue) }
            }
            .tint(.white)
            Text(display)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 48, height: 48)
                }
                Spacer()
                Picker("Capture mode", selection: $camera.mode) {
                    ForEach(CameraEngine.CaptureMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                Spacer()
                if let url = camera.latestMediaURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 48, height: 48)
                    }
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
            }

            Button {
                camera.capture()
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 2)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(camera.isRecording ? .red : .white)
                        .frame(width: camera.isRecording ? 29 : 58,
                               height: camera.isRecording ? 29 : 58)
                        .clipShape(RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 40))
                }
            }
            .buttonStyle(.plain)
            .disabled(!camera.isReady)
            .opacity(camera.isReady ? 1 : 0.35)
            .padding(.bottom, 12)
        }
    }
}
