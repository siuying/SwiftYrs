# Designing for macOS

Source: https://developer.apple.com/design/human-interface-guidelines/designing-for-macos

## macOS Is Not iOS

The most common mistake: treating a Mac app as a scaled-up iPad app. macOS has its own idioms. Users expect:
- A **menu bar** with full app functionality exposed.
- **Window management** — multiple windows, resizing, full screen.
- **Pointer** — hover states, right-click, scroll wheel.
- **Keyboard** — full keyboard navigation, shortcuts for everything important.

Mac Catalyst ports are acceptable as a starting point, but optimize with `UIUserInterfaceIdiom.mac` conditional code or switch to AppKit/SwiftUI on macOS.

---

## Window Management

### Window Types
| Type | Use |
|---|---|
| Document window | Content the user created / saved |
| Utility window | Floating inspector/tool panel |
| Full-screen | Immersive focus mode |
| Panel | Detached toolbar or palette |

- Support **window resizing** unless there's a compelling reason not to.
- Provide a **minimum window size** that keeps the UI usable.
- Restore window position/size between launches (`NSWindow.setFrameAutosaveName`).
- Full-screen: hide the menu bar, support spaces.

### Title Bar
- Document-based: show the filename; support proxy icon drag.
- Non-document: use a clear app-context title.
- Prefer toolbar buttons over title bar buttons for common actions.

---

## Menu Bar

Every Mac app must have a complete, functional menu bar. This is not optional.

### Required Menus
- **App menu** (named after the app): About, Preferences/Settings, Services, Hide, Quit.
- **File**: New, Open, Close, Save, Revert, Print.
- **Edit**: Undo, Redo, Cut, Copy, Paste, Select All, Find.
- **View**: Show/hide panels, zoom, enter full screen.
- **Window**: Minimize, Zoom, Tile, bring windows to front, window list.
- **Help**: App Help (opens help book).

### Keyboard Shortcuts
Assign shortcuts to every frequent action. Follow Apple's standard assignments:
- ⌘N New, ⌘O Open, ⌘S Save, ⌘W Close, ⌘Q Quit
- ⌘Z Undo, ⌘⇧Z Redo, ⌘X Cut, ⌘C Copy, ⌘V Paste
- ⌘, Preferences/Settings
- ⌘? Help
- ⌘M Minimize

---

## Navigation

macOS uses window-based navigation, not a navigation stack like iOS.

- **Source list** (sidebar): shows a hierarchical list of items; selecting an item updates the detail area. Use `NSOutlineView` / SwiftUI `List` with `.listStyle(.sidebar)`.
- **Toolbar**: primary actions for the current window. Customizable by user (`toolbar.allowsUserCustomization`).
- **Tab bar** (document windows): multiple documents in one window, like Safari tabs.
- **Breadcrumb / path control**: for file-system navigation (use `NSPathControl`).

---

## Pointer and Mouse

All interactive elements must respond to the pointer:

- **Hover effects**: highlight buttons on hover; show tooltips after a short delay.
- **Cursor**: change cursor to `pointingHand` over links, `crosshair` in drawing, `resizeLeftRight` at resize handles.
- **Right-click / Control-click**: always show a context menu with relevant actions.
- **Scroll wheel**: scroll containers respond to scroll wheel without extra configuration.

---

## Keyboard Navigation

- Support **Tab** to move between controls, **Space** to activate buttons.
- `acceptsFirstResponder` must return `true` on any custom focusable view.
- Support **Full Keyboard Access** (System Settings → Keyboard → Full Keyboard Access).
- Never design a workflow that requires a mouse.

---

## Controls

Use AppKit / SwiftUI system controls; they automatically match macOS appearance and theme.

| Control | AppKit | SwiftUI |
|---|---|---|
| Button | `NSButton` | `Button` |
| Segmented | `NSSegmentedControl` | `Picker(.segmented)` |
| Checkbox | `NSButton(.switch)` | `Toggle` |
| Radio | `NSButton(.radio)` | `Picker` with radio style |
| Slider | `NSSlider` | `Slider` |
| Stepper | `NSStepper` | `Stepper` |
| Pop-up | `NSPopUpButton` | `Picker(.menu)` |
| Combo box | `NSComboBox` | `ComboBox` |
| Text field | `NSTextField` | `TextField` |
| Date picker | `NSDatePicker` | `DatePicker` |

