# Spread `[typesafeai]` judgments with `selection` and keyless destinations

The `[typesafeai]` gates (Board attention, the librarian absorb gate, librarian
preflight, context review, skill applicability, shared-memory host selection)
all ask the same destination list. Two table keys change how that list is used.
Both are experimental and change no gate's judgment logic.

## Turn it on

`selection` picks the order the walk tries the armed destinations in:

```toml
[typesafeai]
selection = "random"    # default "in_order"
```

- `in_order` (default) asks the table's order on every judgment, as before.
- `random` draws one armed destination uniformly at random per judgment and
  keeps the rest as reserve in walk order. With three armed destinations each
  is drawn first with probability 1/3. It is a draw, not a round-robin: the
  final share of answered calls is close to even but not exact, because a
  refusal moves the call on to the next reserve.

A destination may leave `api_key_env` out. It is then asked with no
`Authorization` header — how the machine's own Ollama joins the walk without
a key:

```toml
[typesafeai]
selection = "random"
destinations = [
  { endpoint = "https://api.typesafe.ai/v1/systemone", model = "jev-latest", api_key_env = "TYPESAFEAI_API_KEY" },
  { endpoint = "https://ollama.com/v1/systemone", model = "clef:cloud", api_key_env = "OLLAMA_CLOUD_API_KEY" },
  { endpoint = "http://127.0.0.1:11434/v1/systemone", model = "nimble" },
]
```

A keyless destination arms the lane on its own; a named variable still has to
hold a non-blank key for its destination to arm. The boot report names a
destination whose variable holds no key, exactly as before.

## Deploy before writing the table

The running server refuses unknown `[typesafeai]` keys, so `selection` and a
keyless destination are **load errors on an older binary**. Deploy a binary
that contains them first; only then edit the live `runtime.toml` through the
admin raw endpoint. Editing the file first leaves the next server start
refusing the whole table.

## What failure looks like

- A drawn destination that refuses (HTTP error, timeout, wrong shape) does not
  lose the judgment: the walk moves to the next reserve, and every attempt is
  recorded as before.
- `selection = "round_robin"` or any other spelling is refused at load with
  `selection must be in_order or random`, not silently treated as ordered.
- A keyless destination whose server is down behaves like any refusing
  destination: the reserve answers, and the refusal is on record.

## Turn it off

Set `selection = "in_order"` or remove the key for the previous per-table
order; remove the keyless destination entry to stop asking that server. Either
edit is a normal `runtime.toml` change through the admin raw endpoint and
takes effect without a restart for routing.

## Experimental scope

Measured 2026-10-19 against the live endpoints: 30 uniform draws over the
three backends above answered first 12 / 8 / 10 (expected 10 each), no
refusals. Backend quality on a 23-question screen: classification and factual
questions equal across jev-latest, clef:cloud and nimble; clef:cloud closest
on a risk rubric; jev-latest reported confidence 1.00 on wrong answers too,
so the Board attention confidence floor does not filter its misses. The
screen is small; revisit before trusting any single backend with a gate.
