(** Current metrics-ledger tool audit for operator control snapshots. *)

type tool_audit =
  { recent_tool_names : string list
  ; latest : Keeper_status_metrics.tool_audit_snapshot
  }

type read =
  | Read of tool_audit
  | Timed_out
  | Unreadable of string

(* Physical metrics rows the recent-tool walk may look at, newest last. *)
let recent_window_rows = 120

let read_from_files config (meta : Keeper_meta_contract.keeper_meta) =
  let store = Keeper_types_support.keeper_metrics_store config meta.name in
  match Dated_jsonl.read_recent_lines_result store recent_window_rows with
  | Error error -> Error (Dated_jsonl.read_error_to_string error)
  | Ok rows ->
    (match
       Keeper_status_metrics.latest_tool_audit_snapshot_from_files
         config
         ~keeper_name:meta.name
     with
     | Error error -> Error (Dated_jsonl.read_error_to_string error)
     | Ok latest ->
       let recent_tool_names =
         Operator_control_snapshot_tool_names.collect_recent_tool_names
           (List.map (fun (_path, line) -> line) rows)
       in
       let latest =
         match latest with
         | Some snapshot -> snapshot
         | None -> Keeper_status_metrics.empty_tool_audit_snapshot
       in
       Ok { recent_tool_names; latest })
;;

(* [Dashboard_cache] holds JSON, so a [Reuse] read hands it this module's own
   encoding of the read outcome and decodes what comes back. The cache owns
   the compute window, stampede protection and stale-while-revalidate; a
   typed memo would have to own them again. Both directions live here, and
   the decoder accepts exactly what the encoder writes: any other value is
   [None], never an audit with empty fields. *)
let json_of_string_opt = function
  | Some value -> `String value
  | None -> `Null
;;

let string_opt_of_json = function
  | `Null -> Some None
  | `String value -> Some (Some value)
  | _ -> None
;;

let json_of_int_opt = function
  | Some value -> `Int value
  | None -> `Null
;;

let int_opt_of_json = function
  | `Null -> Some None
  | `Int value -> Some (Some value)
  | _ -> None
;;

let json_of_strings values = `List (List.map (fun value -> `String value) values)

let strings_of_json = function
  | `List items ->
    List.fold_right
      (fun item acc ->
         match item, acc with
         | `String value, Some rest -> Some (value :: rest)
         | _, _ -> None)
      items
      (Some [])
  | _ -> None
;;

let cached_json_of_outcome = function
  | Ok { recent_tool_names; latest } ->
    `Assoc
      [ ( "read"
        , `List
            [ json_of_strings recent_tool_names
            ; json_of_strings latest.latest_tool_names
            ; json_of_int_opt latest.latest_tool_call_count
            ; json_of_string_opt latest.latest_action_source
            ; json_of_string_opt latest.tool_audit_source
            ; json_of_string_opt latest.tool_audit_at
            ] )
      ]
  | Error detail -> `Assoc [ "unreadable", `String detail ]
;;

let outcome_of_cached_json = function
  | `Assoc
      [ ( "read"
        , `List
            [ recent_tool_names
            ; latest_tool_names
            ; latest_tool_call_count
            ; latest_action_source
            ; tool_audit_source
            ; tool_audit_at
            ] )
      ] ->
    (match
       ( strings_of_json recent_tool_names
       , strings_of_json latest_tool_names
       , int_opt_of_json latest_tool_call_count
       , string_opt_of_json latest_action_source
       , string_opt_of_json tool_audit_source
       , string_opt_of_json tool_audit_at )
     with
     | ( Some recent_tool_names
       , Some latest_tool_names
       , Some latest_tool_call_count
       , Some latest_action_source
       , Some tool_audit_source
       , Some tool_audit_at ) ->
       Some
         (Ok
            { recent_tool_names
            ; latest =
                { latest_tool_names
                ; latest_tool_call_count
                ; latest_action_source
                ; tool_audit_source
                ; tool_audit_at
                }
            })
     | _ -> None)
  | `Assoc [ "unreadable", `String detail ] -> Some (Error detail)
  | _ -> None
