# Designing for watchOS

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos

## Core Principle: Glanceability

Watch interactions are short — typically under 15 seconds. Design for the smallest unit of meaningful action:
- Show the most important information immediately.
- Minimize input; prefer smart defaults and system-suggested completions.
- Support voice input (Siri) for any text entry.

---

## Screen Sizes

| Watch size | Points |
|---|---|
| 40mm | 162 × 197 |
| 41mm | 176 × 215 |
| 44mm | 184 × 224 |
| 45mm | 198 × 242 |
| 49mm (Ultra) | 205 × 251 |

Always design and test at both 40/41mm (smaller) and 44/45mm+ (larger). Font sizes that look fine large may be unreadable small.

---

## Navigation

### Hierarchical (default)
Drill down with a push/pop stack, like iOS. Use for task-oriented apps.

```swift
NavigationStack {
    List(items) { item in
        NavigationLink(item.title) {
            DetailView(item: item)
        }
    }
}
```

### Page-Based
Horizontal page swiping. Use for apps with a small number of peer views (e.g. different data views for the same concept).

```swift
TabView {
    PageOne()
    PageTwo()
}
.tabViewStyle(.page)
```

### Modal
Use `.sheet()` sparingly — it covers the full screen and blocks navigation back.

---

## Layout

- Use the full screen width; the system provides safe area insets.
- Margins: 4 pt from edges on 40mm, up to 8 pt on larger sizes. SwiftUI handles this automatically.
- List rows: at least 44 pt tall — hard on a small watch; keep content tight.
- Avoid horizontal scrolling.
- Scroll vertically; don't paginate content that should scroll.

---

## Digital Crown

The crown is the primary scroll input. It's automatically wired to scroll views.

For custom use:
```swift
.focusable()
.digitalCrownRotation($value)
```

Use crown rotation for: adjusting values, scrolling through time, zooming. Don't require crown input for primary navigation (not all watches have crown available for custom use in every context).

---

## Typography

Use system fonts only. watchOS automatically scales font for watch size.

| Style | Use |
|---|---|
| `largeTitle` | Hero value (e.g. heart rate number) |
| `title` / `title2` / `title3` | Main labels |
| `headline` | Row labels |
| `body` | Default text |
| `footnote` | Small supporting detail |
| `caption` / `caption2` | Smallest labels |

**Never hard-code font sizes.** Keep labels short — aim for 1 line.

---

## Color

- Dark backgrounds with light text are the watchOS default — they show less through the bezel.
- Semantic colors: `.primary`, `.secondary`, `.accentColor` work as expected.
- Avoid light backgrounds behind text; contrast suffers on the OLED screen.
- Use vibrant, saturated colors for accent/highlight only.

---

## Complications

Complications appear on watch faces. They're the highest-value touch point — a user checks their watch face dozens of times a day.

### Complication Families
| Family | Size | Notes |
|---|---|---|
| Modular Small | ~52×52 | Icon or small value |
| Modular Large | ~148×69 | Title + body |
| Utilitarian Small | ~42×42 | Icon |
| Utilitarian Small Flat | ~160×42 | Short text |
| Utilitarian Large | ~160×42 | Longer text |
| Circular Small | ~52×52 | Ring or image |
| Extra Large | ~203×203 | Large value |
| Graphic Corner | ~40×40 | SwiftUI view |
| Graphic Circular | ~84×84 | Gauge, text, image |
| Graphic Rectangular | ~300×94 | Full-width view |
| Graphic Extra Large | Only Series 7+ | Large view |

### Providing Complication Data
Use `CLKComplicationDataSource` or `WidgetKit` (watchOS 7+) for complications:

```swift
// WidgetKit-based complications
struct MyComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MyComplication", provider: Provider()) { entry in
            ComplicationView(entry: entry)
        }
        .configurationDisplayName("My App")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}
```

Complication data should update frequently enough to stay accurate. Budget timeline entries carefully — watchOS batches updates.

---

## Notifications

Watch notifications come in two forms:

**Short Look** — Displayed for ~1 second when the watch is raised. App icon + title only. Cannot customize.

**Long Look** — Shown when the user keeps looking at the watch.
- `header`: app icon + color band
- `body`: custom notification content view
- `footer`: action buttons (up to 4)

```swift
// Custom notification view
struct NotificationView: WKUserNotificationHostingController<NotificationContent> {
    override var body: some View {
        // custom content
    }
}
```

Keep notification content immediately readable — one glance should convey the key info.

---

## App Lifecycle and Background

watchOS aggressively suspends apps. Design for this:
- Save state frequently; restore cleanly.
- Use background app refresh (`WKApplicationRefreshBackgroundTask`) for periodic updates.
- Use `URLSession` background sessions for data fetches.
- Use HealthKit background delivery for health data.
- Long-running workouts use `HKWorkoutSession`.

---

## Inputs

### Buttons
Large, full-width buttons where possible. List rows act as buttons.

```swift
Button("Start Workout") { ... }
    .buttonStyle(.borderedProminent)
```

### Text Entry
Avoid keyboard input — the watch keyboard is tiny. Instead:
- Use `inputLabel` with Scribble/dictation
- Provide a set of quick-reply options (for messaging)
- Use voice: present `WKTextInputController` or `AVSpeechSynthesizer`

### Haptics
`WKInterfaceDevice.current().play(.success)` etc. Use for:
- Confirming completed actions (`.success`)
- Alerts needing attention (`.notification`)
- Navigation steps (`.directionUp`, `.directionDown`)
- Timer/workout milestones

---

## Health and Workout

For workout or health apps:
- Start an `HKWorkoutSession` to keep the app active and in the foreground during workouts.
- Use `HKLiveWorkoutBuilder` to collect live workout data.
- Show workout metrics in large, readable text — users glance quickly.
- Always On Display (Series 5+): provide a dimmed `TimelineView` view for the always-on state.

---

## Always On Display (AOD)

Series 5 and later have AOD. The active content appears dimmed.

```swift
@Environment(\.isLuminanceReduced) var isLuminanceReduced

var body: some View {
    if isLuminanceReduced {
        // simplified, lower-power view
    } else {
        // full view
    }
}
```

In AOD:
- Use TimelineView for time-based updates
- Reduce color saturation; prefer white/grey on black
- Remove animations and gradients
- Show the most essential information only

---

## Watch App Icon

- 1024×1024 px source
- Square format; the system applies the circular crop
- Simple, readable at tiny sizes
