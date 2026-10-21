module Setup = Keeper_sandbox_runtime_setup
module Hardening = Env_config_sandbox.Hardening

let ( let* ) = Result.bind

type spec =
  { job_id : string; keeper_name : string; base_path : string
  ; workspace_host_path : string; argv : string list }

type seccomp = { path : string; sha256 : string; policy : Yojson.Safe.t }
type invocation = { executable : string; arguments : string list }
type directory_identity = { path : string; device : int; inode : int; owner_uid : int; permissions : int }
type preparation =
  { spec : spec; invocation : invocation; docker_command : string list; docker_config_path : string
  ; context_name : string; endpoint : string; daemon_id : string
  ; image_reference : string; image_id : string; image_environment : string list
  ; image_volumes : string list; tmpfs : (string * string) list
  ; uid : int; gid : int; pids : int; nofile : int
  ; memory_argument : string; memory_bytes : int64; seccomp : seccomp option
  ; require_rootless : bool; require_userns : bool; directories : directory_identity list }

let specification prepared = prepared.spec

type error =
  | Invalid_spec of string
  | Image_refused of Keeper_sandbox_image_resolver.error
  | Preparation_refused of string
  | Process_refused of { operation : string; refusal : Process_eio.spawn_refusal }
  | Command_failed of { operation : string; status : Unix.process_status; stdout : string; stderr : string }
  | Response_rejected of { operation : string; detail : string }
  | Log_capture_incomplete of { stream : Process_output_capture.stream; path : string; byte_length : int }
  | Log_capture_failed of { stream : Process_output_capture.stream; path : string option; detail : string }
  | Log_publication_failed of string

type observation = Absent | Created of string | Running of string
  | Stopped of string * int | Unconfirmed of string
type logs = { stdout : Tool_output.artifact_ref; stderr : Tool_output.artifact_ref }

let log_stream_name = function Process_output_capture.Stdout -> "stdout" | Stderr -> "stderr"

let status_text = function
  | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
  | WSIGNALED signal -> Printf.sprintf "signal=%d" signal
  | WSTOPPED signal -> Printf.sprintf "stopped=%d" signal
let error_to_string = function
  | Invalid_spec detail -> "invalid owned job: " ^ detail
  | Image_refused error -> Keeper_sandbox_image_resolver.error_to_string error
  | Preparation_refused detail -> "owned job preparation refused: " ^ detail
  | Process_refused {operation; refusal} -> operation ^ ": " ^ Process_eio.spawn_refusal_to_string refusal
  | Command_failed {operation; status; stdout; stderr} ->
    Printf.sprintf "%s %s; stdout=%s; stderr=%s" operation (status_text status) stdout stderr
  | Response_rejected {operation; detail} -> operation ^ ": " ^ detail
  | Log_capture_incomplete {stream; path; byte_length} ->
    Printf.sprintf "owned job %s capture did not reach EOF: %s (%d bytes)" (log_stream_name stream) path byte_length
  | Log_capture_failed {stream; path; detail} ->
    Printf.sprintf "owned job %s capture failed%s: %s" (log_stream_name stream)
      (match path with None -> "" | Some path -> " at " ^ path) detail
  | Log_publication_failed detail -> "owned job log publication failed: " ^ detail

type base_path_error =
  | Invalid_base_path of string
  | Missing_base_path
  | Non_directory_base_path
  | Base_path_io_failed of string

let base_path_error_to_string = function
  | Invalid_base_path detail -> detail
  | Missing_base_path -> "workspace base directory is missing"
  | Non_directory_base_path -> "workspace base must be a directory, not a symbolic link"
  | Base_path_io_failed detail -> detail

let canonical_base_path base_path =
  (* Anchor relative input before leaving the caller. A host worker must not
     infer a new cwd, and a failed realpath must not grant lexical authority. *)
  let* absolute = Config_dir_resolver.canonical_base_path base_path
    |> Result.map_error (fun error -> Invalid_base_path
      (Config_dir_resolver.canonical_base_path_error_to_string error)) in
  Eio_guard.run_in_systhread ~label:"owned job workspace identity" (fun () ->
    try
      (* Keep the existing backend root-leaf no-symlink restriction while
         accepting aliases in parent components, such as macOS /var. *)
      if (Unix.lstat absolute).Unix.st_kind <> Unix.S_DIR
      then Error Non_directory_base_path
      else Ok (Unix.realpath absolute)
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Missing_base_path
    | Unix.Unix_error (Unix.ENOTDIR, _, _) -> Error Non_directory_base_path
    | Unix.Unix_error (error, operation, argument) ->
      Error (Base_path_io_failed
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error)))
    | Sys_error detail -> Error (Base_path_io_failed detail))

let component = "keeper-owned-job"
let container_kind = "owned-job"
let job_label = "masc.mcp.owned_job"
let workspace_target = "/masc-job"
let digest text = Digestif.SHA256.(to_hex (digest_string text))
let container_name prepared = "masc-owned-job-" ^ prepared.spec.job_id
let contains_nul text = String.contains text '\000'
let identity text = text <> "" && String.trim text = text && not (contains_nul text)
let canonical_absolute path =
  not (Filename.is_relative path) && path <> "/" && not (contains_nul path)
  && (match String.split_on_char '/' path with
      | "" :: parts -> List.for_all (fun part -> part <> "" && part <> "." && part <> "..") parts
      | _ -> false)
let descendant ~parent path =
  let parent = String.split_on_char '/' parent and path = String.split_on_char '/' path in
  let rec prefix parents parts = match parents, parts with
    | [], _ -> true | first :: parents, next :: parts when first = next -> prefix parents parts
    | _ -> false in
  prefix parent path
let volume_target path =
  canonical_absolute path
  && not (List.exists (fun reserved -> descendant ~parent:reserved path || descendant ~parent:path reserved)
      ["/proc"; "/sys"; "/dev"; workspace_target])
let valid_container_id value = String.length value = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value
let valid_image_id value = match String.split_on_char ':' value with
  | ["sha256"; digest] -> valid_container_id digest | _ -> false

let private_paths spec =
  let masc = Common.masc_dir_from_base_path ~base_path:spec.base_path in
  let journal = Filename.concat (Filename.concat (Filename.concat masc "keeper_msg_requests") "owned_jobs") spec.job_id in
  let data = Filename.concat (Filename.concat masc "owned_job_data") spec.job_id in
  journal, data, Filename.concat data "workspace", Filename.concat data "cli"

let directory_paths spec =
  let journal, data, workspace, cli = private_paths spec in
  let chain path = Fs_compat.owned_directory_paths ~ownership_root:spec.base_path path
    |> Result.map_error (fun error -> Invalid_spec (Fs_compat.owned_directory_chain_rejection_to_string error)) in
  let* journal = chain journal in
  let* data = chain data in
  Ok (List.sort_uniq String.compare (spec.base_path :: workspace :: cli :: journal @ data))

let local_endpoint endpoint =
  let uri = Uri.of_string endpoint in
  Uri.scheme uri = Some "unix" && (Uri.host uri = None || Uri.host uri = Some "")
  && Uri.userinfo uri = None && Uri.port uri = None && Uri.query uri = []
  && Uri.fragment uri = None && canonical_absolute (Uri.path uri)

