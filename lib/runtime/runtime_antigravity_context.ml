(* Which subprocess step of an observation refused to complete. Every
   [Command_failed] names one, so the setup receipt can say where the
   observation stopped instead of "did not complete". *)
type phase =
  | Observation_deadline of float
  | Executable_lookup of string
  | Version_probe
  | Status_transport
  | Transport_reported of transport_outcome

(* The two failure statuses the embedded transport script writes on exit 0.
   [captured] and [timed_out] are its two success shapes; anything else the
   script did not write, so it is an invalid observation, not a phase. *)
and transport_outcome =
  | Transport_failed
  | Transport_interrupted

type error =
  | Private_home_unavailable
  | Command_failed of
      { phase : phase
      ; status : Unix.process_status option
      ; stderr_tail : string
      }
  | Timed_out
  | Invalid_observation

(* The transport's stderr may carry a whole Python traceback; the receipt
   needs the last lines, which is where the exception text sits. *)
let stderr_tail_bytes = 512

(* Last [stderr_tail_bytes] of the trimmed text, starting on a UTF-8
   boundary so the receipt JSON never carries a cut glyph: continuation
   bytes (0b10xxxxxx) after the byte cut are skipped, at most three. *)
let stderr_tail stderr =
  let trimmed = String.trim stderr in
  let length = String.length trimmed in
  if length <= stderr_tail_bytes
  then trimmed
  else (
    let rec boundary index =
      if index < length && Char.code trimmed.[index] land 0xC0 = 0x80
      then boundary (index + 1)
      else index
    in
    let start = boundary (length - stderr_tail_bytes) in
    String.sub trimmed start (length - start))
;;

let command_failed ~phase ~status ~stderr =
  Command_failed { phase; status; stderr_tail = stderr_tail stderr }
;;

(* A spawn that never produced a child has no exit status; its refusal text
   takes the stderr slot so the receipt still says why nothing ran. *)
let command_refused ~phase refusal =
  command_failed ~phase ~status:None ~stderr:(Process_eio.spawn_refusal_to_string refusal)
;;

let phase_label = function
  | Observation_deadline timeout_s ->
    Printf.sprintf
      "the observation deadline check (timeout %.17g s is not a positive finite number)"
      timeout_s
  | Executable_lookup command ->
    Printf.sprintf "the executable lookup for %S (no regular executable file)" command
  | Version_probe -> "the CLI version probe"
  | Status_transport -> "the status-line transport"
  | Transport_reported Transport_failed ->
    "the status-line transport, which reported that the CLI produced no status line"
  | Transport_reported Transport_interrupted ->
    "the status-line transport, which reported that it was interrupted"
;;

let status_label = function
  | None -> "no child process started"
  | Some status -> With_process.status_to_string status
;;

let error_message = function
  | Private_home_unavailable ->
    "Antigravity's private context observation directory could not be prepared."
  | Command_failed { phase; status; stderr_tail } ->
    Printf.sprintf
      "Antigravity context observation did not complete during %s: %s%s. Check the \
       selected account and CLI."
      (phase_label phase)
      (status_label status)
      (if stderr_tail = "" then "" else "; stderr: " ^ stderr_tail)
  | Timed_out ->
    "Antigravity did not report its context window before the observation deadline."
  | Invalid_observation ->
    "Antigravity did not report a zero-turn context for the exact selected model and CLI \
     version."
;;

let ( let* ) = Result.bind

let parse_records ~model ~cli_version rows =
  List.fold_left
    (fun result row ->
       let* previous = result in
       let* observed =
         Runtime_antigravity_setup.parse_context
           ~model
           ~cli_version
           (Yojson.Safe.to_string row)
         |> Result.map_error (fun _ -> Invalid_observation)
       in
       match previous, observed with
       | Runtime_antigravity_setup.Unknown_context, value
       | value, Runtime_antigravity_setup.Unknown_context -> Ok value
       | Observed_context left, Observed_context right when left = right -> Ok previous
       | Observed_context _, Observed_context _ -> Error Invalid_observation)
    (Ok Runtime_antigravity_setup.Unknown_context)
    rows
;;

