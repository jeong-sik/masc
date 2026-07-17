(* RFC-0264 P2. See the .mli for the contract. Mirrors the cost-ledger
   append pattern (Keeper_hooks_oas_cost_events): a Dated_jsonl store under
   masc_root, append wrapped so a write failure degrades to a log line and never
   propagates into the turn. Retention is deliberately kept out of append's hot
   path and handled by server maintenance.

   Schema v2 (masc#25052): see the .mli doc comment for why full key lists were
   replaced with per-keeper deltas. *)

module SS = Set_util.StringSet

let base_dir ~masc_root = Filename.concat masc_root "recall_injections"

let field_schema_version = "schema_version"
let field_keeper_id = "keeper_id"
let field_trace_id = "trace_id"
let field_turn = "turn"
let field_injected_fact_keys = "injected_fact_keys"
let field_injected_episode_keys = "injected_episode_keys"
let field_added_fact_keys = "added_fact_keys"
let field_removed_fact_keys = "removed_fact_keys"
let field_added_episode_keys = "added_episode_keys"
let field_removed_episode_keys = "removed_episode_keys"
let field_content_hash = "content_hash"
let field_n_facts_in_store = "n_facts_in_store"
let field_n_episodes_in_store = "n_episodes_in_store"
let field_ts = "ts"
let field_failure_reason = "failure_reason"
let failure_reason_read_error = "read_error"
let failure_reason_prompt_render_error = "prompt_render_error"
let failure_reason_unknown_label = "unknown_failure_reason"

(* Legacy rows (schema_version absent) are v1. v2 is the first delta schema. *)
let schema_version_legacy = 1
let schema_version_delta = 2

type payload =
  | Full_snapshot of
      { fact_keys : string list
      ; episode_keys : string list
      }
  | Delta of
      { added_fact_keys : string list
      ; removed_fact_keys : string list
      ; added_episode_keys : string list
      ; removed_episode_keys : string list
      ; content_hash : string
      }

type record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; ts : float option
  ; failure_reason : string option
  ; n_facts_in_store : int option
  ; n_episodes_in_store : int option
  ; payload : payload
  }

type decode_error =
  [ `Expected_object
  | `Missing_field of string
  | `Invalid_field of string
  | `Unsupported_schema_version of int
  ]

let json_required_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok value
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_required_int_field fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_optional_int_field fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error (`Invalid_field key)
  | None -> Ok None
;;

let json_optional_float_field fields key =
  match List.assoc_opt key fields with
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (Float.of_int value))
  | Some _ -> Error (`Invalid_field key)
  | None -> Ok None
;;

let json_required_string_list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> loop (value :: acc) rest
      | _ :: _ -> Error (`Invalid_field key)
    in
    loop [] items
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_optional_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error (`Invalid_field key)
  | None -> Ok None
;;

