# Designing for iOS and iPadOS

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-ios

## iOS vs iPadOS

iOS and iPadOS share the same HIG foundations. iPadOS adds:
- **Multitasking**: Stage Manager, Split View, Slide Over — apps must work at multiple sizes.
- **Pointer support**: iPad supports trackpad/mouse; interactive elements should respond to hover.
- **Larger canvas**: Use adaptive layouts, not just scaled-up iPhone layouts.
- **Keyboard shortcuts**: iPad users with keyboards expect discoverable shortcuts.

---

## Screen and Layout

### Safe Areas
Always lay out content within safe areas. System chrome (status bar, home indicator, notch/Dynamic Island) lives outside them.

```swift
// SwiftUI — automatic
.ignoresSafeArea(.container, edges: .bottom) // only when content should extend edge-to-edge

// UIKit
view.safeAreaLayoutGuide.topAnchor
```

### Home Indicator
- Leave the bottom safe area clear — never place interactive controls where the home indicator sits.
- The system dims the indicator on full-screen media; don't interfere with this.

### Dynamic Island (iPhone 14 Pro+)
- Never manually position UI to avoid the Dynamic Island; the safe area handles it.
- Live Activities appear in the Dynamic Island — provide a compact and expanded presentation.

### Display Sizes (points, not pixels)
- Smallest (SE): 375 × 667
- Standard (iPhone 15): 390 × 844
- Pro Max: 430 × 932
- Tablet (iPad mini): 744 × 1133 → (iPad Pro 13"): 1024 × 1366

Test at both extremes. Use Auto Layout / SwiftUI's adaptive containers.

---

## Navigation

### Navigation Hierarchy
Use `UINavigationController` / `NavigationStack`. The system Back button and swipe-back gesture are expectations, not options.
- Title: short, noun-phrase (e.g. "Settings", not "Manage Your Settings")
- Large title at root; standard title in detail views.
- `navigationTitle` + `.navigationBarTitleDisplayMode(.large)` at root.

### Tab Bar
- 2–5 tabs; each tab holds an independent navigation stack.
- Always show the tab bar except in full-screen video/reading.
- Use SF Symbols for tab icons; provide selected/unselected states.
- Badge counts: use for actionable items, not informational counts.

### Modal Sheets
- Use for self-contained tasks that don't belong in the navigation hierarchy.
- `.presentationDetents([.medium, .large])` for adjustable sheets (iOS 16+).
- Always provide a clear dismissal path (Done/Cancel button or swipe down).

---

## Touch and Gestures

### Tap Target Minimum
**44 × 44 pt** for all interactive controls. Expand the hit area without enlarging the visual:

```swift
.contentShape(Rectangle()) // SwiftUI
// UIKit: override pointInside(_:with:) in custom view
```

### Standard Gestures (don't override)
| Gesture | System meaning |
|---|---|
| Swipe from left edge | Back navigation |
| Swipe from right edge | Forward (where applicable) |
| Pinch | Zoom |
| Long press | Context menu / peek |
| Swipe down from top | Notification Center |
| Swipe up from bottom | Home / App Switcher |

Only intercept gestures the system doesn't own in your view's coordinate space.

### Haptics
Use `UIFeedbackGenerator` for meaningful moments:
- `UIImpactFeedbackGenerator` — physical impacts, toggles flipping
- `UINotificationFeedbackGenerator` — success / warning / error
- `UISelectionFeedbackGenerator` — selection changes in pickers

---

## Typography

Use Dynamic Type. Never `UIFont(name:size:)` with a hard-coded size unless brand requires it (and even then, scale relative to user preference).

| Style | Use |
|---|---|
| `largeTitle` | Hero headings |
| `title1–3` | Section headings |
| `headline` | Row titles, list headers |
| `body` | Primary body copy |
| `callout` | Secondary body |
| `subheadline` | Supporting text |
| `footnote` | Captions, timestamps |
| `caption1–2` | Smallest labeling |

Set `adjustsFontForContentSizeCategory = true` on all `UILabel` / use `.font(.body)` in SwiftUI.

---

## Color

Use semantic colors so Dark Mode and accessibility work automatically:

```swift
// UIKit
UIColor.label                    // primary text
UIColor.secondaryLabel           // secondary text
UIColor.systemBackground         // primary background
UIColor.secondarySystemBackground
UIColor.systemGroupedBackground  // grouped table background
UIColor.systemBlue               // interactive tint
UIColor.systemRed                // destructive actions

// SwiftUI equivalents
Color.primary
Color(.systemBackground)
Color.accentColor
```

Never use literal hex colors for text or backgrounds unless branding requires it. Even then, provide Dark Mode variants.

---

## Status Bar

- Use `preferredStatusBarStyle` to choose `.default` (dark icons) or `.lightContent` (white icons).
- Full-screen content: hide with `prefersStatusBarHidden`.
- Color behind status bar is determined by the navigation bar's appearance — don't paint over it.

---

## Lists and Tables

`UITableView` / `UICollectionView` with `UIListContentConfiguration` for standard rows. SwiftUI `List`.

- **Swipe actions**: Confirm destructive actions (`.destructive` style auto-adds red).
- **Pull to refresh**: `UIRefreshControl`; expected for content feeds.
- **Separator insets**: Match the leading alignment of text in the row.

---

## iPad-Specific

### Multitasking Sizes
Your app can appear at: full width, 2/3, 1/2, 1/3 of the screen. Test all three.

```swift
// Respond to size changes
override func viewWillTransition(to size: CGSize, with coordinator: ...)
// SwiftUI: use GeometryReader or @Environment(\.horizontalSizeClass)
```

### Sidebar + Split View
Prefer a sidebar + detail pattern on iPad over a tab bar pattern (use tab bar on iPhone, sidebar on iPad).

```swift
// SwiftUI
NavigationSplitView {
    // sidebar
} detail: {
    // detail
}
```

### Pointer / Hover
Add hover effects to interactive elements:

```swift
.hoverEffect(.lift)  // SwiftUI
// UIKit: UIHoverGestureRecognizer, UIPointerInteraction
```

### Drag and Drop
iPad users expect drag and drop across apps. Implement `UIDropInteraction` / SwiftUI `.dropDestination()`.

---

## App Icons

- Provide all required sizes in the asset catalog (20, 29, 38, 40, 60, 76, 83.5, 1024 pt).
- Use the standard iOS corner radius grid — Xcode clips automatically; don't pre-clip.
- No transparency; no text (legibility at small sizes); no screenshots of the UI.

---

## Keyboards

- Set `keyboardType`, `returnKeyType`, `textContentType`, `autocorrectionType`, `autocapitalizationType` on all text fields.
- Scroll content above the keyboard. Use `KeyboardLayoutGuide` (iOS 15+) or observe `keyboardWillShow`.
- Dismiss keyboard: tap outside (make the background view the first responder) or use a toolbar Done button.

---

## Notifications

- Request permission at a meaningful moment with context, not at launch.
- Provide a `UNNotificationCategory` with relevant actions.
- Use notification grouping (`threadIdentifier`) for multi-message apps.
- Support notification summaries (iOS 15+) via `summaryArgument`.
