(** Cascade Inspector (O1) audit runs projection.

   The runtime writer already persists per-call observations under
   [.masc/cascade_audit/YYYY-MM/DD.jsonl].  This projection keeps that
   durable SSOT and reshapes each record into the O1 inspector contract:
   one cascade run with configured pool, selected model, aggregate
   duration, and ordered hop rows. *)

open Dashboard_cascade_helpers

let json_string_member key json =
  match json_assoc_member key json with
  | `String value -> Some value
  | _ -> None
;;

let json_float_member key json =
  match json_assoc_member key json with
  | `Float value -> Some value
  | `Int value -> Some (float_of_int value)
  | _ -> None
;;

let json_int_member key json =
  match json_assoc_member key json with
  | `Int value -> Some value
  | `Float value -> Some (int_of_float value)
  | _ -> None
;;

let json_list_member key json =
  match json_assoc_member key json with
  | `List values -> values
  | _ -> []
;;

let nonempty_string value =
  match value with
  | Some raw ->
    let trimmed = String.trim raw in
    if String.equal trimmed "" then None else Some trimmed
  | None -> None
;;

let first_nonempty values = List.find_map nonempty_string values
let json_string_opt_member key json = json_string_member key json |> nonempty_string

let audit_store_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "cascade_audit"
;;

let cascade_audit_store ~base_path =
  Dated_jsonl.create ~base_dir:(audit_store_dir ~base_path) ()
;;

let stable_audit_run_id json =
  "cascade-audit-"
  ^ String.sub (Digest.to_hex (Digest.string (Yojson.Safe.to_string json))) 0 16
;;

let model_display_of_attempt attempt =
  let _ = attempt in
  "runtime"
;;

let fallback_reason_for_model ~model_id ~model_label fallback_events =
  let _ = model_id, model_label in
  match fallback_events with
  | [] -> None
  | _ :: _ -> Some "runtime_fallback"
;;

let audit_hop_json ~selected_model ~fallback_events attempt =
  let model_id = json_string_opt_member "model_id" attempt in
  let model_label = json_string_opt_member "model_label" attempt in
  let model = model_display_of_attempt attempt in
  let latency_ms = json_int_member "latency_ms" attempt in
  let error = json_string_opt_member "error" attempt in
  let reason =
    match error with
    | Some _ -> Some "runtime_error"
    | None -> fallback_reason_for_model ~model_id ~model_label fallback_events
  in
  let selected =
    let _ = selected_model in
    false
  in
  let status =
    match error, reason, selected with
    | Some _, _, _ -> "error"
    | None, _, true -> "success"
    | None, Some _, false -> "fallback"
    | None, None, _ -> "attempted"
  in
  let base =
    [ "i", `Int (Option.value ~default:0 (json_int_member "attempt_index" attempt))
    ; "model", `String model
    ; "status", `String status
    ; "ms", `Int (Option.value ~default:0 latency_ms)
    ; ( "ms_source"
      , `String
          (if Option.is_some latency_ms then "oas_metrics_callbacks" else "unavailable") )
    ]
  in
  let fields =
    match reason with
    | Some value -> base @ [ "reason", `String value ]
    | None -> base
  in
  `Assoc fields
;;

let attempt_latency_total attempts =
  List.fold_left
    (fun acc attempt ->
       acc + Option.value ~default:0 (json_int_member "latency_ms" attempt))
    0
    attempts
;;

let last_attempt_error attempts =
  List.rev attempts |> List.find_map (json_string_opt_member "error")
;;

let audit_run_json_of_record json =
  let observation = json_assoc_member "observation" json in
  let attempts = json_list_member "attempts" observation in
  let fallback_events = json_list_member "fallback_events" observation in
  let cascade =
    first_nonempty
      [ json_string_member "cascade_name" json
      ; json_string_member "cascade_name" observation
      ]
    |> Option.value ~default:"unknown"
  in
  let ts = Option.value ~default:0.0 (json_float_member "ts" json) in
  let top_level_reason = json_string_opt_member "top_level_reason" json in
  let error_category =
    match top_level_reason with
    | Some _ -> Some "runtime_error"
    | None ->
      (match last_attempt_error attempts with
       | Some _ -> Some "runtime_error"
       | None -> None)
  in
  let base =
    [ "id", `String (stable_audit_run_id json)
    ; "cascade", `String cascade
    ; ( "trigger"
      , `String
          (json_string_opt_member "keeper_name" json |> Option.value ~default:"unknown") )
    ; "at", `Float ts
    ; ( "outcome"
      , `String (json_string_member "outcome" json |> Option.value ~default:"unknown") )
    ; "configured", `List []
    ; "primary", `Null
    ; "selected", `Null
    ; "total_ms", `Int (attempt_latency_total attempts)
    ; ( "total_ms_source"
      , `String
          (if
             List.exists
               (fun attempt -> Option.is_some (json_int_member "latency_ms" attempt))
               attempts
           then "attempt_latency_sum"
           else "unavailable") )
    ; ( "hops"
      , `List
          (List.map (audit_hop_json ~selected_model:None ~fallback_events) attempts) )
    ]
  in
  let fields =
    match error_category with
    | Some value -> base @ [ "error_category", `String value ]
    | None -> base
  in
  `Assoc fields
;;

let audit_run_cascade_matches cascade_filter run =
  match cascade_filter with
  | None -> true
  | Some expected ->
    (match json_string_member "cascade" run with
     | Some actual -> String.equal actual expected
     | None -> false)
;;

let audit_runs_json ?(dashboard_surface = "/api/v1/cascade/audit_runs") ~base_path ?limit
    ?cascade () =
  let limit = Option.value ~default:100 limit |> max 1 |> min 1024 in
  let read_limit = if Option.is_some cascade then min 4096 (limit * 4) else limit in
  let audit_store_dir = audit_store_dir ~base_path in
  let runs =
    Dated_jsonl.read_recent (cascade_audit_store ~base_path) read_limit
    |> List.rev
    |> List.map audit_run_json_of_record
    |> List.filter (audit_run_cascade_matches cascade)
  in
  let rec take n = function
    | _ when n <= 0 -> []
    | [] -> []
    | x :: xs -> x :: take (n - 1) xs
  in
  let runs = take limit runs in
  let generated_at = now_iso () in
  `Assoc
    [ "updated_at", `String generated_at
    ; "generated_at_iso", `String generated_at
    ; "dashboard_surface", `String dashboard_surface
    ; "source", `String "cascade_audit_jsonl"
    ; ( "retention"
      , retention_json
          ~scope:"cascade_audit_runs"
          ~producer:"Cascade_legacy_runner.cascade_observation_to_json"
          ~store_kind:"dated_jsonl"
          ~durable_store:audit_store_dir
          ~cache_policy:"uncached; reads recent persisted JSONL rows newest first"
          () )
    ; ( "query"
      , cascade_query_json
          [ "limit", `Int limit
          ; optional_string_field "cascade" cascade
          ] )
    ; "total_runs", `Int (List.length runs)
    ; "audit_runs", `List runs
    ]
;;
