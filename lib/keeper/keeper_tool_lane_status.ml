(* keeper_lane_status (RFC-0427 D-1): the execution lane's own account of
   itself, read from what this process already knows. Nothing here probes,
   dispatches, or stores; the report is [Keeper_sandbox_remote.report], and
   the operator action is an exhaustive match on its variants. *)

open Keeper_meta_contract

let failure_label = function
  | Keeper_sandbox_remote.Local_timeout -> "local_timeout"
  | Keeper_sandbox_remote.Remote_timeout -> "remote_timeout"
  | Keeper_sandbox_remote.Transport_failed -> "transport_failed"
  | Keeper_sandbox_remote.Shim_refused -> "shim_refused"
  | Keeper_sandbox_remote.Trailer_disagreement -> "trailer_disagreement"
;;

(* Who acts, per class. The text is guidance for the keeper reading it; the
   decision of which text is the variant's, never the detail string's. *)
let action_of_failure = function
  | Keeper_sandbox_remote.Local_timeout | Keeper_sandbox_remote.Remote_timeout ->
    "The payload ran out of its time budget; the lane itself worked. Shorten the \
     command or raise timeout_sec. No operator action."
  | Keeper_sandbox_remote.Transport_failed ->
    "The lane could not read the shim's answer. If the detail names \
     remote_ssh_version_error, the server and the endpoint's shim disagree on the \
     protocol and an operator has to replace the shim. Otherwise the endpoint or \
     its transport is down, also the operator's. Retrying changes neither."
  | Keeper_sandbox_remote.Shim_refused ->
    "The shim refused the request itself: a cwd outside its jail, a config it \
     will not read, or a box it cannot build. A path error is yours to fix; a \
     config or box error is the operator's."
  | Keeper_sandbox_remote.Trailer_disagreement ->
    "The transport's exit and the shim's trailer contradict each other. Give the \
     operator the detail; do not retry in a loop."
;;

let probe_failed_action =
  "The endpoint did not answer a probe: it is unreachable, or its shim speaks a \
   protocol this server does not. Both are the operator's; nothing you run \
   changes them."
;;

let json_of_report (r : Keeper_sandbox_remote.lane_report) : Yojson.Safe.t =
  let probe, probe_action =
    match r.probe with
    | Keeper_sandbox_remote.Probe_not_asked ->
      `Assoc [ "state", `String "not_asked" ], None
    | Keeper_sandbox_remote.Probe_answered { major; capabilities } ->
      ( `Assoc
          [ "state", `String "answered"
          ; "protocol_major", `Int (Exec_ssh_protocol.int_of_major major)
          ; "capabilities", `List (List.map (fun c -> `String c) capabilities)
          ]
      , None )
    | Keeper_sandbox_remote.Probe_failed { at; detail } ->
      ( `Assoc
          [ "state", `String "failed"; "at_unix", `Float at; "detail", `String detail ]
      , Some probe_failed_action )
  in
  let last_dispatch, dispatch_action =
    match r.last_dispatch with
    | None -> `Null, None
    | Some (Keeper_sandbox_remote.Payload_finished { at; status }) ->
      ( `Assoc
          [ "outcome", `String "payload_finished"
          ; "at_unix", `Float at
          ; "status", `String (Keeper_sandbox_exec_failure.status_label status)
          ]
      , None )
    | Some (Keeper_sandbox_remote.Dispatch_failed { at; failure; detail }) ->
      ( `Assoc
          [ "outcome", `String "lane_failed"
          ; "at_unix", `Float at
          ; "failure", `String (failure_label failure)
          ; "detail", `String detail
          ]
      , Some (action_of_failure failure) )
  in
  (* The dispatch is the fresher fact when both exist: a probe that failed
     before a dispatch that finished is history. *)
  let operator_action =
    match dispatch_action, probe_action with
    | Some action, _ | None, Some action -> `String action
    | None, None -> `Null
  in
  `Assoc
    [ "lane", `String r.lane
    ; "endpoint", `String r.endpoint
    ; "probe", probe
    ; "last_dispatch", last_dispatch
    ; "operator_action", operator_action
    ]
;;

let with_profile ~(meta : keeper_meta) fields =
  `Assoc
    (( "profile"
     , `String
         (Keeper_types_profile_sandbox.sandbox_profile_to_string meta.sandbox_profile) )
     :: fields)
;;

let handle ~(config : Workspace.config) ~(meta : keeper_meta) ~args:_ : Yojson.Safe.t =
  match meta.sandbox_profile with
  | Keeper_types_profile_sandbox.Docker ->
    with_profile ~meta
      [ "lane", `Null
      ; "endpoint", `Null
      ; "probe", `Null
      ; "last_dispatch", `Null
      ; "operator_action", `Null
      ; ( "note"
        , `String
            "a docker keeper's tree is a shared mount on this host: there is no shim \
             and no remote lane, so an Execute failure is the container's or the \
             payload's" )
      ]
  | Keeper_types_profile_sandbox.Micro_vm | Keeper_types_profile_sandbox.Remote_ssh ->
    (match Keeper_sandbox_remote_lane.attached_guest_endpoint ~config ~meta () with
     | Ok endpoint ->
       (match json_of_report (Keeper_sandbox_remote.report endpoint) with
        | `Assoc fields -> with_profile ~meta fields
        | other -> other)
     | Error detail ->
       (* No endpoint value at all: the guest is not running, or the endpoint
          is not declared. That is itself the lane's state. *)
       with_profile ~meta
         [ "lane", `Null
         ; "endpoint", `Null
         ; "probe", `Null
         ; "last_dispatch", `Null
         ; "unreachable", `String detail
         ; ( "operator_action"
           , `String
               "The lane has no endpoint to ask right now: the guest is down or the \
                endpoint is undeclared. Starting a guest or declaring an endpoint is \
                the operator's; your turn cannot do either." )
         ])
;;
