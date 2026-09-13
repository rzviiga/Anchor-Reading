# AnchorRead

**Give your eyes a place to land.**

English word-prefix emphasis, across your Mac. AnchorRead uses on-device OCR to find visible English words, then draws native bold prefixes in a transparent overlay. Toggle it with **⌃⌥⌘B**, in the app you are already reading.

[简体中文](README.zh-CN.md) · [MIT License](LICENSE)

| Original | With prefix emphasis |
| --- | --- |
| Find your place in every word. | **Fi**nd **yo**ur **pl**ace **i**n **ev**ery **wo**rd. |

*Illustration of the default 40% setting, not a screenshot or an OCR accuracy demonstration.*

## Why AnchorRead?

Reading happens in browsers, PDF viewers, email clients, and desktop apps. AnchorRead brings word-prefix emphasis to visible screen content through an overlay, without modifying documents, replacing system fonts, or requiring a browser extension.

It is for people who prefer a visual cue at the beginning of English words. Coverage depends on the text and how well its font can be matched.

## Features

- **One shortcut:** toggle emphasis with Control + Option + Command + B, or use the menu bar.
- **Optional energy-saving mode:** capture once after interaction, then retain emphasis without a running capture stream or periodic OCR. Off by default; the setting is remembered.
- **Keyboard-aware energy saving:** hide stale emphasis during typing, deletion, line breaks, navigation, and shortcuts; refresh after input settles. Requires macOS Input Monitoring permission.
- **Popup protection:** energy-saving mode uses a lower overlay level and omits patches overlapping foreign floating windows, including standard input-method candidate windows and menus.
- **Across apps and displays:** recognize visible English text in captured screen content, including rendered PDFs and images when legible.
- **Native bold prefixes:** match the source word with CoreText, draw its prefix in bold, and preserve the original suffix pixels.
- **Reading controls:** emphasize the first letter, 40%, or 50% of each word. Percentage modes emphasize up to four letters.
- **Scroll-aware presentation:** hide emphasis while scrolling and restore it after the screen settles.
- **Selection protection:** hide the overlay while mouse buttons are held and keep it hidden after a selection gesture, so the original selection remains visible.
- **Local processing:** use Apple's Vision and ScreenCaptureKit frameworks, with no account, cloud OCR, or third-party runtime dependencies.

## Status and requirements

AnchorRead is an **early macOS prototype**, currently version **0.6.0**. The app bundle and source modules still use the original name **Anchor Overlay**.

- macOS 14 or later.
- The currently prepared build targets Apple Silicon. Intel compatibility has not been validated.
- macOS Screen Recording permission is required to read visible screen content.
- macOS Input Monitoring permission is additionally needed for keyboard awareness in energy-saving mode. Without it, mouse-driven updates and manual refresh remain available.
- The current menu interface is in Simplified Chinese.

Version 0.6.0 has been compiled and locally signed. Keyboard/IME behavior and battery savings have not been tested for this version; there are no measured accuracy or latency guarantees. Selection protection also needs verification across real desktop apps.

## Build and run

Install Python 3 and Xcode Command Line Tools with a Swift 6 toolchain and macOS SDK. From the repository root:

```sh
python3 scripts/build.py
```

The script builds the app and development executables, then applies an ad-hoc signature. It does **not** run the tests. The output is:

```text
dist/Anchor Overlay.app
```

1. Quit any older copy of Anchor Overlay.
2. Open the built app. It lives in the menu bar.
3. Enable emphasis with **⌃⌥⌘B** or the menu switch.
4. When prompted, allow screen capture in **System Settings → Privacy & Security → Screen Recording**. The setting's name varies by macOS version. Restart the app if needed after granting permission.

Local builds are ad-hoc signed and are not Developer ID notarized.

To create an archive containing the app, source, and documentation:

```sh
python3 scripts/package.py
```

The current output is `dist/Anchor-Overlay-0.6.0.zip`. `Package.swift` is also provided for development in a compatible Swift/Xcode environment; the script above creates the runnable app bundle.

