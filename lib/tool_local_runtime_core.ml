(** Tool_local_runtime core — types, helpers, process discovery, model fetching. *)

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

type llama_process = {
  pid : int option;
  command : string;
  port : int option;
  host : string option;
  alias : string option;
  model_path : string option;
  ctx_size : int option;
  batch_size : int option;
  ubatch_size : int option;
  slots_enabled : bool;
}

type bench_sample = {
  success : bool;
  latency_ms : int;
  error : string option;
}

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let int_opt_to_json = Json_util.int_opt_to_json
let string_opt_to_json = Json_util.string_opt_to_json
let float_opt_to_json = Json_util.float_opt_to_json

let parse_int_opt value =
  int_of_string_opt ((String.trim value))

let unique_preserve_order = Json_util.dedupe_keep_order

let split_ws text =
  text
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun item -> item <> "")

let string_contains_substring = String_util.contains_substring

let parse_pid_and_command line =
  let trimmed = String.trim line in
  if trimmed = "" then
    (None, "")
  else
    match String.index_opt trimmed ' ' with
    | None -> (parse_int_opt trimmed, "")
    | Some idx ->
        let pid = String.sub trimmed 0 idx |> parse_int_opt in
        let command =
          String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
          |> String.trim
        in
        (pid, command)

let find_flag_value tokens flag =
  let rec loop = function
    | [] | [ _ ] -> None
    | key :: value :: rest ->
        if String.equal key flag then
          Some value
        else
          loop (value :: rest)
  in
  loop tokens

let has_flag tokens flag = List.exists (String.equal flag) tokens

let server_port_of_url url =
  let trimmed = String.trim url in
  match String.rindex_opt trimmed ':' with
  | None -> None
  | Some idx ->
      let port =
        String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
      in
      parse_int_opt port

let process_to_yojson (process : llama_process) =
  `Assoc
    [
      ("pid", int_opt_to_json process.pid);
      ("command", `String process.command);
      ("port", int_opt_to_json process.port);
      ("host", string_opt_to_json process.host);
      ("alias", string_opt_to_json process.alias);
      ("model_path", string_opt_to_json process.model_path);
      ("ctx_size", int_opt_to_json process.ctx_size);
      ("batch_size", int_opt_to_json process.batch_size);
      ("ubatch_size", int_opt_to_json process.ubatch_size);
      ("slots_enabled", `Bool process.slots_enabled);
    ]

let process_matches_runtime_ports ports (process : llama_process) =
  match process.port with
  | Some port -> List.mem port ports
  | None -> false

let discover_processes () =
  let status, body =
    Process_eio.run_argv_with_status ~timeout_sec:5.0
      [ "ps"; "-ax"; "-o"; "pid=,command=" ]
  in
  match status with
  | Unix.WEXITED 0 ->
      let processes =
        body
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let pid, command = parse_pid_and_command line in
               if command = "" || not (string_contains_substring command "llama-server") then
                 None
               else
                 let tokens = split_ws command in
                 if not (List.exists (fun token -> String.ends_with ~suffix:"llama-server" token) tokens)
                 then None
                 else
                   Some
                     {
                       pid;
                       command;
                       port =
                         Option.bind
                           (find_flag_value tokens "--port")
                           parse_int_opt;
                       host = find_flag_value tokens "--host";
                       alias = find_flag_value tokens "--alias";
                       model_path = find_flag_value tokens "-m";
                       ctx_size =
                         Option.bind
                           (find_flag_value tokens "-c")
                           parse_int_opt;
                       batch_size =
                         Option.bind
                           (find_flag_value tokens "--batch-size")
                           parse_int_opt;
                       ubatch_size =
                         Option.bind
                           (find_flag_value tokens "--ubatch-size")
                           parse_int_opt;
                       slots_enabled = has_flag tokens "--slots";
                     }
               )
      in
      Ok processes
  | Unix.WEXITED code ->
      Error (Printf.sprintf "ps failed with exit code %d" code)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "ps killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "ps stopped by signal %d" sig_num)

let fetch_models_at base_url =
  let url = String.trim base_url ^ "/v1/models" in
  let status, body =
    Process_eio.run_argv_with_status ~timeout_sec:15.0
      [ "curl"; "-sS"; "--max-time"; "10"; url ]
  in
  match status with
  | Unix.WEXITED 0 -> (
      try
        let json = Yojson.Safe.from_string body in
        let open Yojson.Safe.Util in
        let models =
          match member "data" json with
          | `List items ->
              items
              |> List.filter_map (fun item ->
                     item |> member "id" |> to_string_option)
          | _ -> []
        in
        Ok (url, models)
      with Yojson.Json_error msg -> Error ("invalid llama models response: " ^ msg))
  | Unix.WEXITED code ->
      Error
        (Printf.sprintf "llama models request failed with exit code %d" code)
  | Unix.WSIGNALED sig_num ->
      Error (Printf.sprintf "llama models request killed by signal %d" sig_num)
  | Unix.WSTOPPED sig_num ->
      Error (Printf.sprintf "llama models request stopped by signal %d" sig_num)

let fetch_models () = fetch_models_at Env_config.Llama.server_url
