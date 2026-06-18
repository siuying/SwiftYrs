# Patterns

Source: https://developer.apple.com/design/human-interface-guidelines/patterns

Interaction patterns that apply across multiple components and platforms. Read the relevant section before designing a feature that fits one of these patterns.

---

## Onboarding

Get users to value quickly. The best onboarding is no onboarding — an app that is immediately useful.

### Rules
- **Defer account creation.** Let users explore before signing in. If a guest mode is possible, provide one.
- **Request permissions at first use**, not on launch. Never front-load permission requests.
- **Skip the features tour.** Don't show a slideshow explaining what the app does — let users discover it.
- **Show progress** only if setup requires more than 3 steps (progress bar or step indicators).
- **Provide a skip option** for optional steps.

### What to show on first launch
1. The app's primary content/view — assume the user knows what the app does.
2. If the app is genuinely empty, an empty state with a clear call to action.
3. A focused welcome only if the app offers a complex or unfamiliar concept.

---

## Managing Accounts

### Sign In with Apple
Required when you offer third-party sign-in (Google, Facebook, etc.). Provide Sign in with Apple as an option alongside others.

```swift
import AuthenticationServices

SignInWithAppleButton(.signIn) { request in
    request.requestedScopes = [.fullName, .email]
} onCompletion: { result in
    // handle result
}
.signInWithAppleButtonStyle(.black)
.frame(height: 50)
```

### Account Creation Flow
- Email + password minimum. Offer Sign in with Apple.
- Use `.textContentType(.username)` / `.newPassword` for autofill to work.
- Never show the password in plaintext by default.
- Validate inline (as the user types or on blur), not only on submit.
- Show password strength indicator for new passwords.

### Session Management
- Stay logged in — never require re-login unless there's a security reason.
- Support biometric authentication (`LAContext`) for re-authentication.
- Provide a clear Sign Out in Settings; confirm before signing out.

---

## Accessing Private Data

### The Golden Rule
Request the minimum necessary access, at the moment the user needs it, with context.

### Pre-permission prompt
Before the system permission dialog, show your own explanation:
1. What you're requesting ("Location Access")
2. Why it benefits the user ("To show nearby restaurants")
3. A single action button ("Continue")

The system dialog follows immediately after.

### Handling denial
- Gracefully degrade: the app should still work without the denied permission.
- Never block the app completely because one permission was denied.
- If the feature requires the permission, hide or disable it instead of disabling the whole app.
- Provide a path to Settings if the user later wants to grant it.

```swift
// Check and request
let status = AVCaptureDevice.authorizationStatus(for: .video)
switch status {
case .authorized: startCamera()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        if granted { startCamera() }
    }
case .denied, .restricted:
    showSettingsPrompt() // offer to open Settings
}
```

---

## Notifications

### Request at the right moment
Request notification permission after the user has experienced the app's value, triggered by a specific feature that benefits from notifications (e.g. first time they enable a timer or add an item to track).

### Notification Content
- **Title**: brief, specific. "New message from Alice", not "New notification".
- **Body**: single sentence; most important detail.
- **Subtitle**: secondary context.
- **Actions**: up to 4; verb labels.

### Categories and Grouping
```swift
let category = UNNotificationCategory(
    identifier: "MESSAGE",
    actions: [replyAction, deleteAction],
    intentIdentifiers: [],
    options: .customDismissAction
)

// Grouping
content.threadIdentifier = "conversation-\(conversationID)"
content.summaryArgument = "Alice"
```

### Delivery Timing
- Don't send during expected sleep hours unless it's truly urgent.
- Batch low-priority notifications where possible.
- Use `.timeSensitive` interruption level sparingly.

---

## Feedback

Acknowledge every user action immediately. Silence = confusion.

### Visual feedback
- Button: highlight on press (system handles this for standard buttons).
- Loading: start a spinner within 0.1 s of triggering a slow operation.
- Success/error: inline status, not a modal alert.
- Disabled state: visually distinct (reduced opacity).

### Haptic feedback (iOS)
| Situation | Generator | Style |
|---|---|---|
| Task completed successfully | `UINotificationFeedbackGenerator` | `.success` |
| Error / failure | `UINotificationFeedbackGenerator` | `.error` |
| Warning | `UINotificationFeedbackGenerator` | `.warning` |
| Toggle switched / selection changed | `UISelectionFeedbackGenerator` | — |
| Physical impact (drag released, snap) | `UIImpactFeedbackGenerator` | `.light` / `.medium` / `.rigid` |

Always prepare the generator before triggering it:
```swift
let generator = UIImpactFeedbackGenerator(style: .medium)
generator.prepare()
// later:
generator.impactOccurred()
```

### Audio feedback
Use system sounds (`AudioServicesPlaySystemSound`) sparingly. Don't add custom notification sounds without user control.

---

