# KAPCHURA

KAPCHURA is an independent, free iOS camera application. This repository is being rebuilt as a native SwiftUI + AVFoundation camera, with a focus on manual capture controls and a future computational-video pipeline.

## Current foundation

- Native SwiftUI camera interface.
- AVFoundation live preview and runtime camera discovery.
- Photo capture and video recording.
- ISO, shutter, manual focus, white-balance and zoom controls.
- Runtime detection of RAW still-photo support.
- Share-sheet export of the latest capture.
- Portrait-first camera interface.
- iPhone XS is the initial hardware validation target.

## Important limitations

This foundation does not yet implement RAW video, Apple Log recording, LUT processing, ProRes, or a custom Metal colour pipeline. RAW still-photo support is detected separately; it must not be confused with RAW video capture. Available lenses, formats, frame rates and codecs must be verified on each physical device.

## Build

Requires macOS with Xcode 15.4 or later and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project KAPCHURA.xcodeproj -scheme KAPCHURA -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Open the generated project in Xcode, select a physical iPhone, configure signing, and run. The GitHub Actions workflow performs an unsigned compile check; it does not produce a signed, installable IPA.

## Project direction

The next engineering milestones are:
1. Validate photo/video capture and manual controls on iPhone XS.
2. Add a dedicated frame-processing pipeline using AVCaptureVideoDataOutput and Metal.
3. Add verified log-style recording profiles and 3D LUT preview/output.
4. Investigate supported high-bitrate codecs, frame rates and open-gate capture per device.
5. Add optional RAW/DNG still capture and a proper media library.

KAPCHURA is independently implemented and does not depend on LogCam's code, subscription, or licensing.

## License

MIT
