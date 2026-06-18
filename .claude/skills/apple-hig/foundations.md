# Foundations

Source: https://developer.apple.com/design/human-interface-guidelines/foundations

Foundations are the visual and interaction building blocks that apply across all Apple platforms. Read this when making decisions about color, typography, layout, icons, motion, or privacy.

---

## Color

### Semantic System Colors (always prefer these)
Use semantic colors so Dark Mode, high contrast, and tinting work automatically.

| Semantic role | UIKit | SwiftUI |
|---|---|---|
| Primary text | `UIColor.label` | `Color.primary` |
| Secondary text | `UIColor.secondaryLabel` | `Color.secondary` |
| Tertiary text | `UIColor.tertiaryLabel` | — |
| Primary background | `UIColor.systemBackground` | `Color(.systemBackground)` |
| Grouped background | `UIColor.systemGroupedBackground` | — |
| Separator | `UIColor.separator` | — |
| Interactive/tint | `UIColor.systemBlue` or `tintColor` | `Color.accentColor` |
| Destructive | `UIColor.systemRed` | `Color.red` |

### System Accent Colors
iOS/macOS let users choose an accent color. Use `tintColor` / `Color.accentColor` for interactive elements so the user's preference is respected.

### Dynamic Colors
Always provide light and dark variants for custom colors:
```swift
// Asset catalog: create a Color Set with "Any" and "Dark" appearances
// UIKit
UIColor(dynamicProvider: { traitCollection in
    traitCollection.userInterfaceStyle == .dark ? darkColor : lightColor
})
// SwiftUI
Color("MyBrandColor") // defined with dark variant in asset catalog
```

### Contrast Requirements
- Text on backgrounds: minimum 4.5:1 (normal), 3:1 (large text).
- Use Xcode's Accessibility Inspector to measure contrast.
- Test with "Increase Contrast" enabled.

---

## Typography

### Font Families
- **SF Pro** — default for iOS, iPadOS, macOS, tvOS.
- **SF Compact** — default for watchOS; also used in dense UIs.
- **SF Mono** — monospaced; for code and tabular data.
- **New York** — serif; for reading-heavy content.

All are available via the system; do not bundle them.

### Dynamic Type Styles
Always use these instead of raw sizes:

| Style | Default pt (iOS) | Typical use |
|---|---|---|
| `largeTitle` | 34 | Hero headings |
| `title1` | 28 | Page titles |
| `title2` | 22 | Section headings |
| `title3` | 20 | Sub-section |
| `headline` | 17 bold | Row labels |
| `body` | 17 | Primary body |
| `callout` | 16 | Secondary body |
| `subheadline` | 15 | Supporting text |
| `footnote` | 13 | Captions |
| `caption1` | 12 | Smallest label |
| `caption2` | 11 | Minimum |

```swift
// SwiftUI
Text("Hello").font(.body)

// UIKit
label.font = .preferredFont(forTextStyle: .body)
label.adjustsFontForContentSizeCategory = true
```

### Custom Fonts
If brand requires a custom font, still scale with Dynamic Type:
```swift
// SwiftUI
.font(.custom("BrandFont-Regular", size: 17, relativeTo: .body))

// UIKit
UIFontMetrics(forTextStyle: .body)
    .scaledFont(for: UIFont(name: "BrandFont-Regular", size: 17)!)
```

---

## Icons (SF Symbols)

SF Symbols are Apple's icon library — 5000+ symbols that match the system font automatically.

```swift
// SwiftUI
Image(systemName: "star.fill")
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(.yellow)

// UIKit
UIImage(systemName: "star.fill",
        withConfiguration: UIImage.SymbolConfiguration(textStyle: .body))
```

### Symbol Rendering Modes
| Mode | Effect |
|---|---|
| `.monochrome` | Single color |
| `.hierarchical` | Single color with opacity levels |
| `.palette` | Multiple explicit colors |
| `.multicolor` | Apple-defined colors (e.g. thermometer = red/blue) |

### Weight and Scale
Symbols respond to font weight and scale:
```swift
Image(systemName: "arrow.right")
    .font(.title.weight(.semibold))
    .imageScale(.large) // .small, .medium, .large
```

### Custom Symbols
Create in SF Symbols app; export as SVG; add to asset catalog. Follow the weight/scale template.

---

## Layout

### Safe Areas
Always respect safe areas:
```swift
// SwiftUI (automatic with standard containers)
// Override carefully:
.ignoresSafeArea(.keyboard) // content adjusts to keyboard
.ignoresSafeArea(.container, edges: .horizontal) // full-width backgrounds only

// UIKit
view.safeAreaLayoutGuide.topAnchor
view.safeAreaInsets
```

### Adaptive Layouts
Design for both compact and regular size classes:
```swift
@Environment(\.horizontalSizeClass) var hSizeClass

if hSizeClass == .compact {
    VStack { ... }    // phone / compact split
} else {
    HStack { ... }    // iPad / regular split
}
```

