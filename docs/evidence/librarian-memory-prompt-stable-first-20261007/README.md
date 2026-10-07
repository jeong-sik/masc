# Memory-pass prompt with its unchanging parts first (2026-10-07)

The selection rules, the Keeper's instructions and its current Memory are the
same on every Memory pass of a Keeper until the Memory changes. The template
put the pending sources (`working_context`) and the task contexts before the
Memory. The provider could therefore reuse only the first ~1.8 KB of each
request from its prompt cache.

## Cache

`cache_demo.py` takes two recorded Memory passes of one Keeper (pr-updater,
230 KB Memory) with the same Memory and different conversations, and sends
them one after the other in each order:

| order | second pass prompt tokens | cached |
|---|---|---|
| recorded | 79,812 | 0 |
| unchanging parts first | 79,807 | 78,628 (98.5%) |

- **Price:** ollama.com/pricing lists deepseek-v4.1-flash input at $0.30 and
  cached input at $0.006 per million tokens.
- **Cache lifetime:** a separate probe found a 42.5k-token prefix still cached
  after 15 minutes.
- **Expected effect:** in 740 recorded Memory passes over 7.8 h, a Keeper
  re-sent the same instructions and Memory within 15 minutes for 81 of 155 MB
  of Memory (53%). That 53% is the share this order can serve from the cache.

## Behaviour (`ab_order.py`, `compare.py`)

30 recorded Memory passes, up to three per Keeper, were each sent in both
orders to `deepseek-v4.1-flash` on Ollama Cloud.

| | dropped memories | new claims | absorbed ids |
|---|---|---|---|
| recorded production answers | 14 | 40 | 35 |
| recorded order, rerun | 15 | 31 | 12 |
| unchanging parts first | **49** | 48 | 20 |

The no-change decision agreed in 25 of 30 passes between the two orders, and
in 26 of 30 between the recorded answers and the rerun.

The new order makes the model drop about three times as many memories.

- **What it drops:** every additional drop read by hand is a progress snapshot
  — a closed or merged PR, a superseded count, a finished task's state — that
  the template's own rules say not to keep.
- **What it keeps:** the lesson in each dropped memory is already held by
  another memory, or the answer carries it into a corrected claim.
- **What it never drops:** no constraint or preference.
- **Decision:** the operator chose decisive deletion (2026-10-07).

## Reproduce

```sh
export ORDER_AB_OUT=/path/outside/the/repo
OLLAMA_CLOUD_API_KEY=… python3 -I ab_order.py 30
python3 -I compare.py
OLLAMA_CLOUD_API_KEY=… python3 -I cache_demo.py
```
