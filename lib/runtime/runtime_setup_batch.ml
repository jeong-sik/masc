type revision = Revision of string
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable
  | Child_not_started of Process_eio.spawn_refusal
  | Validation_failed of { exit : Unix.process_status; stderr : string }
  | Verification_failed of { runtime_id : string; code : string; message : string; detail : string option }
  | Verification_unreadable of { runtime_id : string; exit : Unix.process_status; stderr : string; reason : string }
  | Write_failed | Rollback_failed | Lock_unavailable
type readiness = Not_probed | Verified
type receipt = { runtime_id:string; runtime_ids:string list; models:string list;
                 readiness:readiness }
let ( let* ) = Result.bind
(* [Unix.WSIGNALED] carries OCaml's own signal numbers ([Sys.sigkill] is -7),
   which no operator can look up; a signal the runtime does not name arrives
   as the host's positive number. *)
let signal_names =
  [ Sys.sigabrt, "SIGABRT"; Sys.sigalrm, "SIGALRM"; Sys.sigbus, "SIGBUS"
  ; Sys.sigchld, "SIGCHLD"; Sys.sigcont, "SIGCONT"; Sys.sigfpe, "SIGFPE"
  ; Sys.sighup, "SIGHUP"; Sys.sigill, "SIGILL"; Sys.sigint, "SIGINT"
  ; Sys.sigkill, "SIGKILL"; Sys.sigpipe, "SIGPIPE"; Sys.sigpoll, "SIGPOLL"
  ; Sys.sigprof, "SIGPROF"; Sys.sigquit, "SIGQUIT"; Sys.sigsegv, "SIGSEGV"
  ; Sys.sigstop, "SIGSTOP"; Sys.sigsys, "SIGSYS"; Sys.sigterm, "SIGTERM"
  ; Sys.sigtrap, "SIGTRAP"; Sys.sigtstp, "SIGTSTP"; Sys.sigttin, "SIGTTIN"
  ; Sys.sigttou, "SIGTTOU"; Sys.sigurg, "SIGURG"; Sys.sigusr1, "SIGUSR1"
  ; Sys.sigusr2, "SIGUSR2"; Sys.sigvtalrm, "SIGVTALRM"; Sys.sigxcpu, "SIGXCPU"
  ; Sys.sigxfsz, "SIGXFSZ" ]
let signal_text signal = match List.assoc_opt signal signal_names with
  | Some name -> name
  | None -> Printf.sprintf "signal %d" signal
let exit_text status = match Process_eio.exit_reason_of_status status with
  | Process_eio.Completed code -> Printf.sprintf "exit %d" code
  | Process_eio.Timed_out -> "timed out"
  | Process_eio.Signaled signal -> "killed by " ^ signal_text signal
  | Process_eio.Stopped signal -> "stopped by " ^ signal_text signal
let with_detail = function
  | None -> "" | Some detail -> (match String.trim detail with "" -> "" | detail -> ": " ^ detail)
let child_detail stderr = match String.trim stderr with "" -> None | text -> Some text
let error_message = function
  | Invalid_selection -> "Select a default from the selected runtimes."
  | Invalid_configuration -> "The workspace runtime configuration is invalid."
  | Changed_configuration -> "Configuration changed; refresh the selection before saving."
  | Configuration_unavailable -> "The workspace configuration could not be read."
  | Child_not_started refusal ->
    "The MASC executable could not be started for stage validation: " ^ Process_eio.spawn_refusal_to_string refusal
  (* The child's stderr is its log, several lines long, and stays out of this
     one-line summary: {!error_detail} carries it. A summary with a newline in
     it was dropped whole by the setup screen, which then said only that setup
     did not finish. *)
  | Validation_failed { exit; stderr = _ } ->
    Printf.sprintf "Selected runtime configuration did not pass validation (%s)" (exit_text exit)
  | Verification_failed { runtime_id; code; detail } ->
    Printf.sprintf "Runtime %S did not pass response and tool verification (%s)%s" runtime_id code (with_detail detail)
  | Verification_unreadable { runtime_id; exit; stderr = _; reason } ->
    Printf.sprintf "Runtime %S verification returned no readable report (%s; %s)" runtime_id (exit_text exit) reason
  | Write_failed -> "Configuration could not be saved; previous configuration was restored."
  | Rollback_failed -> "Configuration restoration was incomplete; inspect the workspace before retrying."
  | Lock_unavailable -> "Another configuration operation is active; retry after it finishes."
let error_detail = function
  | Validation_failed { stderr; _ } | Verification_unreadable { stderr; _ } -> child_detail stderr
  | Invalid_selection | Invalid_configuration | Changed_configuration | Configuration_unavailable
  | Child_not_started _ | Verification_failed _ | Write_failed | Rollback_failed | Lock_unavailable -> None
let revision_to_string (Revision value) = value
let revision_of_string value =
  if String.length value = 64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
  then Ok (Revision value) else Error Changed_configuration
let safe_id value = value <> "" && String.trim value = value
  && not (String.exists (function '\000'..'\031'|'\127' -> true | _ -> false) value)
let unique values = List.fold_left (fun acc v -> if List.mem v acc then acc else acc @ [v]) [] values
let paths base =
  let config = Filename.concat (Common.masc_dir_from_base_path ~base_path:base) "config" in
  config, Filename.concat config Config_dir_resolver.runtime_toml_filename
let read root path =
  match Fs_compat.load_owned_regular_file_with_snapshot ~ownership_root:root path with
  | Ok value -> Ok value | Error _ -> Error Configuration_unavailable
let snapshot base =
  let root,runtime = paths base in
  let* first = read root runtime in
  match first with None -> Error Configuration_unavailable | Some _ -> Ok first
let content = function None -> "" | Some (file:Fs_compat.owned_regular_file_contents) -> file.content
let revision first =
  let item = function None -> `Null | Some (file:Fs_compat.owned_regular_file_contents) -> `String file.content in
  Revision (Digestif.SHA256.(to_hex (digest_string (Yojson.Safe.to_string (`List [item first])))))
let same_file a b = match a,b with
  | None,None -> true
  | Some (a:Fs_compat.owned_regular_file_contents),Some (b:Fs_compat.owned_regular_file_contents) -> a.content=b.content
    && Fs_compat.equal_owned_regular_file_snapshot a.snapshot b.snapshot
  | _ -> false
let same a c = same_file a c
let io action = try action () with Unix.Unix_error _ | Sys_error _ -> Error Configuration_unavailable
let observe_inventory ~base_path = io (fun () ->
  let base=Unix.realpath base_path in
  let* files=snapshot base in
  let _,path=paths base in
  Ok (revision files,Runtime.config_observation ~path (content files)))
let observe ~base_path = observe_inventory ~base_path |> Result.map fst
let stage_env base =
  let config,_ = paths base in
  let replaced = ["MASC_BASE_PATH";"MASC_CONFIG_DIR"] in
  let kept = Unix.environment () |> Array.to_list |> List.filter (fun value ->
    let key = match String.index_opt value '=' with None -> value | Some n -> String.sub value 0 n in
    not (List.mem key replaced)) in
  Array.of_list (kept @ ["MASC_BASE_PATH="^base;"MASC_CONFIG_DIR="^config])
type child = { status : Unix.process_status; stdout : string; stderr : string }
let run ~binary ~base args =
  match Process_eio.run_argv_with_status_split_or_refusal ~env:(stage_env base)
          (binary :: args) with
  | Ok (status,stdout,stderr) -> Ok { status; stdout; stderr }
  | Error refusal -> Error (Child_not_started refusal)
let validate ~binary ~base args =
  let* child = run ~binary ~base args in
  match child.status with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error (Validation_failed { exit = child.status; stderr = child.stderr })
(* The child's report is the judge, read back through the same module that
   wrote it; the exit status only has to agree with a verified report. *)
let verification ~binary ~base id =
  let* child = run ~binary ~base ["runtime-verify";"--base-path";base;id] in
  let unreadable reason =
    Error (Verification_unreadable { runtime_id = id; exit = child.status; stderr = child.stderr; reason }) in
  let report = match Yojson.Safe.from_string child.stdout with
    | json -> Runtime_verification.of_json json
    | exception Yojson.Json_error reason -> Error ("stdout is not JSON: " ^ reason) in
  match report with
  | Error reason -> unreadable reason
  | Ok (Runtime_verification.Measured result) when not (String.equal result.Runtime_verification.runtime_id id) ->
    unreadable (Printf.sprintf "the report names runtime %S" result.Runtime_verification.runtime_id)
  | Ok (Runtime_verification.Unmeasured { Runtime_verification.runtime_id; _ }) when not (String.equal runtime_id id) ->
    unreadable (Printf.sprintf "the report names runtime %S" runtime_id)
  | Ok (Runtime_verification.Measured { Runtime_verification.failure = None; _ }) ->
    (match child.status with
     | Unix.WEXITED 0 -> Ok ()
     | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> unreadable "a verified report with a failing exit")
  | Ok (Runtime_verification.Measured { Runtime_verification.failure = Some failure; _ }) ->
    Error (Verification_failed { runtime_id = id; code = Runtime_verification.failure_code failure;
                                 message = Runtime_verification.failure_message failure;
                                 detail = Runtime_verification.failure_detail failure })
  | Ok (Runtime_verification.Unmeasured { Runtime_verification.code; detail; message; runtime_id = _ }) ->
    Error (Verification_failed { runtime_id = id; code; message; detail })
let write path mode text =
  Fs_compat.write_file_atomic_strict_staged path ~write:(fun channel ->
    Unix.fchmod (Unix.descr_of_out_channel channel) mode;
    output_string channel text)
let mode = function None -> 0o600 | Some (file:Fs_compat.owned_regular_file_contents) -> file.snapshot.permissions
let with_stage action =
  Eio.Switch.run (fun sw ->
    let root = Filename.temp_dir "masc-runtime-setup-" "" |> Unix.realpath in
    Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree root);
    let masc = Common.masc_dir_from_base_path ~base_path:root in
    Unix.mkdir masc 0o700;
    Unix.mkdir (Filename.concat masc "config") 0o700;
    action root)
let remove_and_sync path =
  Eio_unix.run_in_systhread (fun () ->
    let directory = Unix.openfile (Filename.dirname path) [Unix.O_RDONLY;Unix.O_CLOEXEC] 0 in
    (* Synchronous descriptor settlement in the blocking system thread. *)
    Fun.protect ~finally:(fun () -> Unix.close directory) (fun () ->
      Unix.unlink path;
      Unix.fsync directory))
let publish_using ~(write:string -> int -> string -> (unit,Fs_compat.atomic_replace_failure) result) changes =
  let rec restore = function
    | [] -> true
    | (path,original)::rest ->
      let restored = try match original with
        | None -> remove_and_sync path; true
        | Some file -> (match write path (mode original) file.Fs_compat.content with Ok () -> true | Error _ -> false)
        with Unix.Unix_error _ | Sys_error _ -> false in
      let remaining = restore rest in restored && remaining in
  let rec commit written = function
    | [] -> Ok ()
    | (path,original,text)::rest ->
      match write path (mode original) text with
      | Ok () -> commit ((path,original)::written) rest
      | Error failure ->
        let written = match failure.Fs_compat.stage with
          | Fs_compat.Before_rename -> written
          | Fs_compat.After_rename -> (path,original)::written in
        if restore written then Error Write_failed else Error Rollback_failed in
  (* Cancellation cannot interrupt the two replacements or their rollback. *)
  Eio.Cancel.protect (fun () -> commit [] changes)
let configure_locked ~pending_credentials ~binary ~base ~expected_revision ~specs ~selected ~verify =
  let* original = snapshot base in
  if revision original <> expected_revision then Error Changed_configuration else
  let first = original in
  let* parsed = match Runtime_toml.parse_string (content first) with
    | Ok value -> Ok value | Error _ -> Error Invalid_configuration in
  let existing = List.map Runtime.id_of_binding parsed.Runtime_schema.bindings in
  let rendered = List.map Runtime_setup_spec.render specs in
  let additions = List.fold_left (fun acc (row:Runtime_setup_spec.rendered) ->
    if List.mem row.runtime_id existing || List.exists (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id=row.runtime_id) acc
    then acc else acc @ [row]) [] rendered in
  let available = existing @ List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id) additions in
  if not (List.for_all (fun id -> List.mem id available) selected) then Error Invalid_selection else
  let added = String.concat "" (List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_toml) additions) in
  let runtime_text = content first ^ (if added="" then "" else "\n" ^ added) in
  let* validated = with_stage (fun stage ->
    let _,runtime = paths stage in
    let stage_write path text = match write path 0o600 text with
      | Ok () -> Ok () | Error _ -> Error Configuration_unavailable in
    let* () = stage_write runtime runtime_text in
    match selected with
    | [] -> Error Invalid_selection
    | primary::fallbacks ->
      let args = ["runtime-default-set";"--base-path";stage;primary;"--setup-lanes";"--setup-imp"]
        @ List.concat_map (fun id -> ["--fallback-runtime";id]) fallbacks in
      let* () = validate ~binary ~base:stage args in
      let rec probes = function [] -> Ok () | id::tail -> let* () = verification ~binary ~base:stage id in probes tail in
      let* () = if verify then probes selected else Ok () in
      let* files = snapshot stage in Ok (content files)) in
  let* current = snapshot base in
  if not (same original current) then Error Changed_configuration else
  let _,runtime = paths base in
  let changes = [runtime,first,validated] in
  let* () = Eio.Cancel.protect (fun () ->
    let* () = publish_using ~write changes in
    List.iter Runtime_setup_credentials.retain pending_credentials;
    Ok ()) in
  match selected with
  | [] -> Error Invalid_selection
  | primary::_ -> Ok {runtime_id=primary;runtime_ids=selected;
      models=List.map Runtime_setup_spec.model_id specs; readiness=(if verify then Verified else Not_probed)}
let configure ?(pending_credentials=[]) ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify () =
  if runtime_ids=[] || not (List.for_all safe_id runtime_ids)
     || not (List.mem default_runtime_id runtime_ids) then Error Invalid_selection else
  io (fun () ->
    let base = Unix.realpath base_path and binary = Unix.realpath binary in
    let _,runtime = paths base in
    let selected = default_runtime_id :: List.filter ((<>) default_runtime_id) (unique runtime_ids) in
    (* Keep typed operation failures separate from the lock's string diagnostics. *)
    match Runtime.with_config_lock ~runtime_config_path:runtime (fun () ->
      Ok (configure_locked ~pending_credentials ~binary ~base ~expected_revision ~specs ~selected ~verify)) with
    | Ok result -> result | Error _ -> Error Lock_unavailable)
let receipt_json receipt = `Assoc [
  "runtime_id",`String receipt.runtime_id;
  "runtime_ids",`List (List.map (fun s -> `String s) receipt.runtime_ids);
  "models",`List (List.map (fun s -> `String s) receipt.models);
  "configured",`Bool true;"validation",`String "passed";
  "readiness",`String (match receipt.readiness with Verified -> "verified" | Not_probed -> "not_probed")]

module For_testing = struct
  let publish ~replace ~files =
    let rec originals = function
      | [] -> Ok []
      | (path,text)::rest ->
        let* original = read (Filename.dirname path) path in
        let* tail = originals rest in Ok ((path,original,text)::tail) in
    let* changes = originals files in
    publish_using ~write:replace changes
end
