# Rounded native interface acceptance

This is an app E2E procedure using production SwiftUI views. Builds, manifests and source checks alone do not pass it. The implementation owner has not launched or interacted with this candidate.

## Candidate and safety

Prepare with `python3 script/prepare_app_e2e.py --name "OpenTeams Rounded UI Fixture"` on the reviewed commit. Preserve that exact root, manifest and signed bundle for all restart steps. It contains fictional intercepted accounts, temporary draft/cache storage, an unavailable credential provider, disabled media and no live transport fallback. Teams sends remain rejected. Sample Workspace uses only fictional local messages and memory-only demo drafts. Settings uses the production view, isolated preferences, disabled account actions and disabled notification authorization. No credential helper is packaged. No normal account data or preferences should be accessed.

Open only the exact new candidate with a permitted mounted native route. There has been no foreground agreement. Do not use shell UI, install/stop the live app, retry the previously focus-changing Delete confirmation, bypass a failed closure or reuse old blocked fixtures. If the route refuses or changes focus, stop and record the remaining steps as blocked.

The fixture header switches between the production live-chat shell and Sample Workspace. Appearance selects System, Light or Dark for this fixture window. Settings opens the production Settings window with safe restrictions. Its appearance follows macOS. Use an authorized appearance change for settings, or mark that appearance untested. The header is fixture-only and reduces available height; record the actual window dimensions. The production default is 1180 by 800 and minimum 820 by 580.

## Layout and appearance

For both live chats and Sample Workspace, capture light and dark at 820x580, 1180x800 and 1440x900, with details closed and open. Keep screen captures labeled by commit, appearance, size, workspace and inspector state.

1. The sidebar remains visible when opening details with the toolbar and Option-Command-I. Opening details must not change split-view visibility. User-requested native sidebar hiding remains available. Resize while details stays open. The inspector uses a trailing drawer below 720pt of inset detail width and a companion pane at/above 720pt. Its close button stays visible. At narrow widths the drawer covers part of the conversation; close it to regain the entire timeline/composer. Sidebar navigation must remain reachable throughout.
2. The main container has continuous 18pt corners and 10pt outer spacing, a neutral elevated fill and a 1pt subtle border. Inspector/composer/quote/setting groups use 14pt; attachments/code/results use 12pt; inputs/buttons use 8pt; badges/reactions remain capsules. Confirm actual corners, clipping and borders in both appearances. Avatars remain circles and messages remain a natural timeline.
3. Check no clipped toolbar items, overlapping composer controls, truncated primary buttons or horizontal overflow. Compare resizing from wide to minimum and back while scrolled halfway through the same conversation. The visible message and text selection should survive layout changes; if SwiftUI recreates any view state, report it as a regression.
4. Check hover, selection, enabled/disabled states and native Tab focus. Verify selected sidebar rows and links are legible. Measure text-link contrast on actual rendered light/dark backgrounds; existing contrast figures are not evidence for the candidate. Check VoiceOver names for conversation selection, search, details close, composer and send.

## Navigation, editing and scroll

1. Enter a unique rich draft in live Fictional project. Toggle formatting, bold, mention and a multiline list through production controls. Switch conversations/accounts and verify isolation; restart the exact fixture and verify saved rich draft recovery using APP.md E2E-1. Fixture layout/appearance/sample switching need not persist across restart. Sample Workspace drafts are memory-only and are not claimed to survive restart.
2. Open find using Command-F with details closed, then already open, at both narrow and wide widths. Text entry must focus the native search field each time. Search a known message, select its result and verify the correct conversation and message anchor. Escape clears the sidebar filter. Search an absent term to check empty states. Close/reopen details through its visible close button and shortcut. Switch conversations while details is open and ensure results reset.
3. Scroll up, page older messages and check the visible anchor. Open/close details and resize without losing that anchor. Append through the fixture while at bottom and while scrolled up. Bottom-following must work only when appropriate. Check the new-message affordance. Repeat natural scrolling and local sending in Sample Workspace.
4. In Sample Workspace inspect existing quotes, code, attachments, reactions, long text and multiauthor grouping. Send locally, switch conversations, add/remove a reaction, toggle favorites and compact spacing. Verify existing content and behavior survive styling. No task or Kanban features should appear.
5. Follow APP.md E2E-2 reply/edit steps, and E2E-3 context-original reaction steps on this exact candidate. Production edit/context sheets use the shared panel system. Do not perform Delete without separate foreground agreement. Validate draft retention and neighboring actions after each permitted journey.

## Settings, sheets and states

1. Open Settings from the fixture header and production toolbar. Scroll all sections. Account connect/disconnect and notification authorization are disabled in the fixture. Toggle compact spacing and send-on-Return, verify only this fixture's app preferences change, and check the intended workspace behavior. Open Sample Workspace from Settings and confirm it also uses isolated preferences and memory-only drafts.
2. Open/cancel New Chat and Edit Message through production actions. Check search input focus, button labels and sheet content bounds. Fictional New Chat lookup is unsupported and should produce a readable error without live requests. The Shared tab similarly provides a safe unsupported-response state. Check initial conversation loading if observable and empty sidebar/search results. If a state cannot be reproduced, mark it untested instead of calling source inspection a pass.
3. Sample attachment cards are display-only. File-preview and sign-in sheet styling changed but the main fixture cannot open their successful live content. Review those in separately prepared, isolated existing file-preview fixtures if a permitted route is available. Live sign-in, authorization and service behavior remain untested. Do not open live sign-in for visual QA.

## Results

Record each step as passed, failed, blocked or untested, with candidate SHA, source/binary manifest, bundle path, native window identity, appearance and size. No screenshots or native outcomes have yet been collected. No performance benchmarks need repeating for unchanged core sources. This redesign makes no FPS, startup, latency or performance claim. Independent design review and QA approval of the final commit are required before merge. The frozen performance PRs and broader loading/FPS work remain separate.
