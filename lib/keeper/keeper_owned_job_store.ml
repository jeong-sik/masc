module Backend = Keeper_owned_job_backend
let ( let* ) = Result.bind

module Job_id = struct
  type t = string
  let fresh = Random_id.uuid_v7
  let of_string = Random_id.parse_uuid_v7
  let to_string value = value
end

type source =
  { task_id : string option
  ; turn_ref : Ids.Turn_ref.t option
  ; tool_use_id : string option
  ; trace_id : string option
  ; keeper_turn_id : int option
  }
type phase =
  | Prepared
  | Create_requested
  | Created of string
  | Start_requested of string
  | Running of string
  | Exited of { container_id : string; exit_code : int }
  | Cancelled_before_start of string option
type input = { path : string; artifact : Tool_output.artifact_ref }
type paths = { job_dir : string; workspace : string; cli_config_dir : string }
type record =
  { job_id : Job_id.t; base_path : string; keeper_name : string; source : source
  ; preparation : Backend.preparation; inputs : input list; sequence : int
  ; phase : phase; cancel_requested : bool
  ; outputs : (Tool_output.artifact_ref * Tool_output.artifact_ref) option
  ; detail : string option }
type error =
  | Invalid_authority of string | Corrupt of string | Missing | Conflict
  | Io_failed of string | Commit_unconfirmed of string

let error_to_string = function
  | Invalid_authority detail -> "job authority: " ^ detail
  | Corrupt detail -> "job journal corrupt: " ^ detail
  | Missing -> "job authority is missing"
  | Conflict -> "job authority changed; inspect the same job"
  | Io_failed detail -> "job I/O: " ^ detail
  | Commit_unconfirmed detail -> "job commit unconfirmed: " ^ detail

let canonical_base_path base_path =
  try Ok (Keeper_registry_types.canonical_base_path_exn base_path)
  with Invalid_argument detail -> Error (Invalid_authority detail)

let paths ~base_path job_id =
  let root = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests")
      "owned_jobs" in
  let job_dir = Filename.concat root (Job_id.to_string job_id) in
  let data_dir = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path) "owned_job_data")
      (Job_id.to_string job_id) in
  { job_dir; workspace = Filename.concat data_dir "workspace"
  ; cli_config_dir = Filename.concat data_dir "cli" }

let journal_path ~base_path job_id =
  Filename.concat (paths ~base_path job_id).job_dir "owner.jsonl"

