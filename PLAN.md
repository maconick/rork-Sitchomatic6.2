# Fix Dual Find: Screenshots, False Positives, Keyboard, Live Feed

## Overview

Four targeted fixes for the Dual Find testing system addressing screenshots, Ignition false positives, keyboard intrusion, and live session viewing.

---

### 1. Per-Attempt Screenshots with Toggle

**Features:**

- A screenshot count picker (None / 1 / 3 / 5) appears in the running view header, changeable mid-run
- After each login attempt response, the final page state is captured as a screenshot
- Screenshots are stored via the existing Unified Screenshot Manager with Vision analysis
- When set to 1: captures the final response only; 3: captures post-fill, post-click, final response; 5: captures page load, post-fill, pre-click, post-click, final response
- "None" disables all screenshot capture for maximum speed
- Screenshots tagged with the email, platform, and attempt info for easy filtering

**Design:**

- Compact segmented picker in the progress header area showing "📷 0 | 1 | 3 | 5"
- Screenshot count badge next to the picker showing total captured this run

**Files changed:**

- `DualFindState.swift` — add `DualFindScreenshotMode` enum (none/1/3/5)
- `DualFindViewModel.swift` — add `screenshotMode` property, capture logic in `sessionEmailLoop` and `retryEmailOnFreshSession`
- `DualFindRunningView.swift` — add screenshot mode picker in progress header

---

### 2. Fix Ignition False Positive Logins

**Features:**

- Reorder evaluation: check for error/failure/SMS/disabled keywords BEFORE checking success markers (currently success is checked first, allowing error banners containing "balance" etc. to false-trigger)
- Add Ignition-specific error banner detection: red top-of-page banners with common Ignition error text ("unable to log in", "session expired", "temporarily unavailable", "account locked", "technical difficulties")
- Require URL change for success: a login is only marked successful if the URL has navigated away from the login/overlay page AND success markers are present
- Add verification screenshot with Vision text detection: on any tentative "success" result, capture a screenshot and run Vision OCR to confirm success text is real and no error banners are visible
- Add "hang/no response" detection: if page content is mostly the same as the login page (still has login form fields), classify as transient rather than unsure
- Tighten SMS/fingerprint detection: only trigger if SMS keywords appear WITHOUT success markers present (prevents false burn on pages that happen to mention verification in footer text)

**Files changed:**

- `DualFindViewModel.swift` — rewrite `evaluateResponse()` with negative-first ordering, URL-change requirement, Ignition-specific checks, Vision verification, and hang detection

---

### 3. Fix Keyboard Popping Up During Testing

**Features:**

- Add `document.activeElement.blur()` call after every form fill and field clear operation to dismiss the keyboard immediately
- Remove unnecessary `el.focus()` calls from `clearPasswordFieldOnly()` and `clearEmailFieldOnly()` — clearing a field doesn't need focus
- Add a dedicated `blurActiveElement()` method to the web session that's called after every JS interaction
- Disable the input accessory view on WKWebView instances used for Dual Find to prevent keyboard toolbar flashing

**Files changed:**

- `HyperFlowLegacyBridge.swift` — add `blurActiveElement()` method, add blur calls after fill/clear methods, remove focus from clear methods, add `el.blur()` at end of all fill JS functions instead of leaving focus on the field

---

### 4. Live Feed Session Viewer

**Features:**

- A "Live View" button appears on each session card in the running view
- Tapping it opens a sheet showing the actual WKWebView of that session rendered on-screen in real-time
- The live view shows the session label, current email being tested, and status overlay
- The webview is read-only (hit testing disabled) so you can watch but not interfere
- Can switch between sessions using a picker at the top of the sheet
- Auto-dismisses if the run stops

**Design:**

- Each session card gets a small eye icon button ("👁") in the top-right corner
- The live view sheet uses a dark background with the webview centered
- Session info bar at the top with platform icon, session label, and current email
- A session switcher (horizontal scroll of session chips) at the bottom to jump between sessions

**Files changed:**

- `DualFindViewModel.swift` — add `liveViewSessionIndex`, `liveViewSite` properties, method to get the WKWebView for a given session
- `DualFindRunningView.swift` — add eye icon to session cards, live view sheet with webview rendering
- `DualFindLiveViewSheet.swift` — new view for the live session viewer with WebView representable

