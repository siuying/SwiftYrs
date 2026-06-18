# Accessibility

Source: https://developer.apple.com/design/human-interface-guidelines/accessibility

## Read This First

Accessibility is not an afterthought — it must be designed in from the start. On Apple platforms, most accessibility support comes for free when you use system components correctly. Custom UI requires explicit accessibility work.

Test with VoiceOver on iPhone and Mac, and enable each relevant accessibility feature in Settings. Don't rely on automated checks alone.

---

## VoiceOver

VoiceOver is a screen reader that reads the interface aloud and allows full navigation using swipe gestures or a keyboard.

### Every element needs:
1. **Label**: short name (noun phrase). "Add to Favorites", not "Star button".
2. **Traits**: `.button`, `.link`, `.header`, `.image`, `.staticText`, `.adjustable`, `.selected`, `.notEnabled`.
3. **Value** (for controls): the current state. Toggle: "On" or "Off".
4. **Hint** (optional): one sentence beginning with a verb, describing what happens. Use only when label isn't enough.

```swift
// SwiftUI
Button(action: add) {
    Image(systemName: "star")
}
.accessibilityLabel("Add to Favorites")
.accessibilityHint("Adds this item to your favorites list")

// Hide decorative images
Image("decorativeBackground")
    .accessibilityHidden(true)
```

```swift
// UIKit
button.accessibilityLabel = "Add to Favorites"
button.accessibilityTraits = .button
imageView.isAccessibilityElement = false
```

### Navigation Order
VoiceOver reads elements in the order they appear in the accessibility tree (typically top-left to bottom-right). Fix non-visual-order elements explicitly:

```swift
// Group related elements
VStack {
    Text("Price")
    Text("$9.99")
}
.accessibilityElement(children: .combine) // reads as one: "Price, $9.99"

// Custom sort order
.accessibilitySortPriority(1) // higher = read first
```

### Custom Actions
For complex controls, provide custom actions instead of relying on multiple taps:

```swift
Text(message.body)
    .accessibilityAction(named: "Reply") { replyToMessage() }
    .accessibilityAction(named: "Delete") { deleteMessage() }
```

---

## Dynamic Type

Never hard-code font sizes. Always use Dynamic Type styles.

```swift
// SwiftUI (automatic)
Text("Hello").font(.body)

// UIKit
label.font = UIFont.preferredFont(forTextStyle: .body)
label.adjustsFontForContentSizeCategory = true
```

### Handle Large Text
At the largest accessibility sizes (AX1–AX5), layouts break if they can't flex. Design for it:
- Use flexible container heights (never fixed row heights for text rows).
- Allow multi-line labels; avoid `lineLimit(1)` without truncation fallback.
- Consider alternative layouts at large sizes: stack horizontally when small, stack vertically at large.

```swift
@Environment(\.dynamicTypeSize) var typeSize

VStack {
    if typeSize.isAccessibilitySize {
        VStack { label; control } // vertical stack at large sizes
    } else {
        HStack { label; control }
    }
}
```

---

## Color and Contrast

### Minimum Contrast Ratios
- **Normal text** (< 18 pt regular / 14 pt bold): **4.5:1** contrast ratio.
- **Large text** (≥ 18 pt regular / ≥ 14 pt bold): **3:1** contrast ratio.
- **UI components and graphical objects**: **3:1** against adjacent colors.

Never use color as the sole means of conveying information (e.g. red = error must also have an icon or text label).

### Increase Contrast
Respect the "Increase Contrast" setting. Avoid thin borders and low-contrast overlays.

```swift
@Environment(\.colorSchemeContrast) var contrast
// .standard or .increased
```

### Color Blind Users
~8% of men have some form of color vision deficiency. Test your UI with color blindness simulators (Xcode Accessibility Inspector).

---

## Reduce Motion

Many users experience vestibular disorders and find large-scale animations distressing.

```swift
@Environment(\.accessibilityReduceMotion) var reduceMotion

withAnimation(reduceMotion ? nil : .spring()) {
    // animate
}
```

Avoid:
- Auto-playing parallax effects.
- Rapid flashing or strobing (risk of seizure).
- Large-scale positional animations when reduced motion is enabled.

Replace with: cross-fades, instant transitions, or subtle scale animations.

---

## Switch Control

Switch Control lets users navigate with a hardware switch, scanning through focusable elements.

- Ensure all interactive elements are reachable in a logical scan order.
- Group related elements so scanning doesn't require stepping through each one.
- Custom controls: use `accessibilityActivate()` override for non-standard activation.

---

## Voice Control

Voice Control lets users control the app entirely by voice. It labels every interactive element and lets users say the label to activate it.

- Ensure accessibility labels are pronounceable words/phrases.
- Unique labels: if two buttons have the same visible text, give them different accessibility labels so Voice Control can disambiguate.
- Numeric labels for lists: items without visible text get numbered in Voice Control's overlay.

---

## Keyboard Navigation

On Mac, iPad, and visionOS — and any iOS device with a keyboard — full keyboard navigation is expected.

- All interactive elements must be reachable by Tab key.
- Custom views: implement `canBecomeFirstResponder`/`acceptsFirstResponder`.
- Space activates the focused control; Return activates the default button.
- Escape dismisses dialogs/sheets.

```swift
// SwiftUI keyboard shortcuts
Button("Submit") { submit() }
    .keyboardShortcut(.return, modifiers: [])
```

---

## Text-to-Speech and Audio

- For audio-only content, provide transcripts.
- For video, provide closed captions and audio descriptions.
- Use `AVSpeechSynthesizer` for in-app speech, respecting the user's preferred language.

---

## Accessible Custom Controls

When building a custom control that has no system equivalent:

1. Subclass `UIControl` / `NSControl` (not `UIView`) — you get accessibility traits for free.
2. Set `.accessibilityTraits` to the closest matching trait.
3. Override `accessibilityActivate()` for custom activation logic.
4. Use `.accessibilityValue` to report the current state.
5. For slider-like controls: use `.adjustable` trait and implement `accessibilityIncrement()` / `accessibilityDecrement()`.

```swift
// SwiftUI custom slider-like control
MySlider()
    .accessibilityValue("\(Int(value))%")
    .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: value = min(100, value + 5)
        case .decrement: value = max(0, value - 5)
        }
    }
```

---

## Focus Management

When content changes (a view appears, a task completes), move focus appropriately:

```swift
// SwiftUI
@AccessibilityFocusState private var isFieldFocused: Bool
TextField("Name", text: $name)
    .accessibilityFocused($isFieldFocused)
// later: isFieldFocused = true
```

After dismissing a modal, return focus to the element that triggered it.

---

## Testing Checklist

- [ ] VoiceOver: navigate every screen; all elements have labels and correct traits.
- [ ] Dynamic Type AX5: no text truncation or layout breaks.
- [ ] Color blindness simulator: no information conveyed by color alone.
- [ ] Reduce Motion enabled: no jarring animations.
- [ ] Increase Contrast: all text and UI elements meet contrast ratios.
- [ ] Keyboard navigation: every interaction reachable without a pointer.
- [ ] Accessibility Inspector (Xcode): run the audit; fix all issues flagged as errors.