exception Decode_error of string
let require condition detail = if not condition then raise (Decode_error detail)
let fields json = match json with
  | `Assoc fields ->
    require (List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields))) "duplicate JSON fields";
    fields
  | _ -> raise (Decode_error "expected JSON object")
let exact expected json =
  let fields = fields json in
  require (List.sort String.compare (List.map fst fields) = List.sort String.compare expected) "unexpected or missing JSON fields";
  fields
let field name fields = match List.assoc_opt name fields with
  | Some value -> value | None -> raise (Decode_error ("missing field " ^ name))
let string = function `String value -> value | _ -> raise (Decode_error "expected string")
let integer = function `Int value -> value | _ -> raise (Decode_error "expected integer")
let integer64 = function
  | `Int value -> Int64.of_int value
  | `Intlit value -> (match Int64.of_string_opt value with Some value -> value | None -> raise (Decode_error "invalid int64"))
  | _ -> raise (Decode_error "expected int64")
let boolean = function `Bool value -> value | _ -> raise (Decode_error "expected boolean")
let list decode = function `List values -> List.map decode values | _ -> raise (Decode_error "expected array")
let strings json = list string json
let nullable_strings = function `Null -> [] | json -> strings json
let decode operation f = try Ok (f ()) with
  | Decode_error detail | Yojson.Json_error detail -> Error (Response_rejected {operation; detail})
  | Stack_overflow -> Error (Response_rejected {operation; detail="JSON nesting cannot be decoded"})
let parse operation bytes = decode operation (fun () -> Yojson.Safe.from_string bytes)
let one operation json = decode operation (fun () -> match json with
  | `List [entry] -> entry | _ -> raise (Decode_error "expected exactly one Docker object"))

let invocation_of_spec spec = match spec.argv with
  | executable :: arguments -> Ok {executable; arguments}
  | [] -> Error (Invalid_spec "argv is empty")

let validate_spec spec docker_config_path =
  let* _ = Random_id.parse_uuid_v7 spec.job_id
    |> Result.map_error (fun _ -> Invalid_spec "job_id must be a UUIDv7") in
  if not (identity spec.keeper_name) then Error (Invalid_spec "keeper identity is not canonical")
  else if not (canonical_absolute spec.base_path && canonical_absolute spec.workspace_host_path
      && canonical_absolute docker_config_path) then Error (Invalid_spec "paths must be canonical absolute paths")
  else if (let _, _, workspace, cli = private_paths spec in
    workspace <> spec.workspace_host_path || cli <> docker_config_path)
  then Error (Invalid_spec "workspace and CLI paths differ from the exact owned job data directory")
  else if descendant ~parent:spec.workspace_host_path docker_config_path
      || descendant ~parent:docker_config_path spec.workspace_host_path
  then Error (Invalid_spec "CLI config must be outside the writable workspace")
  else match spec.argv with
    | [] -> Error (Invalid_spec "argv is empty")
    | executable :: args when not (identity executable) || List.exists contains_nul args ->
      Error (Invalid_spec "argv contains an invalid executable or NUL")
    | _ -> Ok ()

let snapshot_directories spec ~owner_uid =
  let* paths = directory_paths spec in
  let operation = "owned job private directory identity" in
  Eio_guard.run_in_systhread ~label:operation (fun () ->
    let inspect () = decode operation (fun () -> List.map (fun path ->
      let stat = Unix.lstat path in
      require (stat.Unix.st_kind = Unix.S_DIR) "owned directory is missing or symbolic";
      require (stat.st_uid = owner_uid && stat.st_perm land 0o022 = 0) "owned directory has a foreign owner or writable permissions";
      {path; device=stat.st_dev; inode=stat.st_ino; owner_uid=stat.st_uid; permissions=stat.st_perm}) paths) in
    try
      let* before = inspect () in
      let _, _, _, cli = private_paths spec in
      let* names = Fs_compat.read_owned_directory ~owner_uid ~ownership_root:spec.base_path cli
        |> Result.map_error (fun error -> Preparation_refused (Fs_compat.owned_regular_file_read_error_to_string error)) in
      let* () = if names = [] then Ok () else Error (Preparation_refused "owned Docker CLI configuration is no longer empty") in
      let* after = inspect () in
      if before = after then Ok after else Error (Preparation_refused "owned directory identity changed during validation")
    with
    | Sys_error detail -> Error (Preparation_refused detail)
    | Unix.Unix_error (error, function_, argument) ->
      Error (Preparation_refused (Printf.sprintf "%s(%s): %s" function_ argument (Unix.error_message error))))

let directories_unchanged prepared =
  let* canonical = canonical_base_path prepared.spec.base_path
    |> Result.map_error (fun error -> Preparation_refused (base_path_error_to_string error)) in
  let* () = if canonical = prepared.spec.base_path && prepared.uid = Unix.getuid () then Ok ()
    else Error (Preparation_refused "canonical base or process owner changed") in
  let* actual = snapshot_directories prepared.spec ~owner_uid:prepared.uid in
  if actual = prepared.directories then Ok ()
  else Error (Preparation_refused "owned job directory identity differs from preparation")

let cli_environment () =
  ["PATH"; "HOME"; "LANG"; "LC_ALL"; "LC_CTYPE"; "TMPDIR"]
  |> List.filter_map (fun name -> Option.map (fun value -> name ^ "=" ^ value) (Sys.getenv_opt name))
  |> Array.of_list
let run ?env ~operation command arguments =
  Process_eio.run_argv_with_status_split_or_refusal ?env (command @ arguments)
  |> Result.map_error (fun refusal -> Process_refused {operation; refusal})
let success ~operation = function
  | Unix.WEXITED 0, stdout, _stderr -> Ok stdout
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
    Error (Command_failed {operation; status; stdout; stderr})
let read_json ?env ~operation command arguments =
  let* result = run ?env ~operation command arguments in
  let* stdout = success ~operation result in parse operation stdout
let command prepared = prepared.docker_command
  @ ["--config"; prepared.docker_config_path; "--host"; prepared.endpoint]
let daemon prepared =
  let operation = "owned job daemon identity" in
  let* json = read_json ~env:(cli_environment ()) ~operation (command prepared) ["info"; "--format"; "{{json .}}"] in
  decode operation (fun () ->
    let info = fields json in
    require (string (field "ID" info) = prepared.daemon_id) "Docker daemon identity changed";
    require (string (field "OSType" info) = "linux") "owned jobs require a Linux Docker daemon";
    let options = strings (field "SecurityOptions" info) in
    let has name = List.exists (fun option_ ->
      List.mem ("name=" ^ name) (String.split_on_char ',' option_)) options in
    require (not prepared.require_rootless || has "rootless") "required rootless mode is unavailable";
    require (not prepared.require_userns || has "userns") "required user namespace isolation is unavailable";
    ())

let spec_json spec = `Assoc ["job_id", `String spec.job_id; "keeper_name", `String spec.keeper_name;
  "base_path", `String spec.base_path; "workspace_host_path", `String spec.workspace_host_path;
  "argv", `List (List.map (fun value -> `String value) spec.argv)]
let spec_of_json json =
  let fields = exact ["job_id"; "keeper_name"; "base_path"; "workspace_host_path"; "argv"] json in
  {job_id = string (field "job_id" fields); keeper_name = string (field "keeper_name" fields);
   base_path = string (field "base_path" fields); workspace_host_path = string (field "workspace_host_path" fields);
   argv = strings (field "argv" fields)}
let csv value = "\"" ^ String.concat "\"\"" (String.split_on_char '"' value) ^ "\""
let labels prepared =
  [Setup.sandbox_component_label_key, component;
   Setup.sandbox_kind_label_key, container_kind;
   Setup.sandbox_base_path_hash_label_key, Setup.base_path_hash prepared.spec.base_path;
   Setup.sandbox_keeper_label_key, prepared.spec.keeper_name;
   job_label, prepared.spec.job_id]
