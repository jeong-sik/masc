# Browser Lane composition experiments

## Product target

The operator and Keeper observe the same selected browser page through TUI text/scene and screenshots, and act on that page. Slack Web collection uses the existing authenticated browser, without Slack Apps or bot tokens. Text entry is deferred; click, scroll and drag are the first interaction scope.

## Existing systems to reuse

- [agent-browser selectors](https://agent-browser.dev/selectors): short observed references and role/label targeting; [diffing](https://agent-browser.dev/diffing) reduces repeated observation.
- [Stagehand observe](https://docs.stagehand.dev/v3/basics/observe) and [extract](https://docs.stagehand.dev/v3/basics/extract): separate locating actions from structured reading, reuse observed actions.
- [Crawl4AI fit markdown](https://docs.crawl4ai.com/core/fit-markdown/): relevance filtering after extraction; this does not itself navigate an authenticated Slack UI.
- [WebDriver Actions](https://www.w3.org/TR/webdriver2/#actions): native pointer and wheel input underneath Browser Lane.

These are patterns or backend candidates, not evidence that an external CLI alone satisfies the TUI product. Compare them inside the Lane on the same fixture and Slack session before choosing a replacement.

## Current experiment

Screenshot viewport coordinates feed a closed BrowserInteract action. The backend prototype uses existing WebDriver native Actions for trusted drag; the live extension can activate the element under a screenshot point. See ../evidence/browser-pointer-20260909/README.md for measured scope and limitations.

## Remaining acceptance

- TUI image placement and mouse coordinates agree; clicking a visible link and dragging updates the same Lane.
- Wheel scrolling reaches nested Slack message panes, not only the top document.
- Operator and Keeper retain the selected source/client/tab and can access the same screenshot metadata.
- Slack site skill composes lazily with Browser Lane, reads observed channel links and message regions, and avoids repeated full-sidebar/DOM artifacts.
- Measure channel collection success, tool round trips and returned bytes on several explicitly selected channels. No performance claim until this comparison is run.
