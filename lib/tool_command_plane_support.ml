module U = Yojson.Safe.Util

type ('clock, 'net) context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t option;
  clock : 'clock Eio.Time.clock option;
  net : 'net option;
  mcp_state : Mcp_server.server_state option;
  mcp_session_id : string option;
  auth_token : string option;
}

type tool_result = bool * string

let get_string_opt = Tool_args.get_string_opt
let get_bool = Tool_args.get_bool

let get_json_opt args key =
  match U.member key args with
  | `Null -> None
  | value -> Some value

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let json_error_fields message fields =
  Yojson.Safe.to_string
    (`Assoc
      ([
         ("status", `String "error");
         ("message", `String message);
       ]
      @ fields))

let json_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, json_error message)

let assoc_field key value = (key, value)

let env_int_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match int_of_string_opt (String.trim raw) with
      | Some value when value > 0 -> value
      | _ -> default)

let env_bool_or ~name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some raw -> (
      match String.lowercase_ascii (String.trim raw) with
      | "1" | "true" | "yes" | "on" -> true
      | "0" | "false" | "no" | "off" -> false
      | _ -> default)

let merge_env_overrides overrides =
  let override_keys = List.map fst overrides in
  let is_override entry =
    match String.index_opt entry '=' with
    | None -> false
    | Some idx ->
        let key = String.sub entry 0 idx in
        List.mem key override_keys
  in
  let base =
    Unix.environment ()
    |> Array.to_list
    |> List.filter (fun entry -> not (is_override entry))
  in
  let injected =
    overrides |> List.map (fun (key, value) -> key ^ "=" ^ value)
  in
  Array.of_list (base @ injected)

let read_all ic =
  let buf = Buffer.create 1024 in
  (try
     while true do
       Buffer.add_channel buf ic 4096
     done
   with End_of_file -> ());
  Buffer.contents buf

let tail_display_max_chars = 4000

let tail_text ?(max_chars = tail_display_max_chars) text =
  let len = String.length text in
  if len <= max_chars then text
  else String.sub text (len - max_chars) max_chars

let close_fd_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

let remove_path_quietly path =
  try Sys.remove path with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let swarm_live_run_dir config run_id =
  Filename.concat
    (Filename.concat (Cp_paths.control_plane_root_dir config) "swarm-live")
    (Room_utils.safe_filename run_id |> String.lowercase_ascii)

let swarm_live_summary_path config run_id =
  Filename.concat (swarm_live_run_dir config run_id) "swarm-live-summary.json"

let swarm_live_runtime_doctor_path config run_id =
  Filename.concat (swarm_live_run_dir config run_id) "runtime-doctor.json"

let json_string_member_opt json key =
  match U.member key json with
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

let read_json_file_opt path =
  if Sys.file_exists path then
    (try Some (Safe_ops.read_json_eio path)
     with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
       Log.CmdPlane.warn "read_json_file_opt %s: %s" path (Printexc.to_string exn);
       None)
  else
    None

type process_result = {
  exit_code : int;
  stdout : string;
  stderr : string;
}

(** Run subprocess and capture stdout/stderr.
    Offloaded to system thread to avoid blocking Eio scheduler. *)
let run_process ~prog ~argv ~env =
  let f () =
    let ic, oc, ec =
      Unix.open_process_args_full prog (Array.of_list argv) env
    in
    close_out_noerr oc;
    let stdout = read_all ic in
    let stderr = read_all ec in
    let exit_code =
      match Unix.close_process_full (ic, oc, ec) with
      | Unix.WEXITED code -> code
      | Unix.WSIGNALED code -> 128 + code
      | Unix.WSTOPPED code -> 256 + code
    in
    { exit_code; stdout; stderr }
  in
  Eio_guard.run_in_systhread f

let rec waitpid_nointr flags pid =
  try Unix.waitpid flags pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_nointr flags pid

