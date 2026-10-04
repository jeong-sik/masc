type revision = Revision of string
type error = Invalid_selection | Invalid_configuration | Changed_configuration
  | Configuration_unavailable
  | Child_not_started of Process_eio.spawn_refusal
  | Validation_failed of { exit : Unix.process_status; stderr : string }
  | Commit_refused of string
  | Verification_failed of { runtime_id : string; code : string; message : string; detail : string option }
  | Verification_unreadable of { runtime_id : string; exit : Unix.process_status; stderr : string; reason : string }
  | Write_failed of string | Lock_unavailable
type usage_limited = { runtime_id : string; code : string }
type readiness =
  | Not_probed
  | Verified
  | Usage_limited of usage_limited * usage_limited list
  | Partly_checked of { limited : usage_limited list; not_rechecked : string list }
type receipt = { runtime_id:string; runtime_ids:string list; models:string list;
                 readiness:readiness; commit:Runtime.config_commit_receipt }
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
  (* The staged child validated this same text, so a refusal here means the
     commit's validation disagrees with the child's -- an operator-fixable
     configuration problem, not a write failure. The reason stays in
     {!error_detail}: like the child's stderr it can run to several lines the
     setup screen would drop. *)
  | Commit_refused _ ->
    "Selected runtime configuration did not pass the final commit validation"
  | Verification_failed { runtime_id; code; detail } ->
    Printf.sprintf "Runtime %S did not pass response and tool verification (%s)%s" runtime_id code (with_detail detail)
  | Verification_unreadable { runtime_id; exit; stderr = _; reason } ->
    Printf.sprintf "Runtime %S verification returned no readable report (%s; %s)" runtime_id (exit_text exit) reason
  | Write_failed _ -> "Configuration could not be saved; the previous configuration is unchanged."
  | Lock_unavailable -> "Another configuration operation is active; retry after it finishes."
let error_detail = function
  | Validation_failed { stderr; _ } | Verification_unreadable { stderr; _ } -> child_detail stderr
  | Commit_refused reason | Write_failed reason -> child_detail reason
  | Invalid_selection | Invalid_configuration | Changed_configuration | Configuration_unavailable
  | Child_not_started _ | Verification_failed _ | Lock_unavailable -> None
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
(* A spent quota or a rate limit is the provider answering for the account and
   declining for its usage. The probe could not show the response and tool
   path, but nothing says the selection is wrong, so the runtime is published
   and reported unmeasured. Every other failure refuses the save. *)
let usage_limit (failure : Runtime_verification.failure) =
  match failure with
  | Runtime_verification.(Rate_limited _ | Quota_exhausted _) -> true
  | Runtime_verification.(Unavailable _ | Provider_overloaded _ | Provider_auth_refused _
    | Provider_unreachable _ | Model_not_found _ | Provider_rejected _ | Timed_out
    | Tool_not_called | Tool_result_not_consumed | Empty_response | Model_unreported) -> false
