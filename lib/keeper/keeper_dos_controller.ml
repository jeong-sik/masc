(* The Keeper side of the DOS controller hand-over.

   The tool surface cannot read Keeper or credential state (RFC-0194), so it
   asks this module whether and why a holder can no longer act.

   - Paused or Stopped: it cannot, and will not pass. Paused is let go on
     purpose: an operator's pause can outlast the game.
   - A Keeper whose stop has finished leaves the registry but keeps its
     meta. A known Keeper with no registry entry has stopped, and is let go.
     A Keeper removed for good keeps neither, so its shutdown lets the
     controller go ([release_retired]).
   - Running, Failing, Draining, Restarting, Crashed (whose only way out is
     an automatic restart) and Offline (launch pending) are on their way
     back and keep the controller.
   - Where a request needs a token, a persisted credential that expired
     cannot authenticate, so its controller is freed on the next move.
     Workers can take a free controller directly, despite not being handoff
     targets, and have the same expiry rule.
   - A name with no meta is not a Keeper. Where every request must carry a
     credential (auth on, token required) nothing else can move the machine,
     so a name whose credential file is gone (a revoked invite) has left
     (RFC play-link-for-the-shared-machine §2.8). A file that is there but
     cannot be read tells nothing, like a meta that cannot be read.
   - Where a request needs no token a name may be self-declared, and a meta
     that cannot be read tells nothing. Both keep the controller: nothing
     here can say whether they are still playing. *)

(* [Enforced]: every request carries a credential, so every name that can
   move the machine is a Keeper's or a credential's. [Self_declared]: a name
   may be anyone's, and no list says who sits at the machine. The same
   condition gates issuing an invite (RFC play-link-for-the-shared-machine
   §2.4). [Unreadable]: the auth config could not be read, so neither can be
   said. *)
type auth_mode =
  | Enforced
  | Self_declared
  | Unreadable of string

let auth_mode ~(config : Workspace.config) =
  match Auth.load_auth_config config.base_path with
  | auth -> if auth.Masc_domain.enabled && auth.require_token then Enforced else Self_declared
  | exception Auth.Auth_config_error { file; reason } -> Unreadable (file ^ ": " ^ reason)
;;

let credential_departure ~transaction ~(config : Workspace.config) ~now holder =
  let credential =
    try Ok (Auth.load_credential config.base_path holder) with
    | (Sys_error _ | Unix.Unix_error _ | Eio.Io _) as exn ->
      Error (Printexc.to_string exn)
  in
  match credential with
  | Error detail ->
    Log.Auth.warn "DOS controller departure cannot read credential for %s: %s" holder detail;
    None
  | Ok (Some ({ Masc_domain.agent_name; _ } as credential))
    when String.equal agent_name holder ->
    (match Play_invite.expired ~now credential with
     | Ok true ->
       (match auth_mode ~config with
        | Enforced -> Some Tool_misc_dos_lane.Credential_expired
        | Self_declared | Unreadable _ -> None)
     | Ok false -> None
     | Error (Masc_domain.Credential_expiry.Invalid_timestamp stamp) ->
       Log.Auth.warn "DOS controller cannot read credential expiry for %s: %S" holder stamp;
       None)
  | Ok (Some _) -> None
  | Ok None ->
    (match auth_mode ~config with
     | Enforced ->
       (match Auth.credential_exists_in_transaction transaction holder with
        | Ok false -> Some Tool_misc_dos_lane.No_credential
        | Ok true -> None
        | Error error ->
          Log.Auth.warn "DOS controller departure cannot check credential file for %s: %s"
            holder (Masc_domain.masc_error_to_string error);
          None)
     | Self_declared | Unreadable _ -> None)
;;

let holder_left ~transaction ~(config : Workspace.config) ~now holder =
  match Keeper_registry.get_phase ~base_path:config.base_path holder with
  | Some (Paused | Stopped) -> Some Tool_misc_dos_lane.Keeper_stopped
  | Some (Running | Failing | Draining | Restarting | Crashed | Offline) -> None
  | None ->
    (match Keeper_meta_store.read_meta config holder with
     | Ok (Some _) -> Some Tool_misc_dos_lane.Keeper_stopped
     | Ok None -> credential_departure ~transaction ~config ~now holder
     | Error _ -> None)
