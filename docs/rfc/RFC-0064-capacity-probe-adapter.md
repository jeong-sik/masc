# RFC-0064: Capacity Probe Adapter

| Field    | Value                                              |
|----------|----------------------------------------------------|
| Status   | Draft                                              |
| Scope    | `lib/cascade/cascade_capacity_probe.ml` (new), `lib/keeper/` |
| Conflict | None expected                                      |

## 1. Problem

`Cascade_http_probe` (formerly `Cascade_ollama_probe`) is the only provider-specific
capacity probe in the cascade system. Keeper modules (`keeper_turn_driver`,
`keeper_turn_liveness`, `keeper_unified_turn`) import it directly and call
`is_ollama_url` to branch on provider identity before invoking probe functions
(`try_probe`, `cached_capacity`, `refresh_many`).

Adding another local LLM provider (vLLM, llama.cpp server, LM Studio) would
require duplicating the same branching pattern across all keeper callers — an
N-of-M anti-pattern (workaround rejection criterion #3).

Current capacity resolution is a hardcoded 3-tier chain scattered across
callers:

```
Cascade_throttle.capacity url
  |> fallback Cascade_http_probe.cached_capacity url
  |> fallback Cascade_client_capacity.capacity url
```

## 2. Proposal

Extract a provider-agnostic `Cascade_capacity_probe` module with:

1. A `Probe` module type (signature) declaring `can_probe`, `probe`, `cached`
2. An HTTP implementation reusing the existing `Cascade_http_probe` internals
3. A registry of registered probes, iterated by the resolution chain
4. Keeper callers simplified to a single `Cascade_capacity_probe.capacity` call

### 2.1 Module Type

```ocaml
module type Probe = sig
  val can_probe : url:string -> bool
  val probe :
    sw:Eio.Switch.t ->
    net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
    url:string ->
    ?timeout_s:float ->
    unit ->
    Cascade_throttle.capacity_info option
  val cached : url:string -> ?now:float -> unit -> Cascade_throttle.capacity_info option
  val refresh_many :
    sw:Eio.Switch.t ->
    net:[> [> `Generic ] Eio.Net.ty ] Eio.Resource.t ->
    urls:string list ->
    ?timeout_s:float ->
    unit ->
    unit
end
```

### 2.2 Resolution Chain

```ocaml
(* Cascade_capacity_probe *)
let capacity url =
  match Cascade_throttle.capacity url with
  | Some _ as v -> v
  | None ->
    (* iterate registered probes *)
    List.find_map (fun (module P : Probe) ->
      if P.can_probe ~url then P.cached ~url () else None
    ) !registered_probes
    |> fun v -> match v with
    | Some _ as v -> v
    | None -> Cascade_client_capacity.capacity url
```

### 2.3 Keeper Caller Simplification

Before (keeper_turn_driver.ml:842-848):
```ocaml
capacity = (fun url ->
  match Cascade_throttle.capacity url with
  | Some _ as v -> v
  | None ->
    match Cascade_http_probe.cached_capacity url with
    | Some _ as v -> v
    | None -> Cascade_client_capacity.capacity url);
```

After:
```ocaml
capacity = Cascade_capacity_probe.capacity;
```

## 3. File Changes

| File | Action | Description |
|------|--------|-------------|
| `lib/cascade/cascade_capacity_probe.ml` | **New** | Module type + registry + resolution chain |
| `lib/cascade/cascade_capacity_probe.mli` | **New** | Public interface |
| `lib/cascade/cascade_http_probe.ml` | Modify | Wrap internals as `Http_probe : Probe` |
| `lib/cascade/cascade_http_probe.mli` | Modify | Export `Http_probe` module for registration |
| `lib/keeper/keeper_turn_driver.ml` | Modify | Replace 3-tier chain with `Cascade_capacity_probe.capacity` |
| `lib/keeper/keeper_turn_liveness.ml` | Modify | Replace `is_ollama_url` branch with probe dispatch |
| `lib/keeper/keeper_unified_turn.ml` | Modify | Replace `Cascade_http_probe.cached_capacity` direct call |
| `lib/dune` | No change | Uses `(include_subdirs unqualified)` — new files auto-discovered |

## 4. Migration Path

1. Create `Cascade_capacity_probe` with the HTTP probe as the sole registered probe.
2. Update keeper callers one at a time (3 files).
3. `Cascade_http_probe` internals remain unchanged — only wrapped with a
   `Probe` module type and re-exported as `Http_probe`.
4. No behavioral change: same resolution chain, same caching, same fail-open.

## 5. Future Extensions

Adding a vLLM probe requires only:
1. Create `cascade_vllm_probe.ml` implementing `Probe`
2. Register it in `Cascade_capacity_probe` startup
3. Zero keeper changes

## 6. Risk Assessment

- **Low risk**: This is a pure refactoring. The resolution chain and caching
  behavior are identical to the current hardcoded chain.
- **Test coverage**: Existing `test_cascade_http_probe.ml` covers the probe
  internals. New integration test for the adapter dispatch.
