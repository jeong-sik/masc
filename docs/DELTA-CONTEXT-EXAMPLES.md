# Delta Context Optimization - Usage Examples

This document provides practical examples of using the delta-based context optimization in MASC.

## Quick Start

### Enabling Delta Checkpoints

Set the feature flag via environment variable:

```bash
export MASC_KEEPER_DELTA_CHECKPOINT_ENABLED=1
```

Or in your configuration file:

```bash
# Enable delta-based checkpoint storage
MASC_KEEPER_DELTA_CHECKPOINT_ENABLED=1

# Enable lazy message loading (experimental)
MASC_KEEPER_LAZY_MESSAGE_LOADING=0

# Maximum delta chain length (default: 5)
MASC_KEEPER_DELTA_MAX_CHAIN_LENGTH=5

# Minimum messages before using delta (default: 3)
MASC_KEEPER_DELTA_MIN_MESSAGES=3
```

### Basic Usage

The delta checkpoint system is integrated into the keeper checkpoint store and works transparently:

```ocaml
(* In your keeper code *)

(* Save a checkpoint with delta support *)
let ckpt =
  Keeper_checkpoint_store.save_with_delta_support
    ~session_dir:"/path/to/session"
    ~prev_ckpt:(Some previous_checkpoint)
    ~ctx:working_context
    ~generation:42
in
Printf.printf "Saved checkpoint: %s\n" ckpt.checkpoint_id

(* Load the latest checkpoint with delta reconstruction *)
match Keeper_checkpoint_store.load_latest_with_delta_support
        ~session_dir:"/path/to/session"
        ~max_tokens:200_000
with
| None ->
  Printf.printf "No checkpoint found\n"
| Some ctx ->
  Printf.printf "Loaded context with %d messages\n"
    (List.length ctx.messages)
```

## Integration Examples

### Example 1: Simple Keeper Session

```ocaml
(* Initialize session *)
let session_dir = "/data/keeper/sessions/keeper-001" in
let max_tokens = 200_000 in

(* First turn - creates full checkpoint *)
let ctx1 =
  Keeper_working_context.create
    ~system_prompt:"You are a helpful assistant"
    ~max_tokens
in
let ctx1 = Keeper_working_context.append ctx1
  (Agent_sdk.Types.user_msg "Hello, who are you?") in
let ckpt1 =
  Keeper_checkpoint_store.save_with_delta_support
    ~session_dir ~prev_ckpt:None ~ctx:ctx1 ~generation:1
in
(* ckpt1 is a FULL checkpoint with base_checkpoint_id = None *)

(* Second turn - creates delta checkpoint *)
let ctx2 = Keeper_working_context.append ctx1
  (Agent_sdk.Types.assistant_msg "I'm a helpful assistant!") in
let ctx2 = Keeper_working_context.append ctx2
  (Agent_sdk.Types.user_msg "What can you help me with?") in
let ckpt2 =
  Keeper_checkpoint_store.save_with_delta_support
    ~session_dir ~prev_ckpt:(Some ckpt1) ~ctx:ctx2 ~generation:2
in
(* ckpt2 is a DELTA checkpoint with base_checkpoint_id = Some ckpt1.checkpoint_id *)
(* Only stores the 2 new messages (assistant + user) *)

(* Load and reconstruct *)
match Keeper_checkpoint_store.load_latest_with_delta_support
        ~session_dir ~max_tokens
with
| Some ctx ->
  assert (List.length ctx.messages = 3); (* All 3 messages reconstructed *)
  Printf.printf "Successfully reconstructed %d messages\n"
    (List.length ctx.messages)
| None ->
  failwith "Failed to load checkpoint"
```

### Example 2: Delta Chain with Multiple Turns

```ocaml
let run_keeper_turns session_dir max_tokens initial_ctx num_turns =
  let rec loop turn_num ctx prev_ckpt =
    if turn_num > num_turns then ctx
    else begin
      (* Simulate a turn *)
      let user_msg = Printf.sprintf "Turn %d: user input" turn_num in
      let asst_msg = Printf.sprintf "Turn %d: assistant response" turn_num in

      let ctx = Keeper_working_context.append ctx
        (Agent_sdk.Types.user_msg user_msg) in
      let ctx = Keeper_working_context.append ctx
        (Agent_sdk.Types.assistant_msg asst_msg) in

      (* Save checkpoint *)
      let ckpt =
        Keeper_checkpoint_store.save_with_delta_support
          ~session_dir ~prev_ckpt ~ctx ~generation:turn_num
      in

      (* Log delta efficiency *)
      let is_delta = match ckpt.checkpoint_id with
        | id ->
          (match Keeper_checkpoint_delta.load_delta ~session_dir ~checkpoint_id:id with
           | Some delta when delta.base_checkpoint_id <> None ->
             let eff = Keeper_checkpoint_delta.compute_delta_efficiency delta in
             Printf.printf "Turn %d: Delta checkpoint (%.1f%% efficiency)\n"
               turn_num (eff *. 100.0);
             true
           | _ ->
             Printf.printf "Turn %d: Full checkpoint\n" turn_num;
             false)
      in

      loop (turn_num + 1) ctx (Some ckpt)
    end
  in
  loop 1 initial_ctx None

(* Run 10 turns *)
let session_dir = "/data/keeper/sessions/test-delta" in
let ctx = Keeper_working_context.create
  ~system_prompt:"System prompt" ~max_tokens:200_000 in
let _final_ctx = run_keeper_turns session_dir 200_000 ctx 10
```

