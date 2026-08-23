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

(* Same split as the chat surface: telling an operator who already presented a
   credential to set one is wrong advice. From #29790. *)
let roster_failure_message ~credential_sent = function
  | Roster_unauthorized when credential_sent ->
      "live keeper status was refused: the operator token this masc-tui \
       presented was rejected — re-run masc login and restart masc-tui"
  | Roster_unauthorized ->
      "live keeper status and lifecycle actions need an operator token — run \
       masc login, or export MASC_TOKEN, and restart masc-tui"
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


let display_status reading =
  match reading.liveness with
  | Unobserved -> None
  | Absent ->
      (* The roster answered and left this keeper out, so no fiber is running
         it. Pause still shows through: an operator who paused a keeper and
         then stopped it should read "paused", not "offline", or the resume
         the boot needs looks unnecessary. *)
      if reading.paused then Some Status.Cp_paused
      else Some (Status.Cp_surface Status.Surface_offline)
  | Present runtime ->
      if reading.paused then Some Status.Cp_paused
      else Some (Status.Cp_surface runtime.Decode.kr_status)

let status_label reading =
  match display_status reading with
  | None -> "unread"
  | Some status -> Status.control_plane_status_to_string status

type action =
  | Pause
  | Resume
  | Boot
  | Shutdown
  | Wakeup

(* One key each, and the toggle key submits whichever of pause/resume/boot the
   reading offers. Every letter here is unused by the Keepers surface's other
   bindings (j/k move, Enter opens, l logs, c and m chat, r refresh, q quits). *)
let action_key = function
  | Pause -> "p"
  | Resume -> "p"
  | Boot -> "p"
  | Shutdown -> "s"
  | Wakeup -> "w"

let action_label = function
  | Pause -> "pause"
  | Resume -> "resume"
  | Boot -> "boot"
  | Shutdown -> "shutdown"
  | Wakeup -> "wake"

let action_gerund = function
  | Pause -> "pausing"
  | Resume -> "resuming"
  | Boot -> "booting"
  | Shutdown -> "shutting down"
  | Wakeup -> "waking"

(* Shutdown ends the fiber and latches a durable operator pause, so bringing
   the keeper back is a three-request sequence rather than an undo. The web
   dashboard puts a confirmation in front of it for the same reason
   (dashboard/src/components/keeper-action-panel.ts). Pause, resume, boot and
   wake each have a single-request inverse and submit on the first press. *)
let requires_confirmation = function
  | Shutdown -> true
  | Pause | Resume | Boot | Wakeup -> false

let available reading =
  match reading.liveness with
  | Unobserved -> []
  | Absent -> [ Boot ]
  | Present runtime ->
      if not runtime.Decode.kr_keepalive_running then [ Boot ]
      else if reading.paused then [ Resume; Wakeup; Shutdown ]
      else [ Pause; Wakeup; Shutdown ]

let primary reading =
  match available reading with
  | [] -> None
  | first :: _ -> Some first

type step =
  | Lifecycle of string
  | Directive of string

let plan = function
  | Pause -> [ Directive "pause" ]
  | Resume -> [ Directive "resume" ]
  | Wakeup -> [ Directive "wakeup" ]
  | Boot -> [ Lifecycle "boot" ]
  | Shutdown -> [ Lifecycle "shutdown" ]

let recovers_from_conflict = function
  | Boot -> Some [ Directive "resume"; Lifecycle "boot" ]
  | Pause | Resume | Shutdown | Wakeup -> None

type outcome =
  | Accepted of { already_live : bool }
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
