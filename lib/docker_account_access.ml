type state = Group_missing | Membership_required | Session_refresh_required | Group_active
type observation = { account : string; uid : int; state : state }
type error = Unsupported_host | Unsupported_distribution | Invalid_account
  | Account_read_failed | Grant_failed | Invalid_resume | Session_not_active
  | Service_unavailable of Sandbox_readiness.entry
let ( let* ) = Result.bind
let grant_label = "Allow this account to use the local Docker engine"
let grant_detail = "Add your current Unix account to the Docker group. This grants root-level control through Docker. Continue setup in a new group session afterward; existing terminals are unchanged."
type snapshot = { uid:int; effective_uid:int; account:string; account_primary_gid:int;
  primary_gid:int; supplementary_gids:int list; docker_group:(int * string list) option }
let snapshot () =
  try
    let uid = Unix.getuid () in
    let account = Unix.getpwuid uid in
    let docker_group = try let group = Unix.getgrnam "docker" in Some (group.gr_gid, Array.to_list group.gr_mem)
      with Not_found -> None in
    Ok {uid; effective_uid=Unix.geteuid (); account=account.pw_name; account_primary_gid=account.pw_gid;
        primary_gid=Unix.getegid (); supplementary_gids=Array.to_list (Unix.getgroups ()); docker_group}
  with Not_found | Unix.Unix_error _ -> Error Account_read_failed
let inspect_snapshot ~host (snapshot:snapshot) =
  match host with
  | Sandbox_readiness.Macos _ | Unsupported -> Error Unsupported_host
  | Linux _ ->
    if snapshot.uid <= 0 || snapshot.effective_uid <> snapshot.uid || snapshot.account=""
    then Error Invalid_account else
    let state = match snapshot.docker_group with
      | None -> Group_missing
      | Some (gid, _) when snapshot.primary_gid=gid || List.mem gid snapshot.supplementary_gids -> Group_active
      | Some (gid, members) when snapshot.account_primary_gid=gid || List.mem snapshot.account members -> Session_refresh_required
      | Some _ -> Membership_required in
    Ok {account=snapshot.account;uid=snapshot.uid;state}
let inspect ~host = let* value = snapshot () in inspect_snapshot ~host value
let to_json (observation:observation) = `Assoc ["schema",`String "masc.docker_account_access.v1";
  "account",`String observation.account;"uid",`Int observation.uid;
  "grant_label",`String grant_label;"grant_detail",`String grant_detail;
  "status",`String (match observation.state with Group_missing -> "docker_group_missing"
    | Membership_required -> "membership_required" | Session_refresh_required -> "reauthentication_required"
    | Group_active -> "group_active");"service_readiness",`String "not_checked"]
let grant_with ~host ~distribution ~read ~run =
  let* before = read () in
  let* observation = inspect_snapshot ~host before in
  match distribution with
  | Sandbox_prerequisites.Other -> Error Unsupported_distribution
  | Debian | Ubuntu ->
    match observation.state with
    | Group_missing -> Error Grant_failed
    | Group_active | Session_refresh_required -> Ok observation
    | Membership_required ->
      let* () = run ["/usr/bin/sudo";"/usr/sbin/usermod";"-a";"-G";"docker";"--";observation.account]
        |> Result.map_error (fun () -> Grant_failed) in
      let* after = read () in
      let* updated = inspect_snapshot ~host after in
      if updated.uid <> observation.uid || updated.account <> observation.account then Error Invalid_account else
      match updated.state with
      | Group_active | Session_refresh_required -> Ok updated
      | Group_missing | Membership_required -> Error Grant_failed
let grant ~host ~distribution ~run = grant_with ~host ~distribution ~read:snapshot ~run
let session_argv ~executable_path ~base_path ~port ~uid =
  if uid <= 0 || port <= 0 || port > 65535 then Error Invalid_resume else
  try
    let executable_path = Unix.realpath executable_path in
    let base_path = Unix.realpath base_path in
    let argv = [executable_path;"docker-session-resume";"--base-path";base_path;
      "--port";string_of_int port;"--expected-uid";string_of_int uid] in
    (* sg(1) requires a /bin/sh command. Every argument is shell-quoted, including
       operator workspace paths. There is no user-supplied shell program.
       https://man7.org/linux/man-pages/man1/sg.1.html *)
    Ok ["/usr/bin/sg";"docker";"-c";"exec " ^ String.concat " " (List.map Filename.quote argv)]
  with Unix.Unix_error _ -> Error Invalid_resume
type handoff = Already_active | Child_finished | Reauthentication_pending
let handoff ~host ~executable_path ~base_path ~port ~run =
  let* observed = inspect ~host in
  match observed.state with
  | Group_missing | Membership_required -> Error Session_not_active
  | Group_active -> Ok Already_active
  | Session_refresh_required ->
    let* argv = session_argv ~executable_path ~base_path ~port ~uid:observed.uid in
    Ok (match run argv with Ok () -> Child_finished | Error () -> Reauthentication_pending)
let validate_snapshot ~host ~expected_uid snapshot ~probe_run ~require_rootless ~require_userns =
  let* observed = inspect_snapshot ~host snapshot in
  if observed.uid <> expected_uid then Error Invalid_account else
  match observed.state with
  | Group_missing | Membership_required | Session_refresh_required -> Error Session_not_active
  | Group_active ->
    let service = Sandbox_readiness.probe ~host ~run:probe_run ~require_rootless ~require_userns Docker in
    match service.state with Service_ready -> Ok service | _ -> Error (Service_unavailable service)
let validate_session ~host ~expected_uid ~probe_run ~require_rootless ~require_userns =
  let* value = snapshot () in
  validate_snapshot ~host ~expected_uid value ~probe_run ~require_rootless ~require_userns
module For_testing = struct
  type nonrec snapshot = snapshot = { uid:int; effective_uid:int; account:string; account_primary_gid:int;
    primary_gid:int; supplementary_gids:int list; docker_group:(int * string list) option }
  let inspect = inspect_snapshot
  let grant = grant_with
  let session_argv = session_argv
  let validate_session = validate_snapshot
end
let error_message = function
  | Unsupported_host -> "Docker group sessions are a Linux setup action."
  | Unsupported_distribution -> "This distribution needs its own account-management procedure; existing membership was not changed."
  | Invalid_account -> "Continue setup as your ordinary Unix account, not as root or another user."
  | Account_read_failed -> "The current account or Docker group could not be read."
  | Grant_failed -> "Docker group membership was not confirmed. Install the local Docker engine and check the administrator step, then retry."
  | Invalid_resume -> "The saved workspace or installed executable could not be resolved for session continuation."
  | Session_not_active -> "Allow the selected account's Docker access first, then continue in a new group session."
  | Service_unavailable entry -> "The new user session cannot use Docker yet: " ^ Sandbox_readiness.state_message entry.state