;;

let read_of_outcome = function
  | Ok audit -> Read audit
  | Error detail -> Unreadable detail
;;

let read
      ~read_policy
      (config : Workspace.config)
      (meta : Keeper_meta_contract.keeper_meta)
  =
  match read_policy with
  | Dashboard_projection_read.Current -> read_of_outcome (read_from_files config meta)
  | Reuse ->
    let base_hash = Digest.to_hex (Digest.string config.base_path) in
    let cache_key = "kta:" ^ base_hash ^ ":" ^ meta.name in
    (* Only ordinary reads reuse this projection. Current source observations
       must see commits inside the existing ten-second request cache window. *)
    let ttl = 10.0 in
    let cached =
      Dashboard_cache.get_or_compute
        cache_key
        ~ttl
        (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
           cached_json_of_outcome (read_from_files config meta)))
    in
    if Dashboard_cache.is_timeout_envelope cached
    then Timed_out
    else (
      match outcome_of_cached_json cached with
      | Some outcome -> read_of_outcome outcome
      | None ->
        Unreadable
          (Printf.sprintf
             "cache entry %s is neither a tool audit nor a timeout envelope"
             cache_key))
;;

let read_state = function
  | Read _ -> Keeper_status_metrics.Tool_audit_read
  | Timed_out -> Tool_audit_timed_out
  | Unreadable _ -> Tool_audit_unreadable
;;

let row_fields read =
  let audit_fields =
    match read with
    | Read { recent_tool_names; latest } ->
      [ "latest_tool_names", json_of_strings latest.latest_tool_names
      ; "recent_tool_names", json_of_strings recent_tool_names
      ; "latest_tool_call_count", json_of_int_opt latest.latest_tool_call_count
      ; "latest_action_source", json_of_string_opt latest.latest_action_source
      ; "tool_audit_source", json_of_string_opt latest.tool_audit_source
      ; "tool_audit_at", json_of_string_opt latest.tool_audit_at
      ]
    | Timed_out | Unreadable _ ->
      [ "latest_tool_names", `Null
      ; "recent_tool_names", `Null
      ; "latest_tool_call_count", `Null
      ; "latest_action_source", `Null
      ; "tool_audit_source", `Null
      ; "tool_audit_at", `Null
      ]
  in
  let read_error =
    match read with
    | Read _ | Timed_out -> `Null
    | Unreadable detail -> `String detail
  in
  audit_fields
  @ [ ( Keeper_status_metrics.tool_audit_read_field
      , `String (Keeper_status_metrics.tool_audit_read_state_to_wire (read_state read)) )
    ; Keeper_status_metrics.tool_audit_read_error_field, read_error
    ]
;;

let completeness ~keeper_name = function
  | Read _ -> Dashboard_projection_read.Complete
  | Timed_out ->
    Partial (Printf.sprintf "Keeper %s tool audit: read timed out" keeper_name)
  | Unreadable detail ->
    Partial (Printf.sprintf "Keeper %s tool audit: %s" keeper_name detail)
;;

(* Concurrency cap for parallel keeper snapshot fibers.
   Originally 4 to guard against memory bursts when many keepers are
   processed simultaneously.  Live measurement via #8829 over 48 samples
   showed this cap was the dominant cost, not the per-keeper I/O:

       wait avg=1334ms max=4424ms   (queued on semaphore)
       work avg=604ms  max=3088ms   (meta/agent/profile I/O + JSON)
       ratio wait/work = 2.21x

   Raising to 16 matches the current fleet size so no fiber queues on
   the semaphore in the common case.  The original memory concern was
   written when keepers were a new surface; modern machines absorb the
   per-fiber JSON construction (~50 fields × 16 keepers ≈ a few MB)
   without visible pressure.  Env-overridable via
   [MASC_KEEPER_SNAPSHOT_CONCURRENCY] for operators on tight memory
   envelopes (e.g. CI runners) who still want the old behaviour. *)
