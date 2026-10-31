# KAPCHURA

An open-source iOS camera experiment focused on computational imaging and camcorder-style capture.

## First milestone included

- AVFoundation live camera preview.
- Runtime camera discovery and basic 1× / 2× zoom controls.
- Manual ISO, shutter, focus and white-balance controls.
- RAW still-photo capability detection using `AVCapturePhotoOutput`.
- Video recording using `AVCaptureMovieFileOutput`.
- Export of the last recording using the iOS share sheet.
- GitHub Actions build workflow.

## Important technical boundary

This starter does **not** claim to record RAW video or produce a genuine Log transform yet. Apple's `AVCapturePhotoOutput` exposes RAW still-photo capture; that does not by itself provide a continuous RAW video stream. KAPCHURA detects RAW still support separately so we do not mislabel processed video as RAW.

The first milestone uses AVFoundation's normal video recording output. The next milestone is to replace/extend this with a custom `AVCaptureVideoDataOutput` + Metal/VideoToolbox processing pipeline, after validating what the target device actually exposes.

## Build

1. Install Xcode 15 or later on macOS.
2. Install XcodeGen: `brew install xcodegen`
3. Run `xcodegen generate` in the project directory.
4. Open `KAPCHURA.xcodeproj`, select a physical iPhone, and run.

The iOS deployment target is 16.0. Test on a physical device; the simulator does not provide equivalent camera hardware.

## Reference device

Initial testing target: iPhone XS. All supported lenses, frame rates, pixel formats and RAW still capabilities must be detected at runtime.

## License

MIT
