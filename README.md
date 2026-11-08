# KAPCHURA

KAPCHURA is an independent, free iOS camera application. This repository is being rebuilt as a native SwiftUI + AVFoundation camera, with a focus on manual capture controls and a computational-video pipeline.

## Current foundation

- Native SwiftUI camera interface and AVFoundation preview.
- Runtime discovery of physical and virtual rear-camera device types.
- Runtime inventory of the active camera's sensor formats, dimensions, pixel subtypes, frame-rate ranges and HDR flags.
- A live `AVCaptureVideoDataOutput` sample-buffer path, reporting the actual delivered frame dimensions and pixel format.
- Standard photo capture and capability-gated Bayer RAW/DNG still capture.
- ISO, shutter, manual focus, white-balance and zoom controls.
- Basic AVFoundation movie recording and share-sheet export of the latest capture.

## Important technical boundaries

RAW still capture is not RAW video. The new sample-buffer output is the starting point for a custom processing pipeline; it does not yet debayer Bayer video, create a Log transform, render through Metal, or write processed frames to a custom movie file. The current movie recorder remains `AVCaptureMovieFileOutput`.

HEVC and ProRes availability must be detected and configured separately for each device and recording path. A device exposing RAW still photo formats does not imply continuous RAW video support. The iPhone XS is the initial hardware validation target; no physical-device validation is claimed by this source change.

## Build

Requires macOS with Xcode 15.4 or later and XcodeGen.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project KAPCHURA.xcodeproj -scheme KAPCHURA -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Open the generated project in Xcode, select a physical iPhone, configure signing, and run. An unsigned CI compile does not validate camera hardware behaviour.

## Next engineering steps

1. Build and run this branch on the iPhone XS; verify RAW DNG capture and the reported frame metadata.
2. Add a Metal/Core Image processing stage consuming the sample buffers, beginning with a neutral pass-through and measured colour conversion.
3. Implement selectable Log transforms and 3D LUT preview/output.
4. Replace the basic movie output with a custom writer path and explicitly configured HEVC; investigate ProRes only where the device/API exposes it.
5. Add exposure overlays, camcorder motion/zoom behaviour, optional VHS effects, gallery and export polish.

KAPCHURA is independently implemented and does not depend on LogCam's code, subscription, or licensing.

## License

MIT