let wait_for_pid_with_timeout ~clock_opt ~timeout_sec pid =
  let start = Unix.gettimeofday () in
  let rec loop () =
    match waitpid_nointr [ Unix.WNOHANG ] pid with
    | 0, _ ->
        if Unix.gettimeofday () -. start >= float_of_int timeout_sec then
          `Timeout
        else (
          (match clock_opt with
          | Some clock -> Eio.Time.sleep clock 0.2
          | None -> Time_compat.sleep 0.2);
          loop ())
    | _, status -> `Exited status
  in
  loop ()

let run_process_with_timeout ?stdin_content ~clock_opt ~timeout_sec ~prog ~argv ~env () =
  let stdin_path_opt = ref None in
  let stdin_fd_opt = ref None in
  let stdout_fd_opt = ref None in
  let stderr_fd_opt = ref None in
  let stdout_path = Filename.temp_file "masc_cp_stdout_" ".log" in
  let stderr_path = Filename.temp_file "masc_cp_stderr_" ".log" in
  let cleanup_setup () =
    Option.iter close_fd_quietly !stdin_fd_opt;
    stdin_fd_opt := None;
    Option.iter close_fd_quietly !stdout_fd_opt;
    stdout_fd_opt := None;
    Option.iter close_fd_quietly !stderr_fd_opt;
    stderr_fd_opt := None;
    Option.iter remove_path_quietly !stdin_path_opt;
    stdin_path_opt := None;
    remove_path_quietly stdout_path;
    remove_path_quietly stderr_path
  in
  let pid =
    try
      let stdin_fd =
        match stdin_content with
        | None -> Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0
        | Some content ->
            let stdin_path, oc =
              Filename.open_temp_file ~mode:[ Open_wronly; Open_creat; Open_trunc; Open_binary ]
                ~perms:0o600 "masc_cp_stdin_" ".log"
            in
            stdin_path_opt := Some stdin_path;
            Out_channel.output_string oc content;
            close_out oc;
            Unix.openfile stdin_path [ Unix.O_RDONLY ] 0
      in
      stdin_fd_opt := Some stdin_fd;
      let stdout_fd =
        Unix.openfile stdout_path
          [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
      in
      stdout_fd_opt := Some stdout_fd;
      let stderr_fd =
        Unix.openfile stderr_path
          [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600
      in
      stderr_fd_opt := Some stderr_fd;
      let pid =
        Unix.create_process_env prog (Array.of_list argv) env stdin_fd stdout_fd
          stderr_fd
      in
      close_fd_quietly stdin_fd;
      stdin_fd_opt := None;
      close_fd_quietly stdout_fd;
      stdout_fd_opt := None;
      close_fd_quietly stderr_fd;
      stderr_fd_opt := None;
      pid
    with exn ->
      cleanup_setup ();
      raise exn
  in
  let finalize exit_code =
    let stdout = In_channel.with_open_bin stdout_path In_channel.input_all in
    let stderr = In_channel.with_open_bin stderr_path In_channel.input_all in
    (match !stdin_path_opt with
    | Some stdin_path -> (
        try Sys.remove stdin_path
        with Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             Log.CmdPlane.warn "failed to remove stdin tmpfile %s: %s" stdin_path
               (Printexc.to_string exn))
    | None -> ());
    (try Sys.remove stdout_path with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.CmdPlane.warn "failed to remove stdout tmpfile %s: %s" stdout_path (Printexc.to_string exn));
    (try Sys.remove stderr_path with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.CmdPlane.warn "failed to remove stderr tmpfile %s: %s" stderr_path (Printexc.to_string exn));
    { exit_code; stdout; stderr }
  in
  match wait_for_pid_with_timeout ~clock_opt ~timeout_sec pid with
  | `Exited (Unix.WEXITED code) -> finalize code
  | `Exited (Unix.WSIGNALED code) -> finalize (128 + code)
  | `Exited (Unix.WSTOPPED code) -> finalize (256 + code)
  | `Timeout ->
      (try Unix.kill pid Sys.sigterm with
       | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
       | exn -> Log.CmdPlane.warn "sigterm pid %d: %s" pid (Printexc.to_string exn));
      (match clock_opt with
      | Some clock -> Eio.Time.sleep clock 1.0
      | None -> Time_compat.sleep 1.0);
      (match waitpid_nointr [ Unix.WNOHANG ] pid with
      | 0, _ ->
          (try Unix.kill pid Sys.sigkill with
           | Unix.Unix_error (Unix.ESRCH, _, _) -> ()
           | exn -> Log.CmdPlane.warn "sigkill pid %d: %s" pid (Printexc.to_string exn));
          ignore (waitpid_nointr [] pid)
      | _, _ -> ());
      finalize 124

let json_with_process_metadata json ({ exit_code; stdout; stderr } : process_result) =
  match json with
  | `Assoc fields ->
      `Assoc
        (fields
        @ [
            assoc_field "harness_exit_code" (`Int exit_code);
            assoc_field "harness_stdout_tail" (`String (tail_text stdout));
            assoc_field "harness_stderr_tail" (`String (tail_text stderr));
          ])
  | other ->
      `Assoc
        [
          assoc_field "result" other;
          assoc_field "harness_exit_code" (`Int exit_code);
          assoc_field "harness_stdout_tail" (`String (tail_text stdout));
          assoc_field "harness_stderr_tail" (`String (tail_text stderr));
        ]

let swarm_live_error_message ?runtime_doctor ~default () =
  match runtime_doctor with
  | None -> default
  | Some json -> (
      match
        ( json_string_member_opt json "runtime_blocker",
          json_string_member_opt json "detail" )
      with
      | Some blocker, Some detail -> Printf.sprintf "%s: %s" blocker detail
      | Some blocker, None -> blocker
      | None, Some detail -> detail
      | None, None -> default)

let swarm_live_error_payload config ~run_id ~message ?proc () =
  let runtime_doctor_path = swarm_live_runtime_doctor_path config run_id in
  let summary_path = swarm_live_summary_path config run_id in
  let runtime_doctor = read_json_file_opt runtime_doctor_path in
  let detailed_json = `Assoc [] in
  let fields =
    [
      assoc_field "run_id" (`String run_id);
      assoc_field "runtime_doctor_path" (`String runtime_doctor_path);
      assoc_field "summary_path" (`String summary_path);
      assoc_field "swarm" detailed_json;
    ]
    @
    match runtime_doctor with
    | None -> []
    | Some doctor ->
        [ assoc_field "runtime_doctor" doctor ]
        @
        (match json_string_member_opt doctor "runtime_blocker" with
        | Some blocker -> [ assoc_field "runtime_blocker" (`String blocker) ]
        | None -> [])
        @
        (match json_string_member_opt doctor "detail" with
        | Some detail -> [ assoc_field "detail" (`String detail) ]
        | None -> [])
  in
  let payload = `Assoc (("status", `String "error") :: ("message", `String message) :: fields) in
  match proc with
  | Some process -> Yojson.Safe.to_string (json_with_process_metadata payload process)
  | None -> Yojson.Safe.to_string payload

let handle_unit_define (ctx : (_, _) context) args : tool_result =
  try
    match Command_plane_v2.upsert_unit ctx.config ~actor:ctx.agent_name args with
    | Ok unit ->
        ( true,
          json_ok
            [
              ("result", Command_plane_v2.unit_to_json unit);
              ("topology", Command_plane_v2.topology_json ctx.config);
            ] )
    | Error message -> (false, json_error message)
  with Invalid_argument message -> (false, json_error message)

let handle_unit_list (ctx : (_, _) context) : tool_result =
  (true, Yojson.Safe.to_string (Command_plane_v2.list_units_json ctx.config))

let object_schema = Tool_schema_dsl.object_schema
let string_prop = Tool_schema_dsl.string_prop
let integer_prop = Tool_schema_dsl.integer_prop
let boolean_prop = Tool_schema_dsl.boolean_prop
let string_array_prop = Tool_schema_dsl.string_array_prop
