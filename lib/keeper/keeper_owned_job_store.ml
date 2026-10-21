module Backend = Keeper_owned_job_backend
module Cleanup = Keeper_owned_job_cleanup_state
let ( let* ) = Result.bind

module Job_id = Keeper_owned_job_identity.Job_id

type source = Keeper_owned_job_identity.source =
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
  | Cancelled_unconfirmed_launch
type reconciliation_hold =
  | Backend_absent
  | Backend_unconfirmed
  | Backend_mismatch
  | Cancelled_job_orphan
  | Backend_error
type reconciliation =
  | Phase_not_observed
  | Phase_confirmed
  | Phase_held of reconciliation_hold
type input = { path : string; artifact : Tool_output.artifact_ref }
type cleanup = Cleanup.t = Resources_retained | Container_removal_requested | Container_removed
  | Data_removal_requested | Resources_removed
type paths = { job_dir : string; workspace : string; cli_config_dir : string }
type outputs =
  | Outputs_complete of Tool_output.artifact_ref * Tool_output.artifact_ref
  | Outputs_unavailable of { evidence : string }
type record =
  { job_id : Job_id.t; base_path : string; keeper_name : string; source : source
  ; preparation : Backend.preparation; inputs : input list; sequence : int
  ; phase : phase; cancel_requested : bool
  ; outputs : outputs option
  ; detail : string option
  ; completion_channel : Keeper_continuation_channel.t
  ; completion_delivered : bool
  ; cleanup : cleanup }
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
  Backend.canonical_base_path base_path
  |> Result.map_error (function
    | Backend.Invalid_base_path detail -> Invalid_authority detail
    | Missing_base_path -> Missing
    | Non_directory_base_path -> Invalid_authority
        (Backend.base_path_error_to_string Backend.Non_directory_base_path)
    | Base_path_io_failed detail -> Io_failed detail)

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
let source_to_json = Keeper_owned_job_identity.source_to_json

let phase_to_string = function
  | Prepared -> "prepared" | Create_requested -> "create_requested"
  | Created _ -> "created" | Start_requested _ -> "start_requested"
  | Running _ -> "running" | Exited _ -> "exited"
  | Cancelled_before_start _ -> "cancelled_before_start"
  | Cancelled_unconfirmed_launch -> "cancelled_unconfirmed_launch"

let container_id = function
  | Prepared | Create_requested -> None
  | Created id | Start_requested id | Running id -> Some id
  | Exited { container_id; _ } -> Some container_id
  | Cancelled_before_start id -> id
  | Cancelled_unconfirmed_launch -> None

let phase_to_json phase =
  let exit_code = match phase with
    | Exited { exit_code; _ } -> Some exit_code
    | Prepared | Create_requested | Created _ | Start_requested _ | Running _
    | Cancelled_before_start _ | Cancelled_unconfirmed_launch -> None in
  `Assoc ["kind", `String (phase_to_string phase);
          "container_id", string_option (container_id phase);
          "exit_code", int_option exit_code]

let input_to_json input =
  `Assoc ["path", `String input.path;
          "artifact", Tool_output.normalized_artifact_ref_to_json input.artifact]

let outputs_to_json = function
  | None -> `Null
  | Some (Outputs_complete (stdout, stderr)) -> `Assoc
      [ "stdout", Tool_output.normalized_artifact_ref_to_json stdout
      ; "stderr", Tool_output.normalized_artifact_ref_to_json stderr ]
  | Some (Outputs_unavailable {evidence}) -> `Assoc ["unavailable", `String evidence]