let payload_of_fields fields =
  match json_optional_int_field fields field_schema_version with
  | Error _ as e -> e
  | Ok (None | Some 1) ->
    (match
       ( json_required_string_list_field fields field_injected_fact_keys
       , json_required_string_list_field fields field_injected_episode_keys )
     with
     | Ok fact_keys, Ok episode_keys -> Ok (Full_snapshot { fact_keys; episode_keys })
     | Error err, _ | _, Error err -> Error err)
  | Ok (Some 2) ->
    (match
       ( json_required_string_list_field fields field_added_fact_keys
       , json_required_string_list_field fields field_removed_fact_keys
       , json_required_string_list_field fields field_added_episode_keys
       , json_required_string_list_field fields field_removed_episode_keys
       , json_required_string_field fields field_content_hash )
     with
     | ( Ok added_fact_keys
       , Ok removed_fact_keys
       , Ok added_episode_keys
       , Ok removed_episode_keys
       , Ok content_hash ) ->
       Ok
         (Delta
            { added_fact_keys; removed_fact_keys; added_episode_keys
            ; removed_episode_keys; content_hash
            })
     | Error err, _, _, _, _
     | _, Error err, _, _, _
     | _, _, Error err, _, _
     | _, _, _, Error err, _
     | _, _, _, _, Error err -> Error err)
  | Ok (Some other) -> Error (`Unsupported_schema_version other)
;;

let record_of_json_result = function
  | `Assoc fields ->
    (match
       ( json_required_string_field fields field_keeper_id
       , json_required_string_field fields field_trace_id
       , json_required_int_field fields field_turn )
     with
     | Error err, _, _ | _, Error err, _ | _, _, Error err -> Error err
     | Ok keeper_id, Ok trace_id, Ok turn ->
       (match
          ( json_optional_float_field fields field_ts
          , json_optional_string_field fields field_failure_reason
          , json_optional_int_field fields field_n_facts_in_store
          , json_optional_int_field fields field_n_episodes_in_store
          , payload_of_fields fields )
        with
        | Error err, _, _, _, _
        | _, Error err, _, _, _
        | _, _, Error err, _, _
        | _, _, _, Error err, _
        | _, _, _, _, Error err -> Error err
        | Ok ts, Ok failure_reason, Ok n_facts_in_store, Ok n_episodes_in_store, Ok payload ->
          Ok
            { keeper_id
            ; trace_id
            ; turn
            ; ts
            ; failure_reason
            ; n_facts_in_store
            ; n_episodes_in_store
            ; payload
            }))
  | _ -> Error `Expected_object
;;

let record_of_json json =
  match record_of_json_result json with
  | Ok record -> Some record
  | Error _ -> None
;;

let bounded_failure_reason_label = function
  | reason
    when String.equal reason failure_reason_read_error
         || String.equal reason failure_reason_prompt_render_error -> reason
  | _ -> failure_reason_unknown_label
;;

(* ── Pure delta primitives ────────────────────────────────────────────── *)

let diff_keys ~previous ~current =
  let prev_set = SS.of_list previous in
  let curr_set = SS.of_list current in
  SS.elements (SS.diff curr_set prev_set), SS.elements (SS.diff prev_set curr_set)
;;

let apply_delta ~previous ~added ~removed =
  let base = SS.of_list previous in
  let added_set = SS.of_list added in
  let removed_set = SS.of_list removed in
  SS.elements (SS.diff (SS.union base added_set) removed_set)
;;

(* Not a security digest: a cheap, order/duplicate-independent change-detection
   and self-consistency signal (tests check that replaying a [Delta] row's
   materialized set hashes back to the row's own [content_hash]). *)
let content_hash_of ~fact_keys ~episode_keys =
  let canon keys = keys |> SS.of_list |> SS.elements |> String.concat "\x1f" in
  Digest.to_hex (Digest.string (canon fact_keys ^ "\x1e" ^ canon episode_keys))
;;

type materialized =
  { record : record
  ; fact_keys : string list
  ; episode_keys : string list
  }

let materialize records =
  (* Precondition (see .mli): [records] is already chronological. Keyed purely
     by [keeper_id] because this is a pure, call-local fold over an in-memory
     list -- not the process-lifetime [Delta_state] registry below. *)
  let state : (string, SS.t * SS.t) Hashtbl.t = Hashtbl.create 16 in
  List.map
    (fun record ->
       let prev_facts, prev_episodes =
         Option.value
           (Hashtbl.find_opt state record.keeper_id)
           ~default:(SS.empty, SS.empty)
       in
       let facts, episodes =
         match record.payload with
         | Full_snapshot { fact_keys; episode_keys } ->
           SS.of_list fact_keys, SS.of_list episode_keys
         | Delta
             { added_fact_keys
             ; removed_fact_keys
             ; added_episode_keys
             ; removed_episode_keys
             ; content_hash = _
             } ->
           ( SS.diff (SS.union prev_facts (SS.of_list added_fact_keys)) (SS.of_list removed_fact_keys)
           , SS.diff
               (SS.union prev_episodes (SS.of_list added_episode_keys))
               (SS.of_list removed_episode_keys) )
       in
       Hashtbl.replace state record.keeper_id (facts, episodes);
       { record; fact_keys = SS.elements facts; episode_keys = SS.elements episodes })
    records
;;

(* ── Serialisers ──────────────────────────────────────────────────────── *)

(* Legacy (v1, [Full_snapshot]) serialiser. Pure. Kept for round-trip tests
   and fixtures; [append] below writes v2 [Delta] rows exclusively. *)
let to_json
      ?failure_reason
      ~keeper_id
      ~trace_id
      ~turn
      ~injected_fact_keys
      ~injected_episode_keys
      ~n_facts_in_store
      ~now
      ()
  : Yojson.Safe.t
  =
  let fields =
    [ field_schema_version, `Int schema_version_legacy
    ; field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_turn, `Int turn
    ; field_injected_fact_keys, `List (List.map (fun k -> `String k) injected_fact_keys)
    ; ( field_injected_episode_keys
      , `List (List.map (fun k -> `String k) injected_episode_keys) )
    ; field_n_facts_in_store, `Int n_facts_in_store
    ; field_ts, `Float now
    ]
  in
  let fields =
    match failure_reason with
    | None -> fields
    | Some reason -> fields @ [ field_failure_reason, `String reason ]
  in
  `Assoc fields
;;

let to_json_delta
      ?failure_reason
      ~keeper_id
      ~trace_id
      ~turn
      ~added_fact_keys
      ~removed_fact_keys
      ~added_episode_keys
      ~removed_episode_keys
      ~content_hash
      ~n_facts_in_store
      ~n_episodes_in_store
      ~now
      ()
  : Yojson.Safe.t
  =
  let fields =
    [ field_schema_version, `Int schema_version_delta
    ; field_keeper_id, `String keeper_id
    ; field_trace_id, `String trace_id
    ; field_turn, `Int turn
    ; field_added_fact_keys, `List (List.map (fun k -> `String k) added_fact_keys)
    ; field_removed_fact_keys, `List (List.map (fun k -> `String k) removed_fact_keys)
    ; ( field_added_episode_keys
      , `List (List.map (fun k -> `String k) added_episode_keys) )
    ; ( field_removed_episode_keys
      , `List (List.map (fun k -> `String k) removed_episode_keys) )
    ; field_content_hash, `String content_hash
    ; field_n_facts_in_store, `Int n_facts_in_store
    ; field_n_episodes_in_store, `Int n_episodes_in_store
    ; field_ts, `Float now
    ]
  in
  let fields =
    match failure_reason with
    | None -> fields
    | Some reason -> fields @ [ field_failure_reason, `String reason ]
  in
  `Assoc fields
;;

let make_store ~masc_root () = Dated_jsonl.create ~base_dir:(base_dir ~masc_root) ()

(* ── Per-keeper previous-state registry (for append-time delta) ─────────
   Process-local, in-memory, keyed by (masc_root, keeper_id) rather than just
   keeper_id: this module has no [t] handle carrying identity across calls
   (every [append] call re-derives its [Dated_jsonl.t] from [masc_root]), and
   tests exercise multiple distinct masc_roots with reused keeper_id strings
   ("alpha", "keeper-a", ...) inside one test binary process. Keying by
   keeper_id alone would let one test's delta baseline leak into an unrelated
   test using the same keeper name against a different masc_root.

   [peek] and [commit] are separate short critical sections rather than one
   held across the [Dated_jsonl.append] call: the store's own append path
   acquires an [Eio.Mutex] and performs blocking file I/O, and a
   [Stdlib.Mutex] critical section must never yield (see
   Keeper_memory_lane's [state_mu] for the same invariant). Splitting them
   means a failed write leaves the registry at the last *persisted* baseline
   (not the attempted-but-lost one), so the next append recomputes the full
   delta including whatever the failed write dropped -- the ledger never
   silently skips a change because a prior write happened to fail. The
   narrow race this permits (two concurrent appends for the very same
   keeper interleaving peek/write/commit) is benign under replay: a
   redundant "added X" when X is already present is a no-op set union, not a
   correctness bug. In normal operation one keeper's turns are processed
   sequentially, so this race is not expected to occur at all. *)
module Delta_state = struct
  let mu = Stdlib.Mutex.create ()
  let table : (string * string, SS.t * SS.t) Hashtbl.t = Hashtbl.create 64

  let peek ~masc_root ~keeper_id =
    Stdlib.Mutex.protect mu (fun () ->
      Option.value
        (Hashtbl.find_opt table (masc_root, keeper_id))
        ~default:(SS.empty, SS.empty))
  ;;

  let commit ~masc_root ~keeper_id ~facts ~episodes =
    Stdlib.Mutex.protect mu (fun () ->
      Hashtbl.replace table (masc_root, keeper_id) (facts, episodes))
  ;;

  let reset_for_testing () = Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset table)
end

let error_label_of_exn exn =
  exn
  |> Keeper_memory_recall_exn_class.classify
  |> Keeper_memory_recall_exn_class.to_label
;;

let append
      ?failure_reason
      ~masc_root
      ~keeper_id
      ~trace_id
      ~turn
      ~injected_fact_keys
      ~injected_episode_keys
      ~n_facts_in_store
      ~now
      ()
  =
  let store = make_store ~masc_root () in
  let prev_facts, prev_episodes = Delta_state.peek ~masc_root ~keeper_id in
  let curr_facts = SS.of_list injected_fact_keys in
  let curr_episodes = SS.of_list injected_episode_keys in
  let added_fact_keys = SS.elements (SS.diff curr_facts prev_facts) in
  let removed_fact_keys = SS.elements (SS.diff prev_facts curr_facts) in
  let added_episode_keys = SS.elements (SS.diff curr_episodes prev_episodes) in
  let removed_episode_keys = SS.elements (SS.diff prev_episodes curr_episodes) in
  let content_hash =
    content_hash_of ~fact_keys:injected_fact_keys ~episode_keys:injected_episode_keys
  in
  let entry =
    to_json_delta
      ?failure_reason
      ~keeper_id
      ~trace_id
      ~turn
      ~added_fact_keys
      ~removed_fact_keys
      ~added_episode_keys
      ~removed_episode_keys
      ~content_hash
      ~n_facts_in_store
      ~n_episodes_in_store:(List.length injected_episode_keys)
      ~now
      ()
  in
  try
    Dated_jsonl.append store entry;
    Delta_state.commit ~masc_root ~keeper_id ~facts:curr_facts ~episodes:curr_episodes
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "recall_injection_ledger: failed to write %s: %s"
      (Dated_jsonl.base_dir store)
      (Printexc.to_string exn)
;;

type prune_error =
  [ `Sys_error
  | `Unix_error
  | `Json_error
  | `Unexpected_exception
  ]

let string_of_prune_error = function
  | `Sys_error -> "sys_error"
  | `Unix_error -> "unix_error"
  | `Json_error -> "json_error"
  | `Unexpected_exception -> "unexpected_exception"
;;

let prune_failure_label = function
  | Sys_error _ -> `Sys_error
  | Unix.Unix_error _ -> `Unix_error
  | Yojson.Json_error _ -> `Json_error
  | _ -> `Unexpected_exception
;;

let prune_older_than ~masc_root ~retention_days =
  try Ok (Dated_jsonl.prune (make_store ~masc_root ()) ~days:retention_days) with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let label = prune_failure_label exn in
    Log.Keeper.warn
      "recall_injection_ledger: failed to prune %s: label=%s"
      (base_dir ~masc_root)
      (string_of_prune_error label);
    Error label
;;

module For_testing = struct
  let reset_delta_state = Delta_state.reset_for_testing
end
