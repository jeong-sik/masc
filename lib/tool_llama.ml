open Types

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let fetch_models () =
  let url = Env_config.Llama.server_url ^ "/v1/models" in
  let status, body =
    Process_eio.run_argv_with_status
      ~timeout_sec:15.0 [ "curl"; "-sS"; "--max-time"; "10"; url ]
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

let handle_models _ctx : result =
  match fetch_models () with
  | Error msg -> (false, json_error msg)
  | Ok (url, models) ->
      ( true,
        json_ok
          [
            ( "result",
              `Assoc
                [
                  ("server_url", `String Env_config.Llama.server_url);
                  ("endpoint", `String url);
                  ("source", `String "llama.cpp /v1/models");
                  ("models", `List (List.map (fun m -> `String m) models));
                  ("model_count", `Int (List.length models));
                ] );
          ] )

let dispatch ctx ~name ~args:_ : result option =
  match name with
  | "masc_llama_models" -> Some (handle_models ctx)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_llama_models";
      description =
        "Read the llama.cpp model inventory from /v1/models. Use this before spawning llama workers so the leader can choose an explicit model id.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ("properties", `Assoc []);
          ];
    };
  ]