Expected output:
```
Turn 1: Full checkpoint
Turn 2: Delta checkpoint (66.7% efficiency)
Turn 3: Delta checkpoint (60.0% efficiency)
Turn 4: Delta checkpoint (57.1% efficiency)
Turn 5: Delta checkpoint (55.6% efficiency)
Turn 6: Full checkpoint  # Max chain length reached
Turn 7: Delta checkpoint (85.7% efficiency)
...
```

### Example 3: Monitoring Delta Chain Stats

```ocaml
let monitor_delta_chain session_dir =
  (* Get delta chain info *)
  let (chain_length, base_id_opt) =
    Keeper_checkpoint_store.get_delta_chain_info ~session_dir
  in

  Printf.printf "Delta chain length: %d\n" chain_length;
  (match base_id_opt with
   | Some base_id -> Printf.printf "Base checkpoint: %s\n" base_id
   | None -> Printf.printf "No base checkpoint found\n");

  (* Load latest checkpoint *)
  match list_checkpoints ~session_dir with
  | [] -> Printf.printf "No checkpoints\n"
  | latest :: _ ->
    let checkpoint_id =
      (* Extract checkpoint_id from filename *)
      String.sub latest 5 (String.length latest - 10)
    in

    (* Try to discover full delta chain *)
    (match Keeper_checkpoint_delta.discover_delta_chain
             ~session_dir ~latest_checkpoint_id:checkpoint_id
    with
     | None ->
       Printf.printf "Not a delta chain (or corrupted)\n"
     | Some chain ->
       let stats = Keeper_checkpoint_delta.compute_chain_stats chain in
       Printf.printf "%s\n" stats;

       (* Detailed delta breakdown *)
       List.iteri (fun i delta ->
         let eff = Keeper_checkpoint_delta.compute_delta_efficiency delta in
         Printf.printf "  Delta %d: %s -> +%d messages (%.1f%% efficiency)\n"
           (i+1)
           delta.checkpoint_id
           (List.length delta.new_messages)
           (eff *. 100.0)
       ) chain.deltas)
```

Example output:
```
Delta chain length: 4
Base checkpoint: ckpt-1234567890123
Delta chain: base=ckpt-1234567890123, deltas=4, new_msgs=8, avg_efficiency=66.67%
  Delta 1: ckpt-1234567890456 -> +2 messages (66.7% efficiency)
  Delta 2: ckpt-1234567890789 -> +2 messages (60.0% efficiency)
  Delta 3: ckpt-1234567891012 -> +2 messages (57.1% efficiency)
  Delta 4: ckpt-1234567891345 -> +2 messages (55.6% efficiency)
```

## Advanced Usage

### Custom Delta Configuration

You can configure delta behavior per session:

```ocaml
(* Temporarily override max chain length for testing *)
let original_max = Env_config_keeper.DeltaCheckpoint.max_chain_length in
Unix.putenv "MASC_KEEPER_DELTA_MAX_CHAIN_LENGTH" "10";

(* Run with extended delta chain *)
let _ctx = run_keeper_turns session_dir 200_000 initial_ctx 15 in

(* Restore original *)
Unix.putenv "MASC_KEEPER_DELTA_MAX_CHAIN_LENGTH"
  (string_of_int original_max)
```

### Fallback to Full Checkpoints

The system automatically falls back to full checkpoints when:

1. Delta chain reaches max length
2. Delta chain is corrupted or incomplete
3. First checkpoint in a session

```ocaml
let save_with_forced_full session_dir ctx generation =
  (* Force full checkpoint by passing None for prev_ckpt *)
  Keeper_checkpoint_store.save_with_delta_support
    ~session_dir
    ~prev_ckpt:None  (* Forces full checkpoint *)
    ~ctx
    ~generation
```

### Delta Chain Repair

If a delta chain becomes corrupted, the system automatically falls back:

```ocaml
let repair_corrupted_chain session_dir max_tokens =
  match Keeper_checkpoint_store.load_latest_with_delta_support
          ~session_dir ~max_tokens
  with
  | None ->
    Printf.printf "No checkpoint found or chain completely corrupted\n";
    None
  | Some ctx ->
    Printf.printf "Successfully loaded context (possibly from fallback)\n";
    (* Save as new full checkpoint to reset chain *)
    let ckpt =
      Keeper_checkpoint_store.save_with_delta_support
        ~session_dir ~prev_ckpt:None ~ctx ~generation:0
    in
    Printf.printf "Saved new base checkpoint: %s\n" ckpt.checkpoint_id;
    Some ctx
```

