# Brainstorm Evolution Plan: Figma-MCP + Native Chain Integration

**Status:** Draft / Strategic Proposal
**Target:** `workspace/yousleepwhen/figma-mcp`
**Date:** 2026-02-08

## 1. Top 5 Differentiators (vs. typical Figma-to-code)

1.  **MCP-Native Design System Grounding**: Instead of generic code, we expose the project's *actual* design system (Tailwind configs, existing React components) as MCP resources. The agent "browses" the design and "reads" the local library simultaneously, performing semantic mapping (e.g., "Figma Frame #101 is actually `<Button variant='ghost'>`").
2.  **Continuous Heartbeat Regression**: A "forever-running" loop that verifies code against design.
    - **Visual**: Multimodal MODEL compares Playwright screenshots vs. Figma exports.
    - **Semantic**: Comparison of Figma's layer hierarchy vs. the generated DOM's accessibility tree.
    - **Structural**: Ensures zero-drift as both design and code evolve.
3.  **Git-Worktree Isolated Evolution**: Conversion happens in a clean, isolated Git worktree. MASC agents perform "self-healing" cycles (fixing lint, running tests) before a PR is ever created, making it an "Agent-to-Agent" workflow rather than "Designer-to-Developer".
4.  **Chain-Orchestrated "Thinking"**: Exploits native `chain.orchestrate` to handle complex UI logic (state, transitions, API integrations) that static exporters ignore. It treats a UI component as a "mini-program" to be solved, not just a layout to be exported.
5.  **Checkpoint-Based Handoff**: For complex designs that exceed context windows, an agent serializes progress into a compact handoff record so a successor can resume without re-scanning the entire screen tree.

## 2. Top 5 Missing Capabilities (The "Moat")

1.  **Interaction-to-State Synthesis**: Extracting Figma "Prototype" links (clicks, transitions, overlays) and synthesizing them into functional React `useState`/`useEffect` hooks automatically.
2.  **Contextual Component Refactoring**: Intelligence to decide when a repeating pattern should be a reusable library component vs. a one-off local refactor, based on scanning the existing codebase.
3.  **Visual "Design Debt" Snapping**: Automatically detecting slight designer deviations (e.g., 15px margin instead of the design system's 16px) and "snapping" them to the nearest valid token during generation.
4.  **Bidirectional Property Bridge**: A "Code-to-Figma" sync where CSS changes in the IDE can be pushed back to Figma properties via API, allowing designers to see the "real" implementation.
5.  **Multimodal a11y Audit**: Using vision-capable models to audit both the design intent and the generated DOM to ensure screen-reader friendliness and WCAG compliance at the source.

## 3. 3 "Shockingly Elegant" Architectural Ideas

1.  **"The Figma File System" (MCP Resources)**:
    Expose the Figma API as a hierarchical virtual filesystem.
    - `ls /figma/Project/Page1/Header`
    - `cat /figma/Project/Page1/Header/Logo.png`
    Models use standard file tools (`ls`, `cat`) to "explore" the design, drastically reducing prompt bloat and allowing the model to focus only on the current "directory" (frame).
2.  **"Visual Heartbeat" Unit Testing**:
    Integrate visual regression directly into the `dune runtest` / `npm test` pipeline. A test case takes a Figma Frame ID, renders the component in Playwright, and uses a Multimodal MODEL Judge to return a pass/fail with a JSON of visual discrepancies.
3.  **"Native Chain Orchestration Middleware"**:
    Use the native chain plane as a "Design Reasoning Engine" that sits between Figma and MASC. It decomposes a frame into a "UI Execution Plan" (JSON), which MASC then parallelizes across multiple agents/worktrees (e.g., Agent A builds the layout, Agent B handles the data-fetching logic).

## 4. Concrete Next Steps (1-2 Week Scope)

### Week 1: Foundation & Cleanup
- [ ] **Audit Storage Boundaries**: Before consolidating any DB clients, identify which figma-mcp modules still own connection setup and which ones are compatibility wrappers.
- [ ] **MCP Resource Bridge**: Implement the "Virtual Canvas" (Figma-as-Resources) allowing `mcp://figma/...` URI access.
- [ ] **SSE Live Sync**: Connect Figma webhooks to MASC's task board via SSE, so design changes automatically trigger "Update" tasks.

### Week 2: The Feedback Loop
- [ ] **Visual Regression Agent**: Build the toolchain for `Figma Export -> Playwright Render -> MODEL Judge`.
- [ ] **Native Chain Integration**: Update `figma-mcp` to use `chain.orchestrate` for multi-step conversion tasks (Planning -> Generation -> Verification -> Fix).
- [ ] **PR Pipeline**: Automate the flow: `Figma Change -> MASC Agent Claim -> Worktree Edit -> Visual Pass -> GitHub PR`.
