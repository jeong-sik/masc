module Backend = Keeper_microvm_backend
module Names = Set.Make (String)

type presence = Present | Absent

type invalid_inventory =
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

let invalid error = Error (Invalid_inventory error)

let unique_keys error fields =
  let rec loop seen = function
    | [] -> Ok ()
    | (key, _) :: rest ->
      if Names.mem key seen then invalid error
      else loop (Names.add key seen) rest
  in
  loop Names.empty fields
;;

let optional_identity fields =
  match List.assoc_opt "id" fields with
  | None -> Ok None
  | Some (`String name) when String.trim name <> "" -> Ok (Some name)
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) ->
    invalid Invalid_identity
;;

let configuration_identity fields =
  let ( let* ) = Result.bind in
  match List.assoc_opt "configuration" fields with
  | None -> Ok None
  | Some (`Assoc configuration) ->
    let* () = unique_keys Duplicate_configuration_key configuration in
    optional_identity configuration
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
    invalid Invalid_configuration
;;

let row_identity = function
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () = unique_keys Duplicate_row_key fields in
    let* top = optional_identity fields in
    let* nested = configuration_identity fields in
    (match top, nested with
     | None, None -> invalid Missing_identity
     | Some name, None | None, Some name -> Ok name
     | Some top, Some nested ->
       if String.equal top nested then Ok top else invalid Conflicting_identity)
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    invalid Expected_row_object
;;

type scoping_labels =
  { component : string
  ; base_path_hash : string
  ; kind : string
  ; keeper : string
  }

type row = { name : string; scoping_labels : scoping_labels option }
type t = { names : Names.t; entries : row list }

let label_pairs = function
  | `Assoc fields ->
    let rec decode seen acc = function
      | [] -> Some (List.sort compare acc)
      | (key, `String value) :: rest ->
        if Names.mem key seen then None
        else decode (Names.add key seen) ((key, value) :: acc) rest
      | (_, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)) :: _ -> None
    in
    decode Names.empty [] fields
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None
;;

let scoping_labels fields =
  let nested = match List.assoc_opt "configuration" fields with
    | Some (`Assoc fields) -> List.assoc_opt "labels" fields
    | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) | None -> None in
  let pairs = match List.assoc_opt "labels" fields, nested with
    | None, None -> None
    | Some labels, None | None, Some labels -> label_pairs labels
    | Some top, Some nested ->
      (match label_pairs top, label_pairs nested with
       | Some top, Some nested when top = nested -> Some top
       | Some _, Some _ | Some _, None | None, Some _ | None, None -> None) in
  let ( let* ) = Option.bind in
  let* pairs = pairs in
  let nonempty key = match List.assoc_opt key pairs with
    | Some value when String.trim value <> "" -> Some value
    | Some _ | None -> None in
  let module Labels = Keeper_sandbox_runtime_setup in
  let* component = nonempty Labels.sandbox_component_label_key in
  let* base_path_hash = nonempty Labels.sandbox_base_path_hash_label_key in
  let* kind = nonempty Labels.sandbox_kind_label_key in
  let* keeper = nonempty Labels.sandbox_keeper_label_key in
  Some { component; base_path_hash; kind; keeper }
;;

let inventory_of_apple_json raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error _ -> invalid Invalid_json
  | `List rows ->
    let rec inventory names entries = function
      | [] -> Ok { names; entries = List.rev entries }
      | row :: rest ->
        Result.bind (row_identity row) (fun name ->
          if Names.mem name names then invalid Duplicate_guest_name
          else
            let labels = match row with
              | `Assoc fields -> scoping_labels fields
              | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None in
            inventory (Names.add name names) ({name; scoping_labels = labels} :: entries) rest)
    in
    inventory Names.empty [] rows
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
    invalid Expected_array
;;

let rows inventory = inventory.entries

let presence ~guest_name inventory =
  if String.trim guest_name = "" then Error Invalid_guest_name
  else Ok (if Names.mem guest_name inventory.names then Present else Absent)
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
  | Error {reason = Capture_cleanup_failed; status = _} ->
    Error (Output_unavailable Capture_cleanup_failed)
  | Error {reason = _; status = Some ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status)}
      when status <> Unix.WEXITED 0 -> Error (Command_failed status)
  | Error {reason; status = (None | Some (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _))} ->
    Error (Output_unavailable reason)
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
    let reason = match reason with
      | Invalid_json -> "invalid JSON"
      | Expected_array -> "expected a JSON array"
      | Expected_row_object -> "expected an object for every row"
      | Duplicate_row_key -> "duplicate row key"
      | Invalid_configuration -> "configuration is not an object"
      | Duplicate_configuration_key -> "duplicate configuration key"
      | Missing_identity -> "a row has no identity"
      | Invalid_identity -> "a row identity is not a nonempty string"
      | Conflicting_identity -> "row identities disagree"
      | Duplicate_guest_name -> "duplicate guest name" in
    "full guest inventory could not be read: " ^ reason
;;

module For_testing = struct
  let inventory_of_apple_json = inventory_of_apple_json
  let presence_of_apple_json = presence_of_apple_json
end
