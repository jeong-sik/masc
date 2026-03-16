(** Worker_container — Worker state machine, meta serialization, checkpoint/turn-log persistence, and file path management. *)

open Printf

type worker_container_state =
  | Worker_missing
  | Worker_pending
  | Worker_ready

type tool_profile =
  | Profile_session_min
  | Profile_session_dev

type shell_profile =
  | Shell_none
  | Shell_readonly
  | Shell_dev

type worker_container_meta = {
  version : int;
  worker_name : string;
  mcp_session_id : string;
  team_session_id : string option;
  workspace_path : string;
  role : string option;
  selection_note : string option;
  execution_scope : Team_session_types.execution_scope;
  thinking_enabled : bool option;
  max_turns_override : int option;
  timeout_seconds : int option;
  tool_profile : tool_profile;
  shell_profile : shell_profile;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
  effective_model : string;
  effective_tier : Team_session_types.model_tier option;
  checkpoint_path : string;
  turn_log_path : string;
  last_run_at : float option;
}

let worker_container_version = 1

let configured_backend () =
  match Sys.getenv_opt "MASC_LOCAL_WORKER_BACKEND" with
  | Some raw when String.lowercase_ascii (String.trim raw) = "legacy" -> `Legacy
  | _ -> `Oas

let tool_profile_to_string = function
  | Profile_session_min -> "session_min"
  | Profile_session_dev -> "session_dev"

let tool_profile_of_string = function
  | "session_min" -> Some Profile_session_min
  | "session_dev" -> Some Profile_session_dev
  | _ -> None

let shell_profile_to_string = function
  | Shell_none -> "none"
  | Shell_readonly -> "readonly"
  | Shell_dev -> "dev"

let shell_profile_of_string = function
  | "none" -> Some Shell_none
  | "readonly" -> Some Shell_readonly
  | "dev" -> Some Shell_dev
  | _ -> None

let worker_container_root ~base_path ~(team_session_id : string option) =
  match team_session_id with
  | Some session_id ->
      Filename.concat
        (Filename.concat
           (Filename.concat (Filename.concat base_path ".masc") "team-sessions")
           session_id)
        "workers"
  | None ->
      Filename.concat (Filename.concat base_path ".masc") "local-workers"

let safe_worker_token worker_name =
  worker_name
  |> String.to_seq
  |> Seq.map (function
       | ('a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.') as ch -> ch
       | _ -> '_')
  |> String.of_seq

let worker_container_dir ~base_path ~(team_session_id : string option)
    ~worker_name =
  Filename.concat
    (worker_container_root ~base_path ~team_session_id)
    (safe_worker_token worker_name)

let worker_meta_path ~base_path ~team_session_id ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~team_session_id ~worker_name)
    "meta.json"

let worker_checkpoint_path ~base_path ~team_session_id ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~team_session_id ~worker_name)
    "checkpoint.json"

let worker_turn_log_path ~base_path ~team_session_id ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~team_session_id ~worker_name)
    "turns.jsonl"

let worker_raw_trace_path ~base_path ~team_session_id ~worker_name =
  Filename.concat
    (worker_container_dir ~base_path ~team_session_id ~worker_name)
    "raw-trace.jsonl"

let oas_trace_session_root ~base_path =
  Filename.concat (Filename.concat base_path ".masc") "oas-runtime"

let ensure_worker_container_dirs ~base_path ~team_session_id ~worker_name =
  let dir = worker_container_dir ~base_path ~team_session_id ~worker_name in
  Team_session_store.write_text_file (Filename.concat dir ".keep") "";
  (try Sys.remove (Filename.concat dir ".keep") with Sys_error _ -> ())

let stable_worker_session_id ?team_session_id worker_name =
  let basis =
    String.concat "\n"
      [
        worker_name;
        Option.value ~default:"global" team_session_id;
      ]
  in
  let digest = Digest.string basis |> Digest.to_hex in
  sprintf "worker-%s" (String.sub digest 0 12)

let oas_worker_evidence_session_id ~worker_run_id =
  String.trim worker_run_id

let evidence_session_id_of_worker_run = function
  | Some worker_run_id when String.trim worker_run_id <> "" ->
      Some (oas_worker_evidence_session_id ~worker_run_id)
  | _ -> None

let session_min_tool_names =
  Agent_tool_surfaces.llama_worker_tool_names

let execution_scope_or_default = function
  | Some scope -> scope
  | None -> Team_session_types.Limited_code_change

