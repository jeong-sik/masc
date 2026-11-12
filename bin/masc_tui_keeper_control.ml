module Status = Masc.Keeper_status_runtime
module Decode = Masc.Tui_decode

(* A server error body is [{ok:false, error}]; anything else is shown as its
   own first line so the operator still sees what the server said. *)
let first_line value =
  match String.index_opt value '\n' with
  | None -> value
  | Some idx -> String.sub value 0 idx

let response_detail ~status body =
  let fallback () =
    match String.trim (first_line body) with
    | "" -> Printf.sprintf "HTTP %d" status
    | text -> text
  in
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc_opt "error" fields with
      | Some (`String detail) when String.trim detail <> "" -> detail
      | Some _ | None -> fallback ())
  | _ -> fallback ()
  | exception Yojson.Json_error _ -> fallback ()


type liveness =
  | Unobserved
  | Invalid of string
  | Absent
  | Present of Decode.keeper_runtime

type reading = {
  name : string;
  paused : bool;
  liveness : liveness;
}

type roster_view =
  | Roster_unobserved
  | Roster_partial of
      { observed : Decode.keeper_runtime list
      ; total : int
      }
  | Roster_invalid of
      { observed : Decode.keeper_runtime list
      ; errors : (string * string) list
      ; complete : bool
      }
  | Roster_complete of Decode.keeper_runtime list

module Roster_names = Map.Make (String)

type roster = { source : roster_view; names : liveness Roster_names.t }

let unobserved_roster = { source = Roster_unobserved; names = Roster_names.empty }

let roster_view roster = roster.source

let prepare_roster source =
  let observed, errors =
    match source with
    | Roster_unobserved -> [], []
    | Roster_partial { observed; total = _ }
    | Roster_complete observed -> observed, []
    | Roster_invalid { observed; errors; complete = _ } -> observed, errors
  in
  let observed =
    List.fold_left
      (fun index (row : Decode.keeper_runtime) ->
        Roster_names.update row.kr_name
          (function None -> Some (Present row) | Some _ as first -> first) index)
      Roster_names.empty observed
  in
  let errors =
    List.fold_left
      (fun index (name, detail) ->
        Roster_names.update name
          (function None -> Some (Invalid detail) | Some _ as first -> first) index)
      Roster_names.empty errors
  in
  { source; names = Roster_names.union (fun _ error _ -> Some error) errors observed }

let roster_of_reading ~errors ~rows ~truncated ~total =
  (* [count] short of [total] is the same fact as truncation: rows that belong
     here are missing. The route drops a keeper whose metadata it cannot read,
     and that keeper's fiber is still running. *)
  let observed_count = List.length rows in
  let source =
    if errors <> [] then
      Roster_invalid { observed = rows; errors;
        complete = not truncated && observed_count + List.length errors >= total }
    else if truncated || observed_count < total then
      Roster_partial { observed = rows; total = max total observed_count }
    else Roster_complete rows
  in
  prepare_roster source

(* One Keeper's row as [GET /api/v1/gate/keepers?name=] answers it
   (RFC-0481 §3.1). *)
type row_reading =
  | Row of Decode.keeper_runtime
  | Row_invalid of string
  | No_row

let row_reading_of_reading ~keeper_name ~rows ~errors =
  match rows, errors with
  | [ (row : Decode.keeper_runtime) ], [] when String.equal row.kr_name keeper_name -> Ok (Row row)
  | [], [ (name, detail) ] when String.equal name keeper_name -> Ok (Row_invalid detail)
  | [], [] -> Ok No_row
  | _ :: _, _ | [], _ :: _ ->
    Error (Printf.sprintf "the row read for %s answered %d rows and %d errors for other names"
             keeper_name (List.length rows) (List.length errors))

let replace_row roster ~keeper_name reading =
  let by_name left right = String.compare left right in
  let splice observed errors =
    let observed =
      List.filter (fun (row : Decode.keeper_runtime) -> not (String.equal row.kr_name keeper_name))
        observed
    in
    let errors = List.filter (fun (name, _) -> not (String.equal name keeper_name)) errors in
    let observed, errors =
      match reading with
      | Row row ->
        ( List.sort (fun (left : Decode.keeper_runtime) (right : Decode.keeper_runtime) ->
              by_name left.kr_name right.kr_name)
            (row :: observed)
        , errors )
      | Row_invalid detail ->
        observed, List.sort (fun (left, _) (right, _) -> by_name left right) ((keeper_name, detail) :: errors)
      | No_row -> observed, errors
    in
    prepare_roster
      (match errors with
       | [] -> Roster_complete observed
       | _ :: _ -> Roster_invalid { observed; errors; complete = true })
  in
  (* Only a complete roster can take one row: a clamped or unread one does not
     say where the row belongs or what else is missing. *)
  match roster.source with
  | Roster_complete observed -> Some (splice observed [])
  | Roster_invalid { observed; errors; complete = true } -> Some (splice observed errors)
  | Roster_unobserved | Roster_partial _ | Roster_invalid { complete = false; _ } -> None

let starting_up_until (row : Decode.keeper_runtime) =
  match
    Decode.keeper_health_reading row.kr_health, row.kr_next_action, row.kr_identity
  with
  | (Decode.Health_running | Decode.Health_idle), Some Status.Probe, Ok identity -> (
      match Workspace_resilience.Time.parse_iso8601_opt identity.Decode.k_created_at with
      | Some created when created > 0.0 -> Some (created +. Status.agent_staleness_threshold_s)
      | Some _ | None -> None)
  | (Decode.Health_running | Decode.Health_idle), Some Status.Probe, Error _
  | (Decode.Health_running | Decode.Health_idle), Some (Status.Recover | Status.Direct_message), _
  | (Decode.Health_running | Decode.Health_idle), None, _
  | (Decode.Health_failing | Decode.Health_offline), _, _ ->
    None

type roster_failure =
  | Roster_unauthorized of Masc_tui_credential.server_reason
  | Roster_unreachable of string
  | Roster_malformed of string

let roster_failure_message ~credential_sent = function
  | Roster_unauthorized reason ->
      Printf.sprintf
        "live keeper status and lifecycle actions are unavailable: %s"
        (Masc_tui_credential.refusal ~credential_sent reason)
  | Roster_unreachable detail -> "live keeper status unavailable: " ^ detail
  | Roster_malformed detail -> "live keeper status unreadable: " ^ detail

let roster_failure_of_status ~status ~body =
  let unreachable () =
    Roster_unreachable
      (match response_detail ~status body with
       | "" -> Printf.sprintf "HTTP %d" status
       | detail -> detail)
  in
  match status with
  | 401 | 403 -> (
      match Masc_tui_credential.server_reason_of_body body with
      | Some reason -> Roster_unauthorized reason
      | None ->
          (* The server answered and refused; the status says so where the
             server's sentence alone would read like a lost connection. *)
          Roster_unreachable
            (Printf.sprintf "HTTP %d: %s" status (response_detail ~status body)))
  | _ -> unreachable ()

let liveness_of_roster roster name =
  match Roster_names.find_opt name roster.names with
  | Some reading -> reading
  | None ->
      match roster.source with
      | Roster_unobserved | Roster_partial _ -> Unobserved
      | Roster_complete _ -> Absent
      | Roster_invalid { complete; _ } -> if complete then Absent else Unobserved


(* One keeper, four separate readings, one accessor each. Nothing here folds
   one axis into another: the function this replaced let operator pause
   overwrite the surface status, so a keeper a person stopped and a keeper
   whose fiber died read the same word.

   [None] everywhere means the roster was not read for this keeper - a fact
   about the reading, not a state the keeper is in. *)
let health reading =
  match reading.liveness with
  | Unobserved | Invalid _ | Absent -> None
  | Present runtime -> Some runtime.Decode.kr_health

let next_action reading =
  match reading.liveness with
  | Unobserved | Invalid _ | Absent -> None
  | Present runtime -> runtime.Decode.kr_next_action

(* Failed configuration, unread status and observed absence are distinct
   readings; none supplies an invented heartbeat state. *)
let health_label ~ko reading =
  match reading.liveness with
  | Invalid _ -> if ko then "설정 오류" else "config error"
  | Unobserved -> Decode.keeper_health_word ~ko None
  | Absent -> if ko then "실시간 목록에 없음" else "absent from live roster"
  | Present runtime -> Decode.keeper_health_word ~ko (Some runtime.Decode.kr_health)

type action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup
  | Delete

(* One key each, and the toggle key submits whichever of pause/resume/boot the
   reading offers. Every letter here is unused by the Keepers surface's other
   bindings (j/k move, Enter opens, l logs, c and m chat, r refresh, q quits).

   Delete takes "x" and not "d": masc_tui.ml already binds "d" on this surface
   to the repository-changes view. "x" is bound elsewhere only under Config,
   Overview task detail, Schedules, Planning, Verification and Harness, each
   guarded on its own surface. *)
let action_key = function
  | Pause -> "p"
  | Resume -> "p"
  | Boot -> "p"
  | Shutdown -> "s"
  | Wakeup -> "w"
  | Delete -> "x"

let action_label ~ko = function
  | Pause -> if ko then "일시 정지" else "pause"
  | Resume -> if ko then "재개" else "resume"
  | Boot -> if ko then "올리기" else "boot"
  | Shutdown -> if ko then "내리기" else "shutdown"
  | Wakeup -> if ko then "깨우기" else "wake"
  | Delete -> if ko then "삭제" else "delete"

let action_gerund ~ko = function
  | Pause -> if ko then "일시 정지하는 중" else "pausing"
  | Resume -> if ko then "재개하는 중" else "resuming"
  | Boot -> if ko then "올리는 중" else "booting"
  | Shutdown -> if ko then "내리는 중" else "shutting down"
  | Wakeup -> if ko then "깨우는 중" else "waking"
  | Delete -> if ko then "삭제하는 중" else "deleting"

(* Shutdown ends the fiber and latches a durable operator pause, so bringing
   the keeper back is a three-request sequence rather than an undo. The web
   dashboard puts a confirmation in front of it for the same reason
   (dashboard/src/components/keeper-action-panel.ts). Pause, resume, boot and
   wake each have a single-request inverse and submit on the first press. *)
(* Mirrors dashboard/src/api/keeper-lifecycle.ts KEEPER_PURGE_ARTIFACTS, which
   mirrors the server's own plan. Written out rather than fetched: the
   confirmation has to name what it removes before the request is sent, and
   there is no route that answers "what would a purge take". *)
let purge_artifacts =
  [ "metrics store"
  ; "decision, feedback and state-transition logs including rotations"
  ; "runtime directory"
  ; "Memory OS snapshots and journal"
  ; "turn boundary log and Librarian read position"
  ; "sandbox workspaces"
  ; "runtime assignment and Keeper egress configuration"
  ; "TOML configuration"
  ; "chat history"
  ; "agent files and auth tokens"
  ]

let requires_confirmation = function
  | Shutdown | Delete -> true
  | Pause | Resume | Boot | Wakeup -> false

(* A row the roster has but whose keepalive is not running is registered
   without a fiber: nothing runs it, the same as a keeper the roster lacks.
   [keepalive_running] on the server is [Keeper_state_machine.can_execute_turn],
   which is [false] in the [Paused] phase even though the keepalive fiber is
   still alive and sleeping on its condition, so [Paused] counts as a live
   fiber too. *)
let runs reading =
  match reading.liveness with
  | Unobserved | Invalid _ -> None
  | Absent -> Some false
  | Present runtime ->
      if Decode.keeper_phase_is_transitioning runtime.Decode.kr_phase then None
      else
        Some
          (runtime.Decode.kr_keepalive_running
           || Decode.keeper_phase_is_paused runtime.Decode.kr_phase)

(* Confirmed deletion uses the durable server shutdown operation, which
   stops and joins the exact lane before removing its artifacts. *)
let available reading =
  match runs reading with
  | None -> [ Delete ]
  | Some false -> [ Boot; Delete ]
  | Some true ->
      let paused =
        reading.paused
        ||
        match reading.liveness with
        | Present runtime ->
            runtime.Decode.kr_paused
            || Decode.keeper_phase_is_paused runtime.Decode.kr_phase
        | Unobserved | Invalid _ | Absent -> false
      in
      if paused then [ Resume; Wakeup; Shutdown; Delete ]
      else [ Pause; Wakeup; Shutdown; Delete ]

let primary reading =
  match available reading with
  | [] | [ Delete ] -> None
  | ((Pause | Resume | Boot | Shutdown | Wakeup) as first) :: _
  | (Delete as first) :: _ :: _ -> Some first

type step =
  | Lifecycle of string
  | Directive of string
  | Purge

let plan = function
  | Pause -> [ Directive "pause" ]
  | Resume -> [ Directive "resume" ]
  | Wakeup -> [ Directive "wakeup" ]
  | Boot -> [ Lifecycle "boot" ]
  | Shutdown -> [ Lifecycle "shutdown" ]
  | Delete -> [ Purge ]

let recovers_from_conflict = function
  | Boot -> Some [ Directive "resume"; Lifecycle "boot" ]
  | Pause | Resume | Shutdown | Wakeup | Delete -> None

type outcome =
  | Accepted of { already_live : bool }
  | Purge_accepted of { operation_id : string }
  | Committed_followup_failed of string
  | Paused_owner_conflict of string
  | Rejected of { status : int; detail : string }

let classify_2xx_response ~status body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      let already_live =
        match List.assoc_opt "already_live" fields with
        | Some (`Bool value) -> value
        | Some _ | None -> false
      in
      match List.assoc_opt "ok" fields with
      | Some (`Bool false) ->
          let committed =
            List.assoc_opt "committed" fields = Some (`Bool true)
            || List.assoc_opt "projection" fields
               = Some
                   (`String
                     Masc.Keeper_paused_work_operator
                     .committed_followup_failed_projection)
          in
          let detail = response_detail ~status body in
          if committed then Committed_followup_failed detail
          else Rejected { status; detail }
      | Some _ | None -> Accepted { already_live })
  | _ -> Accepted { already_live = false }
  | exception Yojson.Json_error _ -> Accepted { already_live = false }

let is_non_recoverable_conflict body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc_opt "code" fields with
      | Some (`String code) ->
          String.equal code
            (Masc.Request_workspace_precondition.refusal_code
               Masc.Request_workspace_precondition.Workspace_mismatch)
          || String.equal code Decode.keeper_boot_phase_conflict_code
      | Some _ | None -> false)
  | _ -> false
  | exception Yojson.Json_error _ -> false

