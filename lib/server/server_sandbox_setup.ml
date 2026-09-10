module Sandbox = Sandbox_readiness
let ( let* ) = Result.bind
type error = Invalid_request | Configuration_unavailable | Configuration_changed
  | Lifecycle_busy | Existing_keeper | Prerequisite_required | Image_failed | Commit_unconfirmed
let error_message = function
  | Invalid_request -> "Choose a sandbox and one of its supported network modes."
  | Configuration_unavailable -> "Initialize or repair imp's declaration before preparing its sandbox."
  | Configuration_changed -> "imp settings changed. Refresh the sandbox choices and select again."
  | Lifecycle_busy -> "imp is changing lifecycle state. Wait for that operation, then retry."
  | Existing_keeper -> "Stop imp using its lifecycle controls before changing its sandbox. Its current settings were preserved."
  | Prerequisite_required -> "Prepare this sandbox service in the server terminal with masc setup, then retry."
  | Image_failed -> "The sandbox image could not be prepared. Check the service and download access, then retry."
  | Commit_unconfirmed -> "Sandbox settings could not be confirmed. Refresh the current settings before retrying."
let path base_path = Keeper_sandbox_config.keeper_toml_path ~base_path ~agent_name:"imp"
let read base_path =
  match Fs_compat.load_owned_regular_file ~ownership_root:base_path (path base_path) with
  | Ok (Some contents) -> Ok contents | _ -> Error Configuration_unavailable
let revision base_path contents =
  Digestif.SHA256.(to_hex (digest_string (Unix.realpath base_path ^ "\000" ^ contents)))
let inspect ~base_path =
  let before=read base_path in
  let catalog=Sandbox.inspect ~base_path:(Some base_path) in
  let after=read base_path in
  let revision=match before,after with
    | Ok a,Ok b when a=b -> `String (revision base_path a) | _ -> `Null in
  match catalog with `Assoc fields -> `Assoc (("selection_revision",revision)::fields) | other -> other
let request = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["backend";"network_mode";"revision"] ->
    (match List.assoc "backend" fields,List.assoc "network_mode" fields,List.assoc "revision" fields with
     | `String backend,`String network,`String revision ->
       (match Sandbox.backend_of_id backend,Keeper_types_profile_sandbox.network_mode_of_string network with
        | Some backend,Some network -> Ok (backend,network,revision)
        | _ -> Error Invalid_request)
     | _ -> Error Invalid_request)
  | _ -> Error Invalid_request
let guard ~base_path ~changed =
  if Option.is_some (Keeper_lifecycle_reservation.current ~base_path ~keeper_name:"imp") then Error Lifecycle_busy
  else match changed,Keeper_registry.get_with_health ~base_path "imp" with
    | false,_ | true,None -> Ok ()
    | true,Some (entry,Keeper_registry.Healthy) when not entry.conditions.fiber_alive
        && not entry.conditions.launch_pending
        && Keeper_registry_types.lane_has_exited entry
        && List.mem entry.phase [Keeper_state_machine.Offline;Stopped] -> Ok ()
    | true,Some _ -> Error Existing_keeper
let prepare_with ~base_path ~run ~image request_json =
  let* backend,network,expected=request request_json in
  let* original=read base_path in
  let* ()=if expected=revision base_path original then Ok () else Error Configuration_changed in
  let host=Sandbox.detect_host ~run in
  let* selection=Sandbox.selection_of_contents ~host ~path:(path base_path) ~contents:original
    ~profile:(Some (Sandbox.profile backend)) ~microvm_backend:(Sandbox.microvm_backend backend)
    ~network_mode:(Some network) |> Result.map_error (fun _ -> Invalid_request) in
  let* staged=Sandbox.stage_contents ~path:(path base_path) ~contents:original selection
    |> Result.map_error (fun _ -> Configuration_unavailable) in
  let changed=original<>staged in
  let* ()=Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:"imp"
    (fun () -> guard ~base_path ~changed) in
  let readiness=Sandbox.probe ~host ~run
    ~require_rootless:(Env_config_sandbox.Hardening.require_rootless ())
    ~require_userns:(Env_config_sandbox.Hardening.require_userns ()) backend in
  let* ()=match readiness.state,backend with
    | Sandbox.Service_ready,(Docker|Apple_container|Nerdctl_kata) -> Ok ()
    | _ -> Error Prerequisite_required in
  let* ()=image backend in
  let guard_failure=ref None in
  let with_publication publish =
    Keeper_lifecycle_reservation.with_key_lock ~base_path ~keeper_name:"imp" (fun () ->
      match guard ~base_path ~changed with
      | Error error -> guard_failure:=Some error; Error (error_message error)
      | Ok () -> publish ()) in
  let* ()=Sandbox.commit_staged_with_publication ~with_publication ~path:(path base_path) ~original ~staged
    |> Result.map_error (fun _ -> Option.value !guard_failure ~default:Commit_unconfirmed) in
  Ok (`Assoc ["schema",`String "masc.sandbox_preparation.v1";
    "configuration_saved",`Bool true;"image_prepared",`Bool true;
    "selection_changed",`Bool changed;"backend",`String (Sandbox.backend_id backend);
    "network_mode",`String (Keeper_types_profile_sandbox.network_mode_to_string network);
    "model_verification",`String "not_run";"guest_verification",`String "not_run"])
let prepare ~binary ~base_path request =
  let image backend =
    let args=[binary;"sandbox-image"] @ (match Sandbox.microvm_backend backend with
      | None -> [] | Some runtime -> ["--runtime";Keeper_microvm_backend.to_string runtime]) in
    match Process_eio.run_argv_with_status_split_or_refusal args with
    | Ok (Unix.WEXITED 0,_,_) -> Ok () | _ -> Error Image_failed in
  prepare_with ~base_path ~run:Sandbox.system_runner ~image request
module For_testing = struct
  let prepare = prepare_with
  let revision = revision
end