## Controls

| Control | Behavior |
| --- | --- |
| **⌃⌥⌘B** | Enable or pause emphasis. |
| **节能模式（按需截图）** — energy-saving mode | Toggle between on-demand screenshots and the existing continuous-capture mode. Off by default; remembered between launches. |
| **键盘感知** — keyboard awareness | Show keyboard-listener status and request Input Monitoring permission or retry. Only shown for energy-saving mode. |
| **刷新当前画面** — refresh current screen | Request a fresh screenshot in energy-saving mode; also ends selection protection. |
| **强调范围** — emphasis range | First letter, 40% (default), or 50%; percentage modes cap at four letters. |
| **识别分辨率** — recognition resolution | 1×, 1.5×, or 2× (default), with capture width capped at 2,880 pixels. Existing preferences are preserved. |
| **恢复阅读增强** — resume emphasis | End selection protection and resume reading. |
| Status line | Show recognized words entering font matching, successfully enhanced words, OCR time, and font-processing time. |

For example, `watermark` becomes **wate**rmark at 40%, or **w**atermark in first-letter mode.

### Energy-saving mode

Enable **节能模式（按需截图）** in the menu bar. A checkmark indicates that it is on. Switching modes while emphasis is enabled drains the current capture/OCR work and starts the selected mode; when emphasis is paused, it saves the choice for the next activation.

| | Standard mode | Energy-saving mode |
| --- | --- | --- |
| Capture | Continuous ScreenCaptureKit stream with frame-change checks. | One screenshot per display after a supported interaction settles. |
| Refresh | Respond to captured changes while the app is enabled. | On activation, after ordinary clicks/scrolling, authorized keyboard activity, app or Space changes, or a manual refresh. |
| While reading a static page | Capture stream and scheduling remain active. | Keep the last emphasis; no running capture stream, repeated pixel checks, scheduled refresh, or OCR work. |
| Rendering | Existing OCR and native bold-prefix renderer. | Same OCR, emphasis range, resolution, and renderer. |

Energy-saving mode waits about **0.3 seconds after mouse interaction** before taking a screenshot. Keyboard input adds a **0.5-second quiet period**, for approximately **0.8 seconds after the last key activity**, with keys released. Capture and OCR time come after that delay. Mouse/key holds, selection protection, and the app's open menu suspend new captures. Displays are processed sequentially, and results made obsolete by a later interaction are discarded. The status line shows **节能 · 静止休眠** once the batch finishes.

This mode is intended for mostly static reading. It does not continuously check whether the pixels behind an emphasis patch have changed. Automatic page updates and delayed loading may leave emphasis stale or misplaced until the next refresh. The same applies to keyboard actions if Input Monitoring is unavailable or macOS suppresses events during secure input. Use **刷新当前画面**, or turn energy-saving mode off when reading dynamic content. Screen Recording permission is still required for individual screenshots.

“Idle” describes the capture/OCR pipeline, not system sleep or zero power consumption. Existing overlay windows and input monitoring remain available. Actual battery and thermal improvements have not been benchmarked.

### Keyboard input and IME candidate windows

Enable energy-saving mode, then choose **键盘感知：需要输入监控权限…** in the menu. Allow Anchor Overlay under **System Settings → Privacy & Security → Input Monitoring**. Restart the app if required. The menu displays **键盘感知：已开启** when the listener is running; permission alone is not treated as a successful listener connection.

The passive listener is installed only while energy-saving emphasis is running. It observes key-down, key-up, and modifier changes without extracting typed strings or altering input. It is removed when emphasis stops or standard mode is selected. A cancellable one-shot delay groups typing activity; it does not introduce a periodic keyboard poll.

Typing immediately invalidates existing patches and pending snapshot results. Once input settles, the screenshot path checks foreign floating-window bounds before capture and again before presenting results. Patches intersecting those regions are omitted, and the overlay uses the floating level instead of appearing above the status bar. This protects standard candidate windows without guessing an input method's process name. If window geometry cannot be obtained, that batch displays no patches.

