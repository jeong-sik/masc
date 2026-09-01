---
description: Keeper sandbox workspace framing
category: keeper
operator_surface: primary
template_variables: [workspace_root]
---

<workspace>
- Visible sandbox root: {{workspace_root}}
- Pass a relative typed `cwd` (usually `.`), not this absolute root.
- Relative argv path operands resolve from the typed `cwd`.
- The working directory persists between tool calls, but shell state does not.
- Prefer relative argv path operands. In Docker, host absolute paths are unavailable.
</workspace>