let classify_response ~status ~body =
  if status >= 200 && status < 300 then
    classify_2xx_response ~status body
  else if status = 409 && not (is_non_recoverable_conflict body) then
    Paused_owner_conflict (response_detail ~status body)
  else Rejected { status; detail = response_detail ~status body }

let classify_purge_response ~keeper_name ~status ~body =
  if status < 200 || status >= 300 then
    Rejected { status; detail = response_detail ~status body }
  else
    let invalid () = Rejected { status; detail = "invalid Keeper purge acceptance: target or operation identity missing" } in
    match Yojson.Safe.from_string body with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields, List.assoc_opt "accepted" fields,
         List.assoc_opt "target_kind" fields, List.assoc_opt "keeper_name" fields,
         List.assoc_opt "operation_id" fields with
       | Some (`Bool true), Some (`Bool true), Some (`String "keeper"),
         Some (`String name), Some (`String operation_id)
         when String.equal name (String.trim keeper_name) && String.trim operation_id <> "" ->
           Purge_accepted { operation_id }
       | _ -> invalid ())
    | _ -> invalid ()
    | exception Yojson.Json_error _ -> invalid ()

type pending = {
  pending_keeper : string;
  pending_action : action;
}

type gate =
  | Gate_submit
  | Gate_arm of pending
  | Gate_blocked_inflight

let gate_transition ~inflight ~pending ~keeper action =
  if inflight then Gate_blocked_inflight
  else if not (requires_confirmation action) then Gate_submit
  else
    match pending with
    | Some armed
      when String.equal armed.pending_keeper keeper
           && armed.pending_action = action ->
        Gate_submit
    | Some _ | None ->
        Gate_arm { pending_keeper = keeper; pending_action = action }

let lifecycle_body = "{}"

let workspace_field (expected_workspace : Decode.server_identity) =
  "expected_workspace", `Assoc
    [ "base_path", `String (Decode.Canonical_path.to_string expected_workspace.sid_base_path)
    ; "masc_root", `String (Decode.Canonical_path.to_string expected_workspace.sid_masc_root) ]

(* The purge route takes the keeper in the body rather than the path, under the
   name the dashboard sends. *)
let purge_body ~expected_workspace keeper_name =
  Yojson.Safe.to_string (`Assoc
    [ "agent_name", `String keeper_name; workspace_field expected_workspace ])