let parse_body ~model ~cli_version ~status ~stderr body =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string body in
    if json |> member "schema" <> `String "masc.antigravity_status_transport.v1"
    then Error Invalid_observation
    else (
      match json |> member "status" |> to_string_option with
      | Some "timed_out" -> Error Timed_out
      | Some "captured" ->
        let rows = json |> member "records" |> to_list in
        if rows = []
        then Error Invalid_observation
        else parse_records ~model ~cli_version rows
      | Some "failed" ->
        Error
          (command_failed
             ~phase:(Transport_reported Transport_failed)
             ~status:(Some status)
             ~stderr)
      | Some "interrupted" ->
        Error
          (command_failed
             ~phase:(Transport_reported Transport_interrupted)
             ~status:(Some status)
             ~stderr)
      | Some _ | None -> Error Invalid_observation)
  with
  | Yojson.Json_error _ | Type_error _ -> Error Invalid_observation
;;

(* The transport owns exit 0 for every status it can report, including the
   failure ones, so a non-zero exit is the shim itself dying (its own
   traceback on stderr) and never a parseable body. *)
let parse_transport ~model ~cli_version (status, body, stderr) =
  match status with
  | Unix.WEXITED 0 -> parse_body ~model ~cli_version ~status ~stderr body
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    Error (command_failed ~phase:Status_transport ~status:(Some status) ~stderr)
;;

let measure ~python_path ~cli_path ~timeout_s ~oauth_source ~model runtime_root =
  let* home =
    Runtime_antigravity_home.prepare
      ~runtime_root
      ~owner_leaf:"context-observation"
      ~oauth_source
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let home_dir = Runtime_antigravity_home.home_dir home in
  let script = Filename.concat runtime_root "status-transport.py" in
  let records = Filename.concat runtime_root "status-records.jsonl" in
  let* () =
    try
      Auth.save_private_text_file script Embedded_antigravity_context.script;
      Auth.save_private_text_file records "";
      Ok ()
    with
    | Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable
  in
  let invocation = [ python_path; "-I"; "-B"; script ] in
  let command =
    String.concat " " (List.map Filename.quote (invocation @ [ "--capture"; records ]))
  in
  let* () =
    Runtime_antigravity_home.write_context_observation_settings home ~command
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let* () =
    Runtime_antigravity_home.clear_mcp_config home
    |> Result.map_error (fun _ -> Private_home_unavailable)
  in
  let env = Runtime_antigravity.official_client_environment ~home_dir () in
  let key entry =
    match String.index_opt entry '=' with
    | None -> entry
    | Some i -> String.sub entry 0 i
  in
  let env =
    Array.to_list env
    |> List.filter (fun entry ->
      not (List.mem (key entry) [ "TERM"; "TMPDIR"; "TMP"; "TEMP"; "XDG_RUNTIME_DIR" ]))
  in
  let env = Array.of_list ("TERM=xterm-256color" :: ("TMPDIR=" ^ runtime_root) :: env) in
  (* Version exec replaces the transport process in its managed foreground
     group. The Python shim sets cwd even when the native Unix fallback cannot. *)
  let* cli_version =
    match
      Process_eio.run_argv_with_status_split_or_refusal
        ~timeout_sec:timeout_s
        ~env
        ~cwd:home_dir
        (invocation @ [ "--version-probe"; "--home"; home_dir; "--cli"; cli_path ])
    with
    | Ok (Unix.WEXITED 0, stdout, _) when String.trim stdout <> "" ->
      Ok (String.trim stdout)
    | Ok (status, _, stderr) ->
      Error (command_failed ~phase:Version_probe ~status:(Some status) ~stderr)
    | Error refusal -> Error (command_refused ~phase:Version_probe refusal)
  in
  (* The PTY transport itself owns its deadline and kills/reaps its unreaped
     child group before returning. An outer kill timeout could orphan that
     separate session, so do not add one here. *)
  match
    Process_eio.run_argv_with_status_split_or_refusal
      ~env
      ~cwd:home_dir
      (invocation
       @ [ "--home"
         ; home_dir
         ; "--cli"
         ; cli_path
         ; "--model"
         ; model.Runtime_antigravity_setup.id
         ; "--records"
         ; records
         ; "--timeout"
         ; Printf.sprintf "%.17g" timeout_s
         ])
  with
  | Ok run -> parse_transport ~model ~cli_version run
  | Error refusal -> Error (command_refused ~phase:Status_transport refusal)
;;

let executable_path command =
  let candidates =
    if Filename.is_implicit command
    then
      (match Env_config_core.raw_value_opt "PATH" with
        | Some path -> path
        | None -> "")
      |> String.split_on_char ':'
      |> List.map (fun directory -> Filename.concat directory command)
    else [ command ]
  in
  match
    List.find_map
      (fun path ->
         try
           let path = Unix.realpath path in
           Unix.access path [ Unix.X_OK ];
           if (Unix.stat path).st_kind = Unix.S_REG then Some path else None
         with
         | Unix.Unix_error _ -> None)
      candidates
  with
  | Some path -> Ok path
  | None -> Error (command_failed ~phase:(Executable_lookup command) ~status:None ~stderr:"")
;;

let observe ~python_path ~cli_path ~timeout_s ~oauth_source ~model =
  if (not (Float.is_finite timeout_s)) || timeout_s <= 0.
  then
    Error
      (command_failed ~phase:(Observation_deadline timeout_s) ~status:None ~stderr:"")
  else (
    try
      let ( let* ) = Result.bind in
      let* python_path = executable_path python_path in
      let* cli_path = executable_path cli_path in
      let runtime_root =
        Filename.temp_dir "masc-antigravity-context-" "" |> Unix.realpath
      in
      let run () =
        measure ~python_path ~cli_path ~timeout_s ~oauth_source ~model runtime_root
      in
      match Eio_context.get_switch_opt () with
      | None -> Fun.protect ~finally:(fun () -> Fs_compat.remove_tree runtime_root) run
      | Some _ ->
        Eio.Cancel.protect (fun () ->
          Eio.Switch.run (fun sw ->
            Eio.Switch.on_release sw (fun () -> Fs_compat.remove_tree runtime_root);
            run ()))
    with
    | Sys_error _ | Unix.Unix_error _ -> Error Private_home_unavailable)
;;

module For_testing = struct
  let parse_transport = parse_transport
end
