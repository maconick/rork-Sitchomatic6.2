# Per-Site Paired Result Display System

## Overview

Replace the single unified classification badge with a **per-site paired result** system. Each credential session stores and displays individual results for Joe Fortune and Ignition separately, shown as pairs like "No Acc | Success" or a single label like "Perm Disabled" when appropriate.

---

### Features

- **Per-site result tracking** — Each session stores a separate outcome for Joe Fortune and for Ignition (success, no acc, perm disabled, temp disabled, unsure)
- **Paired result display** — Results shown as "Joe Result | Ign Result" with a pipe separator (e.g., "No Acc | Temp Dis")
- **Smart singular labels** — When both sites return the same result, show a single label (e.g., "No Accounts" plural, or "Perm Disabled")
- **Split-color badges** — When results differ, the badge splits into two colors side-by-side (green + orange, etc.)
- **Refined "No Account" definition** — A "No Acc" detection requires 3–4 fully completed login button presses where each press was confirmed registered (button returned to original colour) and only common "incorrect password" responses were detected — no disabled/banned/unusual messages
- **Per-site filter matching** — Filter chips (Success, Perm, Temp, No Acc) match if EITHER site has that result
- **Comprehensive result classification** — Almost all outcomes classified as one of the five known types; "Unsure" only used for truly unclassifiable or incomplete automation runs

---

### Design

- **Session tiles** show a split badge when results differ: left half is Joe's colour, right half is Ignition's colour, with a thin divider
- **Badge text** uses pipe separator: `TEMP DIS | NO ACC` in the paired case, or `NO ACCOUNTS` / `SUCCESS` / `PERM DISABLED` when both agree
- **Per-site progress bars** (already present) remain unchanged — they show the 4-attempt dots per site
- **Detail sheet** updated to show each site's individual result label and colour prominently at the top
- **Stats row** counts updated to reflect "either site" logic (a session with "Success | No Acc" counts in both the Success and No Acc stats)
- **Export** updated to include per-site results in CSV columns

---

### Changes

1. **Data model** — Add `joeSiteResult` and `ignitionSiteResult` fields to `DualSiteSession` storing per-site outcome enum (success, noAccount, permDisabled, tempDisabled, unsure, pending)
2. **Worker service** — After each attempt loop completes, store the individual Joe and Ignition outcomes into the session's per-site result fields
3. **Session tile** — Redesigned badge using split-colour capsule with pipe-separated text; single label + colour when both match
4. **Classification icon** — Uses the highest-priority site result for the main icon (Success > Perm > Temp > No Acc > Unsure)
5. **Filter bar** — Updated to match if EITHER site has the filtered result type
6. **Detail sheet** — Shows per-site result labels with site icons at the top of the credential section
7. **Stats row** — Updated counts to reflect per-site matching
8. **Export** — Two new CSV columns: `joe_result` and `ignition_result`
9. **No Account refinement** — Only classified as "No Acc" when automation confirmed 3+ fully registered login button presses with only "incorrect" responses; incomplete runs get "Unsure"

