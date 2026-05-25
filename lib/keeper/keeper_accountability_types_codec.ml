(* Keeper_accountability_types_codec — types, codecs, and store access
   for the accountability ledger.
   Extracted from keeper_accountability.ml during godfile decomposition.
   Contains claim/resolution types, JSON serialization, Dated_jsonl store
   management, Prometheus emit-skip counter, and window entry reader. *)

type claim_kind = Keeper_accountability_claim_types.claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status = Keeper_accountability_claim_types.claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

type claim_event =
  { claim_id : string
  ; agent_name : string
  ; keeper_name : string
  ; trace_id : string option
  ; turn_number : int option
  ; task_id : string option
  ; kind : claim_kind
  ; subject : string
  ; surface : string
  ; created_at : string
  ; evidence_refs : string list
  ; synthetic : bool
  }

type resolution_event =
  { claim_id : string
  ; agent_name : string option
  ; keeper_name : string option
  ; task_id : string option
  ; kind : claim_kind option
  ; subject : string option
  ; status : claim_status
  ; resolved_at : string
  ; reason : string option
  ; supporting_evidence_refs : string list
  }

type claim_snapshot =
  { claim : claim_event
  ; resolution : resolution_event option
  }

let store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4
let store_cache_mu = Eio.Mutex.create ()
let window_read_count_for_testing_ref : int option ref = ref None
let task_commitment_expiry_sec = 72.0 *. 3600.0
let completion_claim_expiry_sec = 24.0 *. 3600.0
let dedupe_window_sec = 3600.0
let summary_window_days = 14

let claim_kind_to_string = Keeper_accountability_claim_types.claim_kind_to_string
let claim_kind_of_string = Keeper_accountability_claim_types.claim_kind_of_string
let claim_status_to_string = Keeper_accountability_claim_types.claim_status_to_string
let claim_status_of_string = Keeper_accountability_claim_types.claim_status_of_string

let normalize_refs refs =
  refs
  |> List.map String.trim
  |> List.filter (fun value -> value <> "")
  |> List.sort_uniq String.compare
;;

let is_keeper_agent_name agent_name =
  Option.is_some (Keeper_identity.canonical_keeper_name_from_agent_name agent_name)
;;

(** #10314: surface accountability ledger emit drops as a Prometheus
    counter so operators can distinguish "no emits because no work"
    from "no emits because the agent_name gate rejected the call".

    Pre-fix the [is_keeper_agent_name] gate at the top of
    [record_task_transition] and [record_completion_claim] silently
    returned unit when the caller's [agent_name] did not parse as
    a [keeper-<name>-agent] alias.  Production evidence (#10314):
    9 of 14 keepers (executor, taskmaster, qa-king, issue_king, ...)
    had decisions.jsonl traffic of 43KB-1MB+ but zero accountability
    events, while 5 keepers dominated the ledger (analyst alone at
    47%).  The skew was invisible because the drop emitted no signal.

    Labels stay bounded:
      [kind]   ∈ task_transition | completion_claim
      [reason] currently "not_keeper_agent_name" or "empty_subject";
               future gate additions get their own reason string. *)
let accountability_emit_skip_metric = "masc_accountability_emit_skip_total"

let () =
  Prometheus.register_counter
    ~name:accountability_emit_skip_metric
    ~help:
      "Total accountability ledger calls dropped before append because a precondition \
       gate rejected the call. Labels: kind (task_transition | completion_claim), reason \
       (not_keeper_agent_name | empty_subject). A non-zero rate on a keeper that has \
       decisions.jsonl traffic is the fleet observability gap from #10314."
    ()
;;

let record_emit_skip ~kind ~reason =
  Prometheus.inc_counter
    accountability_emit_skip_metric
    ~labels:[ "kind", kind; "reason", reason ]
    ()
;;

let keeper_name_of_agent agent_name =
  match Keeper_identity.canonical_keeper_name_from_agent_name agent_name with
  | Some keeper_name -> keeper_name
  | None -> String.trim agent_name
;;

let normalize_keeper_name keeper_name =
  match Keeper_identity.canonical_keeper_name keeper_name with
  | Some keeper_name -> keeper_name
  | None -> String.trim keeper_name
;;

let accountability_dir base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "accountability"
;;

let get_store (config : Coord_query.config) : Dated_jsonl.t =
  let base_path = config.base_path in
  Eio.Mutex.use_rw ~protect:true store_cache_mu (fun () ->
    match Hashtbl.find_opt store_cache base_path with
    | Some store -> store
    | None ->
      let store = Dated_jsonl.create ~base_dir:(accountability_dir base_path) () in
      Hashtbl.replace store_cache base_path store;
      store)
;;

let json_string_opt key json = Safe_ops.json_string_opt key json

let json_int_opt key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int value) -> Some value
     | Some (`Intlit raw) -> int_of_string_opt raw
     | Some (`Float value) -> Some (int_of_float value)
     | _ -> None)
  | _ -> None
;;

let json_bool key ~default json = Safe_ops.json_bool ~default key json

