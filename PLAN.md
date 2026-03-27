# Fix build warnings in TestGateway, DNSPoolService, and DualSiteWorkerService

**Three small fixes to silence compiler warnings:**

1. **TestGateway.swift** — The `rounded(toPlaces:)` helper extension on `Double` is implicitly on the main actor, but it's called from a `nonisolated` enum. Fix: mark the private extension `nonisolated`.

2. **DNSPoolService.swift** — `DispatchWorkItem` captured in a `@Sendable` closure triggers a Sendable warning. Fix: add `@preconcurrency import Dispatch` at the top of the file.

3. **DualSiteWorkerService.swift** — Unused variable `terminalStep` on line 149. Fix: replace `let terminalStep` with `_ =`.