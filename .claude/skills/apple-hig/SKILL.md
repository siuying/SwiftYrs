---
name: apple-hig
description: Apple Human Interface Guidelines reference. Use when designing or reviewing UI/UX for iOS, iPadOS, macOS, watchOS, tvOS, or visionOS apps, or when decisions arise about accessibility, Siri, components, patterns, inputs, or platform conventions. Invoke before adding UI elements, reviewing layout code, or choosing between platform idioms.
---

# Apple Human Interface Guidelines

Reference for building apps that feel at home on Apple platforms. The HIG's central principle: people should be able to predict how your app behaves because it uses platform conventions consistently.

## Quick Platform Lookup

Read the relevant detail file before making platform-specific UI decisions:

| Platform | Detail file | Key differentiator |
|---|---|---|
| iOS / iPadOS | `ios.md` | Touch-first, safe areas, home indicator |
| macOS | `macos.md` | Pointer, menu bar, window management |
| watchOS | `watchos.md` | Glanceable, Digital Crown, complications |
| tvOS | `tvos.md` | Focus engine, remote, lean-back |
| visionOS | `visionos.md` | Spatial windows, eye+hand input, depth |

## Topic Detail Files

| Topic | File | When to read |
|---|---|---|
| Accessibility | `accessibility.md` | Any UI change — read first |
| Foundations | `foundations.md` | Color, typography, layout, motion, dark mode |
| Components | `components.md` | Choosing or customizing a UIKit/AppKit/SwiftUI element |
| Patterns | `patterns.md` | Navigation, onboarding, modality, sharing, notifications |
| Siri & Voice | `siri.md` | Adding Intents, App Shortcuts, voice UI |

## The Three Themes

Apple's design is organized around three overarching themes that every app should express:

1. **Clarity** — Text is legible at all sizes. Icons are precise and lucid. Ornaments are subtle and appropriate. Every element forwards the purpose.
2. **Deference** — Fluid motion and a crisp, beautiful interface help people understand and interact with content without competing with it.
3. **Depth** — Visual layers and realistic motion convey hierarchy, confer vitality, and facilitate understanding.

## Core Principles (Apply Everywhere)

### Prefer system over custom
- Use system fonts (SF Pro, SF Compact, New York) and `UIFont.preferredFont` / `.body` / `.headline` Dynamic Type styles.
- Use SF Symbols for icons — they automatically match font weight, scale, and color.
- Use semantic system colors (`label`, `secondaryLabel`, `systemBackground`, `systemGroupedBackground`) so Dark Mode and accessibility just work.
- Use UIKit/AppKit/SwiftUI system components before building custom ones.

### Respect user preferences
- Honor Dynamic Type — never hard-code font sizes.
- Honor Reduce Motion — offer alternatives to parallax and large-scale animations.
- Honor Increase Contrast — avoid thin strokes and low-contrast overlays.
- Honor Dark Mode — use semantic colors; test in both appearances.

### Design for all sizes
- Use Auto Layout / SwiftUI layout system with relative spacing.
- Respect safe areas on all platforms.
- Minimum tappable target: **44×44 pt**.
- Use `UITraitCollection` / `@Environment(\.sizeCategory)` to adapt layouts.

### Prioritize content over chrome
- Remove controls that aren't needed for the current task.
- Use progressive disclosure — show detail on demand.
- Never use decorative chrome that competes with user content.

## Common Mistakes to Avoid

| Mistake | Correct approach |
|---|---|
| Hard-coded colors | Use semantic system colors |
| Fixed font sizes | Use Dynamic Type styles |
| Covering the home indicator | Leave the bottom safe area clear |
| Alerts for non-destructive confirmations | Use inline feedback instead |
| Custom navigation that breaks Back gesture | Use system navigation containers |
| Requesting permissions at launch | Request at point of use with context |
| Mimicking iOS on macOS | Use AppKit conventions on Mac |
| Sub-44pt tap targets | Expand hit area, shrink visual if needed |

## How to Use This Skill

1. Identify the target platform(s).
2. Read the platform detail file.
3. Read any relevant topic files (accessibility always, components if adding UI).
4. Apply the guidance to the code/review task.
5. When in doubt, choose the system-provided behavior over a custom one.

Source: https://developer.apple.com/design/human-interface-guidelines/
