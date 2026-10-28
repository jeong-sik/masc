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
  | Keeper_sandbox_remote.Local_timeout ->
    "The local transport timed out before it received a trustworthy result. \
     The endpoint's power state and the command's effects are unknown; inspect \
     the endpoint and effects before deciding whether to run it again."
  | Keeper_sandbox_remote.Remote_timeout ->
    "The payload ran out of its time budget; the lane itself worked. Shorten the \
     command or raise timeout_sec. No operator action."
  | Keeper_sandbox_remote.Transport_failed ->
    "The lane could not read the shim's answer. The endpoint, authentication, \
     transport, or protocol may be unavailable; this does not establish that \
     the machine is powered off. The operator must inspect the endpoint. A \
     dispatched effect may have happened; inspect it before running it again."
  | Keeper_sandbox_remote.Shim_refused ->
    "The shim refused the request itself: a cwd outside its jail, a config it \
     will not read, or a box it cannot build. A path error is yours to fix; a \
     config or box error is the operator's."
  | Keeper_sandbox_remote.Trailer_disagreement ->
    "The transport's exit and the shim's trailer contradict each other. Give the \
     operator the detail; the effects are unknown and must be inspected before \
     another attempt."
;;

let probe_failed_action =
  "The endpoint did not answer a probe: it is unreachable, or its shim speaks a \
   protocol this server does not. Both are the operator's; nothing you run \
   changes them."
;;

(* RFC-0427 B-3. The lane answered, so the keeper's own work is fine; this
   tells it not to read a later transport failure as its own doing. *)
let outdated_shim_action =
  "The endpoint answers, but its shim came from a different release than this \
   server. The lane still runs: the two negotiate the protocol and tolerate one \
   release apart. Nothing you run changes it, and the operator repairs it by \
   reinstalling the shim from this server's release. The release shown is what \
   the endpoint answered at observed_at_unix; a shim replaced since is not \
   seen until the server asks again."
;;

let unreported_shim_release_action =
  "The endpoint answered, but its shim did not report a release. Its release \
   cannot be compared with this server's; a mismatch has not been established. \
   The lane still runs with the negotiated protocol. The operator can inspect \
   the shim's provenance and, if needed, reinstall it from this server's \
   release. This is the probe's observation at observed_at_unix."
;;

let json_of_report (r : Keeper_sandbox_remote.lane_report) : Yojson.Safe.t =
  let probe, probe_action =
    match r.probe with
    | Keeper_sandbox_remote.Probe_not_asked ->
      `Assoc [ "state", `String "not_asked" ], None
    | Keeper_sandbox_remote.Probe_answered { major; capabilities; release; observed_at; boot } ->
      ( `Assoc
          [ "state", `String "answered"
          ; "protocol_major", `Int (Exec_ssh_protocol.int_of_major major)
          ; "capabilities", `List (List.map (fun c -> `String c) capabilities)
          ; ( "shim_release"
            , match release with
              | Some release -> `String release
              | None -> `Null )
          ; "server_release", `String Build_version.current
          ; "observed_at_unix", `Float observed_at
          ; ( "kernel_boot"
            , `Assoc
                [ "id", (match boot.boot_id with Some id -> `String id | None -> `Null)
                ; "comparison", `String (match boot.change with
                    | Boot_unreported -> "unreported" | Boot_first -> "first_observation"
                    | Boot_unchanged -> "unchanged" | Boot_changed -> "changed")
                ; "last_changed_at_unix", (match boot.last_changed_at with
                    | Some at -> `Float at | None -> `Null)
                ; "comparison_scope", `String "same_endpoint_this_server_process"
                ] )
          ; "workspace_continuity", `String "unknown"
          ]
      , (match release with
         | Some release when String.equal release Build_version.current -> None
         | Some _ -> Some outdated_shim_action
         | None -> Some unreported_shim_release_action) )
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
  (* Guidance belongs to the newest observation, including a successful
     observation which clears an older failure. *)
  let operator_action =
    let probe_at = match r.probe with
      | Keeper_sandbox_remote.Probe_not_asked -> None
      | Probe_answered { observed_at; _ } -> Some observed_at
      | Probe_failed { at; _ } -> Some at in
    let dispatch_at = match r.last_dispatch with
      | None -> None
      | Some (Keeper_sandbox_remote.Payload_finished { at; _ }
             | Keeper_sandbox_remote.Dispatch_failed { at; _ }) -> Some at in
    let action = match dispatch_at, probe_at with
      | Some dispatch_at, Some probe_at when dispatch_at > probe_at -> dispatch_action
      | _, Some _ -> probe_action
      | Some _, None -> dispatch_action
      | None, None -> None in
    match action with Some action -> `String action | None -> `Null
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

let with_remote_report ~(meta : keeper_meta) = function
  | Ok report ->
    (match json_of_report report with
     | `Assoc fields -> with_profile ~meta fields
     | other -> other)
  | Error detail ->
    with_profile ~meta
      [ "lane", `Null
      ; "endpoint", `Null
      ; "probe", `Null
      ; "last_dispatch", `Null
      ; "unreachable", `String detail
      ; ( "operator_action"
        , `String
            "The lane endpoint cannot be named from its declarations. Correcting \
             the keeper's runtime or endpoint declaration is the operator's." )
      ]
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
  | Keeper_types_profile_sandbox.Remote_ssh ->
    Keeper_sandbox_ssh.resolve_endpoint
      ~base_path:config.base_path ~keeper_name:meta.name
    |> Result.map (fun endpoint ->
      Keeper_sandbox_ssh.openssh_configuration ~base_path:config.base_path ~endpoint ()
      |> Keeper_sandbox_remote.report_openssh
           ~scope:(Keeper_sandbox_remote.Keeper_dispatch meta.name)
           ~base_path:config.base_path)
    |> with_remote_report ~meta
  | Keeper_types_profile_sandbox.Micro_vm ->
    Keeper_turn_sandbox_runtime.microvm_attached_endpoint ~config ~meta ()
    |> Result.map Keeper_sandbox_remote.report
    |> with_remote_report ~meta
;;