;;

let recover_in_transaction ?announce ~transaction ~config ~who () =
  let now = Time_compat.now () in
  Tool_misc_dos_lane.free_left_controller ?announce ~holder_left:(holder_left ~transaction ~config ~now) ~who ()
;;

let before_move ~config ~who =
  let released = Tool_misc_dos_lane.with_deferred_announcements (fun announce ->
    Auth.with_credential_transaction config.Workspace.base_path (fun transaction ->
      recover_in_transaction ~announce ~transaction ~config ~who ()))
  in
  (* Board publication must never run while credential writers are excluded. *)
  Tool_misc_dos_lane.after_announcing released
;;

let release_retired ~keeper_name ~by =
  match Tool_misc_dos_lane.release_retired_keeper ~holder:keeper_name ~by with
  | Ok (true | false) | Error Dos_lane.No_machine -> Ok ()
  | Error
      (( Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
       | Dos_lane.Guest_fault _ | Dos_lane.Unsaveable _ | Dos_lane.Checkpoint_refused _
       | Dos_lane.Other_program _ ) as err) ->
    Error (Dos_lane.error_to_string err)
;;

type call_refusal =
  | Refused of string
  | Seats_unknown of string

(* A pass to a name nobody sits under leaves the machine held by no one who
   can move it, so it is refused before anything happens. The name is read
   the way the pass itself reads it. Where a name may be self-declared there
   is no list to check it against, and the pass goes on as before. *)
let pass_refusal ~transaction ~config args =
  match auth_mode ~config with
  | Self_declared -> None
  | Unreadable detail -> Some (Seats_unknown ("cannot read the auth config: " ^ detail))
  | Enforced -> (
    match Tool_misc_dos_lane.pass_target args with
    | Error message -> Some (Refused message)
    | Ok None -> None
    | Ok (Some target) ->
      (match Play_seat.hand_to_in_transaction ~transaction config ~now:(Time_compat.now ()) with
       | Error detail -> Some (Seats_unknown ("cannot tell who sits at the DOS machine: " ^ detail))
       | Ok names when List.mem target names -> None
       | Ok _ ->
         Some
           (Refused
              (Printf.sprintf
                 "%s is not at the DOS machine: pass to a Keeper, an operator or an invited player"
                 target))))
;;

let refusal_result ~tool_name = function
  | Refused message ->
    Tool_misc_dos_lane.reject ~tool_name ~start_time:(Tool_timing.start ()) message
  | Seats_unknown message ->
    Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure
      ~start_time:(Tool_timing.start ()) message
;;

let execute ~config ~who ~name ~args ~run =
  let recover_error error =
    Seats_unknown ("cannot recover the DOS controller: " ^ Masc_domain.masc_error_to_string error) in
  let operation = Tool_schemas_misc.misc_operation_of_tool_name name in
  match operation with
  | Some Tool_schemas_misc.Misc_dos_pass ->
    let result = Tool_misc_dos_lane.with_deferred_announcements (fun announce ->
      Auth.with_credential_transaction config.Workspace.base_path (fun transaction ->
      match pass_refusal ~transaction ~config args with
      | Some refusal -> Error refusal
      | None ->
        recover_in_transaction ~announce ~transaction ~config ~who ();
        Ok (Some (Tool_misc_dos_lane.pass_without_announcing ~announce ~tool_name:name
          ~start_time:(Tool_timing.start ()) ~base_path:config.base_path ~agent_name:who args))))
      |> Result.map_error recover_error |> Result.join in
    Tool_misc_dos_lane.after_announcing result
  | Some _ | None ->
    let recovered = match Option.map Tool_schemas_misc.dos_controller_need operation with
      | Some Tool_schemas_misc.Takes_controller -> before_move ~config ~who |> Result.map_error recover_error
      | Some Tool_schemas_misc.Hands_controller -> Error (Refused "unsupported DOS handoff operation")
      | Some Tool_schemas_misc.No_controller | None -> Ok () in
    Result.map (fun () -> run ()) recovered
;;