This is window-based protection, not a universal API for another app's text-composition state. Custom candidates drawn inside an app's normal window, secure input, and delayed popups still need real-app verification. Candidate-window contents are not specifically enhanced, and unrelated floating panels may also lose emphasis.

### Selecting and copying text

The overlay window is configured to pass mouse input through and never take keyboard focus. While a mouse button is held, the app hides its patches and pauses new OCR work.

After dragging, double/triple-clicking, or Shift-clicking, selection protection keeps the overlay hidden. Copy text in the original app as usual. A new ordinary click, scrolling, switching apps, or the resume menu item ends protection.

This uses input gestures rather than inspecting another app's actual selection. Moving a window or dragging a slider can also trigger protection. With authorized keyboard awareness in energy-saving mode, **Command+A** and **Shift+navigation keys** also trigger protection; **Command+C** preserves it. Other app-specific keyboard selection shortcuts may not be recognized.

## How it works

```text
Visible screen content
        ↓
ScreenCaptureKit — stream frames or take a single screenshot, excluding this app
        ↓
Vision — recognize English text and whole-word boxes
        ↓
CoreText — match source ink and calculate prefix placement
        ↓
Transparent overlay — native bold prefix + original suffix pixels
```

One OCR worker processes frames in the background. In standard mode, stale results are discarded after detected screen changes or interaction, and unchanged patches can remain visible when another part of the screen changes. Energy-saving mode instead uses cancellable one-shot delays triggered by interaction and does not compare screen pixels while idle. Both modes use a bounded font-matching cache.

If the original font match fails, the renderer tries additional installed fonts and small position/size adjustments for the two closest candidates. Words still need to pass source-pixel checks before any patch is drawn.

## Privacy

Screen Recording permission allows AnchorRead to capture the frames it needs for OCR. Frames and recognized text are processed in memory on your Mac. Standard mode runs a capture stream; energy-saving mode requests individual screenshots and releases their pixels after processing. The app does not save screenshots or recognized text to disk, capture audio, or upload screen content. Pausing emphasis stops capture and drains in-flight work.

Input monitoring observes interaction to hide or resume the overlay; it does not replace or replay events. The keyboard listener uses event type, physical key code, and modifier flags, keeping only transient held-key state. It does not extract typed strings, record a keystroke history, or upload keyboard activity. Popup checks use window geometry and level without recording window titles or text.

## Limitations

- **Visible English text only.** AnchorRead does not modify a PDF, webpage, document, or exported file. Covered, offscreen, or capture-protected content cannot be enhanced.
- **Some words are skipped.** Small text, unusual or unavailable fonts, low contrast, textured backgrounds, and rotated text can prevent a reliable match.
- **Font matching is approximate.** A high match score does not guarantee that the selected font or prefix position is correct.
- **Recovery takes time.** Dense pages and difficult fonts can increase the delay after scrolling. Continuous animation may delay new results.
- **Timing is partial.** Menu timings report OCR and font processing, not the complete delay from a screen change to visible emphasis.

## Project layout

```text
Sources/
  AnchorOverlay/          Menu bar app, standard/snapshot capture, input, overlay windows
  AnchorOverlayCore/      OCR, font matching, pixel data, reading policy
  OverlayBench/           Benchmark executable source
  OverlayChecks/          Check executable source
  OverlayRegression/      Rendering and scheduling regression source
Tests/                    Core test source
scripts/                  Build and packaging scripts
qa/                       Development notes
```

## Contributing

Issues and pull requests are welcome, especially for missed words, incorrect prefix placement, selection behavior, and time to recover after scrolling.

For a useful bug report, include your macOS version, target app, display scaling, recognition resolution, emphasis setting, and a short reproduction. A non-sensitive sample sentence and font name are particularly helpful for recognition issues.

Keep rendering changes separate from recognition and interaction changes where practical, and describe what you actually validated. Include regression coverage when addressing recognition or scheduling bugs.

## License

[MIT](LICENSE).