## Performance Comparison

### Benchmark: I/O Reduction

```ocaml
let benchmark_io_reduction () =
  let session_dir = "/tmp/benchmark-session" in
  let max_tokens = 200_000 in

  (* Disable delta *)
  Unix.putenv "MASC_KEEPER_DELTA_CHECKPOINT_ENABLED" "0";

  let ctx = Keeper_working_context.create
    ~system_prompt:(String.make 1000 'x') ~max_tokens in
  let t0 = Unix.gettimeofday () in

  (* Save 20 full checkpoints *)
  let _final = run_keeper_turns session_dir max_tokens ctx 20 in
  let t1 = Unix.gettimeofday () in
  let time_full = t1 -. t0 in

  (* Clean up *)
  ignore (Sys.command (Printf.sprintf "rm -rf %s" session_dir));

  (* Enable delta *)
  Unix.putenv "MASC_KEEPER_DELTA_CHECKPOINT_ENABLED" "1";

  let ctx = Keeper_working_context.create
    ~system_prompt:(String.make 1000 'x') ~max_tokens in
  let t2 = Unix.gettimeofday () in

  (* Save with deltas *)
  let _final = run_keeper_turns session_dir max_tokens ctx 20 in
  let t3 = Unix.gettimeofday () in
  let time_delta = t3 -. t2 in

  Printf.printf "Full checkpoints: %.3f seconds\n" time_full;
  Printf.printf "Delta checkpoints: %.3f seconds\n" time_delta;
  Printf.printf "Speedup: %.2fx\n" (time_full /. time_delta)
```

Expected output:
```
Full checkpoints: 0.450 seconds
Delta checkpoints: 0.082 seconds
Speedup: 5.49x
```

## Troubleshooting

### Delta Chain Not Working

Check if delta is enabled:

```bash
# Check environment variable
echo $MASC_KEEPER_DELTA_CHECKPOINT_ENABLED

# Check runtime value
ocaml -I _build/default/lib <<EOF
#require "masc";;
print_endline (string_of_bool Env_config_keeper.DeltaCheckpoint.enabled);;
EOF
```

### Delta Chain Broken

Inspect delta files:

```bash
# List delta checkpoint files
ls -lh /path/to/session/delta-*.json

# Check a delta checkpoint
cat /path/to/session/delta-ckpt-1234567890.json | jq .
```

Expected structure:
```json
{
  "checkpoint_id": "ckpt-1234567890",
  "base_checkpoint_id": "ckpt-1234567000",
  "timestamp": 1709123456.789,
  "generation": 5,
  "message_offset": 10,
  "new_messages": [
    {"role": "user", "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "incremental_token_count": 150,
  "total_message_count": 12,
  "total_token_count": 5400,
  "format_version": "delta-v1"
}
```

### Performance Not Improving

1. **Chain too short**: Increase session length or reduce `min_messages_for_delta`
2. **Chain too long**: Delta reconstruction overhead increases; reduce `max_chain_length`
3. **Frequent full checkpoints**: Check logs for why deltas aren't being used

## Migration Guide

### Migrating Existing Sessions

Existing full checkpoints work with delta-enabled code:

```ocaml
(* Load existing full checkpoint *)
let ctx_opt =
  Keeper_checkpoint_store.load_latest_with_delta_support
    ~session_dir:"/path/to/existing/session"
    ~max_tokens:200_000
in

(* Next save will create delta if appropriate *)
match ctx_opt with
| Some ctx ->
  let ctx = Keeper_working_context.append ctx
    (Agent_sdk.Types.user_msg "New message after migration") in
  let ckpt =
    Keeper_checkpoint_store.save_with_delta_support
      ~session_dir:"/path/to/existing/session"
      ~prev_ckpt:None  (* First save after migration - use full *)
      ~ctx
      ~generation:1
  in
  Printf.printf "Migration successful: %s\n" ckpt.checkpoint_id
| None ->
  failwith "No checkpoint to migrate"
```

### Disabling Delta for Specific Sessions

```ocaml
(* Override globally *)
Unix.putenv "MASC_KEEPER_DELTA_CHECKPOINT_ENABLED" "0";

(* Or use regular checkpoint functions *)
let ckpt = Keeper_working_context.create_checkpoint ctx ~generation in
Keeper_checkpoint_store.save ~session_dir ckpt
```

## Best Practices

1. **Start with defaults**: Use default configuration for most cases
2. **Monitor metrics**: Track delta efficiency and chain stats
3. **Periodic full checkpoints**: Let the system automatically create them
4. **Test before production**: Enable delta on development sessions first
5. **Backup important sessions**: Keep backups before enabling delta

## See Also

- [DELTA-CONTEXT-OPTIMIZATION.md](DELTA-CONTEXT-OPTIMIZATION.md) - Full specification
- [COMMON-PITFALLS.md](COMMON-PITFALLS.md) - Refactor traps
- `lib/keeper/keeper_checkpoint_delta.ml` - Implementation
- `lib/keeper/keeper_checkpoint_store.ml` - Integration
