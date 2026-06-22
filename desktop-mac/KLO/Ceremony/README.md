# Ceremony + tutorial dev notes

Three UserDefaults flags gate the first-launch UX. Reset them while
iterating so you can re-trigger without rebuilding:

```sh
defaults delete com.klo.KLO klo.hasSeenLaunchCeremony
defaults delete com.klo.KLO klo.hasSeenKeyboardTutorial
defaults delete com.klo.KLO klo.hasCompletedOnboarding
```

| Flag | Fires the |
|---|---|
| `klo.hasSeenLaunchCeremony` | full-screen cloud + sound + wordmark + "Your computer can fly now." |
| `klo.hasCompletedOnboarding` | borderless onboarding window (Welcome → Sign in → Permissions → Ready) |
| `klo.hasSeenKeyboardTutorial` | post-auth ⌘K keyboard tutorial card |

Bundle ids may differ in dev — `defaults read | grep klo` to check.