type probe = Probe_verified | Probe_usage_limited of usage_limited
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
     | Unix.WEXITED 0 -> Ok Probe_verified
     | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> unreadable "a verified report with a failing exit")
  | Ok (Runtime_verification.Measured { Runtime_verification.failure = Some failure; _ }) ->
    let code = Runtime_verification.failure_code failure
    and message = Runtime_verification.failure_message failure
    and detail = Runtime_verification.failure_detail failure in
    if usage_limit failure then Ok (Probe_usage_limited { runtime_id = id; code })
    else Error (Verification_failed { runtime_id = id; code; message; detail })
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
(* A runtime already bound in runtime.toml is not called again just because it
   sits in the selected chain: its result would not change what this save
   writes. Two kinds are probed: runtimes this save adds, and the runtime that
   becomes the chain's first call when it was not the first call before. *)
let needs_probe ~existing ~previous_primary ~primary selected =
  List.filter (fun id ->
    not (List.mem id existing)
    || (String.equal id primary && previous_primary <> Some id)) selected

let configure_locked ~replace_file ~pending_credentials ~default_lane_id ~binary ~base ~expected_revision ~specs ~selected ~verify =
  let* original = snapshot base in
  if revision original <> expected_revision then Error Changed_configuration else
  let first = original in
  let* parsed = match Runtime_toml.parse_string (content first) with
    | Ok value -> Ok value | Error _ -> Error Invalid_configuration in
  let* () = match default_lane_id with
    | None -> Ok ()
    | Some lane_id ->
      if parsed.Runtime_schema.default_runtime_id = Some lane_id
         && List.exists (fun (lane:Runtime_schema.lane_decl) -> String.equal lane.id lane_id) parsed.lane_decls
      then Ok () else Error Invalid_selection in
  let rec resolve_specs = function
    | [] -> Ok []
    | spec :: rest ->
      let* spec = Runtime_setup_spec.resolve_provider spec parsed.providers
        |> Result.map_error (fun _ -> Invalid_selection) in
      let* rest = resolve_specs rest in Ok (spec :: rest) in
  let* specs = resolve_specs specs in
  let existing = List.map Runtime_instance.id_of_binding parsed.Runtime_schema.bindings in
  let previous_primary = match default_lane_id with
    | None -> parsed.Runtime_schema.default_runtime_id
    | Some lane_id ->
      List.find_map (fun (lane:Runtime_schema.lane_decl) ->
        if String.equal lane.id lane_id then List.nth_opt lane.candidate_ids 0 else None)
        parsed.lane_decls in
  let providers = List.map (fun (provider:Runtime_schema.provider) -> provider.id) parsed.providers in
  let bound_providers = List.filter_map (fun (binding:Runtime_schema.binding) ->
    if binding.enabled then Some binding.provider_id else None) parsed.bindings in
  (* One account has one provider section, even when this save selects several
     models or context variants. Subsequent saves append only their new model
     and binding; existing provider settings remain the operator's values. *)
  let _, _, added_providers, additions = List.fold_left (fun (providers, bound_providers, added_providers, acc) spec ->
    let provider = Runtime_setup_spec.provider_id spec in
    let row = Runtime_setup_spec.render
        ~include_provider:(not (List.mem provider providers))
        ~wizard_default:(not (List.mem provider bound_providers)) spec in
    if List.mem row.runtime_id existing || List.exists (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id=row.runtime_id) acc
    then providers, bound_providers, added_providers, acc
    else provider :: providers, provider :: bound_providers, provider :: added_providers, acc @ [row])
      (providers, bound_providers, [], []) specs in
  let available = existing @ List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_id) additions in
  if not (List.for_all (fun id -> List.mem id available) selected) then Error Invalid_selection else
  let added = String.concat "" (List.map (fun (r:Runtime_setup_spec.rendered) -> r.runtime_toml) additions) in
  (* Freeze the wizard's already resolved choice before adding candidates.
     A sole enabled binding (or the provider-owned workspace default) was a
     real choice without a flag; expansion must not make it ambiguous. *)
  let* preserved = List.fold_left (fun result (provider:Runtime_schema.provider) ->
    let* text = result in
    if not (List.mem provider.id added_providers) then Ok text else
    match Runtime_wizard_inventory.binding_for_provider parsed provider with
    | Ok binding when not binding.wizard_default ->
        Toml_line_editor.edit_nested_bool text ~path:[binding.provider_id; binding.model_id]
          ~key:"wizard-default" ~value:true
        |> Result.map_error (fun _ -> Invalid_configuration)
    | Ok _ | Error _ -> Ok text) (Ok (content first)) parsed.providers in
  let runtime_text = preserved ^ (if added="" then "" else "\n" ^ added) in
  let runtime_text = match default_lane_id with
    | None -> runtime_text
    | Some lane_id -> Toml_line_editor.edit_table_multiline_array runtime_text
        ~path:(Runtime_toml_namespace.(path Runtime) ("lanes." ^ Toml_line_editor.render_key lane_id))
        ~key:"candidates" ~values:selected in
  let* (validated, readiness) = with_stage (fun stage ->
    let _,runtime = paths stage in
    let stage_write path text = match write path 0o600 text with
      | Ok () -> Ok () | Error _ -> Error Configuration_unavailable in
    let* () = stage_write runtime runtime_text in
    match selected with
    | [] -> Error Invalid_selection
    | primary::fallbacks ->
      let args = match default_lane_id with
        | Some lane_id -> ["runtime-default-set";"--base-path";stage;lane_id]
        | None -> ["runtime-default-set";"--base-path";stage;primary;"--setup-lanes";"--setup-imp"]
          @ List.concat_map (fun id -> ["--fallback-runtime";id]) fallbacks in
      let* () = validate ~binary ~base:stage args in
      let rec probes limited = function
        | [] -> Ok (List.rev limited)
        | id::tail ->
          let* probe = verification ~binary ~base:stage id in
          probes (match probe with Probe_verified -> limited | Probe_usage_limited row -> row :: limited) tail in
      let* readiness =
        if not verify then Ok Not_probed else
        let to_probe = needs_probe ~existing ~previous_primary ~primary selected in
        let not_rechecked = List.filter (fun id -> not (List.mem id to_probe)) selected in
        let* limited = probes [] to_probe in
        Ok (match limited, not_rechecked with
          | [], [] -> Verified
          | first :: rest, [] -> Usage_limited (first, rest)
          | _, _ :: _ -> Partly_checked { limited; not_rechecked }) in
      let* files = snapshot stage in Ok (content files, readiness)) in
  let* current = snapshot base in
  if not (same original current) then Error Changed_configuration else
  let _,runtime = paths base in
  (* The write goes through the same commit every routing edit uses, so the
     registry this process serves carries the account the moment the rename
     lands; a plain file replacement here left the published runtime list at
     its boot-time snapshot until a restart (task-2054). The staged child
     validated this text; the commit re-runs the same validation in-process.
     [first] keeps the file's original mode on the replacement. *)
  let* commit = Eio.Cancel.protect (fun () ->
    let* receipt =
      Runtime.commit_config_text_locked
        ~replace_file:(fun path text -> replace_file path (mode first) text)
        ~runtime_config_path:runtime validated
      |> Result.map_error (function
          | Runtime.Config_commit_refused reason -> Commit_refused reason
          | Runtime.Config_commit_write_failed failure ->
            Write_failed (Fs_compat.atomic_replace_failure_to_string failure)) in
    List.iter Runtime_setup_credentials.retain pending_credentials;
    Ok receipt) in
  match selected with
  | [] -> Error Invalid_selection
  | primary::_ ->
    let runtime_id = match default_lane_id with Some lane_id -> lane_id | None -> primary in
    Ok {runtime_id;runtime_ids=selected;
      models=List.map Runtime_setup_spec.model_id specs; readiness; commit}
let configure_with_replace_file ~with_lock ~replace_file ?(pending_credentials=[]) ?default_lane_id ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify () =
  if runtime_ids=[] || not (List.for_all safe_id runtime_ids)
     || not (List.mem default_runtime_id runtime_ids) then Error Invalid_selection else
  io (fun () ->
    let base = Unix.realpath base_path and binary = Unix.realpath binary in
    let _,runtime = paths base in
    let selected = default_runtime_id :: List.filter ((<>) default_runtime_id) (unique runtime_ids) in
    (* Keep typed operation failures separate from the lock's string diagnostics. *)
    match with_lock ~runtime_config_path:runtime (fun () ->
      configure_locked ~replace_file ~pending_credentials ~default_lane_id ~binary ~base ~expected_revision ~specs ~selected ~verify) with
    | Ok {Runtime.value=Ok receipt; warnings} ->
        Ok {receipt with commit=Runtime.attach_lock_warnings warnings receipt.commit}
    | Ok {Runtime.value=Error error; _} -> Error error
    | Error _ -> Error Lock_unavailable)
let configure ?pending_credentials ?default_lane_id ~binary ~base_path ~expected_revision
    ~specs ~runtime_ids ~default_runtime_id ~verify () =
  configure_with_replace_file ~with_lock:Runtime.with_config_lock_observed ~replace_file:write ?pending_credentials ?default_lane_id
    ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify ()
let usage_limited_json (row : usage_limited) = `Assoc [
  "runtime_id",`String row.runtime_id;"code",`String row.code]
let receipt_json receipt = `Assoc ([
  "runtime_id",`String receipt.runtime_id;
  "runtime_ids",`List (List.map (fun s -> `String s) receipt.runtime_ids);
  "models",`List (List.map (fun s -> `String s) receipt.models);
  "configured",`Bool true;"validation",`String "passed";
  "commit",`Assoc [
    "source_revision",`String (Runtime.config_source_revision_to_string receipt.commit.observation.source_revision);
    "order",`String (Runtime.config_commit_order_to_string receipt.commit.order);
    "durability",`String (match receipt.commit.durability with Runtime.Durable -> "durable" | Durability_unconfirmed _ -> "unconfirmed");
    "warnings",`List (List.map (function Runtime.Config_lock_release_unconfirmed _ ->
      `Assoc ["code",`String "runtime_config_lock_release_unconfirmed"]) receipt.commit.lock_warnings)]]
  @ match receipt.readiness with
    | Verified -> ["readiness",`String "verified"]
    | Not_probed -> ["readiness",`String "not_probed"]
    | Partly_checked { limited; not_rechecked } -> ["readiness",`String "partly_checked";
        "unverified",`List (List.map usage_limited_json limited);
        "not_rechecked",`List (List.map (fun id -> `String id) not_rechecked)]
    | Usage_limited (first, rest) -> ["readiness",`String "usage_limited";
        "unverified",`List (List.map usage_limited_json (first :: rest))])

module For_testing = struct
  let configure ?release_failure ~replace_file ?pending_credentials ?default_lane_id
      ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify () =
    let with_lock = match release_failure with
      | None -> Runtime.with_config_lock_observed
      | Some release_failure -> Runtime.For_testing.with_config_lock_observed_with_release_failure ~release_failure in
    configure_with_replace_file ~with_lock ~replace_file ?pending_credentials ?default_lane_id
      ~binary ~base_path ~expected_revision ~specs ~runtime_ids ~default_runtime_id ~verify ()
end
