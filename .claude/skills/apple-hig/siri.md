# Siri and Voice Interaction

Source: https://developer.apple.com/design/human-interface-guidelines/siri

## Overview

Siri integration lets users invoke your app's capabilities using natural language, without opening the app. There are two main integration points:

1. **App Intents** (iOS 16+, recommended): defines discrete, discoverable actions.
2. **SiriKit Intents** (older API): predefined intent domains (messaging, payments, workouts, etc.).

---

## App Intents (Modern API)

App Intents is the current framework for all Siri integration, Shortcuts, Spotlight, and the Action button.

### Define an Intent

```swift
import AppIntents

struct StartWorkoutIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Workout"
    static var description = IntentDescription("Starts a workout session.")

    @Parameter(title: "Workout Type")
    var workoutType: WorkoutType

    func perform() async throws -> some IntentResult {
        await WorkoutManager.shared.start(workoutType)
        return .result()
    }
}

enum WorkoutType: String, AppEnum {
    case running, cycling, swimming
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout Type")
    static var caseDisplayRepresentations: [WorkoutType: DisplayRepresentation] = [
        .running: "Running",
        .cycling: "Cycling",
        .swimming: "Swimming"
    ]
}
```

### App Shortcuts

App Shortcuts surface intents in Siri, Spotlight, and the Shortcuts app without the user having to create them manually.

```swift
struct MyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkoutIntent(),
            phrases: [
                "Start a \(\.$workoutType) workout in \(.applicationName)",
                "Begin \(\.$workoutType) in \(.applicationName)"
            ],
            shortTitle: "Start Workout",
            systemImageName: "figure.run"
        )
    }
}
```

Phrases must include `\(.applicationName)` to prevent Siri conflicts with other apps.

---

## SiriKit Intent Domains (Legacy)

For the built-in Siri intent domains (before App Intents), use SiriKit. Common domains:

| Domain | Use case |
|---|---|
| Messages | Send, search messages |
| Calls | Start/end calls |
| Payments | Send money, request payments |
| Workouts | Start, end, pause workouts |
| Ride booking | Request rides |
| Restaurant reservations | Book a table |
| Notes | Create, search notes |
| Lists | Create, add to lists |
| Photo search | Find photos |
| Media | Play music, podcasts |
| VoIP | Start audio/video calls |

For new apps, prefer App Intents; SiriKit domains have limited extensibility.

---

## Siri Voice Interaction Design Principles

### Natural Language
- Use phrases people actually say. Test by speaking them aloud.
- Provide multiple phrase variations in your App Shortcut phrases array.
- Parameter labels should be natural in speech (e.g., "workout type", not "workoutTypeIdentifier").

### Brevity
- Siri responses should be short — one to two sentences.
- Don't repeat information Siri already said.
- Avoid confirmation dialogs for low-risk actions.

### Confirmation Only for Destructive Actions
- Don't ask "Are you sure?" for routine actions.
- Do confirm before irreversible actions (sending a payment, deleting data).
- Use `needsConfirmationDialog` or `requestConfirmation` in your intent.

```swift
func perform() async throws -> some IntentResult {
    try await requestConfirmation(
        actionName: .delete,
        dialog: "Delete all workouts from this week?"
    )
    await WorkoutManager.shared.deleteWeekWorkouts()
    return .result(dialog: "Deleted.")
}
```

### Error Handling
Provide clear, actionable error messages:

```swift
throw IntentError.noWorkoutsFound // bad: generic
throw IntentError.message("No workouts found for this week. Try a different date range.") // good
```

---

## Widgets and Siri Suggestions

Siri Suggestions (on-device ML) predict when to show your widget or offer your shortcuts. Improve predictions by:

- Using `NSUserActivity` when the user performs actions worth repeating.
- Donating shortcuts with `INInteraction.donate()` (SiriKit) or App Intents (automatic).
- Using `INRelevantShortcut` for widget suggestions at predicted times/locations.

```swift
// Donate activity for Siri Suggestions
let activity = NSUserActivity(activityType: "com.myapp.viewWorkout")
activity.title = "View Today's Workout"
activity.isEligibleForPrediction = true
activity.persistentIdentifier = "viewTodayWorkout"
view.userActivity = activity
```

---

## Action Button (iPhone 15 Pro+)

The Action button can be configured by the user to trigger any App Intent. Make your key intents eligible:

```swift
struct StartWorkoutIntent: AppIntent {
    // Eligible for the Action button when user configures it
    static var openAppWhenRun: Bool = false // runs without opening app
}
```

---

## Siri UI Design

When Siri runs an intent with a visual result, it can show a snippet UI. Provide a clear, concise view:

```swift
func perform() async throws -> some IntentResult & ShowsSnippetView {
    return .result(
        value: workout,
        view: WorkoutSummaryView(workout: workout)
    )
}
```

- Keep the snippet view compact (about 3–5 rows of information).
- Don't include full navigation; it's a summary, not the app.
- Use system fonts and colors so it matches Siri's glass interface.

---

## Localization

- All `LocalizedStringResource` values in intents are localizable.
- Phrases in `AppShortcut` must be localized in `AppShortcuts.strings`.
- Test voice phrases in all supported languages — pronunciation of your app name matters.

---

## Privacy

- Siri sends recognized speech to Apple's servers (unless on-device Siri is used, iOS 17+).
- Don't include sensitive data in intent parameters unless necessary.
- Use `@Parameter(requestValueDialog:)` to ask for sensitive inputs only when needed, not upfront.
- Sensitive intents (payments, medical) should confirm before acting.

---

## Testing Siri

1. In Xcode: Product → Perform Action → Test SiriKit Intent
2. Use Simulator or device; say the phrase or type it.
3. Check the Shortcuts app — your shortcuts should appear automatically under your app's section.
4. Test all parameter variations and error paths.