let infer_model_tier_from_model_name model_name =
  let model_name = String.trim model_name in
  let haystack = String.lowercase_ascii model_name in
  let contains needle =
    let needle = String.lowercase_ascii needle in
    let needle_len = String.length needle in
    let haystack_len = String.length haystack in
    let rec loop idx =
      if needle_len = 0 then true
      else if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0
  in
  if model_name = "" then
    None
  else if contains "35b" then
      Some Team_session_types.Tier_35b
  else if contains "27b" then
      Some Team_session_types.Tier_27b
  else if contains "9b" then
      Some Team_session_types.Tier_9b
  else
    None

let worker_profiles_of_scope scope =
  match scope with
  | Team_session_types.Observe_only ->
      (Profile_session_min, Shell_readonly)
  | Team_session_types.Limited_code_change ->
      (Profile_session_dev, Shell_dev)

let derive_effective_tier worker_size model_id =
  match worker_size with
  | Some size -> Team_session_types.model_tier_of_worker_size size
  | None -> infer_model_tier_from_model_name model_id

let effective_worker_size worker_size model_id =
  match worker_size with
  | Some _ as explicit -> explicit
  | None ->
      Option.bind
        (infer_model_tier_from_model_name model_id)
        Team_session_types.worker_size_of_model_tier