## Modality

Use modals for tasks that are self-contained and must be completed before returning to the main flow.

### When to use modal presentation
- Configuration that applies before proceeding (compose message, filter settings).
- Multi-step tasks that don't belong in the navigation hierarchy.
- Confirmation of destructive actions.

### When NOT to use modal
- Primary navigation (use tabs or navigation stack).
- Displaying content the user will want to share or refer to alongside other content.
- Showing detail information (use navigation push instead).

### Dismissal
Every modal must have a clear dismissal action:
- Sheet: drag down or explicit Cancel/Done button.
- Full-screen: explicit Cancel/Close button.
- Alert: Cancel or dismiss button.

Use Cancel (discards changes) vs Done (commits changes) correctly — not OK.

---

## Loading

- Show a progress indicator as soon as a load starts.
- For skeleton screens: show the layout with placeholder content (shimmer effect).
- For pull-to-refresh: use `UIRefreshControl` / `.refreshable { }`.
- Don't show a loading screen > 3 s; if loading takes longer, provide something useful (cached data, partial content, progress indicator with elapsed time).
- Prefetch content before the user needs it.

---

## Empty States

Every list/collection must handle the empty case.

A good empty state has:
1. **Icon or illustration**: optional; reflects the content type.
2. **Title**: what's missing or what this view is for.
3. **Body**: why it's empty, or what to do.
4. **Call to action**: button to add the first item.

```swift
// Example
ContentUnavailableView {
    Label("No Messages", systemImage: "envelope")
} description: {
    Text("Messages from your contacts will appear here.")
} actions: {
    Button("Compose Message") { compose() }
}
```

Use `ContentUnavailableView` (iOS 17+) for standard empty/error states.

---

## Search

- Show recent searches in the search field before the user types.
- Show suggestions as the user types (instant search).
- If no results: show `ContentUnavailableView.search` (iOS 17+) with the query string.
- Scope buttons for filtering by category.

```swift
.searchable(text: $query, prompt: "Search items")
.searchScopes($scope) {
    Text("All").tag(Scope.all)
    Text("Favorites").tag(Scope.favorites)
}
.onChange(of: query) { performSearch(query: query) }
```

---

## Settings

- App-level settings live in Settings.app via the Settings Bundle.
- In-app settings are for preferences that users change frequently or that affect the immediate experience.
- Prefer in-app settings for: display preferences, notification preferences, account info.
- Prefer Settings.app for: permissions, data reset, export.

### Settings conventions
- Group related settings in sections.
- Changes apply immediately (no Save button).
- Provide a "Reset to Defaults" option for complex settings.
- Use the platform's settings UI pattern (grouped table on iOS, preferences panel on macOS).

---

## Undo and Redo

Support undo for any meaningful user action that modifies content.

```swift
// SwiftUI
@Environment(\.undoManager) var undoManager

func addItem(_ item: Item) {
    items.append(item)
    undoManager?.registerUndo(withTarget: self) { target in
        target.removeItem(item)
    }
    undoManager?.setActionName("Add Item")
}
```

- Shake to undo (iOS): don't disable unless absolutely necessary.
- Keyboard: ⌘Z / ⌘⇧Z on Mac and iPad.
- Infinite undo stack for text editors; a single level is acceptable for simple actions.

---

## Drag and Drop

Support drag and drop for any content the user would reasonably want to move or share.

```swift
// Source
.draggable(item)  // SwiftUI, item conforms to Transferable

// Destination
.dropDestination(for: Item.self) { items, location in
    handleDrop(items: items)
    return true
}
```

- Show a drag preview that represents the content being dragged.
- Use spring-loaded targets for dragging into folders/containers.
- Support both single and multiple item drags.

---

## Printing

Implement printing for any content users might want on paper (documents, photos, receipts).

```swift
// UIKit
let printController = UIPrintInteractionController.shared
printController.printFormatter = webView.viewPrintFormatter()
printController.present(animated: true)
```

---

## Ratings and Reviews

Prompt for ratings at the right moment — after a clear success (task completed, level passed, item found) — not immediately on launch or after a failure.

```swift
import StoreKit

// Request at the right moment:
if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
    SKStoreReviewController.requestReview(in: scene)
}
```

- Maximum 3 requests per 365-day period (enforced by StoreKit).
- Never ask after a frustrating experience.
- Never block the app if the user declines to rate.

---

## Sharing

Support the system share sheet for any sharable content.

```swift
// SwiftUI
ShareLink(item: url, subject: Text("Check this out"), message: Text("Found this interesting article"))
ShareLink("Share", item: image, preview: SharePreview("Sunset photo", image: image))
```

- Use `ShareLink` / `UIActivityViewController` — never build a custom share sheet.
- Provide the most useful representation (URL > file > text).
- Include a meaningful `subject` and `message` for email/message sharing.