let deletion_retry_body ~expected_workspace ~keeper_name ~operation_id =
  Yojson.Safe.to_string
    (`Assoc
      [ "keeper_name", `String keeper_name
      ; "operation_id", `String operation_id
      ; workspace_field expected_workspace
      ])

let directive_body ~(expected_workspace : Decode.server_identity) ~operator_operation_id action =
  let fields =
    match action with
    | "resume" ->
        [ ("action", `String "resume")
        ; ("operator_operation_id", `String operator_operation_id)
        ]
    | _ -> [ ("action", `String action) ]
  in
  Yojson.Safe.to_string (`Assoc (workspace_field expected_workspace :: fields))

let mint_operation_id () =
  "masc-tui-resume-" ^ Random_id.uuid_v7 ()


type deletion_operation =
  | Runtime_shutdown of Masc.Keeper_shutdown_types.t
  | Configuration_removal of Masc.Keeper_configuration_removal.receipt

type deletion_row = {
  operation : deletion_operation;
  completed : bool;
  can_retry : bool;
}

type deletion_inventory = { operations : deletion_row list; errors : string list }

let decode_deletion_inventory json =
  let open Yojson.Safe.Util in
  let open Result.Syntax in
  let rec decode_rows acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      let* operation = Masc.Keeper_shutdown_store.of_json (member "operation" row)
        |> Result.map_error Masc.Keeper_shutdown_store.error_to_string in
      (match member "completed" row, member "can_retry" row with
       | `Bool completed, `Bool can_retry ->
         let open Masc.Keeper_shutdown_types in
         let expected = match operation.cleanup_intent.reason, operation.phase with
           | Dashboard_keeper_purge _, Finalized { completion = Completion_delivered Dashboard_keeper_purged; _ } ->
             Some (true, false)
           | Dashboard_keeper_purge _, Finalized { completion =
               (Completion_pending Dashboard_keeper_purged
               | Completion_delivery_failed { action = Dashboard_keeper_purged; _ }); _ } ->
             Some (false, true)
           | Dashboard_keeper_purge _,
             ( Prepared | Joining_lanes | Joined_idle | Finalizing_tasks _
             | Cleanup_ready _ | Reconciliation_required _ | Owner_absent _
             | Operator_absence_acknowledged _ | Blocked _ | Superseded _
             | Finalized
                 { completion =
                     ( Completion_not_requested
                     | Completion_pending Supervisor_cleaned
                     | Completion_delivery_failed
                         { action = Supervisor_cleaned; _ }
                     | Completion_delivered Supervisor_cleaned )
                 ; _
                 } ) -> Some (false, false)
           | ( Operator_stop_retain_meta | Operator_stop_remove_meta
             | Supervisor_cleanup ), _ -> None in
         if expected = Some (completed, can_retry)
         then decode_rows ({ operation = Runtime_shutdown operation; completed; can_retry } :: acc) rest
         else Error "deletion projection contradicts its durable operation"
       | _ -> Error "deletion row is missing completed/can_retry")
  in
  let rec decode_errors acc = function
    | [] -> Ok (List.rev acc)
    | row :: rest ->
      (match member "keeper_name" row, member "operation_id" row, member "error" row with
       | `String keeper, `String operation, `String detail ->
         decode_errors ((keeper ^ " / " ^ operation ^ ": " ^ detail) :: acc) rest
       | _ -> Error "invalid deletion inventory error")
  in
  try
    let rec decode_config acc = function
      | [] -> Ok (List.rev acc)
      | json :: rest ->
        let* receipt = Masc.Keeper_configuration_removal.of_json json
          |> Result.map_error Masc.Keeper_configuration_removal.error_to_string in
        let completed = receipt.state = Masc.Keeper_configuration_removal.Removed in
        decode_config ({ operation = Configuration_removal receipt; completed; can_retry = not completed } :: acc) rest in
    let rec strings acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> strings (value :: acc) rest
      | _ -> Error "invalid configuration deletion inventory error" in
    match member "operations" json, member "errors" json,
          member "configuration_removals" json, member "configuration_errors" json with
    | `List rows, `List errors, `List config_rows, `List config_errors ->
      let* operations = decode_rows [] rows in
      let* errors = decode_errors [] errors in
      let* configurations = decode_config [] config_rows in
      let* configuration_errors = strings [] config_errors in
      Ok { operations = operations @ configurations; errors = errors @ configuration_errors }
    | _ -> Error "invalid deletion inventory"
  with Yojson.Safe.Util.Type_error (detail, _) -> Error detail


let deletion_keeper_name row = match row.operation with
  | Runtime_shutdown operation -> operation.keeper_name
  | Configuration_removal receipt -> receipt.keeper_name

let deletion_operation_id row = match row.operation with
  | Runtime_shutdown operation -> operation.operation_id
  | Configuration_removal receipt -> receipt.operation_id

let deletion_json row = match row.operation with
  | Runtime_shutdown operation -> Masc.Keeper_shutdown_store.to_json operation
  | Configuration_removal receipt -> Masc.Keeper_configuration_removal.to_json receipt
