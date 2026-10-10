(** Workspace authority for machine controller liveness and handoff.
    No emulator state is read or mutated here. Keep the credential transaction
    through the controller effect; publish events only after releasing it. *)

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
        | Enforced -> Some Machine_controller_contract.Credential_expired
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
        | Ok false -> Some Machine_controller_contract.No_credential
        | Ok true -> None
        | Error error ->
          Log.Auth.warn "DOS controller departure cannot check credential file for %s: %s"
            holder (Masc_domain.masc_error_to_string error);
          None)
     | Self_declared | Unreadable _ -> None)
;;

let holder_left ~transaction ~(config : Workspace.config) ~now holder =
  match Keeper_registry.get_phase ~base_path:config.base_path holder with
  | Some (Paused | Stopped) -> Some Machine_controller_contract.Keeper_stopped
  | Some (Running | Failing | Draining | Restarting | Crashed | Offline) -> None
  | None ->
    (match Keeper_meta_store.read_meta config holder with
     | Ok (Some _) -> Some Machine_controller_contract.Keeper_stopped
     | Ok None -> credential_departure ~transaction ~config ~now holder
     | Error _ -> None)
;;

type call_refusal =
  | Refused of string
  | Seats_unknown of string

(* A pass to a name nobody sits under leaves the machine held by no one who
   can move it, so it is refused before anything happens. The caller supplies
   the target parsed by the same contract as the worker. Where a name may be
   self-declared there is no list to check it against. *)
let pass_refusal ~transaction ~config ~target =
  match auth_mode ~config with
  | Self_declared -> None
  | Unreadable detail -> Some (Seats_unknown ("cannot read the auth config: " ^ detail))
  | Enforced -> (
    match target with
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