let cleanup_of_json = function
  | `String value -> (match Cleanup.of_string value with
    | Some state -> Ok state | None -> Error (Corrupt "unknown cleanup state"))
  | _ -> Error (Corrupt "invalid cleanup state")

let record_to_json record =
  `Assoc
    [ "version", `Int 2; "job_id", `String (Job_id.to_string record.job_id)
    ; "base_path", `String record.base_path; "keeper_name", `String record.keeper_name
    ; "source", source_to_json record.source
    ; "preparation", Backend.preparation_to_json record.preparation
    ; "inputs", `List (List.map input_to_json record.inputs)
    ; "sequence", `Int record.sequence; "phase", phase_to_json record.phase
    ; "cancel_requested", `Bool record.cancel_requested
    ; "outputs", outputs_to_json record.outputs; "detail", string_option record.detail
    ; "completion_channel", Keeper_continuation_channel.to_yojson record.completion_channel
    ; "completion_delivered", `Bool record.completion_delivered
    ; "cleanup", `String (Cleanup.to_string record.cleanup) ]

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

let outputs_of_json = function
  | `Null -> Ok None
  | `Assoc fields when List.mem_assoc "unavailable" fields ->
      (match fields with
       | ["unavailable", `String evidence] -> Ok (Some (Outputs_unavailable {evidence}))
       | ["unavailable", _] -> Error (Corrupt "invalid outputs evidence")
       | _ -> Error (Corrupt "unknown outputs field"))
  | `Assoc _ as value ->
      let* fields = exact_object ["stdout";"stderr"] value in
      let* stdout = decode_field fields "stdout" artifact in
      let* stderr = decode_field fields "stderr" artifact in
      Ok (Some (Outputs_complete (stdout, stderr)))
  | _ -> Error (Corrupt "expected outputs object")

let source_of_json value =
  Keeper_owned_job_identity.source_of_json value |> Result.map_error (fun detail -> Corrupt detail)

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
  | "cancelled_unconfirmed_launch", None, None -> Ok Cancelled_unconfirmed_launch
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

let result_ready (record : record) = match record.phase, record.outputs with
  | Exited _, Some _ | Running _, Some (Outputs_unavailable _)
  | (Cancelled_before_start _ | Cancelled_unconfirmed_launch), None -> true
  | (Prepared | Create_requested | Created _ | Start_requested _), _
  | Running _, (None | Some (Outputs_complete _))
  | Exited _, None | (Cancelled_before_start _ | Cancelled_unconfirmed_launch), Some _ -> false

let validate_record (record : record) =
  let spec = Backend.specification record.preparation in
  let expected_paths = paths ~base_path:record.base_path record.job_id in
  (* Historical rows retain their structural check. The public operation
     resolves its root once; scope_matches then binds the final owner to it.
     Re-resolving every old row would add filesystem work per journal entry. *)
  let* canonical = Config_dir_resolver.canonical_base_path record.base_path
    |> Result.map_error (fun error -> Invalid_authority
      (Config_dir_resolver.canonical_base_path_error_to_string error)) in
  if canonical <> record.base_path || record.keeper_name = ""
     || spec.job_id <> Job_id.to_string record.job_id
     || spec.keeper_name <> record.keeper_name || spec.base_path <> record.base_path
     || spec.workspace_host_path <> expected_paths.workspace
  then Error (Invalid_authority "backend owner or private workspace differs")
  else let* _ = source_of_json (source_to_json record.source) in
    let* () = validate_inputs record.inputs in
    let* () = match record.cleanup with
      | Resources_retained -> Ok ()
      | Container_removal_requested | Container_removed | Data_removal_requested | Resources_removed ->
        if record.completion_delivered && result_ready record then Ok ()
        else Error (Corrupt "resource cleanup precedes complete result delivery") in
    let* _ = Keeper_continuation_channel.of_yojson
        (Keeper_continuation_channel.to_yojson record.completion_channel)
        |> Result.map_error (fun detail -> Corrupt detail) in
    let* () = if not record.completion_delivered then Ok () else
      match record.phase, record.outputs with
      | Exited _, Some _ | Running _, Some (Outputs_unavailable _)
      | (Cancelled_before_start _ | Cancelled_unconfirmed_launch), None -> Ok ()
      | (Prepared | Create_requested | Created _ | Start_requested _), _
      | Running _, (None | Some (Outputs_complete _))
      | Exited _, None | (Cancelled_before_start _ | Cancelled_unconfirmed_launch), Some _ ->
          Error (Corrupt "completion acknowledgement precedes a complete terminal result") in
    match record.phase, record.outputs with
    | Exited _, _ | Running _, Some (Outputs_unavailable _) -> Ok ()
    | (Prepared | Create_requested | Created _ | Start_requested _ | Running _
      | Cancelled_before_start _ | Cancelled_unconfirmed_launch), None -> Ok ()
    | (Prepared | Create_requested | Created _ | Start_requested _
      | Cancelled_before_start _ | Cancelled_unconfirmed_launch), Some _
    | Running _, Some (Outputs_complete _) -> Error (Corrupt "outputs precede confirmed exit")

let record_of_json value =
  let* fields = exact_object
      ["version";"job_id";"base_path";"keeper_name";"source";"preparation";
       "inputs";"sequence";"phase";"cancel_requested";"outputs";"detail";
       "completion_channel";"completion_delivered";"cleanup"] value in
  let* version = decode_field fields "version" integer in
  let* sequence = decode_field fields "sequence" integer in
  if version <> 2 || sequence < 1 then Error (Corrupt "invalid version or sequence")
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
    let* outputs = decode_field fields "outputs" outputs_of_json in
    let* detail = decode_field fields "detail" (nullable string) in
    let* completion_channel = decode_field fields "completion_channel"
        (fun json -> Keeper_continuation_channel.of_yojson json
          |> Result.map_error (fun detail -> Corrupt detail)) in
    let* completion_delivered = decode_field fields "completion_delivered" boolean in
    let* cleanup = decode_field fields "cleanup" cleanup_of_json in
    let record = {job_id;base_path;keeper_name;source;preparation;inputs;sequence;
                  phase;cancel_requested;outputs;detail;completion_channel;completion_delivered;cleanup} in
    let* () = validate_record record in Ok record

let same_record left right = record_to_json left = record_to_json right
let same_owner left right =
  same_record {left with sequence=right.sequence;phase=right.phase;
      cancel_requested=right.cancel_requested;outputs=right.outputs;detail=right.detail;
      completion_delivered=right.completion_delivered;cleanup=right.cleanup} right

let phase_transition before after =
  if before = after then true else match before, after with
  | Prepared, (Create_requested | Cancelled_before_start None) -> true
  | Create_requested, Created _ -> true
  | Created id, Start_requested next -> id = next
  | Created id, Cancelled_before_start (Some next) -> id = next
  | Start_requested id, Running next -> id = next
  | Start_requested id, Exited {container_id;_} -> id = container_id
  | Running id, Exited {container_id;_} -> id = container_id
  | (Create_requested | Created _ | Start_requested _ | Running _),
    Cancelled_unconfirmed_launch -> true
  | (Prepared | Create_requested | Created _ | Start_requested _ | Running _
    | Exited _ | Cancelled_before_start _ | Cancelled_unconfirmed_launch), _ -> false

let follows previous next =
  previous.sequence < max_int && next.sequence = previous.sequence + 1
  && same_owner previous next && phase_transition previous.phase next.phase
  && Cleanup.can_transition previous.cleanup next.cleanup
  && (not previous.cancel_requested || next.cancel_requested)
  && (not previous.completion_delivered || next.completion_delivered)
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
                  && not next.completion_delivered
                  && next.cleanup=Resources_retained
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

let validate_owned_file_blocking ~base_path ~path ~create =
  let root = Common.masc_dir_from_base_path ~base_path in
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

let validate_owned_file ~base_path ~path ~create =
  protect_io (fun () -> match Fs_compat.execution_context () with
    | Fs_compat.Non_eio -> validate_owned_file_blocking ~base_path ~path ~create
    | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread ~label:"owned-job-journal-authority"
        (fun () -> validate_owned_file_blocking ~base_path ~path ~create))

let validate_owned_path ~base_path ~job_id ~create =
  validate_owned_file ~base_path ~path:(journal_path ~base_path job_id) ~create

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

let recover ~base_path ~keeper_name job_id =
  let* base_path = canonical_base_path base_path in
  let* () = validate_owned_path ~base_path ~job_id ~create:false in
  let read_prefix bytes =
    let* () = validate_owned_path ~base_path ~job_id ~create:false in
    let* record = decode_journal bytes in
    if scope_matches ~base_path ~keeper_name ~job_id record then Ok record
    else Error (Invalid_authority "different job/base/Keeper") in
  protect_io (fun () ->
    (* Effects follow a confirmed full intent append, so an incomplete suffix
       cannot own a backend effect or delivery ACK. Retain every complete row. *)
    match Fs_compat.recover_and_update_private_jsonl_durable_locked_result
        ~validate_prefix:(fun bytes -> match read_prefix bytes with
          | Ok _ -> Fs_compat.Recovery_authorized
          | Error error -> Fs_compat.Recovery_refused (Error error))
        ~create:false (journal_path ~base_path job_id)
        (fun bytes -> None, read_prefix bytes) with
    | Fs_compat.Private_file_succeeded result -> result
    | Private_file_succeeded_with_cleanup_failure {cleanup_failure;_} ->
        Error (Commit_unconfirmed (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
    | Private_file_failed error -> Error (Io_failed (Fs_compat.durable_append_error_to_string error))
    | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
        Error (Io_failed (Fs_compat.durable_append_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let ensure_directory ~base_path path =
  match Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path path with
  | Error _ -> Error (Io_failed "private job directory preparation failed")
  | Ok _ -> (match Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
        ~ownership_root:base_path path with
      | Ok names -> Ok names
      | Error _ -> Error (Invalid_authority "job directory owner, permissions or identity refused"))

let delivery_directory ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path)
      "keeper_msg_requests") "owned_job_completion_pending"
let delivery_path ~base_path job_id =
  Filename.concat (delivery_directory ~base_path) (Job_id.to_string job_id ^ ".json")

type pending_delivery = { job_id : Job_id.t; keeper_name : string }
type pending_deliveries =
  { entries : pending_delivery list; failures : (string * error) list }
let marker_json (marker : pending_delivery) =
  `Assoc ["job_id", `String (Job_id.to_string marker.job_id); "keeper_name", `String marker.keeper_name]