let create_arguments prepared =
  ["container"; "create"] @ Setup.docker_run_pull_never_args ()
  @ ["--name"; container_name prepared; "--network"; "none"; "--read-only";
     "--restart"; "no"; "--cap-drop"; "ALL"; "--security-opt"; "no-new-privileges";
     "--user"; Printf.sprintf "%d:%d" prepared.uid prepared.gid;
     "--pids-limit"; string_of_int prepared.pids; "--memory"; prepared.memory_argument;
     "--ulimit"; Printf.sprintf "nofile=%d:%d" prepared.nofile prepared.nofile;
     "--mount"; String.concat "," ["type=bind"; csv ("source=" ^ prepared.spec.workspace_host_path);
       "target=" ^ workspace_target; "bind-propagation=rprivate"];
     "--workdir"; workspace_target; "--entrypoint"; prepared.invocation.executable]
  @ List.concat_map (fun (key, value) -> ["--label"; key ^ "=" ^ value]) (labels prepared)
  @ List.concat_map (fun (target, options) -> ["--tmpfs"; target ^ ":" ^ options]) prepared.tmpfs
  @ (match prepared.seccomp with None -> [] | Some seccomp -> ["--security-opt"; "seccomp=" ^ seccomp.path])
  @ [prepared.image_id] @ prepared.invocation.arguments
let footprint_json prepared =
  `List (`Assoc ["kind", `String "workspace_bind"; "source", `String prepared.spec.workspace_host_path;
    "target", `String workspace_target; "writable", `Bool true]
    :: List.map (fun (target, options) -> `Assoc ["kind", `String "private_tmpfs";
      "target", `String target; "options", `String options]) prepared.tmpfs)
let json_int64 value =
  if value >= Int64.of_int min_int && value <= Int64.of_int max_int then `Int (Int64.to_int value)
  else `Intlit (Int64.to_string value)
let directory_json directory = `Assoc ["path", `String directory.path; "device", `Int directory.device;
  "inode", `Int directory.inode; "owner_uid", `Int directory.owner_uid; "permissions", `Int directory.permissions]