let json_string_list key json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`List items) ->
       List.filter_map (function
         | `String s -> Some s
         | _ -> None) items
     | _ -> [])
  | _ -> []
;;

let option_string_field key = function
  | Some value ->
    let trimmed = String.trim value in
    if trimmed <> "" then [ key, `String trimmed ] else []
  | None -> []
;;

let option_int_field key = function
  | Some value -> [ key, `Int value ]
  | None -> []
;;

let option_claim_kind_field key = function
  | Some value -> [ key, `String (claim_kind_to_string value) ]
  | None -> []
;;

let claim_event_to_json (event : claim_event) =
  `Assoc
    ([ "event_type", `String "claim_created"
     ; "claim_id", `String event.claim_id
     ; "agent_name", `String event.agent_name
     ; "keeper_name", `String event.keeper_name
     ; "kind", `String (claim_kind_to_string event.kind)
     ; "subject", `String event.subject
     ; "surface", `String event.surface
     ; "created_at", `String event.created_at
     ; "evidence_refs", `List (List.map (fun r -> `String r) event.evidence_refs)
     ; "synthetic", `Bool event.synthetic
     ]
     @ option_string_field "trace_id" event.trace_id
     @ option_int_field "turn_number" event.turn_number
     @ option_string_field "task_id" event.task_id)
;;

let resolution_event_to_json (event : resolution_event) =
  `Assoc
    ([ "event_type", `String "claim_resolved"
     ; "claim_id", `String event.claim_id
     ; "status", `String (claim_status_to_string event.status)
     ; "resolved_at", `String event.resolved_at
     ; ( "supporting_evidence_refs"
       , `List (List.map (fun r -> `String r) event.supporting_evidence_refs) )
     ]
     @ option_string_field "agent_name" event.agent_name
     @ option_string_field "keeper_name" event.keeper_name
     @ option_string_field "task_id" event.task_id
     @ option_claim_kind_field "kind" event.kind
     @ option_string_field "subject" event.subject
     @ option_string_field "reason" event.reason)
;;

let event_date_string ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf
    "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
;;

let iso8601_of_unix ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf
    "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec
;;

let claim_event_of_json json =
  match json_string_opt "event_type" json with
  | Some "claim_created" ->
    (match claim_kind_of_string (Safe_ops.json_string ~default:"" "kind" json) with
     | Some kind ->
       let claim_id = Safe_ops.json_string ~default:"" "claim_id" json in
       let ident = Keeper_identity.parse_json_identity json in
       let agent_name = ident.agent_name in
       let keeper_name = ident.keeper_name in
       let subject = Safe_ops.json_string ~default:"" "subject" json in
       let surface = Safe_ops.json_string ~default:"task" "surface" json in
       let created_at = Safe_ops.json_string ~default:"" "created_at" json in
       if claim_id = "" || agent_name = "" || subject = "" || created_at = ""
       then None
       else
         Some
           { claim_id
           ; agent_name
           ; keeper_name
           ; trace_id = ident.trace_id
           ; turn_number = json_int_opt "turn_number" json
           ; task_id = json_string_opt "task_id" json
           ; kind
           ; subject
           ; surface
           ; created_at
           ; evidence_refs = normalize_refs (json_string_list "evidence_refs" json)
           ; synthetic = json_bool "synthetic" ~default:false json
           }
     | None -> None)
  | _ -> None
;;

let resolution_event_of_json json =
  match json_string_opt "event_type" json with
  | Some "claim_resolved" ->
    (match claim_status_of_string (Safe_ops.json_string ~default:"" "status" json) with
     | Some status ->
       let claim_id = Safe_ops.json_string ~default:"" "claim_id" json in
       let resolved_at = Safe_ops.json_string ~default:"" "resolved_at" json in
       if claim_id = "" || resolved_at = ""
       then None
       else
         Some
           { claim_id
           ; agent_name = json_string_opt "agent_name" json
           ; keeper_name = json_string_opt "keeper_name" json
           ; task_id = json_string_opt "task_id" json
           ; kind =
               (* STR-OK: JSON boundary parse into typed claim_kind. *)
               (match json_string_opt "kind" json with
                | Some value -> claim_kind_of_string value
                | None -> None)
           ; subject = json_string_opt "subject" json
           ; status
           ; resolved_at
           ; reason = json_string_opt "reason" json
           ; supporting_evidence_refs =
               normalize_refs (json_string_list "supporting_evidence_refs" json)
           }
     | None -> None)
  | _ -> None
;;

let read_window_entries (config : Coord_query.config) =
  (match !window_read_count_for_testing_ref with
   (* tla-lint: allow-mutation: test hook — opt-in counter for window-read assertions *)
   | Some count -> window_read_count_for_testing_ref := Some (count + 1)
   | None -> ());
  let now = Time_compat.now () in
  let since = event_date_string (now -. (float_of_int summary_window_days *. 86400.0)) in
  let until = event_date_string now in
  Dated_jsonl.read_range (get_store config) ~since ~until
;;