let marker_of_json json =
  let* fields = exact_object ["job_id";"keeper_name"] json in
  let* id = decode_field fields "job_id" string in
  let* job_id = Job_id.of_string id |> Result.map_error (fun detail -> Corrupt detail) in
  let* keeper_name = decode_field fields "keeper_name" string in
  Ok {job_id;keeper_name}
let decode_marker bytes =
  try marker_of_json (Yojson.Safe.from_string bytes)
  with Yojson.Json_error detail -> Error (Corrupt detail)

let prepare_delivery_marker ~base_path ~keeper_name job_id =
  let* _ = ensure_directory ~base_path (delivery_directory ~base_path) in
  let path = delivery_path ~base_path job_id in
  let marker = {job_id;keeper_name} in
  let* () = validate_owned_file ~base_path ~path ~create:true in
  protect_io (fun () ->
    match Fs_compat.update_private_file_durable_locked_result path (fun bytes ->
      let result = let* () = validate_owned_file ~base_path ~path ~create:false in
        if bytes = "" then Ok None else
          let* found = decode_marker bytes in
          if marker_json found = marker_json marker then Ok (Some found)
          else Error (Invalid_authority "completion discovery marker names another owner") in
      match result with
      | Ok None -> Some (Yojson.Safe.to_string (marker_json marker) ^ "\n"), Ok ()
      | Ok (Some _) -> None, Ok ()
      | Error error -> None, Error error) with
    | Fs_compat.Private_file_succeeded result -> result
    | Private_file_succeeded_with_cleanup_failure {cleanup_failure;_} ->
        Error (Commit_unconfirmed (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
    | Private_file_failed error -> Error (Io_failed (Fs_compat.durable_append_error_to_string error))
    | Private_file_failed_with_cleanup_failure {error;cleanup_failure} ->
        Error (Io_failed (Fs_compat.durable_append_error_to_string error ^ "; " ^
          Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)))

let discover_pending_deliveries ~base_path ~on_entry =
  let* base_path = canonical_base_path base_path in
  let directory = delivery_directory ~base_path in
  let* names = protect_io (fun () ->
    let* inspection = Fs_compat.inspect_owned_directory_chain
        ~ownership_root:(Common.masc_dir_from_base_path ~base_path) directory
        |> Result.map_error (fun error -> Invalid_authority
          (Fs_compat.owned_directory_chain_rejection_to_string error)) in
    match inspection with
      | Fs_compat.Owned_directory_missing -> Ok []
      | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
          ~ownership_root:(Common.masc_dir_from_base_path ~base_path) directory
          |> Result.map_error (fun _ -> Invalid_authority "completion discovery directory refused")) in
  let read_marker name =
    let path = Filename.concat directory name in
    let* job_id = if Filename.extension name <> ".json" then Error (Corrupt "invalid pending marker name")
      else Job_id.of_string (Filename.remove_extension name) |> Result.map_error (fun detail -> Corrupt detail) in
    let* () = validate_owned_file ~base_path ~path ~create:false in
    let* bytes = Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
        ~ownership_root:(Common.masc_dir_from_base_path ~base_path) path
        |> Result.map_error (fun error -> Io_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
    let* () = validate_owned_file ~base_path ~path ~create:false in
    match bytes with
    | None -> Error Missing
    | Some bytes -> let* marker = decode_marker bytes.content in
        if marker.job_id = job_id then Ok marker
        else Error (Invalid_authority "completion marker does not match its filename") in
  let rec collect report = function
    | [] -> Ok {entries=List.rev report.entries;failures=List.rev report.failures}
    | name :: rest ->
      (* Keep an explicit marker refusal in the report, but preserve the
         original whole-read error for an unexpected filesystem exception.
         The scheduling callback must not be misclassified as file I/O. *)
      let* marker = protect_io (fun () -> Ok (read_marker name)) in
      let report = match marker with
        | Ok entry -> on_entry entry; {report with entries=entry :: report.entries}
        | Error error -> {report with failures=(name,error) :: report.failures} in
      collect report rest in
  collect {entries=[];failures=[]} names

let pending_deliveries ~base_path =
  discover_pending_deliveries ~base_path ~on_entry:ignore

let create ~base_path ~keeper_name ~job_id ~source ~completion_channel ~preparation ~inputs =
  let* base_path = canonical_base_path base_path in
  let record = {job_id;base_path;keeper_name;source;preparation;inputs;sequence=1;
      phase=Prepared;cancel_requested=false;outputs=None;detail=None;
      completion_channel;completion_delivered=false;cleanup=Resources_retained} in
  let* () = validate_record record in
  (* The discovery pointer is durable first. A pulse seeing it before the
     owner journal exists keeps uncertainty; it never prepares or launches. *)
  let* () = prepare_delivery_marker ~base_path ~keeper_name job_id in
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

let append_next (record : record) (next : record) =
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

let transition record ~phase ~cancel_requested ~outputs ~detail =
  if record.sequence = max_int then Error (Corrupt "sequence exhausted") else
  append_next record {record with phase;cancel_requested;outputs;detail;sequence=record.sequence+1}

let advance_cleanup (record : record) cleanup =
  if not record.completion_delivered || not (result_ready record)
  then Error (Invalid_authority "cleanup requires complete result delivery")
  else if record.cleanup=cleanup then Error (Invalid_authority "cleanup must advance to its next state")
  else if record.sequence=max_int then Error (Corrupt "sequence exhausted")
  else append_next record {record with cleanup;detail=None;sequence=record.sequence+1}

let acknowledge_completion (record : record) =
  if not (result_ready record) then Error (Invalid_authority "completion result is not ready")
  else if record.completion_delivered then Ok record
  else if record.sequence = max_int then Error (Corrupt "sequence exhausted")
  else append_next record {record with completion_delivered=true;sequence=record.sequence+1}

let retire_delivery_marker (record : record) =
  (* This marker is discovery only. The canonical owner retains the monotone
     acknowledgement, so a concurrent duplicate marker cannot replay delivery. *)
  let* current = load ~base_path:record.base_path ~keeper_name:record.keeper_name record.job_id in
  if not current.completion_delivered || current.cleanup<>Resources_removed
  then Error (Invalid_authority "completion or resource cleanup is not confirmed")
  else Keeper_fs.remove_file_durable ~ownership_root:(Common.masc_dir_from_base_path ~base_path:record.base_path)
      (delivery_path ~base_path:record.base_path record.job_id)
    |> Result.map_error (fun error -> Io_failed (Keeper_fs.durable_remove_error_to_string error))

let load_any ~base_path job_id =
  let* () = validate_owned_path ~base_path ~job_id ~create:false in
  protect_io (fun () ->
    Fs_compat.update_existing_private_file_durable_locked_result
      (journal_path ~base_path job_id)
      (fun bytes -> None,
         let* () = validate_owned_path ~base_path ~job_id ~create:false in
         let* record = decode_journal bytes in
         if record.base_path = base_path && record.job_id = job_id
         then Ok record else Error (Invalid_authority "different job/base"))
    |> existing_outcome)

let source_absent ~base_path ~keeper_name ~source =
  let* base_path = canonical_base_path base_path in
  let* _ = source_of_json (source_to_json source) in
  if keeper_name = "" then Error (Invalid_authority "keeper_name is required") else
  let* deliveries = pending_deliveries ~base_path in
  match deliveries.failures with
  | (_, error) :: _ -> Error error
  | [] ->
      let root = Filename.concat
          (Filename.concat (Common.masc_dir_from_base_path ~base_path) "keeper_msg_requests")
          "owned_jobs" in
      let* names = protect_io (fun () ->
        let* inspection = Fs_compat.inspect_owned_directory_chain
            ~ownership_root:(Common.masc_dir_from_base_path ~base_path) root
            |> Result.map_error (fun error -> Invalid_authority
              (Fs_compat.owned_directory_chain_rejection_to_string error)) in
        match inspection with
        | Fs_compat.Owned_directory_missing -> Ok []
        | Owned_directory _ -> Fs_compat.read_owned_directory ~owner_uid:(Unix.getuid ())
            ~ownership_root:(Common.masc_dir_from_base_path ~base_path) root
            |> Result.map_error (fun _ -> Invalid_authority "owned job directory refused")) in
      let* directory_ids = map_result
          (fun name -> Job_id.of_string name |> Result.map_error (fun detail -> Corrupt detail))
          names in
      let all_ids = List.sort_uniq
          (fun left right -> String.compare (Job_id.to_string left) (Job_id.to_string right))
          (directory_ids @ List.map (fun (entry : pending_delivery) -> entry.job_id) deliveries.entries) in
      let target = source_to_json source in
      let rec scan = function
        | [] -> Ok true
        | job_id :: rest ->
            let* record = load_any ~base_path job_id in
            if record.keeper_name = keeper_name && source_to_json record.source = target
            then Ok false else scan rest
      in scan all_ids


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

let reconciliation_to_json = function
  | Phase_not_observed ->
      `Assoc ["state", `String "not_observed"; "reason", `Null]
  | Phase_confirmed ->
      `Assoc ["state", `String "confirmed"; "reason", `Null]
  | Phase_held reason ->
      let reason = match reason with
        | Backend_absent -> "backend_absent"
        | Backend_unconfirmed -> "backend_unconfirmed"
        | Backend_mismatch -> "backend_mismatch"
        | Cancelled_job_orphan -> "cancelled_job_orphan"
        | Backend_error -> "backend_error" in
      `Assoc ["state", `String "held"; "reason", `String reason]

let result_json ?(reconciliation=Phase_not_observed) record =
  let status, exit_code = match record.phase, record.outputs with
    | Prepared, _ -> "waiting", None
    | (Create_requested | Start_requested _), _ -> "unconfirmed", None
    | Created _, _ -> "ready", None
    | Running _, Some (Outputs_unavailable _) -> "unavailable", None
    | Running _, (None | Some (Outputs_complete _)) -> "running", None
    | Exited {exit_code;_}, _ -> "exited", Some exit_code
    | (Cancelled_before_start _ | Cancelled_unconfirmed_launch), _ -> "cancelled", None in
  let status = match reconciliation with
    | Phase_held _ when not (result_ready record) -> "unconfirmed"
    | Phase_not_observed | Phase_confirmed | Phase_held _ -> status in
  let artifacts = match record.outputs with
    | Some (Outputs_complete (stdout, stderr)) -> [stdout; stderr]
    | Some (Outputs_unavailable _) | None -> [] in
  `Assoc ["job_id", `String (Job_id.to_string record.job_id); "status", `String status;
      "result_ready", `Bool (result_ready record);
      "reconciliation", reconciliation_to_json reconciliation;
      "source", source_to_json record.source; "phase", `String (phase_to_string record.phase);
      "cancel_requested", `Bool record.cancel_requested;
      "cleanup", `String (Cleanup.to_string record.cleanup);
      "artifacts", `List (List.map Tool_output.normalized_artifact_ref_to_json artifacts);
      "detail", string_option record.detail;
      "container_id", string_option (container_id record.phase); "exit_code", int_option exit_code]