let preparation_to_json prepared =
  `Assoc ["schema", `Int 1; "spec", spec_json prepared.spec;
    "docker_command", `List (List.map (fun value -> `String value) prepared.docker_command);
    "docker_config_path", `String prepared.docker_config_path;
    "directories", `List (List.map directory_json prepared.directories);
    "context", `Assoc ["name", `String prepared.context_name; "endpoint", `String prepared.endpoint; "daemon_id", `String prepared.daemon_id];
    "image", `Assoc ["reference", `String prepared.image_reference; "id", `String prepared.image_id;
      "environment", `List (List.map (fun value -> `String value) prepared.image_environment);
      "volumes", `List (List.map (fun value -> `String value) prepared.image_volumes)];
    "hardening", `Assoc ["uid", `Int prepared.uid; "gid", `Int prepared.gid; "pids", `Int prepared.pids;
      "nofile", `Int prepared.nofile; "memory_argument", `String prepared.memory_argument;
      "memory_bytes", json_int64 prepared.memory_bytes;
      "require_rootless", `Bool prepared.require_rootless; "require_userns", `Bool prepared.require_userns;
      "seccomp", (match prepared.seccomp with None -> `Null | Some value -> `Assoc
        ["path", `String value.path; "sha256", `String value.sha256; "policy", value.policy])];
    "writable_footprint", footprint_json prepared;
    "create_argv", `List (List.map (fun value -> `String value) (command prepared @ create_arguments prepared))]

let memory_bytes text =
  (* Docker's RAMInBytes grammar: a separated suffix, or a suffix after the
     last numeric character. Float conversion matches its byte conversion. *)
  let split = match String.index_opt text ' ' with
    | Some split -> split
    | None ->
      let rec last index = if index < 0 then 0 else
        match text.[index] with '0' .. '9' | '.' -> index + 1 | _ -> last (index - 1) in
      last (String.length text - 1) in
  let number = String.sub text 0 split in
  let suffix_start = if split < String.length text && text.[split] = ' ' then split + 1 else split in
  let unit_ = String.sub text suffix_start (String.length text - suffix_start) |> String.lowercase_ascii in
  let scale = match unit_ with
    | "" | "b" -> Some 1. | "k" | "kb" | "kib" -> Some 1024.
    | "m" | "mb" | "mib" -> Some 1048576. | "g" | "gb" | "gib" -> Some 1073741824.
    | "t" | "tb" | "tib" -> Some 1099511627776.
    | "p" | "pb" | "pib" -> Some 1125899906842624. | _ -> None in
  match float_of_string_opt number, scale with
  | Some number, Some scale when Float.is_finite number && number > 0.
      && number *. scale >= 1. && number *. scale < 9223372036854775808. -> Ok (Int64.of_float (number *. scale))
  | _ -> Error (Preparation_refused "memory setting is not an exact representable Docker byte size")

let preparation_of_json json =
  let operation = "owned job preparation decode" in
  let* prepared = decode operation (fun () ->
    let root = exact ["schema"; "spec"; "docker_command"; "docker_config_path"; "directories"; "context"; "image";
      "hardening"; "writable_footprint"; "create_argv"] json in
    require (field "schema" root = `Int 1) "unsupported preparation schema";
    let spec = spec_of_json (field "spec" root) in
    let context = exact ["name"; "endpoint"; "daemon_id"] (field "context" root) in
    let image = exact ["reference"; "id"; "environment"; "volumes"] (field "image" root) in
    let hardening = exact ["uid"; "gid"; "pids"; "nofile"; "memory_argument"; "memory_bytes"; "seccomp";
      "require_rootless"; "require_userns"] (field "hardening" root) in
    let seccomp = match field "seccomp" hardening with
      | `Null -> None | value ->
        let fields = exact ["path"; "sha256"; "policy"] value in
        let path = string (field "path" fields) and sha256 = string (field "sha256" fields) and policy = field "policy" fields in
        require (canonical_absolute path && valid_container_id sha256 && sha256 = digest (Yojson.Safe.to_string policy)) "invalid frozen seccomp policy";
        Some {path; sha256; policy} in
    let tmpfs = list (fun entry ->
        let fields = fields entry in
        match string (field "kind" fields) with
        | "workspace_bind" ->
          let _ = exact ["kind"; "source"; "target"; "writable"] entry in
          require (field "source" fields = `String spec.workspace_host_path && field "target" fields = `String workspace_target
              && field "writable" fields = `Bool true) "invalid private workspace footprint";
          None
        | "private_tmpfs" ->
          let _ = exact ["kind"; "target"; "options"] entry in
          Some (string (field "target" fields), string (field "options" fields))
        | _ -> raise (Decode_error "unknown writable footprint")) (field "writable_footprint" root) |> List.filter_map Fun.id in
    let invocation = match invocation_of_spec spec with
      | Ok invocation -> invocation | Error error -> raise (Decode_error (error_to_string error)) in
    {spec; invocation; docker_command = strings (field "docker_command" root); docker_config_path = string (field "docker_config_path" root);
     context_name = string (field "name" context); endpoint = string (field "endpoint" context); daemon_id = string (field "daemon_id" context);
     image_reference = string (field "reference" image); image_id = string (field "id" image);
     image_environment = strings (field "environment" image); image_volumes = strings (field "volumes" image); tmpfs;
     uid = integer (field "uid" hardening); gid = integer (field "gid" hardening); pids = integer (field "pids" hardening);
     nofile = integer (field "nofile" hardening); memory_argument = string (field "memory_argument" hardening);
     memory_bytes = integer64 (field "memory_bytes" hardening); seccomp;
     require_rootless = boolean (field "require_rootless" hardening);
     require_userns = boolean (field "require_userns" hardening);
     directories = list (fun json ->
       let fields = exact ["path"; "device"; "inode"; "owner_uid"; "permissions"] json in
       {path=string (field "path" fields); device=integer (field "device" fields); inode=integer (field "inode" fields);
        owner_uid=integer (field "owner_uid" fields); permissions=integer (field "permissions" fields)}) (field "directories" root)}) in
  let* () = validate_spec prepared.spec prepared.docker_config_path in
  let* directory_paths = directory_paths prepared.spec in
  let* expected_memory = memory_bytes prepared.memory_argument in
  let* () = decode operation (fun () ->
    require (prepared.docker_command <> [] && List.for_all identity prepared.docker_command) "invalid Docker command";
    require (identity prepared.context_name && identity prepared.daemon_id && valid_image_id prepared.image_id
      && Keeper_sandbox_image_catalog.is_reference prepared.image_reference) "invalid frozen backend identity";
    require (List.for_all (fun value -> not (contains_nul value)) prepared.image_environment) "invalid frozen image environment";
    require (local_endpoint prepared.endpoint) "only a local Unix Docker endpoint can own the bind mount";
    require (prepared.uid >= 0 && prepared.gid >= 0 && prepared.pids > 0 && prepared.nofile > 0
      && prepared.memory_bytes = expected_memory) "invalid frozen hardening";
    require (List.map (fun directory -> directory.path) prepared.directories = directory_paths) "owned directory identities are incomplete";
    List.iter (fun directory -> require (directory.owner_uid = prepared.uid && directory.permissions >= 0
      && directory.permissions land 0o022 = 0) "invalid private directory ownership") prepared.directories;
    require (List.for_all volume_target prepared.image_volumes
      && prepared.image_volumes = List.sort_uniq String.compare prepared.image_volumes) "invalid image writable targets";
    let targets = List.map fst prepared.tmpfs in
    require (targets = List.sort_uniq String.compare ("/tmp" :: prepared.image_volumes)) "private tmpfs footprint is incomplete";
    List.iter (fun (_, options) ->
      match String.split_on_char ',' options with
      | ["rw"; "nosuid"; "nodev"; "noexec"; size; "mode=1777"] ->
        (match String.split_on_char '=' size with
         | ["size"; size] -> (match memory_bytes size with
           | Ok _ -> () | Error _ -> raise (Decode_error "invalid tmpfs size"))
         | _ -> raise (Decode_error "invalid tmpfs size option"))
      | _ -> raise (Decode_error "invalid closed tmpfs options")) prepared.tmpfs;
    require (Yojson.Safe.equal (Yojson.Safe.sort json) (Yojson.Safe.sort (preparation_to_json prepared)))
      "preparation is not the canonical closed representation") in
  Ok prepared

let isolation_guard () =
  try Setup.refuse_real_daemon_under_test ~what:"operate an isolated owned job"; Ok ()
  with Failure detail -> Error (Preparation_refused detail)

let read_policy path =
  let operation = "owned job seccomp policy" in
  let* bytes =
    try Ok (Eio_guard.run_in_systhread ~label:operation (fun () ->
      In_channel.with_open_bin path In_channel.input_all))
    with
    | Sys_error detail -> Error (Preparation_refused detail)
    | Unix.Unix_error (error, function_, argument) ->
      Error (Preparation_refused (Printf.sprintf "%s(%s): %s" function_ argument (Unix.error_message error))) in
  let* policy = parse operation bytes in
  decode operation (fun () ->
    let _ = fields policy in
    {path; sha256 = digest (Yojson.Safe.to_string policy); policy})

let policy_unchanged prepared = match prepared.seccomp with
  | None -> Ok ()
  | Some expected ->
    let* actual = read_policy expected.path in
    if actual.sha256 = expected.sha256 then Ok ()
    else Error (Preparation_refused "seccomp policy changed since preparation")

let image_volume_targets json = match json with
  | `Null -> []
  | json -> fields json |> List.map (fun (target, declaration) ->
    require (fields declaration = []) "invalid Docker image volume declaration";
    require (volume_target target) "image volume overlaps a reserved isolation path";
    target) |> List.sort String.compare

let prepare ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta)
    ~docker_config_path spec =
  let* () = validate_spec spec docker_config_path in
  let* invocation = invocation_of_spec spec in
  let* canonical_base = canonical_base_path config.base_path
    |> Result.map_error (function
      | Invalid_base_path detail -> Invalid_spec detail
      | (Missing_base_path | Non_directory_base_path | Base_path_io_failed _) as error ->
        Preparation_refused (base_path_error_to_string error)) in
  let* () = if canonical_base <> spec.base_path || meta.name <> spec.keeper_name
    then Error (Invalid_spec "configuration and Keeper do not own this specification") else Ok () in
  let* () = match meta.sandbox_profile with
    | Keeper_types_profile.Docker -> Ok ()
    | Micro_vm | Remote_ssh -> Error (Preparation_refused "owned jobs require the Docker Keeper profile") in
  let* () = if Hardening.relax_fs () then Error (Preparation_refused "owned jobs require the configured read-only root and noexec tmpfs") else Ok () in
  let* () = isolation_guard () in
  let* directories = snapshot_directories spec ~owner_uid:(Unix.getuid ()) in
  let* image = Keeper_sandbox_image_resolver.for_keeper ~base_path:config.base_path meta
    |> Result.map_error (fun error -> Image_refused error) in
  let docker_command = Setup.docker_command_argv () in
  let operation = "owned job Docker context" in
  let* result = run ~operation docker_command ["context"; "show"] in
  let* context_output = success ~operation result in
  let context_name = String.trim context_output in
  let* () = if identity context_name then Ok () else Error (Response_rejected {operation; detail="invalid context identity"}) in
  let* context_json = read_json ~operation docker_command ["context"; "inspect"; context_name] in
  let* context_json = one operation context_json in
  let* context_endpoint = decode operation (fun () ->
    let context = fields context_json in
    require (string (field "Name" context) = context_name) "context identity changed";
    let endpoints = fields (field "Endpoints" context) in
    string (field "Host" (fields (field "docker" endpoints)))) in
  let configured name = match Sys.getenv_opt name with
    | Some value when String.trim value <> "" -> Some (String.trim value)
    | None | Some _ -> None in
  let endpoint = match configured "DOCKER_CONTEXT", configured "DOCKER_HOST" with
    | None, Some host -> host | _ -> context_endpoint in
  let* () = if local_endpoint endpoint then Ok ()
    else Error (Preparation_refused "a remote Docker endpoint cannot establish ownership of this host workspace") in
  let operation = "owned job original daemon" in
  let* original_info = read_json ~operation docker_command ["info"; "--format"; "{{json .}}"] in
  let* daemon_id = decode operation (fun () ->
    let id = string (field "ID" (fields original_info)) in
    require (identity id) "invalid daemon identity"; id) in
  let pinned_command = docker_command @ ["--config"; docker_config_path; "--host"; endpoint] in
  let operation = "owned job image inventory" in
  let* image_json = read_json ~env:(cli_environment ()) ~operation pinned_command ["image"; "inspect"; image.reference] in
  let* image_json = one operation image_json in
  let* (image_id, image_environment, image_volumes) = decode operation (fun () ->
    let image = fields image_json in
    require (string (field "Os" image) = "linux") "owned jobs require a Linux image";
    let image_id = string (field "Id" image) in
    require (valid_image_id image_id) "invalid image content identity";
    let config = fields (field "Config" image) in
    let environment = nullable_strings (field "Env" config) in
    require (List.for_all (fun value -> not (contains_nul value)) environment) "invalid image environment";
    image_id, environment, image_volume_targets (field "Volumes" config)) in
  let memory_argument = Hardening.memory () in
  let* memory_bytes = memory_bytes memory_argument in
  let* tmpfs_options = decode "owned job tmpfs hardening" (fun () ->
    match String.split_on_char ':' (Hardening.tmpfs_mount ()) with
    | ["/tmp"; options] -> options ^ ",mode=1777"
    | _ -> raise (Decode_error "invalid configured tmpfs mount")) in
  let seccomp_path = String.trim (Hardening.seccomp_profile ()) in
  let* seccomp = if seccomp_path = "" then Ok None
    else if not (canonical_absolute seccomp_path) then Error (Preparation_refused "seccomp path must be canonical and absolute")
    else read_policy seccomp_path |> Result.map Option.some in
  let prepared = {spec; invocation; docker_command; docker_config_path; context_name; endpoint; daemon_id;
    image_reference=image.reference; image_id; image_environment; image_volumes;
    tmpfs=List.sort_uniq String.compare ("/tmp" :: image_volumes) |> List.map (fun target -> target, tmpfs_options);
    uid=Unix.getuid (); gid=Unix.getgid (); pids=Hardening.pids_limit (); nofile=Hardening.nofile_limit ();
    memory_argument; memory_bytes; seccomp; require_rootless=Hardening.require_rootless (); require_userns=Hardening.require_userns (); directories} in
  let* prepared = preparation_of_json (preparation_to_json prepared) in
  let* () = directories_unchanged prepared in
  let* () = daemon prepared in
  Ok prepared

let empty_sequence = function `Null | `List [] -> true | _ -> false
let empty_map = function `Null -> true | json -> fields json = []
let same_json left right = Yojson.Safe.equal (Yojson.Safe.sort left) (Yojson.Safe.sort right)

let inspect_object prepared expected_id json =
  let operation = "owned job container contract" in
  decode operation (fun () ->
    let root = fields json in
    let id = string (field "Id" root) in
    require (id = expected_id && valid_container_id id) "container identity differs from inventory";
    require (string (field "Name" root) = "/" ^ container_name prepared) "container name differs from prepared owner";
    require (string (field "Image" root) = prepared.image_id) "container image content identity changed";
    let config = fields (field "Config" root) in
    let actual_labels = fields (field "Labels" config) in
    List.iter (fun (key, value) -> require (field key actual_labels = `String value) ("ownership label differs: " ^ key)) (labels prepared);
    List.iter (fun key -> require (not (List.mem_assoc key actual_labels)) "owned job carries a lifetime/sweep ownership label")
      [Setup.sandbox_owner_pid_label_key; Setup.sandbox_started_at_label_key; Setup.sandbox_ttl_sec_label_key; "masc.keeper.sandbox"];
    require (string (field "Image" config) = prepared.image_id) "container image reference is not pinned";
    require (strings (field "Entrypoint" config) = [prepared.invocation.executable]
      && nullable_strings (field "Cmd" config) = prepared.invocation.arguments) "container command changed";
    require (string (field "WorkingDir" config) = workspace_target
      && string (field "User" config) = Printf.sprintf "%d:%d" prepared.uid prepared.gid) "container user/workspace changed";
    require (List.sort String.compare (nullable_strings (field "Env" config)) = List.sort String.compare prepared.image_environment)
      "container environment differs from the frozen image";
    require (image_volume_targets (field "Volumes" config) = prepared.image_volumes) "container image volume declaration changed";
    let host = fields (field "HostConfig" root) in
    require (string (field "NetworkMode" host) = "none" && boolean (field "ReadonlyRootfs" host)
      && not (boolean (field "Privileged" host)) && not (boolean (field "AutoRemove" host))
      && not (boolean (field "PublishAllPorts" host))) "container network/root/effect contract changed";
    let restart = fields (field "RestartPolicy" host) in
    require (string (field "Name" restart) = "no" && integer (field "MaximumRetryCount" restart) = 0) "container restart policy changed";
    require (empty_sequence (field "CapAdd" host) && strings (field "CapDrop" host) = ["ALL"]) "container capability contract changed";
    List.iter (fun key -> require (empty_sequence (field key host)) ("unexpected container host source: " ^ key))
      ["Binds"; "VolumesFrom"; "Devices"; "DeviceRequests"; "DeviceCgroupRules"; "Links"; "GroupAdd"];
    require (empty_map (field "PortBindings" host)) "unexpected published ports";
    List.iter (fun key -> require (string (field key host) = "") ("unexpected shared namespace: " ^ key)) ["PidMode"; "UTSMode"; "UsernsMode"];
    require (List.mem (string (field "IpcMode" host)) ["private"; "shareable"]) "unexpected shared IPC namespace";
    require (integer64 (field "Memory" host) = prepared.memory_bytes
      && integer64 (field "PidsLimit" host) = Int64.of_int prepared.pids) "container resource hardening changed";
    let ulimits = list (fun json ->
      let fields = fields json in
      string (field "Name" fields), integer64 (field "Soft" fields), integer64 (field "Hard" fields)) (field "Ulimits" host) in
    require (List.assoc_opt "nofile" (List.map (fun (name, soft, hard) -> name, (soft, hard)) ulimits)
      = Some (Int64.of_int prepared.nofile, Int64.of_int prepared.nofile)) "container nofile hardening changed";
    let security = strings (field "SecurityOpt" host) in
    let expected_security_count = match prepared.seccomp with None -> 1 | Some _ -> 2 in
    require (List.length security = expected_security_count && List.mem "no-new-privileges" security) "container security options changed";
    (match prepared.seccomp with None -> () | Some expected ->
      let policies = List.filter_map (fun option_ ->
        match String.index_opt option_ '=' with
        | Some split when String.sub option_ 0 split = "seccomp" ->
          Some (Yojson.Safe.from_string (String.sub option_ (split + 1) (String.length option_ - split - 1)))
        | _ -> None) security in
      require (match policies with [actual] -> same_json actual expected.policy | _ -> false) "container seccomp policy changed");
    let tmpfs = fields (field "Tmpfs" host) |> List.map (fun (target, options) -> target, string options) |> List.sort compare in
    require (tmpfs = prepared.tmpfs) "container private tmpfs footprint changed";
    let mounts = list fields (field "Mounts" root) in
    let bind_count = List.fold_left (fun bind_count mount ->
      match string (field "Type" mount) with
      | "bind" ->
        require (string (field "Source" mount) = prepared.spec.workspace_host_path
          && string (field "Destination" mount) = workspace_target && boolean (field "RW" mount)
          && string (field "Propagation" mount) = "rprivate") "container workspace mount changed";
        bind_count + 1
      | "tmpfs" ->
        require (List.mem_assoc (string (field "Destination" mount)) prepared.tmpfs
          && boolean (field "RW" mount)) "unexpected tmpfs mount";
        bind_count
      | _ -> raise (Decode_error "unexpected container mount outside the private footprint")) 0 mounts in
    require (bind_count = 1) "container private workspace binding is absent or duplicated";
    let state = fields (field "State" root) in
    require (not (boolean (field "Paused" state)) && not (boolean (field "Restarting" state))
      && not (boolean (field "Dead" state))) "container transition is not settled";
    let running = boolean (field "Running" state) and exit_code = integer (field "ExitCode" state) in
    match string (field "Status" state), running with
    | "created", false when exit_code = 0 -> Created id
    | "running", true when exit_code = 0 -> Running id
    | "exited", false -> Stopped (id, exit_code)
    | _ -> Unconfirmed "container status is absent, contradictory or not a settled owned phase")

let inventory prepared =
  let operation = "owned job container inventory" in
  let filters = List.concat_map (fun (key, value) -> ["--filter"; "label=" ^ key ^ "=" ^ value]) (labels prepared) in
  let* result = run ~env:(cli_environment ()) ~operation (command prepared)
    (["container"; "ls"; "--all"; "--no-trunc"] @ filters @ ["--format"; "{{json .ID}}"] ) in
  let* stdout = success ~operation result in
  decode operation (fun () ->
    String.split_on_char '\n' stdout |> List.filter (fun line -> String.trim line <> "")
    |> List.map (fun line -> let id = string (Yojson.Safe.from_string line) in
      require (valid_container_id id) "invalid full container identity"; id))

type presence_hint =
  | No_owned_container_seen
  | Owned_container_seen
  | Presence_unavailable of error

module Presence_route = struct
  type t = {
    base_path : string; docker_command : string list; endpoint : string;
    daemon_id : string; context_name : string; uid : int;
    require_rootless : bool; require_userns : bool;
  }
  let coordinates route =
    route.base_path, route.docker_command, route.endpoint, route.daemon_id,
    route.context_name, route.uid, route.require_rootless, route.require_userns
  let compare left right = Stdlib.compare (coordinates left) (coordinates right)
end
module Presence_routes = Map.Make (Presence_route)
module Presence_owners = Set.Make (struct
  type t = string * string
  let compare = Stdlib.compare
end)
type presence_round = {
  mutable inventories : (Presence_owners.t, error) result Eio.Lazy.t Presence_routes.t;
}
let create_presence_round () = {inventories=Presence_routes.empty}

let presence_route (prepared : preparation) : Presence_route.t =
  {base_path=prepared.spec.base_path;docker_command=prepared.docker_command;
   endpoint=prepared.endpoint;daemon_id=prepared.daemon_id;context_name=prepared.context_name;
   uid=prepared.uid;require_rootless=prepared.require_rootless;require_userns=prepared.require_userns}

let presence_columns =
  ["component",Setup.sandbox_component_label_key;"kind",Setup.sandbox_kind_label_key;
   "base_path_hash",Setup.sandbox_base_path_hash_label_key;
   "keeper_name",Setup.sandbox_keeper_label_key;"job_id",job_label]
let presence_format =
  "{\"container_id\":{{json .ID}}," ^ String.concat "," (List.map (fun (name,label) ->
    Printf.sprintf "\"%s\":{{.Label %S | json}}" name label) presence_columns) ^ "}"

let with_presence_directory ?(completed_files=ref []) (route : Presence_route.t) f =
  Eio.Switch.run @@ fun sw ->
  let* path = Eio.Cancel.protect (fun () ->
    let* path,device,inode =
      try Eio_guard.run_in_systhread ~label:"owned job shared presence scope create" (fun () ->
        let path = Filename.temp_dir
            ~temp_dir:(Common.masc_dir_from_base_path ~base_path:route.base_path)
            ~perms:0o700 ".owned-job-presence-" "" in
        let stat = Unix.lstat path in
        Ok (path,stat.Unix.st_dev,stat.st_ino))
      with
      | Sys_error detail -> Error (Preparation_refused detail)
      | Unix.Unix_error (error,function_,argument) ->
          Error (Preparation_refused (Printf.sprintf "%s(%s): %s" function_ argument (Unix.error_message error))) in
    Eio.Switch.on_release sw (fun () ->
      (* Release runs protected from cancellation. Remove only complete captures
         whose validated snapshots still match, then our exact empty directory.
         Incomplete or unexpected contents remain evidence, never recursive GC. *)
      try Eio_guard.run_in_systhread ~label:"owned job shared presence scope release" (fun () ->
        let stat = Unix.lstat path in
        if stat.Unix.st_kind=Unix.S_DIR && stat.st_dev=device && stat.st_ino=inode
           && stat.st_uid=route.uid && stat.st_perm=0o700
        then (
          List.iter (fun (file,(expected : Fs_compat.owned_regular_file_snapshot)) ->
            let actual = Unix.lstat file in
            if Filename.dirname file=path && actual.Unix.st_kind=Unix.S_REG && actual.st_nlink=1
               && actual.st_dev=expected.device && actual.st_ino=expected.inode
               && actual.st_uid=expected.owner_uid && actual.st_perm=expected.permissions
               && actual.st_size=expected.file_size && actual.st_mtime=expected.modified_at
               && actual.st_ctime=expected.changed_at
            then Unix.unlink file
            else Log.Keeper.warn "owned job shared presence capture retained path=%s: file identity changed" file) !completed_files;
          Unix.rmdir path)
        else Log.Keeper.warn "owned job shared presence scope retained path=%s: directory identity changed" path)
      with
      | Sys_error detail -> Log.Keeper.warn "owned job shared presence scope retained path=%s: %s" path detail
      | Unix.Unix_error (error,function_,argument) ->
          Log.Keeper.warn "owned job shared presence scope retained path=%s: %s(%s): %s"
            path function_ argument (Unix.error_message error));
    Ok path) in
  f path

let shared_presence_inventory (route : Presence_route.t) =
  with_presence_directory route @@ fun cli ->
  let completed_files = ref [] in
  with_presence_directory ~completed_files route @@ fun capture_dir ->
  let operation = "owned job shared presence inventory" in
  let base_hash = Setup.base_path_hash route.base_path in
  let filters = List.concat_map (fun (key,value) -> ["--filter";"label=" ^ key ^ "=" ^ value])
      [Setup.sandbox_component_label_key,component;Setup.sandbox_kind_label_key,container_kind;
       Setup.sandbox_base_path_hash_label_key,base_hash] in
  let result,files = Process_output_capture.with_capture ~capture_dir (fun output_capture ->
    Process_eio.run_argv_with_status_split_streaming ~env:(cli_environment ()) ~output_capture
      ~on_stdout_chunk:ignore ~on_stderr_chunk:ignore
      (route.docker_command @ ["--config";cli;"--host";route.endpoint;
        "container";"ls";"--all";"--no-trunc"] @ filters @ ["--format";presence_format])) in
  let* _ = success ~operation result in
  let complete = function
    | Process_output_capture.Complete_file {path;byte_length} ->
        let* contents = Eio_guard.run_in_systhread ~label:"owned job complete presence capture" (fun () ->
          Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:route.uid
              ~ownership_root:route.base_path path
            |> Result.map_error (fun error -> Response_rejected {operation;
                detail=Fs_compat.owned_regular_file_read_error_to_string error})) in
        (match contents with
         | Some contents when Filename.dirname path=capture_dir && contents.snapshot.file_size=byte_length
             && String.length contents.content=byte_length ->
             completed_files := (path,contents.snapshot) :: !completed_files;
             Ok contents.content
         | Some _ | None -> Error (Response_rejected {operation;detail="complete inventory capture changed or disappeared"}))
    | Incomplete_file _ | Capture_failed _ ->
        Error (Response_rejected {operation;detail="inventory capture did not establish complete pipe EOF"}) in
  let* stdout = complete files.stdout in
  let* _ = complete files.stderr in
  Eio_guard.run_in_systhread ~label:"owned job decode complete presence inventory" (fun () ->
  decode operation (fun () ->
    String.split_on_char '\n' stdout |> List.filter (fun line -> String.trim line<>"")
    |> List.fold_left (fun owners line ->
      let row = exact ("container_id" :: List.map fst presence_columns) (Yojson.Safe.from_string line) in
      require (valid_container_id (string (field "container_id" row))) "invalid full container identity";
      require (string (field "component" row)=component && string (field "kind" row)=container_kind
        && string (field "base_path_hash" row)=base_hash) "shared inventory row has another ownership scope";
      let keeper_name = string (field "keeper_name" row) and job_id = string (field "job_id" row) in
      require (identity keeper_name && identity job_id) "shared inventory row lacks exact owner labels";
      Presence_owners.add (keeper_name,job_id) owners) Presence_owners.empty))

let shared_presence_hint round prepared =
  let route = presence_route prepared in
  let inventory = match Presence_routes.find_opt route round.inventories with
    | Some inventory -> inventory
    | None ->
        let inventory = Eio.Lazy.from_fun ~cancel:`Restart (fun () -> shared_presence_inventory route) in
        (* Publish before forcing/yielding, so sibling workers join the same
           in-flight read. This pulse's fibers share one Eio domain. *)
        round.inventories <- Presence_routes.add route inventory round.inventories;
        inventory in
  let* owners = Eio.Lazy.force inventory in
  let* () = directories_unchanged prepared in
  Ok (if Presence_owners.mem (prepared.spec.keeper_name,prepared.spec.job_id) owners
      then Owned_container_seen else No_owned_container_seen)

let presence_hint ?round prepared =
  let result =
    let* () = isolation_guard () in
    let* () = directories_unchanged prepared in
    match round with
    | Some round -> shared_presence_hint round prepared
    | None ->
        let* ids = inventory prepared in
        Ok (match ids with [] -> No_owned_container_seen | _ :: _ -> Owned_container_seen)
  in
  match result with Ok hint -> hint | Error error -> Presence_unavailable error

let inspect prepared =
  let result =
    let* () = isolation_guard () in
    let* () = directories_unchanged prepared in
    let* () = daemon prepared in
    let* ids = inventory prepared in
    match ids with
    | [] -> Ok Absent
    | [id] ->
      let operation = "owned job container inspect" in
      let* json = read_json ~env:(cli_environment ()) ~operation (command prepared) ["container"; "inspect"; id] in
      let* json = one operation json in inspect_object prepared id json
    | _ -> Error (Response_rejected {operation="owned job container inventory"; detail="multiple containers claim this exact job"}) in
  match result with Ok observation -> observation | Error error -> Unconfirmed (error_to_string error)

let after_effect prepared ~operation ~expected_id result =
  match result with
  | status, stdout, stderr when status <> Unix.WEXITED 0 ->
    Unconfirmed (error_to_string (Command_failed {operation; status; stdout; stderr}))
  | _ ->
    let observed = inspect prepared in
    match observed with
    | Created id | Running id | Stopped (id, _) when id <> expected_id -> Unconfirmed "post-effect container identity differs"
    | Absent -> Unconfirmed "effectful command returned success but exact owned container is absent"
    | (Created _ | Running _ | Stopped _ | Unconfirmed _) as observation -> observation

let create prepared =
  let* () = isolation_guard () in
  let* () = directories_unchanged prepared in
  let* () = daemon prepared in
  let* () = policy_unchanged prepared in
  match inspect prepared with
  | Unconfirmed detail -> Ok (Unconfirmed detail)
  | Created _ | Running _ | Stopped _ -> Error (Preparation_refused "the exact job already has a container; reconcile its persisted intent")
  | Absent ->
    let* () = directories_unchanged prepared in
    let* () = policy_unchanged prepared in
    let operation = "owned job container create" in
    let* result = run ~env:(cli_environment ()) ~operation (command prepared) (create_arguments prepared) in
    (match result with
     | Unix.WEXITED 0, stdout, _ ->
       let id = String.trim stdout in
       if valid_container_id id then Ok (after_effect prepared ~operation ~expected_id:id result)
       else Ok (Unconfirmed "create returned no exact container identity")
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Ok (Unconfirmed (error_to_string (Command_failed {operation; status; stdout; stderr}))))

let start ~container_id prepared =
  let* () = isolation_guard () in
  match inspect prepared with
  | (Created id | Running id | Stopped (id,_)) when id <> container_id ->
      Ok (Unconfirmed "saved container identity differs; replacement cannot be started")
  | Created id ->
    let* () = directories_unchanged prepared in
    let operation = "owned job container start" in
    let* result = run ~env:(cli_environment ()) ~operation (command prepared) ["container"; "start"; id] in
    Ok (after_effect prepared ~operation ~expected_id:id result)
  | Running _ as observation -> Ok observation
  | Unconfirmed _ as observation -> Ok observation
  | Absent -> Error (Preparation_refused "start requires the exact created container")
  | Stopped _ -> Error (Preparation_refused "a stopped job is not automatically restarted")

let cancel ~container_id prepared =
  let* () = isolation_guard () in
  match inspect prepared with
  | (Created id | Running id | Stopped (id,_)) when id <> container_id ->
      Ok (Unconfirmed "saved container identity differs; replacement cannot be cancelled")
  | Running id ->
    let* () = directories_unchanged prepared in
    let operation = "owned job container kill" in
    let* result = run ~env:(cli_environment ()) ~operation (command prepared) ["container"; "kill"; id] in
    Ok (after_effect prepared ~operation ~expected_id:id result)
  | Absent | Created _ | Stopped _ | Unconfirmed _ as observation -> Ok observation

let confirm_removed ~container_id prepared =
  let operation = "owned job container removal confirmation" in
  match inspect prepared with
  | Created _ | Running _ | Stopped _ ->
    Error (Response_rejected {operation; detail="a container still claims the original job"})
  | Unconfirmed detail -> Error (Response_rejected {operation; detail})
  | Absent ->
    match container_id with
    | None -> Ok ()
    | Some id ->
      (* Label inventory alone cannot prove the saved full ID disappeared. *)
      let* result = run ~env:(cli_environment ()) ~operation (command prepared)
        ["container";"ls";"--all";"--no-trunc";"--filter";"id=" ^ id;"--format";"{{json .ID}}"] in
      let* stdout = success ~operation result in
      let* ids = decode operation (fun () ->
        String.split_on_char '\n' stdout |> List.filter (fun line -> String.trim line <> "")
        |> List.map (fun line -> let id = string (Yojson.Safe.from_string line) in
          require (valid_container_id id) "invalid full container identity"; id)) in
      if ids=[] then Ok () else
        Error (Response_rejected {operation;detail="saved container ID remains outside its ownership inventory"})

type removal_target = Never_created | Absent_after_launch of string | Before_start of string
  | After_exit of { container_id : string; exit_code : int }

let remove_container ~target prepared =
  let* () = isolation_guard () in
  let operation = "owned job container removal" in
  let container_id = match target with Never_created -> None
    | Absent_after_launch id | Before_start id | After_exit {container_id=id;_} -> Some id in
  let remove id =
    let* () = directories_unchanged prepared in
    let* () = daemon prepared in
    let* result = run ~env:(cli_environment ()) ~operation (command prepared) ["container";"rm";id] in
    let* _ = success ~operation result in
    confirm_removed ~container_id prepared in
  match inspect prepared, target with
  | Absent, (Never_created | Absent_after_launch _ | Before_start _ | After_exit _) -> confirm_removed ~container_id prepared
  | Created id, Before_start expected when id=expected -> remove id
  | Stopped (id,code), After_exit {container_id=expected;exit_code} when id=expected && code=exit_code -> remove id
  | Unconfirmed detail, (Never_created | Absent_after_launch _ | Before_start _ | After_exit _) -> Error (Response_rejected {operation;detail})
  | Running _, (Never_created | Absent_after_launch _ | Before_start _ | After_exit _) -> Error (Response_rejected {operation;detail="cleanup never removes a running container"})
  | (Created _ | Stopped _), (Never_created | Absent_after_launch _ | Before_start _ | After_exit _) ->
    Error (Response_rejected {operation;detail="saved terminal phase or container identity differs; cleanup cannot remove a replacement"})

let remove_data prepared =
  let _,data,_,_ = private_paths prepared.spec in
  let chain = List.filter (fun (directory : directory_identity) -> descendant ~parent:directory.path data) prepared.directories
    |> List.map (fun (directory : directory_identity) -> Fs_compat.
      {path=directory.path;device=directory.device;inode=directory.inode;
       owner_uid=directory.owner_uid;permissions=directory.permissions}) in
  Eio_guard.run_in_systhread ~label:"owned-job-terminal-data-cleanup" (fun () ->
    Fs_compat.remove_owned_tree chain)
  |> Result.map_error (fun detail -> Preparation_refused ("owned job data cleanup: " ^ detail))

let log_container_authority ~container_id prepared =
  match inspect prepared with
  | Created id | Running id | Stopped (id, _) when id = container_id -> Ok ()
  | Created _ | Running _ | Stopped _ ->
    Error (Response_rejected {operation="owned job container logs"; detail="saved container identity differs"})
  | Absent -> Error (Preparation_refused "logs require the exact owned container")
  | Unconfirmed detail -> Error (Response_rejected {operation="owned job container logs"; detail})

let inspect_capture_directory prepared capture_dir =
  let operation = "owned job log capture directory" in
  let* () = directories_unchanged prepared in
  Eio_guard.run_in_systhread ~label:operation (fun () ->
    let* _ = Fs_compat.read_owned_directory ~owner_uid:prepared.uid
      ~ownership_root:prepared.spec.base_path capture_dir
      |> Result.map_error (fun error -> Log_publication_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
    try decode operation (fun () ->
      let stat = Unix.lstat capture_dir in
      require (stat.Unix.st_kind = Unix.S_DIR && stat.st_uid = prepared.uid
        && stat.st_perm land 0o077 = 0) "capture directory is not private and process-owned";
      {path=capture_dir;device=stat.st_dev;inode=stat.st_ino;owner_uid=stat.st_uid;permissions=stat.st_perm})
    with
    | Sys_error detail -> Error (Log_publication_failed detail)
    | Unix.Unix_error (error, operation, _) ->
      Error (Log_publication_failed (operation ^ ": " ^ Unix.error_message error)))

let prepare_capture_directory prepared =
  let* () = directories_unchanged prepared in
  let _, data, _, _ = private_paths prepared.spec in
  let capture_dir = Filename.concat data "captures" in
  let* () = Eio_guard.run_in_systhread ~label:"owned-job-create-capture-directory" (fun () ->
    try Unix.mkdir capture_dir 0o700; Ok () with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
    | Unix.Unix_error (error, operation, _) ->
      Error (Log_publication_failed (operation ^ ": " ^ Unix.error_message error))) in
  let* identity = inspect_capture_directory prepared capture_dir in
  Ok (capture_dir, identity)

let capture_directory_unchanged prepared expected =
  let* actual = inspect_capture_directory prepared expected.path in
  if actual = expected then Ok ()
  else Error (Log_publication_failed "private capture directory identity changed")

let complete_log_file ~stream = function
  | Process_output_capture.Complete_file {path; byte_length} -> Ok (path, byte_length)
  | Incomplete_file {path; byte_length} -> Error (Log_capture_incomplete {stream; path; byte_length})
  | Capture_failed {path; message} -> Error (Log_capture_failed {stream; path; detail=message})

let capture_file_snapshot prepared ~capture_directory ~path ~byte_length =
  let* () = capture_directory_unchanged prepared capture_directory in
  let* () = if Filename.dirname path = capture_directory.path then Ok ()
    else Error (Log_publication_failed "capture file escaped its private directory") in
  let* file = Fs_compat.load_owned_regular_file_range ~ownership_root:prepared.spec.base_path
    ~offset:0 ~max_bytes:0 path
    |> Result.map_error (fun error -> Log_publication_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
  match file with
  | None -> Error (Log_publication_failed "complete capture file is absent")
  | Some file ->
    let snapshot = file.Fs_compat.snapshot in
    if snapshot.owner_uid = prepared.uid && snapshot.permissions land 0o077 = 0
      && snapshot.file_size = byte_length
    then Ok snapshot
    else Error (Log_publication_failed "capture file owner, permissions or EOF length differs")

let publish_log_file prepared ~capture_directory blobs (path, byte_length) =
  let* before = capture_file_snapshot prepared ~capture_directory ~path ~byte_length in
  let* sha256 = Fs_compat.sha256_owned_regular_file ~ownership_root:prepared.spec.base_path path
    |> Result.map_error (fun error -> Log_publication_failed (Fs_compat.owned_regular_file_read_error_to_string error)) in
  let* sha256 = match sha256 with Some value -> Ok value
    | None -> Error (Log_publication_failed "complete capture disappeared before publication") in
  let* reference =
    try Ok (Tool_blob_store.put_file_durable blobs ~path ~mime:"text/plain") with
    | Sys_error detail -> Error (Log_publication_failed detail)
    | Unix.Unix_error (error, operation, _) ->
      Error (Log_publication_failed (operation ^ ": " ^ Unix.error_message error)) in
  let* after = capture_file_snapshot prepared ~capture_directory ~path ~byte_length in
  if Fs_compat.equal_owned_regular_file_snapshot before after
    && reference.Tool_output.sha256 = sha256 && reference.bytes = byte_length
  then Ok reference
  else Error (Log_publication_failed "complete capture changed during durable publication")

let logs ~container_id prepared =
  let* () = isolation_guard () in
  let* () = log_container_authority ~container_id prepared in
  let* capture_dir, capture_directory = prepare_capture_directory prepared in
  let operation = "owned job container logs" in
  let (result, files) = Process_output_capture.with_capture ~capture_dir (fun output_capture ->
    let* () = capture_directory_unchanged prepared capture_directory in
    let* () = log_container_authority ~container_id prepared in
    Ok (Process_eio.run_argv_with_status_split_streaming
      ~env:(cli_environment ()) ~output_capture
      ~on_stdout_chunk:(fun _ -> ()) ~on_stderr_chunk:(fun _ -> ())
      (command prepared @ ["container"; "logs"; container_id]))) in
  let* status, stdout, stderr = result in
  let* () = match status with Unix.WEXITED 0 -> Ok ()
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status ->
        Error (Command_failed {operation; status; stdout; stderr}) in
  let* stdout_file = complete_log_file ~stream:Process_output_capture.Stdout files.stdout in
  let* stderr_file = complete_log_file ~stream:Process_output_capture.Stderr files.stderr in
  let* () = log_container_authority ~container_id prepared in
  let blobs = Tool_blob_store.create ~base_path:prepared.spec.base_path in
  let* stdout = publish_log_file prepared ~capture_directory blobs stdout_file in
  let* stderr = publish_log_file prepared ~capture_directory blobs stderr_file in
  let* () = log_container_authority ~container_id prepared in
  let* () = capture_directory_unchanged prepared capture_directory in
  Ok {stdout; stderr}
