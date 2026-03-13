# Qwen3.5 llama-server MASC Probe

Runtime probe for the current local path:

- model: `qwen3.5-35b-a3b-ud-q8-xl`
- server: `http://127.0.0.1:8085`
- protocol SSOT: OpenAI-compatible `/v1/chat/completions`
- tool source: `http://127.0.0.1:8935/mcp`

## What it checks

1. Engine contract
   plain text, JSON mode
2. Synthetic tool protocol
   tool selection, tool round-trip
3. MASC families
   status, coding, board, cleanup, team session, voice

## Usage

```bash
python3 scripts/qwen35_llama_masc_probe.py
```

Optional profiles:

```bash
python3 scripts/qwen35_llama_masc_probe.py \
  --sampling-profile unsloth_precise_coding

python3 scripts/qwen35_llama_masc_probe.py \
  --sampling-profile unsloth_general \
  --enable-thinking
```

Output:

- default JSON report: `/tmp/qwen35-llama-masc-probe.json`
- stdout: same JSON, pretty-printed

## Notes

- This probe classifies the full MASC catalog, but only executes safe or
  reversible representative tool families.
- It does not attempt destructive governance/admin flows.
- `enable_thinking=false` remains the safe default for tool loops.