Minimum control size: buttons ≥ 32 pt tall; input fields ≥ 22 pt tall.

---

## Toolbars

- Toolbar items are typically icon-only with tooltip, or icon + label at large size.
- Use `NSToolbar` with `NSToolbarItem` identifiers; allow customization.
- SwiftUI: use `.toolbar { ToolbarItem(placement: .primaryAction) { ... } }`.
- Keep to the 5–7 most important actions; put others in the menu bar.

---

## Sidebars

Sidebars show navigation content (mailboxes, playlists, file system). Use `.listStyle(.sidebar)` in SwiftUI.

- Width: typically 200–260 pt; user-resizable.
- Collapsible with a toolbar button.
- Groups: use disclosure groups for collapsible sections.
- Icons: use SF Symbols at 16 pt.

---

## Inspectors / Panels

- Floating inspector panels for properties of a selected object.
- Use `NSPanel` (floats above document windows) or a trailing sidebar.
- Keep inspector lightweight — it should not block the main workflow.

---

## Typography

Mac uses the same SF Pro family as iOS, but at denser sizes (default body is 13 pt).

| Style | Default size | Use |
|---|---|---|
| Title 1 | 28 | Large headings |
| Title 2 | 22 | Section headings |
| Title 3 | 18 | Sub-section headings |
| Headline | 13 bold | Row/column labels |
| Body | 13 | Primary content |
| Callout | 12 | Secondary labels |
| Subheadline | 11 | Small labels |
| Footnote | 10 | Captions |

---

## Color and Appearance

- Support **Dark Mode** and **Light Mode** automatically using semantic colors.
- Support **accent color** — the user's chosen accent propagates to all controls.
- Semantic colors: `NSColor.labelColor`, `.secondaryLabelColor`, `.windowBackgroundColor`, `.controlBackgroundColor`, `.separatorColor`.
- **High Contrast** mode: avoid custom colors that reduce contrast.
- Vibrancy / materials: use `NSVisualEffectView` for sidebars, panels, and toolbars.

---

## Dialogs and Alerts

- **Alert** (`NSAlert`): use sparingly; only for errors, warnings, confirmations of destructive actions.
- **Sheet**: attached to a window; blocks the window but not the app. Prefer sheets over floating alerts.
- **Open / Save panels**: use `NSOpenPanel` / `NSSavePanel`; never build a custom file picker.
- **Confirmation before destructive actions**: always use a sheet with Cancel and destructive-titled button (e.g. "Delete", not "OK").

---

## Drag and Drop

Mac users expect drag and drop everywhere. Register every view that should accept drops.

```swift
// SwiftUI
.dropDestination(for: URL.self) { urls, _ in ... }
// AppKit
registerForDraggedTypes([.fileURL, .string])
```

---

## App Icons

macOS icons are square with rounded corners (the system applies the corner radius). Provide a 1024×1024 px version and all smaller sizes. macOS icons are more detailed and realistic than iOS icons — they have a 3D quality with perspective.

---

## Preferences / Settings

- Use `NSPreferencesWindowController` or SwiftUI `Settings { ... }` on macOS 13+.
- Organize with toolbar tabs for multiple sections.
- Changes apply immediately (no OK/Apply); Undo is available for discrete changes.
- Shortcut: ⌘, opens preferences.

---

## Services

Expose your app's capabilities via the Services menu (`NSServices`). This lets other apps pass text/data to your app.

---

## Mac Catalyst Notes

When using Mac Catalyst:
- Set `UIUserInterfaceIdiom.mac` targeted interface to `.mac` (not `.pad`).
- Replace `UIBarButtonItem` with toolbar items.
- Replace `UIAlertController` sheets with `NSAlert`.
- Remove swipe-to-delete; use context menus or toolbar delete.
- Provide a real menu bar structure.
