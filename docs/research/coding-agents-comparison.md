# Coding Agent Comparison: Claude Code MCP / Gemini CLI / DeepSeek-R1

**Task:** task-476  
**Date:** 2026-05-21  
**Keeper:** lifecycle-worker

## Executive Summary

Comparative analysis of three terminal-native AI coding agents: Anthropic's Claude Code (with MCP), Google's Gemini CLI, and DeepSeek-R1 as a coding assistant. Evaluated across autonomy, tool integration, reasoning, cost, and MASC compatibility.

---

## 1. Anthropic Claude Code + MCP

### Overview
Claude Code is Anthropic's agentic coding tool that runs in the terminal. It uses the Model Context Protocol (MCP) for extensible tool/server integration.

### Strengths
- **MCP Protocol**: Open standard for tool integration — filesystem, git, LSP, custom servers. First-class for MASC keeper worktrees.
- **Autonomous Agent Loop**: Multi-turn agentic execution with tool calls, file edits, shell commands. Matches MASC's keeper lifecycle pattern.
- **Strong Code Understanding**: Claude 3.5/4 excels at multi-file reasoning, refactoring, and architecture decisions.
- **Permission Model**: Granular approval gates for file writes, shell commands, and network calls.

### Weaknesses
- **Cost**: Higher per-token cost vs open alternatives; extended agentic sessions accumulate quickly.
- **Latency**: Multi-step agentic loops add wall-clock time per task.
- **Vendor Lock-in**: MCP is open, but Claude Code runtime is proprietary to Anthropic's API.

### MASC Compatibility
- **High**: MCP servers can expose MASC tools directly. Worktree-based isolation aligns well. Draft PR creation workflow fits the keeper lifecycle.

---

## 2. Google Gemini CLI

### Overview
Google's Gemini CLI provides terminal-native access to Gemini 2.5 models with built-in code editing and shell integration.

### Strengths
- **Long Context Window**: Gemini 2.5 supports 1M+ tokens — useful for entire codebase ingestion.
- **Cost Efficiency**: Significantly lower per-token pricing than Claude/GPT-4 class models.
- **Google Ecosystem**: Deep integration with Google Cloud, Firebase, and internal Google tooling.
- **Multimodal**: Native image/audio/video understanding alongside code.

### Weaknesses
- **Agent Loop Maturity**: Less mature multi-step agentic execution compared to Claude Code. Fewer autonomous tool-use iterations.
- **Tool Ecosystem**: No equivalent to MCP's open server protocol. Tool integration is Gemini CLI-internal.
- **Code Editing Quality**: Good for suggestions but less reliable for multi-file surgical edits compared to Claude.
- **Reasoning Depth**: Occasionally misses nuanced architectural implications in complex codebases.

### MASC Compatibility
- **Medium**: Can work with MASC worktrees but lacks MCP-equivalent extensible tool protocol. Would need custom adapter layer.

---

## 3. DeepSeek-R1 (Coding)

### Overview
DeepSeek-R1 is an open-weight reasoning model optimized for chain-of-thought coding tasks. Used via API or local deployment.

### Strengths
- **Cost**: Lowest cost option — open weights allow self-hosting, API pricing is competitive.
- **Reasoning Transparency**: Explicit chain-of-thought output shows reasoning steps; useful for auditability.
- **Open Weights**: Full control over model deployment, fine-tuning, and data privacy.
- **Strong Math/Logic**: Excels at algorithmic reasoning, competitive programming, and formal verification tasks.

### Weaknesses
- **Tool Use**: Limited native tool-use capabilities compared to Claude Code. No built-in agentic file edit / shell loop.
- **Code Generation Reliability**: Higher variance in generated code quality; needs more human review cycles.
- **Context Handling**: Shorter effective context window for code tasks compared to Gemini 2.5.
- **Ecosystem**: No equivalent to MCP or Claude Code's permission/approval system.

### MASC Compatibility
- **Low-Medium**: Best suited as a reasoning/computation backend rather than autonomous agent. Would need significant wrapper tooling to match MASC keeper lifecycle requirements.

---

## Comparative Matrix

| Dimension | Claude Code + MCP | Gemini CLI | DeepSeek-R1 |
|-----------|-------------------|------------|-------------|
| **Autonomy** | ★★★★★ | ★★★☆☆ | ★★☆☆☆ |
| **Tool Integration** | ★★★★★ (MCP) | ★★★☆☆ (internal) | ★★☆☆☆ (limited) |
| **Code Understanding** | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| **Multi-file Editing** | ★★★★★ | ★★★☆☆ | ★★☆☆☆ |
| **Reasoning Depth** | ★★★★☆ | ★★★★☆ | ★★★★★ |
| **Cost** | ★★☆☆☆ | ★★★★☆ | ★★★★★ |
| **Context Window** | ★★★★☆ | ★★★★★ | ★★★☆☆ |
| **Openness** | ★★★☆☆ | ★★☆☆☆ | ★★★★★ |
| **MASC Fit** | ★★★★★ | ★★★☆☆ | ★★☆☆☆ |

---

## Recommendation

For MASC keeper workflows (worktree isolation, draft PR lifecycle, multi-tool coordination):

1. **Primary**: Claude Code with MCP — best fit for autonomous agent loops, tool extensibility, and the draft-PR lifecycle that MASC keepers execute.
2. **Budget Alternative**: Gemini CLI — acceptable for single-pass code assistance where cost matters more than autonomous multi-step execution.
3. **Specialized**: DeepSeek-R1 — valuable as a reasoning oracle for algorithmic tasks, but not suitable as a standalone keeper agent without significant wrapper infrastructure.

---

## Methodology Notes

- Comparison based on public documentation, API capabilities, and observed behavior patterns.
- No controlled benchmark was run; ratings reflect qualitative assessment of fitness for MASC keeper PR lifecycle work.
- All three agents experience capacity backpressure in shared API environments (observed across MASC fleet turns).