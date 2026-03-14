# Worker Shell Constraints

Workers spawned via MASC (`spawn_eio.ml`) have specific shell execution constraints.

## Constraint: No compound shell commands in worker tool calls

Workers stall when their tool calls contain shell metacharacters: `cd`, `&&`, `;`, `|`, `||`.

### Why

MASC workers execute tools through their respective CLI interfaces (claude, codex, gemini). When a worker calls a shell tool (e.g., `Bash`, `shell_exec`), the tool receives a single command string. Compound commands fail because:

1. **CLI agents** (claude, codex, gemini): Spawned via `Eio.Process.spawn` with the prompt as stdin. The agent's Bash tool may handle compound commands, but the agent itself sometimes splits or misinterprets them.
2. **Local llama workers**: Run via `Local_agent_eio.run_worker_oas`. The llama model frequently generates compound commands that exceed the tool's single-command expectation.

### Affected patterns

```bash
# These cause worker stalls:
cd /path && dune build          # compound (&&)
git add . ; git commit -m "x"  # compound (;)
cat file | grep pattern         # pipe (|)
test -f x || echo "missing"    # conditional (||)

# These work:
dune build --root /path         # single command with flag
git -C /path status             # git with -C flag
grep pattern file               # no pipe needed
```

### Workarounds

1. **Use tool-specific flags** instead of `cd`: `dune build --root /path`, `git -C /path`
2. **Split into separate tool calls**: One command per Bash invocation
3. **Use `bash -c`** to wrap compound commands: `bash -c "cd /path && dune build"` (works but fragile)

### For prompt authors

When writing prompts for MASC workers, avoid instructing them to use compound commands. Instead, provide explicit single-command alternatives.

### For MASC developers

Potential improvements (tracked as task-357):
- Add prompt validation that warns on shell metacharacters in worker instructions
- Wrap worker shell tool calls in `bash -c` at the spawn level
- Document allowed tool schemas more explicitly for local workers
