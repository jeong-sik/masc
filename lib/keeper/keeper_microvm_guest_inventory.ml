module Backend = Keeper_microvm_backend
module Json = Keeper_microvm_inventory_json

type presence = Json.presence = Present | Absent

type invalid_inventory = Json.invalid_inventory =
  | Invalid_json
  | Expected_array
  | Expected_row_object
  | Duplicate_row_key
  | Invalid_configuration
  | Duplicate_configuration_key
  | Missing_identity
  | Invalid_identity
  | Conflicting_identity
  | Duplicate_guest_name

type unavailable_output = Keeper_microvm_cli_output.unavailable_output =
  | Capture_directory_unavailable
  | Capture_incomplete
  | Capture_failed
  | Capture_limit_exceeded
  | Capture_unreadable
  | Capture_permissions_invalid
  | Capture_length_mismatch
  | Capture_cleanup_failed

type error =
  | Unsupported of Backend.t
  | Invalid_guest_name
  | Command_failed of Unix.process_status
  | Invalid_inventory of invalid_inventory
  | Output_unavailable of unavailable_output

type scoping_labels = Json.scoping_labels =
  { component : string
  ; base_path_hash : string
  ; kind : string
  ; keeper : string
  }

type row = Json.row = { name : string; scoping_labels : scoping_labels option }
type t = Json.t

let inventory_of_apple_json raw =
  Json.of_apple_json raw |> Result.map_error (fun reason -> Invalid_inventory reason)
;;

let rows = Json.rows

let presence ~guest_name inventory =
  Json.presence ~guest_name inventory
  |> Result.map_error (fun Json.Invalid_guest_name -> Invalid_guest_name)
;;

let presence_of_apple_json ~guest_name raw =
  if String.trim guest_name = "" then Error Invalid_guest_name
  else Result.bind (inventory_of_apple_json raw) (presence ~guest_name)
;;

let read_apple ~timeout_sec =
  match Keeper_microvm_cli_output.read ~timeout_sec
      ~argv:(Keeper_sandbox_microvm.guest_listing_argv_for Backend.Apple_container) with
  | Ok (Unix.WEXITED 0, stdout) -> inventory_of_apple_json stdout
  | Ok (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), _stdout) ->
    Error (Command_failed status)
  | Error {reason; status} ->
    match reason with
    | Capture_cleanup_failed -> Error (Output_unavailable Capture_cleanup_failed)
    | (Capture_directory_unavailable | Capture_incomplete | Capture_failed | Capture_limit_exceeded
      | Capture_unreadable | Capture_permissions_invalid | Capture_length_mismatch) as reason ->
      match status with
      | None | Some (Unix.WEXITED 0) -> Error (Output_unavailable reason)
      | Some ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status) ->
        Error (Command_failed status)
;;

let read ~backend ~guest_name ~timeout_sec =
  match (backend : Backend.t) with
  | Backend.Microsandbox | Backend.Nerdctl_kata -> Error (Unsupported backend)
  | Backend.Apple_container ->
    if String.trim guest_name = "" then Error Invalid_guest_name
    else Result.bind (read_apple ~timeout_sec) (presence ~guest_name)
;;

let error_message = function
  | Unsupported backend ->
    Printf.sprintf "full guest inventory is unsupported for %s" (Backend.to_string backend)
  | Invalid_guest_name -> "full guest inventory requires a nonempty guest name"
  | Output_unavailable reason ->
    "full guest inventory unavailable: " ^ Keeper_microvm_cli_output.unavailable_message reason
  | Command_failed status ->
    let status = match status with
      | Unix.WEXITED code -> Printf.sprintf "exit %d" code
      | Unix.WSIGNALED signal -> Printf.sprintf "signal %d" signal
      | Unix.WSTOPPED signal -> Printf.sprintf "stopped %d" signal in
    "full guest inventory command failed: " ^ status
  | Invalid_inventory reason ->
    let reason = Json.invalid_inventory_message reason in
    "full guest inventory could not be read: " ^ reason
;;

module For_testing = struct
  let inventory_of_apple_json = inventory_of_apple_json
  let presence_of_apple_json = presence_of_apple_json
end
