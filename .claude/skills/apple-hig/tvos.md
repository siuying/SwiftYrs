# Designing for tvOS

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-tvos

## Core Principle: Lean Back

TV is a shared, lean-back experience viewed from ~3 meters away. Users navigate with the Siri Remote (or a game controller), not touch. Design for:
- **Distance**: large text, clear focus states, minimal density.
- **Shared screens**: content appropriate for a household.
- **Remote navigation**: directional pad + select; no free pointer (unless hover is used via the trackpad surface of the Siri Remote).

---

## Focus Engine

The focus engine is tvOS's core interaction model. Every interactive element can receive focus; the remote moves focus between them.

### Rules
- All interactive controls (buttons, table rows, collection cells) are focusable by default.
- SwiftUI: focusable elements get focus automatically.
- UIKit: `canBecomeFocused` returns `true` by default for `UIButton`, `UITableViewCell`, `UICollectionViewCell`.

### Focus Appearance
When an element is focused, it grows slightly and a glow/shadow appears — the **parallax effect**. Never suppress this without a strong reason.

```swift
// SwiftUI: focus state
@FocusState private var isFocused: Bool

// UIKit: override to customize appearance
override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) { ... }
```

### Focus Management
- Guide the focus to the most important element when a screen appears.
- Don't let focus get stuck in unreachable areas.
- Use `UIFocusGuide` to redirect focus around gaps between elements.

---

## Layout and Screen

### Overscan Safe Area
TVs may overscan (crop edges). Keep critical content inside the **safe zone**: 60 pt from each edge. SwiftUI safe areas handle this automatically.

### Resolution
tvOS renders at 1920×1080 (1080p) or 3840×2160 (4K). The logical coordinate space is 1920×1080 points.

### Layout Margins
Use generous margins. A typical content inset from the screen edge: 90 pt (left/right), 60 pt (top/bottom).

### Density
Keep layouts sparse. Don't port phone-density UIs. Use large cards, large text, lots of breathing room.

---

## Typography

Text must be readable from 3 meters away.

| Style | Approximate size | Use |
|---|---|---|
| `largeTitle` | 76 pt | Hero headings |
| `title1` | 57 pt | Page titles |
| `title2` | 47 pt | Section headings |
| `title3` | 39 pt | Sub-section |
| `headline` | 29 pt bold | Card labels |
| `body` | 29 pt | Content |
| `callout` | 25 pt | Secondary |
| `footnote` | 19 pt | Minimum useful size |

Body text at 29 pt is the effective minimum for comfortable TV viewing.

---

## Navigation

### Tab Bar
Top-mounted tab bar is the standard navigation model for tvOS apps.

```swift
TabView {
    HomeView().tabItem { Label("Home", systemImage: "house") }
    SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
}
```

- Tabs appear along the top; selecting a tab swipes the content area.
- When the user swipes up from content, focus returns to the tab bar.

### Page / Collection Navigation
Use horizontal scrolling collections for content rows (e.g. Netflix-style rows).

```swift
ScrollView(.horizontal) {
    LazyHStack {
        ForEach(items) { item in
            CardView(item: item)
                .focusable()
        }
    }
}
```

### Modals
Limit modal use. If needed, use full-screen presentations. Provide a clear way to dismiss (Back button / Menu button).

---

## Remote and Input

### Siri Remote Controls
| Input | Action |
|---|---|
| Swipe (trackpad surface) | Move focus / scroll |
| Click (trackpad) | Select |
| Menu button | Back / dismiss |
| TV button | Home screen |
| Play/Pause | Play/pause media |
| Siri button | Siri |

### Back/Menu Button
Always handle the Menu button as a "back" or "dismiss" — never trap the user. This is enforced by the system for root-level screens (returns to Apple TV home).

### Game Controllers
Many Apple TV users have MFi controllers. Support them if your app has any game-like interaction.

---

## Content and Cards

Cards are the primary content unit.

- Standard card size: ~308×185 pt (16:9 thumbnail) for media content.
- Include a title label and optional subtitle below each card.
- Focused cards display the parallax effect; layered images (3 layers) enhance this.
- Use `TVMonoscapeImage` (tvOS-specific API) for layered parallax images.

---

## Buttons

- Full-width buttons are common on tvOS confirmation screens.
- Button height: at least 60 pt.
- Group primary and secondary actions at the bottom of a form/alert.
- The focused button should be visually obvious (system handles this automatically).

---

## Alerts

Use `UIAlertController` (`.alert` style) for confirmations. Keep to a maximum of 3 buttons. The top button receives initial focus.

---

## Media Playback

For video apps, use `AVPlayerViewController`. It provides:
- Transport controls (play/pause, scrub)
- Info panel
- Chapter navigation
- AirPlay/subtitle controls

Customize the info panel via `AVCustomRoutingController` and content proposal.

Always support:
- **AirPlay**: automatic with `AVPlayerViewController`.
- **Subtitles / Closed Captions**: via `AVMediaSelectionGroup`.
- **Resume playback**: restore position when the user returns.

---

## Top Shelf Extension

The Top Shelf appears when your app is in the top row of the home screen.

- **Static**: single image (2320×720 px).
- **Dynamic**: scrollable content rows using `TVTopShelfItemCollection`.

Provide dynamic Top Shelf content for content-rich apps (streaming, news, games).

---

## App Icons

tvOS icons use a layered format (2–5 layers) to create a parallax effect when focused.

- Main icon: 400×240 pt (layered image)
- App Store icon: 1280×768 px
- Each layer is a PNG with transparent areas; the parallax effect separates them in Z.

---

## Onboarding and Sign-In

- Defer authentication — let users explore before requiring a sign-in.
- Support **Sign In with Apple** and **TV Provider authentication** (TVAuthenticationHelper).
- One-time sign-in only: once authenticated, never ask again unless the user signs out.
- Use QR codes or companion app sign-in to avoid typing on TV.
