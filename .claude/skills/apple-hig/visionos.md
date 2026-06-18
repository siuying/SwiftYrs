# Designing for visionOS

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-visionos

## Core Principle: Spatial Computing

visionOS runs on Apple Vision Pro. The environment is the display — the user's real surroundings are visible. Apps appear as windows, volumes, or full-space experiences floating in the person's space.

The human is always in control of their environment. Your app exists in that environment, not the other way around.

---

## Three Presentation Styles

### Windows (Shared Space)
Flat, 2D windows that float in the user's space. Multiple apps can show windows simultaneously.

```swift
WindowGroup {
    ContentView()
}
.windowStyle(.plain) // or .volumetric for 3D content
```

- Most apps start here; windows can be positioned, resized, and closed by the user.
- Use standard SwiftUI layout; it works in visionOS windows without modification.
- The user controls window placement — never force a window to a fixed position.

### Volumes (Shared Space)
3D bounded spaces. Appropriate for 3D content (objects, models).

```swift
WindowGroup {
    Model3DView()
}
.windowStyle(.volumetric)
.defaultSize(width: 0.5, height: 0.5, depth: 0.5, in: .meters)
```

### Full Spaces
The app takes over the entire view. Either:
- **Mixed**: the passthrough environment remains visible; your 3D content is placed into it.
- **Full immersion**: the passthrough is dimmed or hidden; the app controls the entire visual field.

```swift
ImmersiveSpace(id: "mainSpace") {
    RealityView { content in
        // place RealityKit entities
    }
}
.immersionStyle(selection: $immersionStyle, in: .mixed, .progressive, .full)
```

Use Full Spaces for immersive experiences (games, meditation, cinema). Always provide a clear way out.

---

## Input Model

The primary input is **eye + hand**:
1. User looks at an element (eye tracking highlights it).
2. User pinches their fingers to activate it.

Never assume the user is holding a controller or using a trackpad.

### Eyes (Look)
- Interactive elements highlight when the user looks at them — a subtle glow.
- Minimum tappable target: **60×60 pt** (larger than iOS because targeting is less precise).
- Avoid placing interactive elements too close together.

### Hands (Pinch Gestures)
| Gesture | Action |
|---|---|
| Tap (pinch + release) | Select |
| Long press (hold pinch) | Secondary action |
| Drag (pinch + move) | Move content |
| Two-hand spread | Scale |
| Rotate (two hands) | Rotate |

### Indirect Pinch
The standard interaction: look at a target, pinch anywhere (hands can be at sides). Direct touch (reaching out to tap a virtual surface) is also supported for content placed nearby.

### Other Inputs
- **Keyboard**: physical Bluetooth keyboard or virtual system keyboard.
- **Voice**: Siri and dictation.
- **Trackpad / pointer**: connected accessory; pointer appears and hover states activate.
- **Game controller**: MFi controllers work.

---

## Spatial Layout

### Distance and Scale
Content placed at natural distances:
- **Nearby** (~0.5 m): small interactive objects, hands-on content.
- **Conversational** (~1–2 m): windows, panels — the default window placement zone.
- **Environmental** (~2–5 m): large displays, panoramic content.

Scale content to feel natural at its intended distance. A window at conversational distance should use roughly the same visual size as a MacBook screen.

### Depth
Use depth to convey hierarchy — not just Z-translation but visual layering:
- Bring important content forward.
- Push background/contextual content back.
- Use `ZStack` with `.offset(z:)` or RealityKit entity transforms.

### Glass Material
The system's default background for windows. Use it for panels, sidebars, and overlays.

```swift
.glassBackgroundEffect()
```

Don't cover the glass with opaque backgrounds unless the content requires it (e.g. video player).

---

## Typography

Text must be legible at distance. Use Dynamic Type; visionOS scales appropriately for the window's distance.

- Minimum body text: `body` style — do not go smaller.
- Avoid thin font weights at small sizes.
- Light text on glass backgrounds works well (system default).

---

## Color

- Prefer **light colors** — they contrast well against the glass material and real environments.
- Avoid large fields of saturated color — they feel garish in a spatial context.
- Never rely on color alone to convey information (spatial context adds extra uncertainty to perception).
- System tint / accentColor works normally.

---

## Depth and Hover Effects

When content is interactive, it should signal this visually. The `.hoverEffect()` modifier adds system-provided highlighting:

```swift
Button("Action") { ... }
    .hoverEffect()  // highlights on look
```

Custom 3D hover: in RealityKit, use `InputTargetComponent` and `HoverEffectComponent`.

---

## Windows and Ornaments

**Ornaments** are UI panels attached to a window, appearing just outside its bounds (e.g. a toolbar below the window).

```swift
.ornament(attachmentAnchor: .scene(.bottom)) {
    ToolbarView()
}
```

Use ornaments for persistent controls (playback controls, tool palettes) that should not occupy the main window canvas.

---

## Immersive Sound

Spatial audio enhances the experience. Use `RealityKit` audio entities or `AVAudioEngine` with spatial audio APIs to position sounds in 3D space.

---

## Privacy and Passthrough

- Never capture, store, or transmit the passthrough camera feed.
- The system provides the ARKit scene understanding APIs; use them only for the declared purpose.
- Eye tracking data is private — the system never exposes raw gaze coordinates to apps.
- Request camera/microphone permission with context.

---

## Compatibility with Existing Apps

- iOS/iPadOS apps run on visionOS in a **compatibility window** (fixed size, 2D, no spatial features).
- They work but don't feel native. To feel native: add `visionOS` as a supported destination and handle the spatial idioms.
- Use `#if os(visionOS)` to add platform-specific spatial code.

---

## Common Mistakes

| Mistake | Correct approach |
|---|---|
| Using flat dark backgrounds | Use `.glassBackgroundEffect()` |
| Forcing window position/size | Let the user control placement |
| Sub-60pt interactive targets | Increase target size |
| Expecting direct touch by default | Design for indirect (look + pinch) |
| Opaque overlays over the environment | Use translucent glass materials |
| Excessive full-immersion use | Reserve for genuinely immersive experiences |
