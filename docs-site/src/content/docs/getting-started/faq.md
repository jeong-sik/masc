---
title: Frequently Asked Questions (FAQ)
description: Common questions regarding MASC concepts, origins, and technical architecture.
---

### Q. How does MASC differ from standalone AI tools (Claude Code, Cursor)?

Standalone AI coding assistants keep memory and execution context confined to their own individual session.  
MASC provides a **shared coordination layer** where multiple agents collaborate without collisions:
- Centralizes goals, tasks, board posts, and evidence in a single `.masc/` directory.
- Enforces task ownership (`claim`) so multiple agents don't overwrite each other's files.
- Shares negative evidence across agents so nobody repeats failed attempts.

---

### Q. Can I run MASC without external cloud API keys?

**Yes.**  
MASC functions as a local MCP server out of the box. You can also connect local models (such as Qwen running on `llama-server` or Ollama) to serve as verifiers and librarians at zero API cost.

---

### Q. Does MASC pollute my repository?

No. MASC stores all coordination state, logs, and artifacts exclusively inside the `<base-path>/.masc/` directory, leaving your actual source code untouched until an agent is explicitly directed to edit files.

---

### Q. What is the Gate?

The **Gate** is MASC's Human-In-The-Loop (HITL) approval boundary. When an agent attempts sensitive shell commands or file operations, execution pauses until an operator explicitly approves (`y`) or denies (`n`) the action in the TUI.
