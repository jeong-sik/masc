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
let failure_reason_read_error = "read_error"
let failure_reason_fact_store_parse_error = "fact_store_parse_error"
let failure_reason_episode_store_parse_error = "episode_store_parse_error"
let failure_reason_prompt_render_error = "prompt_render_error"
let failure_reason_unknown_label = "unknown_failure_reason"

type record =
  { keeper_id : string
  ; trace_id : string
  ; turn : int
  ; injected_fact_keys : string list
  ; injected_episode_keys : string list
  ; failure_reason : string option
  }

type decode_error =
  [ `Expected_object
  | `Missing_field of string
  | `Invalid_field of string
  ]

let json_required_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) -> Error (`Invalid_field key)
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_required_int_field fields key =
  match List.assoc_opt key fields with
  | Some (`Int value) -> Ok value
  | Some (`Intlit raw) ->
    (match int_of_string_opt raw with
     | Some value -> Ok value
     | None -> Error (`Invalid_field key))
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_required_string_list_field fields key =
  match List.assoc_opt key fields with
  | Some (`List items) ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest when String.trim value <> "" -> loop (value :: acc) rest
      | _ :: _ -> Error (`Invalid_field key)
    in
    loop [] items
  | Some _ -> Error (`Invalid_field key)
  | None -> Error (`Missing_field key)
;;

let json_optional_string_field fields key =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Ok (Some value)
  | Some (`String _) -> Error (`Invalid_field key)
  | Some _ -> Error (`Invalid_field key)
  | None -> Ok None
;;

let record_of_json_result = function
  | `Assoc fields ->
    (match
       ( json_required_string_field fields field_keeper_id
       , json_required_string_field fields field_trace_id
       , json_required_int_field fields field_turn
       , json_required_string_list_field fields field_injected_fact_keys
       , json_required_string_list_field fields field_injected_episode_keys
       , json_optional_string_field fields field_failure_reason )
     with
     | ( Ok keeper_id
       , Ok trace_id
       , Ok turn
       , Ok injected_fact_keys
       , Ok injected_episode_keys
       , Ok failure_reason ) ->
       Ok
         { keeper_id
         ; trace_id
         ; turn
         ; injected_fact_keys
         ; injected_episode_keys
         ; failure_reason
         }
     | Error err, _, _, _, _, _
     | _, Error err, _, _, _, _
     | _, _, Error err, _, _, _
     | _, _, _, Error err, _, _
     | _, _, _, _, Error err, _
     | _, _, _, _, _, Error err -> Error err)
  | _ -> Error `Expected_object
;;

let decode_error_to_string = function
  | `Expected_object -> "expected_object"
  | `Missing_field field -> Printf.sprintf "missing_field:%s" field
  | `Invalid_field field -> Printf.sprintf "invalid_field:%s" field
;;

let bounded_failure_reason_label = function
  | reason
    when String.equal reason failure_reason_read_error
         || String.equal reason failure_reason_fact_store_parse_error
         || String.equal reason failure_reason_episode_store_parse_error
         || String.equal reason failure_reason_prompt_render_error -> reason
  | _ -> failure_reason_unknown_label
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
  match Dated_jsonl.append_result store entry with
  | Ok () -> ()
  | Error msg ->
    Log.Keeper.warn
      "recall_injection_ledger: failed to write %s: %s"
      (Dated_jsonl.base_dir store)
      msg
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
