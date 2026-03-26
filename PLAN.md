# Replace Static Concurrency with AI-Driven Adaptive Concurrency System

## What Changes

Replace the current manual concurrency slider (1–8) with an intelligent system that **always starts at 1 session** and automatically ramps up/down based on live AI analysis, capped at a user-chosen maximum.

---

## Features

- **Always starts at 1** — every batch begins with a single session pair, then the system watches and decides when to add more
- **AI-first decisions** — calls the Rork AI engine for every major concurrency change, with a fast local heuristic as instant fallback when offline or between AI calls
- **Cautious ramp-up** — increases by 1 session every ~30 seconds of stable, successful performance
- **Instant ramp-down** — drops immediately if problems are detected (timeouts, page failures, memory pressure, network instability)
- **Smart factor analysis** — the AI considers:
  - **Memory** — current usage, growth rate, death spiral detection
  - **Network** — latency trends, connection failure rate, timeout rate
  - **Testing success** — are sessions completing with valid results (success/no-acc/perm/temp) vs failing (timeouts, page-not-loading, retries needed)
  - **App state** — foreground vs background (reduce when backgrounded)
  - **Stability score** — composite of all factors
- **Max cap presets** — user picks from preset buttons: Conservative (2), Balanced (4), Performance (6), Aggressive (8), Maximum (10)
- **Full live dashboard** during a batch showing:
  - Current live worker count vs max cap (e.g. "▶ 3/8 workers")
  - AI reasoning text (e.g. "Ramping up — 4 consecutive successes, memory stable")
  - Mini sparkline graph showing concurrency level over time
  - Factor score badges: Memory, Network, Success Rate, Stability — each with a colored indicator

---

## Design

### Concurrency Control (replaces the old slider)

- **Before batch starts**: Row of 5 preset capsule buttons (2 / 4 / 6 / 8 / 10) with the selected one highlighted in cyan — labeled "MAX SESSION CAP"
- Small helper text: "AI starts at 1 and ramps up to this cap based on live conditions"
- The START button sits below the presets

### Live AI Dashboard (visible during batch run)

- **Card with dark background** at the top of the feed, showing:
  - Large "▶ 3 / 8" display (current / cap) with a pulsing dot when actively adjusting
  - AI reasoning line in monospaced font below
  - **Mini concurrency graph** — a small sparkline (last 60 data points) showing the concurrency level over time, green when ramping up, orange when stable, red when dropping
  - **Factor badges row** — 4 small pills showing: 🧠 Memory (green/yellow/red), 🌐 Network (green/yellow/red), ✅ Success (percentage), ⚡ Stability (score)
  - Tap the card to expand a sheet with full AI analysis history and detailed factor breakdown

### AI Analysis History Sheet

- Scrollable list of every concurrency decision with timestamp, old→new value, reasoning, and which factors drove the change
- Each entry color-coded: green for ramp-up, orange for hold, red for ramp-down

---

## Technical Approach

### New Service: `AdaptiveConcurrencyEngine`

- Replaces the current static `maxConcurrency` usage in `UnifiedSessionViewModel`
- Starts monitoring when batch begins, stops when batch ends
- Maintains a rolling window of session outcomes, latency samples, memory snapshots
- Every 10 seconds: runs local heuristic for instant decisions
- Every 30 seconds (or on significant events): calls Rork AI for deeper analysis
- Publishes `liveConcurrency`, `maxCap`, `currentReasoning`, `factorScores`, and `concurrencyHistory` for the UI to bind to

### Changes to `UnifiedSessionViewModel`

- Remove `maxConcurrency` as a simple integer — replace with `maxConcurrencyCap` (the user-set ceiling) and `liveConcurrency` (the AI-controlled current value)
- `startBatch()` always begins with liveConcurrency = 1
- The batch loop reads `liveConcurrency` from the engine instead of a fixed number
- Engine adjusts liveConcurrency up/down in real-time during the batch

### Changes to `UnifiedSessionFeedView`

- Remove the old +/− slider `concurrencyControl`
- Replace with preset cap buttons + the live AI dashboard card during runs

### Enhance existing `AIPredictiveConcurrencyGovernor`

- Refactor to support the "start at 1, ramp up" model
- Add foreground/background awareness via `UIApplication.shared.applicationState`
- Feed richer data to the Rork AI (session outcomes by type, not just success/fail)
- Track concurrency history for the sparkline graph

### Files affected:

- **New**: `AdaptiveConcurrencyEngine.swift` (Service)
- **New**: `AdaptiveConcurrencyDashboardView.swift` (View — the live dashboard card + expanded sheet)
- **Modified**: `UnifiedSessionViewModel.swift` — use adaptive engine instead of static concurrency
- **Modified**: `UnifiedSessionFeedView.swift` — replace concurrency slider with presets + dashboard
- **Modified**: `AIPredictiveConcurrencyGovernor.swift` — enhance with ramp-from-1 logic and richer factor tracking

