# Tools page with an installed binary outside a repository

Actual CI preview source 4c082dac16 over the isolated v0.35.12 server reproduced a Tools render exception: `server_repo_path.path` is null, but ConfigRow called string replacement. This is the backend's normal representation when its installed executable has no repository path.

The wire type now preserves null. The row shows 경로 없음 without a copy action, while existing paths retain their exact clipboard values. A source review found no blocker; the shell's separate normalizer still omits null-path metadata, which is outside this Tools response path.

TypeScript checking and 23 focused component/copy tests passed. A Vite development preview over the same actual backend then displayed the missing path, copied data root byte-for-byte, and searched the real masc_goal_list inventory entry with its description. No render errors occurred. Desktop screenshots were opened and inspected. This is source-preview evidence, not a CI-built fix or deployment proof.

The mobile document measured 390px without horizontal overflow, but the screenshot did not visibly show the expected inventory card after viewport change. Mobile inventory acceptance remains open and is being investigated separately; DOM presence or width alone does not establish usability. The initial after-probe timed out during source-preview startup; a later fresh browser run produced the retained receipt. No runtime restart was used to cure the observation timeout.

The build-identity banner and disconnected WebSocket indicator are expected for this mixed-source, read-only browser probe. Browser writes and WebSockets were blocked. No local production build was run.

A subsequent fresh mobile browser over the same patched frontend and the upgraded isolated 83afd backend visibly rendered the actual Goal tool card. The card's 331×155.66px rectangle was fully inside viewport and ancestor clips; center hit-testing reached its descendant. The screenshot was independently opened. The initial blank capture did not persist and its exact cause remains unproven. See `mobile-followup/`. Mobile description remains line-clamped; this is card visibility proof, not a claim that every description is fully expanded.
