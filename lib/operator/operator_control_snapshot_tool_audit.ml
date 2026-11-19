(** Current metrics-ledger tool audit for operator control snapshots. *)

type tool_audit =
  { recent_tool_names : string list
  ; latest : Keeper_status_metrics.tool_audit_snapshot
  }

type read =
  | Read of tool_audit
  | Unreadable of string

(* The recent-tool walk looks at the newest metrics rows the store keeps as
   text. [newest_lines] is what
   [Keeper_status_metrics.newest_metrics_lines_result] answered for the
   Keeper: the row asks that once and gives the answer to this read and to
   its recent activity. The newest turn's audit is a kept fact of the same
   store.

   A fact the store holds is answered from memory. One it does not hold is
   read from the store's files. The answer is kept from then on when the
   process keeps facts, the read succeeds and no append landed while it
   ran. Otherwise the next call reads the files again: a process that keeps
   no facts and a store the strict read refuses read them on every call.
   This read adds no cache and no job of its own to that. *)
let read config (meta : Keeper_meta_contract.keeper_meta) ~newest_lines =
  match newest_lines with
  | Error error -> Unreadable (Dated_jsonl.read_error_to_string error)
  | Ok lines ->
    (match
       Keeper_status_metrics.latest_tool_audit_snapshot_from_files
         config
         ~keeper_name:meta.name
     with
     | Error error -> Unreadable (Dated_jsonl.read_error_to_string error)
     | Ok latest ->
       let recent_tool_names =
         Operator_control_snapshot_tool_names.collect_recent_tool_names lines
       in
       let latest =
         match latest with
         | Some snapshot -> snapshot
         | None -> Keeper_status_metrics.empty_tool_audit_snapshot
       in
       Read { recent_tool_names; latest })
;;

let json_of_string_opt = function
  | Some value -> `String value
  | None -> `Null
;;

let json_of_int_opt = function
  | Some value -> `Int value
  | None -> `Null
;;

let json_of_strings values = `List (List.map (fun value -> `String value) values)

let read_state = function
  | Read _ -> Keeper_status_metrics.Tool_audit_read
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
    | Unreadable _ ->
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
    | Read _ -> `Null
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