let worker_meta_to_yojson (meta : worker_container_meta) =
  `Assoc
    [
      ("version", `Int meta.version);
      ("worker_name", `String meta.worker_name);
      ("mcp_session_id", `String meta.mcp_session_id);
      ( "team_session_id",
        Option.fold ~none:`Null ~some:(fun s -> `String s) meta.team_session_id
      );
      ("workspace_path", `String meta.workspace_path);
      ("role", Option.fold ~none:`Null ~some:(fun s -> `String s) meta.role);
      ( "selection_note",
        Option.fold ~none:`Null ~some:(fun s -> `String s) meta.selection_note
      );
      ( "execution_scope",
        `String
          (Team_session_types.execution_scope_to_string meta.execution_scope) );
      ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) meta.thinking_enabled);
      ("max_turns_override", Option.fold ~none:`Null ~some:(fun n -> `Int n) meta.max_turns_override);
      ("timeout_seconds", Option.fold ~none:`Null ~some:(fun n -> `Int n) meta.timeout_seconds);
      ("tool_profile", `String (tool_profile_to_string meta.tool_profile));
      ("shell_profile", `String (shell_profile_to_string meta.shell_profile));
      ( "worker_class",
        Option.fold ~none:`Null
          ~some:(fun kind ->
            `String (Team_session_types.worker_class_to_string kind))
          meta.worker_class );
      ( "worker_size",
        Option.fold ~none:`Null
          ~some:(fun size ->
            `String (Team_session_types.worker_size_to_string size))
          meta.worker_size );
      ("effective_model", `String meta.effective_model);
      ( "effective_tier",
        Option.fold ~none:`Null
          ~some:(fun tier ->
            `String (Team_session_types.model_tier_to_string tier))
          meta.effective_tier );
      ("checkpoint_path", `String meta.checkpoint_path);
      ("turn_log_path", `String meta.turn_log_path);
      ( "last_run_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts) meta.last_run_at );
    ]

let worker_meta_of_yojson json =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc _ -> (
      match json |> member "worker_name" |> to_string_option with
      | None -> None
      | Some worker_name ->
          let execution_scope =
            json |> member "execution_scope" |> to_string_option
            |> Option.map (fun value ->
                   Team_session_types.execution_scope_of_string
                     (String.lowercase_ascii (String.trim value)))
            |> execution_scope_or_default
          in
          Some
            {
              version =
                json |> member "version" |> to_int_option
                |> Option.value ~default:worker_container_version;
              worker_name;
              mcp_session_id =
                json |> member "mcp_session_id" |> to_string_option
                |> Option.value ~default:(stable_worker_session_id worker_name);
              team_session_id =
                json |> member "team_session_id" |> to_string_option;
              workspace_path =
                json |> member "workspace_path" |> to_string_option
                |> Option.value ~default:"";
              role = json |> member "role" |> to_string_option;
              selection_note =
                json |> member "selection_note" |> to_string_option;
              execution_scope;
              thinking_enabled =
                json |> member "thinking_enabled" |> to_bool_option;
              max_turns_override =
                json |> member "max_turns_override" |> to_int_option;
              timeout_seconds =
                json |> member "timeout_seconds" |> to_int_option;
              tool_profile =
                (match json |> member "tool_profile" |> to_string_option with
                | Some value -> (
                    match tool_profile_of_string value with
                    | Some profile -> profile
                    | None -> fst (worker_profiles_of_scope execution_scope))
                | None -> fst (worker_profiles_of_scope execution_scope));
              shell_profile =
                (match json |> member "shell_profile" |> to_string_option with
                | Some value -> (
                    match shell_profile_of_string value with
                    | Some profile -> profile
                    | None -> snd (worker_profiles_of_scope execution_scope))
                | None -> snd (worker_profiles_of_scope execution_scope));
              worker_class =
                (match json |> member "worker_class" |> to_string_option with
                | Some value ->
                    Team_session_types.worker_class_of_string
                      (String.lowercase_ascii (String.trim value))
                | None -> None);
              worker_size =
                (match json |> member "worker_size" |> to_string_option with
                | Some value ->
                    Team_session_types.worker_size_of_string
                      (String.lowercase_ascii (String.trim value))
                | None -> None);
              effective_model =
                json |> member "effective_model" |> to_string_option
                |> Option.value ~default:"";
              effective_tier =
                (match json |> member "effective_tier" |> to_string_option with
                | Some value ->
                    Team_session_types.model_tier_of_string
                      (String.lowercase_ascii (String.trim value))
                | None -> None);
              checkpoint_path =
                json |> member "checkpoint_path" |> to_string_option
                |> Option.value ~default:"";
              turn_log_path =
                json |> member "turn_log_path" |> to_string_option
                |> Option.value ~default:"";
              last_run_at = json |> member "last_run_at" |> to_float_option;
            })
  | _ -> None

let load_worker_meta ~base_path ~team_session_id ~worker_name =
  let path = worker_meta_path ~base_path ~team_session_id ~worker_name in
  if Sys.file_exists path then
    try
      Yojson.Safe.from_file path |> worker_meta_of_yojson
    with Yojson.Json_error _ | Sys_error _ -> None
  else
    None

let save_worker_meta ~base_path ~team_session_id ~worker_name
    (meta : worker_container_meta) =
  try
    ensure_worker_container_dirs ~base_path ~team_session_id ~worker_name;
    Team_session_store.write_text_file
      (worker_meta_path ~base_path ~team_session_id ~worker_name)
      (meta |> worker_meta_to_yojson |> Yojson.Safe.pretty_to_string);
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to save worker meta for %s: %s" worker_name msg)

let get_worker_container_state ~base_path ~team_session_id ~worker_name =
  let meta_exists =
    Sys.file_exists (worker_meta_path ~base_path ~team_session_id ~worker_name)
  in
  let checkpoint_exists =
    Sys.file_exists
      (worker_checkpoint_path ~base_path ~team_session_id ~worker_name)
  in
  match meta_exists, checkpoint_exists with
  | false, false -> Worker_missing
  | _, true -> Worker_ready
  | true, false -> Worker_pending

let load_worker_checkpoint ~base_path ~team_session_id ~worker_name =
  let path =
    worker_checkpoint_path ~base_path ~team_session_id ~worker_name
  in
  if Sys.file_exists path then
    try
      let raw = In_channel.with_open_text path In_channel.input_all in
      Agent_sdk.Checkpoint.of_string raw |> Result.to_option
    with Sys_error _ -> None
  else
    None

let save_worker_checkpoint ~base_path ~team_session_id ~worker_name checkpoint =
  try
    ensure_worker_container_dirs ~base_path ~team_session_id ~worker_name;
    Team_session_store.write_text_file
      (worker_checkpoint_path ~base_path ~team_session_id ~worker_name)
      (Agent_sdk.Checkpoint.to_string checkpoint);
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to save worker checkpoint for %s: %s" worker_name msg)

let append_worker_turn_log ~base_path ~team_session_id ~worker_name json =
  try
    ensure_worker_container_dirs ~base_path ~team_session_id ~worker_name;
    Team_session_store.append_text_file
      (worker_turn_log_path ~base_path ~team_session_id ~worker_name)
      (Yojson.Safe.to_string json ^ "\n");
    Ok ()
  with Sys_error msg ->
    Error
      (sprintf "failed to append worker turn log for %s: %s" worker_name msg)

let resolved_mcp_session_id ~base_path ~team_session_id ~worker_name =
  match load_worker_meta ~base_path ~team_session_id ~worker_name with
  | Some meta when String.trim meta.mcp_session_id <> "" -> meta.mcp_session_id
  | _ -> stable_worker_session_id ?team_session_id worker_name
