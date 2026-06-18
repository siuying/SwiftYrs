# Components

Source: https://developer.apple.com/design/human-interface-guidelines/components

Quick reference for choosing and using system UI components correctly. Always prefer system components over custom ones.

---

## Buttons

### When to use each button style
| Style | Use |
|---|---|
| Filled (primary) | Most important action; one per view |
| Filled tonal | Secondary action with emphasis |
| Bordered | Secondary action |
| Borderless | Inline or low-emphasis action |
| Destructive | Delete, remove, irreversible actions |

```swift
// SwiftUI
Button("Add to Cart") { ... }
    .buttonStyle(.borderedProminent)  // primary, filled

Button("Cancel") { ... }
    .buttonStyle(.bordered)           // secondary

Button("Delete", role: .destructive) { ... }
    .buttonStyle(.bordered)
```

### Rules
- One primary (filled) button per view context; don't stack two filled buttons.
- Labels: verb + object ("Save Draft", not "Save" or "Yes").
- Destructive buttons: red, requires confirmation for irreversible actions.
- Minimum 44×44 pt touch target.
- Disable when the action is unavailable (don't hide it).

---

## Text Fields

```swift
TextField("Email", text: $email)
    .textContentType(.emailAddress)
    .keyboardType(.emailAddress)
    .autocorrectionDisabled()
    .autocapitalization(.never)
    .textFieldStyle(.roundedBorder)

SecureField("Password", text: $password)
    .textContentType(.password)
```

### Key attributes to always set
- `textContentType`: enables autofill (`.username`, `.password`, `.emailAddress`, `.newPassword`, `.oneTimeCode`, `.name`, `.streetAddressLine1`, `.postalCode`, etc.)
- `keyboardType`: shows the right keyboard (`.numberPad`, `.emailAddress`, `.URL`, `.phonePad`, `.decimalPad`)
- `autocorrectionType` / `autocapitalizationType`: turn off for usernames, emails, codes
- `returnKeyType`: `Next` to advance between fields, `Done` or `Go` for the last field

---

## Toggles / Switches

```swift
Toggle("Dark Mode", isOn: $isDarkMode)
    .toggleStyle(.switch)    // default on iOS
    .toggleStyle(.checkbox)  // macOS default
```

- For boolean settings only. Not for selecting between multiple options (use segmented control).
- Label on leading side; switch on trailing.
- No confirmation needed — it's reversible.

---

## Pickers and Segmented Controls

**Segmented control**: 2–5 exclusive options visible simultaneously.
```swift
Picker("View", selection: $viewMode) {
    Text("List").tag("list")
    Text("Grid").tag("grid")
}
.pickerStyle(.segmented)
```

**Picker (wheel/inline/menu)**: longer lists of options.
```swift
Picker("Category", selection: $category) {
    ForEach(categories) { cat in
        Text(cat.name).tag(cat)
    }
}
.pickerStyle(.menu)  // or .wheel, .inline
```

Use `.segmented` for small option sets that should all be visible; `.menu` for longer lists.

---

## Sliders

```swift
Slider(value: $volume, in: 0...100, step: 1)
    .accessibilityValue("\(Int(volume))%")
    .accessibilityAdjustableAction { direction in
        volume = direction == .increment
            ? min(100, volume + 1)
            : max(0, volume - 1)
    }
```

- Use for continuous value selection where the exact number matters less than the relative position.
- Provide labels at min/max ends.
- Always implement accessibility adjustable action.

---

## Steppers

```swift
Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
```

Use for small integer values where each step is meaningful. Not for large ranges.

---

## Date Pickers

```swift
DatePicker("Appointment", selection: $date, displayedComponents: [.date, .hourAndMinute])
    .datePickerStyle(.graphical)  // calendar view
    // or .compact (inline text)
    // or .wheel
```

Provide sensible `in: minimumDate...maximumDate` range when applicable.

---

## Lists and Tables

```swift
List {
    Section("Recent") {
        ForEach(items) { item in
            HStack {
                Image(systemName: item.icon)
                Text(item.title)
                Spacer()
                Text(item.subtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .onDelete { indexSet in deleteItems(at: indexSet) }
        .onMove { from, to in moveItems(from: from, to: to) }
    }
}
.listStyle(.insetGrouped)  // iOS grouped style
```

### List Styles
| Style | Platform | Use |
|---|---|---|
| `.insetGrouped` | iOS | Rounded grouped sections (Settings-like) |
| `.grouped` | iOS | Full-width grouped |
| `.plain` | iOS/macOS | Flat list without section backgrounds |
| `.sidebar` | macOS/iPadOS | Navigation sidebar |

### Swipe Actions
```swift
.swipeActions(edge: .trailing) {
    Button("Delete", role: .destructive) { delete(item) }
    Button("Archive") { archive(item) }.tint(.blue)
}
.swipeActions(edge: .leading) {
    Button("Flag") { flag(item) }.tint(.orange)
}
```

---

## Navigation (Navigation Bar / Tab Bar)

### Navigation Bar
```swift
NavigationStack {
    ContentView()
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.large)  // or .inline
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { compose() } label: { Image(systemName: "square.and.pencil") }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
}
```

Placements: `.primaryAction`, `.cancellationAction`, `.confirmationAction`, `.navigationBarLeading`, `.navigationBarTrailing`, `.bottomBar`, `.keyboard`

### Tab Bar
```swift
TabView(selection: $tab) {
    InboxView()
        .tabItem { Label("Inbox", systemImage: "tray") }
        .tag(Tab.inbox)
        .badge(unreadCount)
    
    SettingsView()
        .tabItem { Label("Settings", systemImage: "gear") }
        .tag(Tab.settings)
}
```

- Max 5 tabs. If more are needed, use a "More" tab or sidebar pattern on iPad.
- Tab icons: SF Symbols. Provide both filled (selected) and outline (unselected) variants.

---

## Sheets and Modals

```swift
// Sheet (swipe down to dismiss)
.sheet(isPresented: $showSheet) {
    MySheetView()
        .presentationDetents([.medium, .large])  // adjustable height
        .presentationDragIndicator(.visible)
}

// Full-screen cover (cannot swipe to dismiss)
.fullScreenCover(isPresented: $showFullScreen) {
    FullScreenView()
}
```

Always provide a dismissal path (button or drag). Full-screen covers need an explicit dismiss button.

---

## Alerts and Action Sheets

```swift
// Alert: for important information or confirmation
.alert("Delete Item?", isPresented: $showAlert) {
    Button("Delete", role: .destructive) { delete() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("This cannot be undone.")
}

// Confirmation dialog (action sheet): for choosing between multiple actions
.confirmationDialog("Share via", isPresented: $showShareDialog) {
    Button("Messages") { shareViaMessages() }
    Button("Mail") { shareViaMail() }
    Button("Cancel", role: .cancel) { }
}
```

- Alerts: max 2–3 buttons; destructive is prominent.
- Action sheets / confirmation dialogs: list of actions; Cancel always at the bottom.
- Don't use alerts for non-critical information — use inline feedback instead.

---

## Progress Indicators

```swift
// Determinate (known progress)
ProgressView(value: progress, total: 1.0)
    .progressViewStyle(.linear)

// Indeterminate (unknown duration)
ProgressView()  // spinning indicator
    .progressViewStyle(.circular)
```

- Use determinate when progress can be measured; it reduces user anxiety.
- Place close to the content being loaded, not in a blocking overlay.
- For short operations (< 1 s), don't show a spinner — it flashes and looks broken.

---

## Search Fields

```swift
.searchable(text: $searchQuery, prompt: "Search messages")
// Or with scopes:
.searchable(text: $searchQuery, tokens: $tokens, suggestedTokens: .constant(suggestions))
```

`searchable` modifier adds a search field to the navigation bar automatically. On iOS it appears above the list; on macOS in the toolbar.

---

## Menus and Context Menus

```swift
// Context menu (long press on iOS; right-click on Mac)
.contextMenu {
    Button("Copy") { copy(item) }
    Button("Share") { share(item) }
    Divider()
    Button("Delete", role: .destructive) { delete(item) }
}
.contextMenu { ... } primaryAction: { open(item) }  // tap opens, long press shows menu

// Pull-down button (toolbar)
Menu {
    Button("Sort by Date") { sortByDate() }
    Button("Sort by Name") { sortByName() }
} label: {
    Image(systemName: "arrow.up.arrow.down")
}
```

---

## Scroll Views

```swift
ScrollView {
    LazyVStack(spacing: 12) {
        ForEach(items) { item in
            ItemView(item: item)
        }
    }
    .padding()
}
.scrollDismissesKeyboard(.immediately)
```

- Use `LazyVStack` / `LazyHStack` / `LazyVGrid` inside scroll views for long lists.
- Avoid nested scroll views with the same scroll direction.
- `ScrollView` + `LazyVStack` is more flexible than `List` for custom layouts.

---

## Notifications (In-App)

For non-critical feedback, use inline messages or toasts rather than alerts:

```swift
// iOS 16+ toast via overlay
.overlay(alignment: .top) {
    if showToast {
        Text("Saved!")
            .padding()
            .background(.regularMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
```

Alternatively, use `UNUserNotificationCenter` for system notifications (see `ios.md`).

---

## Charts (Swift Charts)

```swift
import Charts

Chart(data) { item in
    BarMark(
        x: .value("Category", item.category),
        y: .value("Value", item.value)
    )
    .foregroundStyle(by: .value("Series", item.series))
}
.chartXAxis { ... }
.chartYAxis { ... }
.chartLegend(.visible)
```

- Provide accessibility: `.accessibilityLabel()` on each mark, or use `.chartAccessibilityLabel()`.
- Don't rely on color alone to distinguish data series.
- Keep chart type to the simplest that shows the data clearly.
