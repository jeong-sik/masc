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
  | Absent
  | Present of Decode.keeper_runtime

type reading = {
  name : string;
  paused : bool;
  liveness : liveness;
}

type roster =
  | Roster_unobserved
  | Roster_partial of
      { observed : Decode.keeper_runtime list
      ; total : int
      }
  | Roster_complete of Decode.keeper_runtime list

let roster_of_reading ~rows ~truncated ~total =
  (* [count] short of [total] is the same fact as truncation: rows that belong
     here are missing. The route drops a keeper whose metadata it cannot read,
     and that keeper's fiber is still running. *)
  let observed_count = List.length rows in
  if truncated || observed_count < total then
    Roster_partial { observed = rows; total = max total observed_count }
  else Roster_complete rows

type roster_failure =
  | Roster_unauthorized
  | Roster_unreachable of string
  | Roster_malformed of string

let roster_failure_message ~credential_sent = function
  | Roster_unauthorized ->
      Printf.sprintf
        "live keeper status and lifecycle actions are unavailable: %s"
        (Masc_tui_credential.refusal ~credential_sent)
  | Roster_unreachable detail -> "live keeper status unavailable: " ^ detail
  | Roster_malformed detail -> "live keeper status unreadable: " ^ detail

let roster_failure_of_status ~status ~body =
  match status with
  | 401 | 403 -> Roster_unauthorized
  | _ ->
      Roster_unreachable
        (match response_detail ~status body with
         | "" -> Printf.sprintf "HTTP %d" status
         | detail -> detail)

let find_row rows name =
  List.find_opt
    (fun (row : Decode.keeper_runtime) -> String.equal row.kr_name name)
    rows

let liveness_of_roster roster name =
  match roster with
  | Roster_unobserved -> Unobserved
  | Roster_partial { observed; total = _ } -> (
      match find_row observed name with
      | Some row -> Present row
      | None ->
          (* Rows are missing from this roster, so this name may be one of
             them. That is not evidence of a stopped fiber. *)
          Unobserved)
  | Roster_complete rows -> (
      match find_row rows name with
      | Some row -> Present row
      | None -> Absent)


(* One keeper, four separate readings, one accessor each. Nothing here folds
   one axis into another: the function this replaced let operator pause
   overwrite the surface status, so a keeper a person stopped and a keeper
   whose fiber died read the same word.

   [None] everywhere means the roster was not read for this keeper - a fact
   about the reading, not a state the keeper is in. *)
let health reading =
  match reading.liveness with
  | Unobserved | Absent -> None
  | Present runtime -> Some runtime.Decode.kr_health

let next_action reading =
  match reading.liveness with
  | Unobserved | Absent -> None
  | Present runtime -> runtime.Decode.kr_next_action

(* Three outcomes, not two. A roster that was never read and a roster that
   answered without this keeper are different facts: the first says nothing
   about the keeper, the second says no fiber is running it. Spelling both
   "unread" would fold a reading into the absence of one. *)
let health_label reading =
  match reading.liveness with
  | Unobserved -> "unread"
  | Absent -> "absent"
  | Present runtime -> Decode.keeper_health_to_string runtime.Decode.kr_health

(* The roster header's tally, counted with the same function that labels the
   status column so the header and the column cannot disagree. They did: the
   tally folded [Surface_inactive] into "running", so ten rows reading
   "inactive" sat under a header reading "10 running". Counting the label
   itself removes the second spelling of the same reading rather than keeping
   it in step by hand. *)
let tally_by label_of readings =
  List.fold_left
    (fun counts reading ->
      let label = label_of reading in
      let rec bump = function
        | [] -> [ (label, 1) ]
        | (name, n) :: rest when String.equal name label -> (name, n + 1) :: rest
        | entry :: rest -> entry :: bump rest
      in
      bump counts)
    []
    readings

(* Counted with [health_label] because that is the word the status column now
   shows. The header and the column are one reading drawn twice; whichever
   function labels the column has to be the one that counts it. *)
let health_tally readings = tally_by health_label readings

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

let action_label = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Boot -> "boot"
  | Shutdown -> "shutdown"
  | Wakeup -> "wake"
  | Delete -> "delete"

let action_gerund = function
  | Pause -> "pausing"
  | Resume -> "resuming"
  | Boot -> "booting"
  | Shutdown -> "shutting down"
  | Wakeup -> "waking"
  | Delete -> "deleting"

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
  ; "sandbox workspaces"
  ; "runtime assignment and Keeper egress configuration"
  ; "TOML configuration"
  ; "chat history"
  ; "agent files and auth tokens"
  ]

let requires_confirmation = function
  | Shutdown | Delete -> true
  | Pause | Resume | Boot | Wakeup -> false

(* Confirmed deletion uses the server's durable shutdown operation, which
   stops and joins the exact lane before removing its artifacts. *)
let available reading =
  match reading.liveness with
  | Unobserved -> []
  | Absent -> [ Boot; Delete ]
  | Present runtime ->
      if not runtime.Decode.kr_keepalive_running then [ Boot; Delete ]
      else if reading.paused then [ Resume; Wakeup; Shutdown; Delete ]
      else [ Pause; Wakeup; Shutdown; Delete ]

let primary reading =
  match available reading with
  | [] -> None
  | first :: _ -> Some first

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
  | Paused_owner_conflict of string
  | Rejected of { status : int; detail : string }

let already_live_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc_opt "already_live" fields with
      | Some (`Bool value) -> value
      | Some _ | None -> false)
  | _ -> false
  | exception Yojson.Json_error _ -> false

let classify_response ~status ~body =
  if status >= 200 && status < 300 then
    Accepted { already_live = already_live_of_body body }
  else if status = 409 then Paused_owner_conflict (response_detail ~status body)
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

(* The purge route takes the keeper in the body rather than the path, under the
   name the dashboard sends. *)
let purge_body keeper_name =
  Yojson.Safe.to_string (`Assoc [ ("agent_name", `String keeper_name) ])

let directive_body ~operator_operation_id action =
  let fields =
    match action with
    | "resume" ->
        [ ("action", `String "resume")
        ; ("operator_operation_id", `String operator_operation_id)
        ]
    | _ -> [ ("action", `String action) ]
  in
  Yojson.Safe.to_string (`Assoc fields)

let mint_operation_id ~keeper ~serial =
  Printf.sprintf "masc-tui-resume-%s-%d" keeper serial


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
  let ( let* ) = Result.bind in
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
           | Dashboard_keeper_purge _, _ -> Some (false, false)
           | _ -> None in
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
