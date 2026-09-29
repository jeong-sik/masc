(* The Keeper side of the DOS controller hand-over.

   The tool surface cannot read Keeper or credential state (RFC-0194), so it
   asks this module whether and why a holder can no longer act.

   - Paused or Stopped: it cannot, and will not pass. Paused is let go on
     purpose: an operator's pause can outlast the game.
   - A Keeper whose stop has finished leaves the registry but keeps its
     meta. A known Keeper with no registry entry has stopped, and is let go.
   - Running, Failing, Draining, Restarting, Crashed (whose only way out is
     an automatic restart) and Offline (launch pending) are on their way
     back and keep the controller.
   - Where a request needs a token, an expired Player or Admin credential
     cannot act again, so its controller is freed on the next move.
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

let credential_departure ~(config : Workspace.config) ~now holder =
  match Auth.load_credential config.base_path holder with
  | Some ({ Masc_domain.agent_name; role = (Masc_domain.Admin | Masc_domain.Player); _ } as credential)
    when String.equal agent_name holder && Play_invite.expired ~now credential ->
    (match auth_mode ~config with
     | Enforced -> Some Tool_misc_dos_lane.Credential_expired
     | Self_declared | Unreadable _ -> None)
  | Some _ -> None
  | None ->
    (match auth_mode ~config with
     | Enforced ->
       if Play_invite.credential_exists ~base_path:config.base_path holder
       then None
       else Some Tool_misc_dos_lane.No_credential
     | Self_declared | Unreadable _ -> None)
;;

let holder_left ~(config : Workspace.config) ~now holder =
  match Keeper_registry.get_phase ~base_path:config.base_path holder with
  | Some (Paused | Stopped) -> Some Tool_misc_dos_lane.Keeper_stopped
  | Some (Running | Failing | Draining | Restarting | Crashed | Offline) -> None
  | None ->
    (match Keeper_meta_store.read_meta config holder with
     | Ok (Some _) -> Some Tool_misc_dos_lane.Keeper_stopped
     | Ok None -> credential_departure ~config ~now holder
     | Error _ -> None)
;;

let before_move ~config ~who =
  (* DET-OK: sample time once at the move boundary to classify invite expiry. *)
  let now = Unix.gettimeofday () in
  Tool_misc_dos_lane.free_left_controller ~holder_left:(holder_left ~config ~now) ~who
;;

type call_refusal =
  | Refused of string
  | Seats_unknown of string

(* A pass to a name nobody sits under leaves the machine held by no one who
   can move it, so it is refused before anything happens. The name is read
   the way the pass itself reads it. Where a name may be self-declared there
   is no list to check it against, and the pass goes on as before. *)
let pass_refusal ~config args =
  match auth_mode ~config with
  | Self_declared -> None
  | Unreadable detail -> Some (Seats_unknown ("cannot read the auth config: " ^ detail))
  | Enforced -> (
    match Tool_misc_dos_lane.pass_target args with
    | Error message -> Some (Refused message)
    | Ok None -> None
    | Ok (Some target) ->
      (match Play_seat.hand_to config ~now:(Time_compat.now ()) with
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

let before_call ~config ~who ~name ~args =
  match
    Option.map Tool_schemas_misc.dos_controller_need
      (Tool_schemas_misc.misc_operation_of_tool_name name)
  with
  | Some Tool_schemas_misc.Takes_controller ->
    before_move ~config ~who;
    Ok ()
  | Some Tool_schemas_misc.Hands_controller ->
    (match pass_refusal ~config args with
     | Some refusal -> Error refusal
     | None ->
       before_move ~config ~who;
       Ok ())
  | Some Tool_schemas_misc.No_controller | None -> Ok ()
;;
