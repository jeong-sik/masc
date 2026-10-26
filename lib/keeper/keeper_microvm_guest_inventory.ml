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

type unavailable_output =
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

let presence_of_apple_json ~guest_name raw =
  if String.trim guest_name = "" then Error Invalid_guest_name
  else
    match Yojson.Safe.from_string raw with
    | exception Yojson.Json_error _ -> invalid Invalid_json
    | `List rows ->
      let rec inventory names = function
        | [] -> Ok (if Names.mem guest_name names then Present else Absent)
        | row :: rest ->
          Result.bind (row_identity row) (fun name ->
            if Names.mem name names then invalid Duplicate_guest_name
            else inventory (Names.add name names) rest)
      in
      inventory Names.empty rows
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ ->
      invalid Expected_array
;;

let release_capture_directory directory =
  let remove () = Fs_compat.remove_tree directory in
  match
    (match Fs_compat.execution_context () with
     | Fs_compat.Non_eio -> remove ()
     | Fs_compat.Eio_fiber -> Eio.Cancel.protect remove)
  with
  | () -> Ok ()
  | exception (Sys_error _ | Unix.Unix_error _ | Eio.Io _) ->
    Error (Output_unavailable Capture_cleanup_failed)
;;

let with_capture_directory use =
  match Filename.temp_dir "masc-guest-inventory-" "" with
  | exception (Sys_error _ | Unix.Unix_error _) ->
    Error (Output_unavailable Capture_directory_unavailable)
  | directory ->
    let cleanup () = release_capture_directory directory in
    let reraise exn backtrace =
      (match cleanup () with
       | Ok () -> ()
       | Error _ -> Log.Keeper.warn "private guest inventory capture cleanup failed");
      Printexc.raise_with_backtrace exn backtrace in
    match use directory with
    | result -> (match cleanup () with Ok () -> result | Error _ as error -> error)
    | exception (Eio.Cancel.Cancelled _ as exn) ->
      reraise exn (Printexc.get_raw_backtrace ())
    | exception exn -> reraise exn (Printexc.get_raw_backtrace ())
;;

let read_complete_stdout ~capture_dir = function
  | Process_output_capture.Incomplete_file _ -> Error (Output_unavailable Capture_incomplete)
  | Process_output_capture.Capture_failed _ -> Error (Output_unavailable Capture_failed)
  | Process_output_capture.Complete_file {path; byte_length} ->
    (match Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
        ~ownership_root:capture_dir path with
     | Error _ | Ok None -> Error (Output_unavailable Capture_unreadable)
     | Ok (Some file) ->
       if file.snapshot.permissions <> 0o600 then Error (Output_unavailable Capture_permissions_invalid)
       else if String.length file.content <> byte_length then Error (Output_unavailable Capture_length_mismatch)
       else Ok file.content)
;;

let read ~backend ~guest_name ~timeout_sec =
  match (backend : Backend.t) with
  | Backend.Microsandbox | Backend.Nerdctl_kata -> Error (Unsupported backend)
  | Backend.Apple_container ->
    if String.trim guest_name = "" then Error Invalid_guest_name
    else
      with_capture_directory (fun directory ->
        let capture_dir = Unix.realpath directory in
        let ((status, _stdout_preview, _stderr_preview), files) =
          Process_output_capture.with_capture ~capture_dir (fun output_capture ->
            Process_eio.run_argv_with_status_split_streaming ~timeout_sec ~output_capture
              ~on_stdout_chunk:ignore ~on_stderr_chunk:ignore
              (Keeper_sandbox_microvm.guest_listing_argv_for backend)) in
        match status with
        | Unix.WEXITED 0 ->
          Result.bind (read_complete_stdout ~capture_dir files.stdout)
            (presence_of_apple_json ~guest_name)
        | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status ->
          Error (Command_failed status))
;;

let error_message = function
  | Unsupported backend ->
    Printf.sprintf "full guest inventory is unsupported for %s" (Backend.to_string backend)
  | Invalid_guest_name -> "full guest inventory requires a nonempty guest name"
  | Output_unavailable reason ->
    let reason = match reason with
      | Capture_directory_unavailable -> "private capture directory unavailable"
      | Capture_incomplete -> "stdout EOF was not established"
      | Capture_failed -> "complete stdout capture unavailable"
      | Capture_unreadable -> "owned capture could not be read"
      | Capture_permissions_invalid -> "capture permissions are not private"
      | Capture_length_mismatch -> "capture byte length changed"
      | Capture_cleanup_failed -> "private capture cleanup failed" in
    "full guest inventory unavailable: " ^ reason
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
  let presence_of_apple_json = presence_of_apple_json
end
