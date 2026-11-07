# Execute held time, 2026-11-05 to 2026-11-08

Evidence for `docs/rfc/RFC-execute-background-through-the-tool-outbox.md`.

## Command

```
python3 docs/evidence/execute-background-2026-11/measure_execute_held_time.py \
    --base-path ~/me --since 2026-11-05T00:00:00 --until 2026-11-08T00:00:00 \
    --json-out docs/evidence/execute-background-2026-11/result-2026-11-05_11-08.json
```

The script reads the tool-call ledger and the Keepers' chat-operations
databases and writes nothing else. Its docstring defines each count.

## Result

Window: `ts` in [2026-11-05T00:00Z, 2026-11-08T00:00Z), long means 60 s or longer.

| | calls | hours |
|---|---|---|
| Execute, all Keepers | 26,733 | 67.79 |
| Execute, `github-pr-checker` and `pr-updater`, command contains `sleep <digits>`, long | 159 | 18.68 |
| Execute that ended with exit code 124, any duration | 34 | 2.86 |

| Delegations between Keepers that ended in the window | 288 |
|---|---|
| Completed while the submitter was inside a long Execute | 1 |
| Execute time left after that completion | 13.1 s |

## Limits

- The ledger is the live `~/me/.masc` of one operator. A different window or
  base path gives different counts; the result file records the window.
- The exit code is read from the first 600 characters of the stored `output`.
  A call whose output the ledger stored differently is not counted.
- A call counts as a sleep poll by the text of its command, so a command that
  only mentions `sleep 5` in a string is counted too.
- None of this shows what a Keeper does with the time a background run frees.
