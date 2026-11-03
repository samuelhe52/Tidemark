# 007.003 — Table UI, model display names, and the sticky header

## Context

The maintainer checked the feature in the running app on 2026-11-03 and reported the
following problems, mostly with screenshots and screen recordings:

- **Scroll bars:** both scroll bars showed while a mouse was connected.
- **Rows:** they had opaque, dark, rounded backgrounds.
- **Header:** it was an opaque black square strip. It did not line up with the rows,
  and it sometimes went missing or flashed while scrolling.
- **Columns:** they were much wider than their content.
- **Header drag:** during a reorder drag, the dragged column's title jumped instead of
  following the cursor, while its cells did follow.
- **Panel height:** the panel stopped before the end of the Usage section.

The maintainer also asked for these changes:

- CC Switch's model display names, if CC Switch has them.
- "TTFT" in place of "First token".
- An option for short Claude model names.

Claude Code made these changes, except for the flashing fix. Two attempts by Claude Code
did not fix the flashing, so a Codex thread (`gpt-6.1-sol`, high effort, thread
`01a1a1f5-30a3-7651-a601-0424fe6f14ae`) found and fixed its cause.

## Change

### Scrolling and layout

- **No scrollers:** neither `NSScrollView` shows a scroller, even with a mouse
  connected. Trackpad and wheel scrolling still work, and Shift-wheel scrolls sideways.
- **Panel height:** `DashboardView.preferredSize(maxHeight:)` now measures where the view
  above the logs separator ends, from the laid-out frames in the flipped document. The
  earlier version subtracted estimated `fittingSize` heights, and it stopped short.

### Table look

- **Plain table:** the table uses `.plain` style. The `.inset` default offset the rows
  from the header.
- **Row stripes:** faint stripes (`labelColor` at 5% alpha) replace the opaque
  alternating row colors.
- **Columns fit their content:** each column fits the wider of its title and its widest
  loaded value. Any spare width is shared out in whole points, so a narrow table fills
  the section and a wide one scrolls sideways.
  - A column's rect is its width plus the intercell spacing. The first fitting counted
    the spacing twice, which made every table scroll slightly.
- **No manual resizing:** content fitting would undo a manual resize, so the user can no
  longer resize columns. This replaces the width preservation in
  [002](002-review-fixes.md).

### Header

1. **First version: a separate overlay.** The header was hosted in its own `NSClipView`
   over the dashboard scroll view, and it had an opaque `windowBackgroundColor` fill.
   This design made the header go missing at times, made its drag title jump, and gave
   it the square look.
2. **Back in its scroll view.** The header returned to the inner scroll view's own header
   slot, so AppKit draws it and animates header drags. The sticky behavior now works by
   moving the inner scroll view's frame top to the pinned position. A clip view
   (`RequestLogLockedClipView`) holds a vertical offset of the same distance, so the rows
   stay in place.
3. **The black strip.** A standalone AppKit harness found the cause: a header cell that
   overrides `draw(withFrame:in:)` makes AppKit render the header region as an opaque
   black strip on macOS 26. `RequestLogHeaderCell` now overrides only
   `drawInterior(withFrame:in:)`. The system header background, the column dividers and
   the bottom line stay.
4. **Rows below the header.** `RequestLogHorizontalScrollView.tile()` puts the content
   clip below the header, so rows no longer scroll under the titles. The system's
   scroll-edge effect then has nothing to cover.
5. **The flashing**, fixed by the Codex thread:
   - **Cause:** `DashboardView` did not reposition the header in its
     `boundsDidChangeNotification` handler. It queued the repositioning with
     `DispatchQueue.main.async`, so a frame could be drawn with the new outer offset and
     the old header position.
   - **Fix:** the handler now repositions synchronously. It is suppressed while the
     stack rebuilds and runs once afterward. `layoutBody` sets the vertical lock before
     it resizes, and finishes tiling before it scrolls the clip.
   - **Responsive scrolling stays off:** Claude Code's earlier change turned it off on
     the dashboard document (`isCompatibleWithResponsiveScrolling`). The thread kept it,
     because cached scrolling must not get ahead of the synchronous handler.

### Model names and column titles

- **Display names:** the new `ModelDisplayNames` reads `model_pricing.display_name`. It
  matches a logged model the way CC Switch matches a model to its price
  (`find_model_pricing_row` and `model_pricing_candidates`, `usage_stats.rs`, commit
  `c018907`):
  1. Clean the ID: keep the last path part, drop anything after ":", remove the
     `[1m]` marker, and lowercase it.
  2. Make candidates by stripping namespaces, Claude Desktop prefixes, Bedrock `-vN`,
     dates and reasoning-effort suffixes, and by changing dotted Claude versions to
     dashes.
  3. Try an exact match, case-insensitive.
  4. Try a prefix match, only for the families CC Switch allows. The shortest ID wins.
- **Where names show:** in the Request Logs Model column and the Usage Model view, with
  the raw ID as the tooltip. CC Switch's own request table shows raw IDs, so this part is
  a Tidemark choice, made at the maintainer's request.
- **TTFT:** the `firstToken` column's title is now "TTFT".
- **Short Claude names:** a new setting, Settings → Usage → Display → "Short Claude model
  names". It is off by default and stored as `DefaultsKey.shortClaudeModelNames`. It
  removes the "Claude " prefix from display names ("Claude Opus 5.5" → "Opus 5.5"). Raw
  IDs stay whole.

## Refs

- `Sources/Tidemark/RequestLogView.swift`
- `Sources/Tidemark/RequestLogText.swift`
- `Sources/Tidemark/DashboardView.swift`
- `Sources/Tidemark/DashboardView+History.swift`
- `Sources/Tidemark/HistoryText.swift`
- `Sources/Tidemark/SettingsStore.swift`
- `Sources/Tidemark/SettingsView.swift`
- `Sources/Tidemark/DefaultsKey.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/ModelDisplayNames.swift`
- `Packages/TidemarkKit/Sources/TidemarkData/RequestLog.swift` (`modelName`)
- `Packages/TidemarkKit/Sources/TidemarkData/UsageHistory.swift` (`UsageGroup.displayName`)
- Tests: `Packages/TidemarkKit/Tests/TidemarkDataTests/ModelDisplayNamesTests.swift`

## Validation

Run by Claude Code on 2026-11-03, after the sticky-header fix:

- `make build` passed.
- `make test` passed 40 tests in the TidemarkData run, among them
  `ModelDisplayNamesTests`, and 8 in the TidemarkEngine run.

Runtime evidence:

- **Maintainer, from screenshots and recordings:**
  - The header style is correct after the `drawInterior` fix.
  - The responsive-scrolling change alone did not stop the flashing.
- **Claude Code, from probe captures:** standalone AppKit probe windows showed the black
  strip with a custom `draw(withFrame:in:)` and a clear header with `drawInterior` only.
- **The Codex thread, from its harness:** an AppKit harness counted frames with the
  header out of place:

  | Scrolling | Before | After |
  | --- | --- | --- |
  | Programmatic | 239 of 240 | 0 of 240 |
  | Synthetic wheel and momentum | 28 of 160 | 0 of 160 |
  | Fractional and boundary positions | 5 of 9 | 0 of 9 |

Not verified yet:

- the flashing fix with a real trackpad, including elastic scrolling;
- the native header-drag animation;
- the short-name toggle in the running app.
