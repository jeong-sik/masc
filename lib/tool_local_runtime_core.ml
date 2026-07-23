module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_local_runtime core — types, helpers, process discovery, model fetching. *)

type tool_result = Tool_result.result

type external_effect_authorizer =
  operation:string ->
  input:Yojson.Safe.t ->
  continue:(unit -> tool_result) ->
  tool_result

type context = {
  config : Workspace.config;
  agent_name : string;
  authorize_external_effect : external_effect_authorizer option;
}

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

let parse_int_opt value =
  Stdlib.int_of_string_opt ((String.trim value))


let split_ws text =
  match Exec_policy.parse_string_to_ir ~mode:Strict text with
  | Error _ ->
      let trimmed = String.trim text in
      if String.equal trimmed "" then [] else [ trimmed ]
  | Ok ir -> Exec_policy.flat_stage_words ir


let parse_pid_and_command line =
  let trimmed = String.trim line in
  if String.equal trimmed "" then
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
      ("pid", Json_util.int_opt_to_json process.pid);
      ("command", `String process.command);
      ("port", Json_util.int_opt_to_json process.port);
      ("host", Json_util.string_opt_to_json process.host);
      ("alias", Json_util.string_opt_to_json process.alias);
      ("model_path", Json_util.string_opt_to_json process.model_path);
      ("ctx_size", Json_util.int_opt_to_json process.ctx_size);
      ("batch_size", Json_util.int_opt_to_json process.batch_size);
      ("ubatch_size", Json_util.int_opt_to_json process.ubatch_size);
      ("slots_enabled", `Bool process.slots_enabled);
    ]

let process_matches_runtime_ports ports (process : llama_process) =
  match process.port with
  | Some port -> List.mem port ports
  | None -> false

let discover_processes () =
  let argv = [ "ps"; "-ax"; "-o"; "pid=,command=" ] in
  let status, body =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"tool local runtime process discovery"

      argv
  in
  match status with
  | Unix.WEXITED 0 ->
      let processes =
        body
        |> String.split_on_char '\n'
        |> List.filter_map (fun line ->
               let pid, command = parse_pid_and_command line in
               if String.equal command "" || not (String_util.contains_substring command "llama-server") then
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
  let url =
    String.trim base_url ^ Masc_network_defaults.openai_models_path
  in
  let argv = [ "curl"; "-sS"; "--max-time"; "10"; url ] in
  let status, body =
    Masc_exec.Exec_gate.run_argv_with_status
      ~actor:(Masc_exec.Agent_id.of_string "tool/local_runtime")
      ~raw_source:(String.concat " " (List.map Filename.quote argv))
      ~summary:"tool local runtime fetch models"

      argv
  in
  match status with
  | Unix.WEXITED 0 -> (
      try
        let json = Yojson.Safe.from_string body in
        let models =
          match Json_util.get_array json "data" with
          | Some (`List items) ->
              items
              |> List.filter_map (fun item ->
                     Json_util.get_string item "id")
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

let fetch_models () = fetch_models_at Env_config.Local_runtime.server_url