let string_option = function None -> `Null | Some value -> `String value
let int_option = function None -> `Null | Some value -> `Int value
let source_to_json source =
  `Assoc
    [ "task_id", string_option source.task_id
    ; "turn_ref", string_option (Option.map Ids.Turn_ref.to_string source.turn_ref)
    ; "tool_use_id", string_option source.tool_use_id
    ; "trace_id", string_option source.trace_id
    ; "keeper_turn_id", int_option source.keeper_turn_id ]

let phase_to_string = function
  | Prepared -> "prepared" | Create_requested -> "create_requested"
  | Created _ -> "created" | Start_requested _ -> "start_requested"
  | Running _ -> "running" | Exited _ -> "exited"
  | Cancelled_before_start _ -> "cancelled_before_start"

let container_id = function
  | Prepared | Create_requested -> None
  | Created id | Start_requested id | Running id -> Some id
  | Exited { container_id; _ } -> Some container_id
  | Cancelled_before_start id -> id

let phase_to_json phase =
  let exit_code = match phase with
    | Exited { exit_code; _ } -> Some exit_code
    | Prepared | Create_requested | Created _ | Start_requested _ | Running _
    | Cancelled_before_start _ -> None in
  `Assoc ["kind", `String (phase_to_string phase);
          "container_id", string_option (container_id phase);
          "exit_code", int_option exit_code]

let input_to_json input =
  `Assoc ["path", `String input.path;
          "artifact", Tool_output.normalized_artifact_ref_to_json input.artifact]

let outputs_to_json = function
  | None -> `Null
  | Some (stdout, stderr) -> `Assoc
      [ "stdout", Tool_output.normalized_artifact_ref_to_json stdout
      ; "stderr", Tool_output.normalized_artifact_ref_to_json stderr ]

let record_to_json record =
  `Assoc
    [ "version", `Int 1; "job_id", `String (Job_id.to_string record.job_id)
    ; "base_path", `String record.base_path; "keeper_name", `String record.keeper_name
    ; "source", source_to_json record.source
    ; "preparation", Backend.preparation_to_json record.preparation
    ; "inputs", `List (List.map input_to_json record.inputs)
    ; "sequence", `Int record.sequence; "phase", phase_to_json record.phase
    ; "cancel_requested", `Bool record.cancel_requested
    ; "outputs", outputs_to_json record.outputs; "detail", string_option record.detail ]

let exact_object keys = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.sort String.compare names = List.sort String.compare keys
      then Ok fields else Error (Corrupt "missing, duplicate or unknown object field")
  | _ -> Error (Corrupt "expected object")
let field fields key =
  match List.assoc_opt key fields with
  | Some value -> Ok value | None -> Error (Corrupt ("missing " ^ key))
let string = function
  | `String value when value <> "" -> Ok value
  | _ -> Error (Corrupt "expected nonempty string")
let nullable decode = function `Null -> Ok None | value -> Result.map Option.some (decode value)
let integer = function `Int value -> Ok value | _ -> Error (Corrupt "expected integer")
let boolean = function `Bool value -> Ok value | _ -> Error (Corrupt "expected boolean")
let decode_field fields key decode = let* value = field fields key in decode value
let rec map_result decode = function
  | [] -> Ok []
  | value :: rest -> let* value = decode value in
      let* rest = map_result decode rest in Ok (value :: rest)
let artifact value = match Tool_output.normalized_artifact_ref_of_json value with
  | Tool_output.Decoded_normalized_artifact_ref reference -> Ok reference
  | Tool_output.Invalid_normalized_artifact_ref { detail } -> Error (Corrupt detail)
  | Tool_output.Not_normalized_artifact_ref -> Error (Corrupt "expected normalized artifact")

let source_of_json value =
  let* fields = exact_object ["task_id";"turn_ref";"tool_use_id";"trace_id";"keeper_turn_id"] value in
  let* task_id = decode_field fields "task_id" (nullable string) in
  let turn_ref value = let* value = string value in
    match Ids.Turn_ref.of_string value with Some value -> Ok value
    | None -> Error (Corrupt "invalid source turn reference") in
  let* turn_ref = decode_field fields "turn_ref" (nullable turn_ref) in
  let* tool_use_id = decode_field fields "tool_use_id" (nullable string) in
  let* trace_id = decode_field fields "trace_id" (nullable string) in
  let* keeper_turn_id = decode_field fields "keeper_turn_id" (nullable integer) in
  Ok {task_id;turn_ref;tool_use_id;trace_id;keeper_turn_id}

let phase_of_json value =
  let* fields = exact_object ["kind";"container_id";"exit_code"] value in
  let* kind = decode_field fields "kind" string in
  let* container = decode_field fields "container_id" (nullable string) in
  let* exit_code = decode_field fields "exit_code" (nullable integer) in
  match kind, container, exit_code with
  | "prepared", None, None -> Ok Prepared
  | "create_requested", None, None -> Ok Create_requested
  | "created", Some id, None -> Ok (Created id)
  | "start_requested", Some id, None -> Ok (Start_requested id)
  | "running", Some id, None -> Ok (Running id)
  | "exited", Some container_id, Some exit_code -> Ok (Exited {container_id;exit_code})
  | "cancelled_before_start", id, None -> Ok (Cancelled_before_start id)
  | _ -> Error (Corrupt "invalid phase/handle/exit-code combination")

let valid_input_path path =
  path <> "" && path <> "." && path <> ".." && Filename.basename path = path
  && not (String.contains path '\000') && not (String.contains path '\\')

let validate_inputs inputs =
  let names = List.map (fun input -> input.path) inputs in
  if List.for_all valid_input_path names
     && List.length (List.sort_uniq String.compare names) = List.length names
  then Ok () else Error (Invalid_authority "inputs require distinct single file names")

let input_of_json value =
  let* fields = exact_object ["path";"artifact"] value in
  let* path = decode_field fields "path" string in
  let* artifact = decode_field fields "artifact" artifact in Ok {path;artifact}

let validate_record (record : record) =
  let spec = Backend.specification record.preparation in
  let expected_paths = paths ~base_path:record.base_path record.job_id in
  let* canonical = canonical_base_path record.base_path in
  if canonical <> record.base_path || record.keeper_name = ""
     || spec.job_id <> Job_id.to_string record.job_id
     || spec.keeper_name <> record.keeper_name || spec.base_path <> record.base_path
     || spec.workspace_host_path <> expected_paths.workspace
  then Error (Invalid_authority "backend owner or private workspace differs")
  else let* _ = source_of_json (source_to_json record.source) in
    let* () = validate_inputs record.inputs in
    match record.phase, record.outputs with
    | Exited _, _ -> Ok ()
    | (Prepared | Create_requested | Created _ | Start_requested _ | Running _
      | Cancelled_before_start _), None -> Ok ()
    | (Prepared | Create_requested | Created _ | Start_requested _ | Running _
      | Cancelled_before_start _), Some _ -> Error (Corrupt "outputs precede confirmed exit")

let record_of_json value =
  let* fields = exact_object
      ["version";"job_id";"base_path";"keeper_name";"source";"preparation";
       "inputs";"sequence";"phase";"cancel_requested";"outputs";"detail"] value in
  let* version = decode_field fields "version" integer in
  let* sequence = decode_field fields "sequence" integer in
  if version <> 1 || sequence < 1 then Error (Corrupt "invalid version or sequence")
  else
    let* raw_id = decode_field fields "job_id" string in
    let* job_id = Job_id.of_string raw_id |> Result.map_error (fun detail -> Corrupt detail) in
    let* base_path = decode_field fields "base_path" string in
    let* keeper_name = decode_field fields "keeper_name" string in
    let* source = decode_field fields "source" source_of_json in
    let* preparation_json = field fields "preparation" in
    let* preparation = Backend.preparation_of_json preparation_json
        |> Result.map_error (fun error -> Corrupt (Backend.error_to_string error)) in
    let* inputs_json = field fields "inputs" in
    let* inputs = match inputs_json with `List values -> map_result input_of_json values
      | _ -> Error (Corrupt "inputs must be an array") in
    let* phase = decode_field fields "phase" phase_of_json in
    let* cancel_requested = decode_field fields "cancel_requested" boolean in
    let outputs value = let* fields = exact_object ["stdout";"stderr"] value in
      let* stdout = decode_field fields "stdout" artifact in
      let* stderr = decode_field fields "stderr" artifact in Ok (stdout,stderr) in
    let* outputs = decode_field fields "outputs" (nullable outputs) in
    let* detail = decode_field fields "detail" (nullable string) in
    let record = {job_id;base_path;keeper_name;source;preparation;inputs;sequence;
                  phase;cancel_requested;outputs;detail} in
    let* () = validate_record record in Ok record

let same_record left right = record_to_json left = record_to_json right
let same_owner left right =
  same_record {left with sequence=right.sequence;phase=right.phase;
      cancel_requested=right.cancel_requested;outputs=right.outputs;detail=right.detail} right

let phase_transition before after =
  if before = after then true else match before, after with
  | Prepared, (Create_requested | Cancelled_before_start None) -> true
  | Create_requested, Created _ -> true
  | Created id, Start_requested next -> id = next
  | Created id, Cancelled_before_start (Some next) -> id = next
  | Start_requested id, Running next -> id = next
  | Start_requested id, Exited {container_id;_} -> id = container_id
  | Running id, Exited {container_id;_} -> id = container_id
  | (Prepared | Create_requested | Created _ | Start_requested _ | Running _
    | Exited _ | Cancelled_before_start _), _ -> false

let follows previous next =
  previous.sequence < max_int && next.sequence = previous.sequence + 1
  && same_owner previous next && phase_transition previous.phase next.phase
  && (not previous.cancel_requested || next.cancel_requested)
  && (match previous.outputs with None -> true | Some _ -> previous.outputs = next.outputs)

let decode_journal bytes =
  let decode row =
    try record_of_json (Yojson.Safe.from_string row)
    with Yojson.Json_error detail -> Error (Corrupt detail) in
  match String.split_on_char '\n' bytes |> List.rev with
  | "" :: reversed ->
      let rec fold previous = function
        | [] -> (match previous with Some record -> Ok record | None -> Error Missing)
        | row :: rest -> let* next = decode row in
            let valid = match previous with
              | None -> next.sequence = 1 && next.phase = Prepared
                  && not next.cancel_requested && next.outputs = None
              | Some previous -> follows previous next in
            if valid then fold (Some next) rest else Error (Corrupt "invalid ownership transition")
      in fold None (List.rev reversed)
  | [] | _ :: _ -> Error (Corrupt "incomplete journal tail")

let scope_matches ~base_path ~keeper_name ~job_id record =
  record.base_path = base_path && record.keeper_name = keeper_name && record.job_id = job_id

let protect_io work =
  try work () with
  | Sys_error detail -> Error (Io_failed detail)
  | Unix.Unix_error (code, operation, path) ->
      Error (Io_failed (operation ^ " " ^ path ^ ": " ^ Unix.error_message code))

let validate_owned_path_blocking ~base_path ~job_id ~create =
  let root = Common.masc_dir_from_base_path ~base_path in
  let path = journal_path ~base_path job_id in
  let* directories = Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname path)
      |> Result.map_error (fun rejection -> Invalid_authority
          (Fs_compat.owned_directory_chain_rejection_to_string rejection)) in
  let inspect kind location =
    match Unix.lstat location with
    | stats when stats.Unix.st_kind = kind && stats.st_uid = Unix.getuid ()
        && stats.st_perm land 0o022 = 0
        && (kind <> Unix.S_REG || stats.st_nlink = 1) -> Ok ()
    | _ -> Error (Invalid_authority "journal kind, owner, permissions or unique binding refused")
    | exception Unix.Unix_error (Unix.ENOENT,_,_) ->
        if create && location = path then Ok () else Error Missing in
  let* () = List.fold_left (fun result directory ->
      let* () = result in inspect Unix.S_DIR directory) (Ok ()) (root :: directories) in
  inspect Unix.S_REG path

let validate_owned_path ~base_path ~job_id ~create =
  protect_io (fun () -> match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> validate_owned_path_blocking ~base_path ~job_id ~create
    | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread ~label:"owned-job-journal-authority"
        (fun () -> validate_owned_path_blocking ~base_path ~job_id ~create))

let existing_outcome = function
  | Fs_compat.Private_file_succeeded (Some result) -> result
  | Fs_compat.Private_file_succeeded None -> Error Missing
  | Fs_compat.Private_file_succeeded_with_cleanup_failure {cleanup_failure;_} ->
      Error (Commit_unconfirmed (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Fs_compat.Private_file_failed error ->
      Error (Io_failed (Fs_compat.private_jsonl_transaction_error_to_string error))
  | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
      Error (Io_failed (Fs_compat.private_jsonl_transaction_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))

let load ~base_path ~keeper_name job_id =
  let* base_path = canonical_base_path base_path in
  let* () = validate_owned_path ~base_path ~job_id ~create:false in
  protect_io (fun () ->
    Fs_compat.update_existing_private_file_durable_locked_result
      (journal_path ~base_path job_id)
      (fun bytes -> None,
         let* () = validate_owned_path ~base_path ~job_id ~create:false in
         let* record = decode_journal bytes in
         if scope_matches ~base_path ~keeper_name ~job_id record
         then Ok record else Error (Invalid_authority "different job/base/Keeper"))
    |> existing_outcome)

let create ~base_path ~keeper_name ~job_id ~source ~preparation ~inputs =
  let* base_path = canonical_base_path base_path in
  let record = {job_id;base_path;keeper_name;source;preparation;inputs;sequence=1;
      phase=Prepared;cancel_requested=false;outputs=None;detail=None} in
  let* () = validate_record record in
  let* () = validate_owned_path ~base_path ~job_id ~create:true in
  protect_io (fun () ->
    match Fs_compat.update_private_file_durable_locked_result
        (journal_path ~base_path job_id)
        (fun bytes -> match validate_owned_path ~base_path ~job_id ~create:false with
          | Error error -> None, Error error
          | Ok () -> if bytes <> "" then None, Error Conflict
            else Some (Yojson.Safe.to_string (record_to_json record) ^ "\n"), Ok record) with
    | Fs_compat.Private_file_succeeded result -> result
    | Fs_compat.Private_file_succeeded_with_cleanup_failure {cleanup_failure;_} ->
        Error (Commit_unconfirmed (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
    | Fs_compat.Private_file_failed error -> Error (Io_failed (Fs_compat.durable_append_error_to_string error))
    | Fs_compat.Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
        Error (Io_failed (Fs_compat.durable_append_error_to_string error ^ "; " ^
            Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let transition record ~phase ~cancel_requested ~outputs ~detail =
  if record.sequence = max_int then Error (Corrupt "sequence exhausted") else
  let next = {record with phase;cancel_requested;outputs;detail;sequence=record.sequence+1} in
  let* () = validate_record next in
  if not (follows record next) then Error (Invalid_authority "invalid requested transition")
  else
    let* () = validate_owned_path ~base_path:record.base_path ~job_id:record.job_id ~create:false in
    protect_io (fun () ->
    Fs_compat.update_existing_private_file_durable_locked_result
      (journal_path ~base_path:record.base_path record.job_id)
      (fun bytes ->
         match (let* () = validate_owned_path ~base_path:record.base_path
             ~job_id:record.job_id ~create:false in decode_journal bytes) with
         | Error error -> None, Error error
         | Ok current when not (same_record current record) -> None, Error Conflict
         | Ok _ -> Some (Yojson.Safe.to_string (record_to_json next) ^ "\n"), Ok next)
    |> existing_outcome)

let ensure_directory ~base_path path =
  match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path path with
  | Error _ -> Error (Io_failed "private job directory preparation failed")
  | Ok _ -> (match Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
        ~ownership_root:base_path path with
      | Ok names -> Ok names
      | Error _ -> Error (Invalid_authority "job directory owner, permissions or identity refused"))

let prepare_workspace ~base_path job_id inputs =
  let* base_path = canonical_base_path base_path in
  let* () = validate_inputs inputs in
  let paths = paths ~base_path job_id in
  protect_io (fun () ->
    let* names = ensure_directory ~base_path paths.job_dir in
    if names <> [] then Error (Invalid_authority "job authority directory already exists") else
    let* data_names = ensure_directory ~base_path (Filename.dirname paths.workspace) in
    if data_names <> [] then Error (Invalid_authority "job data directory already exists") else
    let* workspace_names = ensure_directory ~base_path paths.workspace in
    let* cli_names = ensure_directory ~base_path paths.cli_config_dir in
    if workspace_names <> [] || cli_names <> [] then Error (Invalid_authority "job directories are not empty") else
    let blobs = Tool_blob_store.create ~base_path in
    let rec copy = function
      | [] -> Ok paths
      | input :: rest ->
          let* bytes = match Tool_blob_store.fetch blobs ~sha256:input.artifact.sha256 with
            | Ok (Some bytes) when String.length bytes = input.artifact.bytes -> Ok bytes
            | Ok (Some _) -> Error (Invalid_authority "artifact declared byte count differs")
            | Ok None -> Error (Invalid_authority "input artifact is missing")
            | Error error -> Error (Invalid_authority (Tool_blob_store.fetch_error_to_string error)) in
          let* () = Fs_compat.save_file_atomic_strict (Filename.concat paths.workspace input.path) bytes
              |> Result.map_error (fun detail -> Io_failed detail) in
          copy rest
    in copy inputs)

let result_json record =
  let status, exit_code = match record.phase with
    | Prepared -> "waiting", None
    | Create_requested | Start_requested _ -> "unconfirmed", None
    | Created _ -> "ready", None
    | Running _ -> "running", None
    | Exited {exit_code;_} -> "exited", Some exit_code
    | Cancelled_before_start _ -> "cancelled", None in
  let artifacts = match record.outputs with None -> [] | Some (stdout,stderr) -> [stdout;stderr] in
  `Assoc ["job_id", `String (Job_id.to_string record.job_id); "status", `String status;
      "source", source_to_json record.source; "phase", `String (phase_to_string record.phase);
      "cancel_requested", `Bool record.cancel_requested;
      "artifacts", `List (List.map Tool_output.normalized_artifact_ref_to_json artifacts);
      "detail", string_option record.detail;
      "container_id", string_option (container_id record.phase); "exit_code", int_option exit_code]
