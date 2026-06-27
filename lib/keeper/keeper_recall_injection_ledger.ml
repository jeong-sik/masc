(* RFC-0264 P2. See the .mli for the contract. Mirrors the cost-ledger
   append pattern (Keeper_hooks_oas_cost_events): a Dated_jsonl store under
   masc_root, append wrapped so a write failure degrades to a log line and never
   propagates into the turn. Retention is deliberately kept out of append's hot
   path and handled by server maintenance. *)

let base_dir ~masc_root = Filename.concat masc_root "recall_injections"

let field_keeper_id = "keeper_id"
let field_trace_id = "trace_id"
let field_turn = "turn"
let field_injected_fact_keys = "injected_fact_keys"
let field_injected_episode_keys = "injected_episode_keys"
let field_n_facts_in_store = "n_facts_in_store"
let field_ts = "ts"
let field_failure_reason = "failure_reason"

type record =
  { keeper_id : string
  ; injected_fact_keys : string list
  ; injected_episode_keys : string list
  ; failure_reason : string option
  }

let json_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | _ -> None
;;

let json_string_list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    List.filter_map
      (function
        | `String value -> Some value
        | _ -> None)
      items
  | _ -> []
;;

let record_of_json = function
  | `Assoc fields ->
    (match json_string_field fields field_keeper_id with
     | None -> None
     | Some keeper_id ->
       Some
         { keeper_id
         ; injected_fact_keys = json_string_list_field fields field_injected_fact_keys
         ; injected_episode_keys = json_string_list_field fields field_injected_episode_keys
         ; failure_reason = json_string_field fields field_failure_reason
         })
  | _ -> None
;;

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
    [ field_keeper_id, `String keeper_id
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

let make_store ~masc_root () = Dated_jsonl.create ~base_dir:(base_dir ~masc_root) ()

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

let error_label_of_exn exn = exn |> prune_failure_label |> string_of_prune_error
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
  let entry =
    to_json
      ?failure_reason
      ~keeper_id
      ~trace_id
      ~turn
      ~injected_fact_keys
      ~injected_episode_keys
      ~n_facts_in_store
      ~now
      ()
  in
  try Dated_jsonl.append store entry with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Log.Keeper.warn
      "recall_injection_ledger: failed to write %s: %s"
      (Dated_jsonl.base_dir store)
      (Printexc.to_string exn)
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
