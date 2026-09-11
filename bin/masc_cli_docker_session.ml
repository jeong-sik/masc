module Account = Masc.Docker_account_access
module Sandbox = Masc.Sandbox_readiness
module Prerequisites = Masc.Sandbox_prerequisites

type action = Grant | Handoff
let action_id = function Grant -> "grant" | Handoff -> "handoff"
let action_of_id = function "grant" -> Some Grant | "handoff" -> Some Handoff | _ -> None
let host () = Sandbox.detect_host ~run:Sandbox.system_runner
let distribution () =
  try In_channel.with_open_text "/etc/os-release" In_channel.input_all |> Prerequisites.distribution_of_os_release
  with Sys_error _ -> Prerequisites.Other
let actions distribution (observed:Account.observation) =
  match observed.state, distribution with
  | Account.Membership_required, (Prerequisites.Debian | Ubuntu) -> [Grant]
  | Account.Session_refresh_required, _ -> [Handoff]
  | _ -> []
let action_json action =
  let label,detail,admin = match action with
    | Grant -> "Allow this account to use Docker", Account.grant_detail, true
    | Handoff -> "Continue saved setup in a Docker group session",
      "Open a new group session as this same account. Your saved model choices and workspace are kept; Docker access is checked again before sandbox setup.", false in
  `Assoc ["id",`String (action_id action);"label",`String label;"detail",`String detail;
    "requires_admin",`Bool admin;"source_url",`String "https://docs.docker.com/engine/install/linux-postinstall/"]
let print value = print_endline (Yojson.Safe.to_string value)
type outcome = Failed | Recheck_required | Session_finished | Reauthentication_required
let outcome state reason =
  let status = match state with Failed -> "failed" | Recheck_required -> "recheck_required"
    | Session_finished -> "session_finished" | Reauthentication_required -> "reauthentication_required" in
  print (`Assoc (["schema",`String "masc.docker_account_action_result.v1";
    "status",`String status;"readiness",`String "not_checked"]
    @ match reason with None -> [] | Some reason -> ["reason",`String reason]))
let fail error = outcome Failed (Some (Account.error_message error)); 1
let run ~action ~base_path ~port =
  let host = host () in
  let observed = Account.inspect ~host in
  let available = match observed with Ok observed -> actions (distribution ()) observed | Error _ -> [] in
  match action with
  | None ->
    print (`Assoc ["schema",`String "masc.docker_account_actions.v1";
      "observation",(match observed with Ok value -> Account.to_json value | Error _ -> `Null);
      "actions",`List (List.map action_json available)]); 0
  | Some requested ->
    match action_of_id requested with
    | None -> fail Account.Invalid_resume
    | Some action when not (List.mem action available) ->
      (match observed with Error error -> fail error | Ok _ -> fail Account.Session_not_active)
    | Some Grant ->
      (match Account.grant ~host ~distribution:(distribution ()) ~run:Masc_cli_prerequisites.run_terminal with
       | Error error -> fail error
       | Ok _ -> outcome Recheck_required None; 0)
    | Some Handoff ->
      match base_path with
      | None -> fail Account.Invalid_resume
      | Some base_path ->
        (match Account.handoff ~host ~executable_path:Sys.executable_name ~base_path ~port
          ~run:Masc_cli_prerequisites.run_terminal with
         | Error error -> fail error
         | Ok Account.Already_active -> outcome Recheck_required None; 0
         | Ok Child_finished -> outcome Session_finished None; 0
         | Ok Reauthentication_pending -> outcome Reauthentication_required
             (Some "The new session did not complete. Your saved model choices remain; retry the group session or sign in again."); 0)
let resume ~base_path ~port ~expected_uid =
  if port <= 0 || port > 65535 then (prerr_endline (Account.error_message Account.Invalid_resume); 1)
  else match Account.validate_session ~host:(host ()) ~expected_uid
    ~probe_run:Sandbox.system_runner
    ~require_rootless:(Env_config_sandbox.Hardening.require_rootless ())
    ~require_userns:(Env_config_sandbox.Hardening.require_userns ()) with
  | Error error -> prerr_endline (Account.error_message error); 1
  | Ok _ -> Masc_cli_onboarding.run ~base_path:(Some base_path) ~port ~resume:false ~sandbox_step:true