### Spacing System
Use multiples of 4 pt for spacing: 4, 8, 12, 16, 20, 24, 32, 44 pt.
Standard margins: 16 pt (compact), 20 pt (regular).
Content max width: 375–700 pt depending on context; constrain wide layouts.

### Grid
Use LazyVGrid / LazyHGrid for tile layouts; let column count adapt to available width.

---

## Dark Mode

Dark Mode must work correctly. Use semantic colors (they adapt automatically). Test both appearances before shipping.

### Do
- Use semantic colors everywhere: `.label`, `.systemBackground`, `.systemGroupedBackground`.
- Use adaptive asset catalog colors for custom brand colors.
- Test images — provide a dark-mode variant in the asset catalog if needed.
- Use system materials for translucent backgrounds.

### Don't
- Don't hard-code `UIColor.white` or `UIColor.black` for text/backgrounds.
- Don't invert colors manually — the system handles this.
- Don't create a custom dark mode toggle; use the system setting.

```swift
// Asset catalog image with dark variant
Image("HeroImage") // automatically uses dark variant when available
```

---

## Motion and Animation

### Principles
- **Purposeful**: every animation should aid comprehension or acknowledge input.
- **Responsive**: begin immediately, don't delay.
- **Natural**: follow physics (spring, easing); avoid linear or mechanical motion.

### Standard Durations
- Micro-interactions: 100–200 ms
- Screen transitions: 250–400 ms
- Complex multi-step: up to 600 ms

### Reduce Motion
Always check before animating:
```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion
withAnimation(reduceMotion ? .none : .spring(response: 0.3)) {
    isExpanded.toggle()
}
```

Alternatives when motion is reduced:
- Cross-fade instead of slide/scale
- Instant transition instead of animated
- Subtle opacity change instead of parallax

---

## Materials (Translucency)

Materials create depth and show context behind content. Use sparingly.

```swift
// SwiftUI
.background(.regularMaterial)  // default blurred translucency
.background(.thickMaterial)
.background(.thinMaterial)
.background(.ultraThinMaterial)
.background(.ultraThickMaterial)
// or:
.background(.bar) // matches tab/nav bar appearance
```

AppKit: `NSVisualEffectView` with `.sidebar`, `.headerView`, `.popover` etc.

Use materials for: sidebars, floating panels, tab bars, popovers. Not for full-screen backgrounds.

---

## App Icons

| Platform | Size | Notes |
|---|---|---|
| iOS | 1024×1024 | App Store; Xcode generates smaller sizes |
| macOS | 1024×1024 | Square (system rounds corners) |
| watchOS | 1024×1024 | System crops to circle |
| tvOS | 400×240 per layer (×3 layers) | Parallax layered format |
| visionOS | 1024×1024 + background layer | Specular effect applied |

Design principles:
- Simple, recognizable at 16×16 pt.
- No screenshots of the UI; no transparency; no text (almost always).
- Unique silhouette.
- iOS icons are flat with a sense of depth via lighting; macOS icons are more 3D/realistic.

---

## Privacy

### Request Permissions at Point of Use
Never request sensitive permissions at launch. Request them when the user first encounters the feature that needs it.

Provide a clear `NSUsageDescription` string explaining why the permission is needed. This text appears in the system prompt.

```
// Info.plist
NSCameraUsageDescription = "Used to scan QR codes for check-in."
NSLocationWhenInUseUsageDescription = "Shows nearby pickup locations."
```

### Permission Best Practices
- Show your own pre-prompt explaining the benefit before the system prompt.
- Gracefully degrade if permission is denied (don't block the rest of the app).
- Use the minimum access level: "When In Use" instead of "Always" for location.
- Re-request only via Settings (after denial); don't harass with repeated requests.

### Privacy Nutrition Labels
App Store requires accurate privacy nutrition labels. Match your `Info.plist` declarations to actual data usage.

---

## Writing

### Voice and Tone
- **Clear**: use plain language. Avoid jargon.
- **Concise**: omit needless words.
- **Friendly**: conversational, not corporate.
- **Helpful**: tell users what they can do, not just what went wrong.

### UI Copy Rules
- **Button labels**: verb + noun ("Add Friend", "Share Photo"). Never just "OK".
- **Alert titles**: state the situation, not the error code.
- **Error messages**: say what happened and what to do.
- **Placeholder text**: brief example of the expected input, not instructions.
- **Empty states**: explain why it's empty and what to do ("No favorites yet. Tap ♡ to save items.").
- **Avoid**: "Please…", "Error!", "Warning:", excessive exclamation marks.

### Inclusive Language
- Use gender-neutral terms: "they" not "he/she".
- Avoid idioms that don't translate.
- Prefer direct descriptions over metaphors.
- Avoid ableist language.
