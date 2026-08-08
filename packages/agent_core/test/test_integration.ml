open Agent_sdk
open Types

(** Mock Server Logic — Openai Chat Completions format *)
let mock_handler _conn req body =
  let path = Uri.path (Cohttp.Request.uri req) in
  match path with
  | "/v1/chat/completions" ->
    let body_str = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    let json = Yojson.Safe.from_string body_str in
    let messages = Yojson.Safe.Util.(json |> member "messages" |> to_list) in
    let last_msg = List.hd (List.rev messages) in
    let text =
      let open Yojson.Safe.Util in
      match last_msg |> member "content" with
      | `String s -> s
      | `List items ->
        (match items with
         | [] -> "No content"
         | item :: _ ->
           (match item |> member "text" |> to_string_option with
            | Some t -> t
            | None ->
              item
              |> member "content"
              |> to_string_option
              |> Option.value ~default:"unknown"))
      | _ -> "No content"
    in
    let response_body =
      if text = "ping"
      then
        {|{"id":"chatcmpl-1","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"pong"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
      else if text = "use_tool"
      then
        {|{"id":"chatcmpl-2","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"calculator","arguments":"{\"a\":1,\"b\":2}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
      else if text = "3"
      then
        {|{"id":"chatcmpl-3","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"The result is 3"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
      else
        {|{"id":"chatcmpl-e","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"err"},"finish_reason":"stop"}],"usage":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":0}}|}
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  | _ -> Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"Not found" ()
;;

let fresh_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.setsockopt s Unix.SO_REUSEADDR true;
  Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname s with
    | Unix.ADDR_INET (_, p) -> p
    | _ -> failwith "not inet"
  in
  Unix.close s;
  port
;;

let skip_if_bisect label =
  match Sys.getenv_opt "BISECT_ENABLE" with
  | Some ("1" | "yes" | "true") ->
    Printf.printf "  [SKIP] %s under bisect coverage run\n%!" label;
    Alcotest.skip ()
  | _ -> ()
;;

let test_simple_conversation () =
  skip_if_bisect "simple_conversation";
  let port = fresh_port () in
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:mock_handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let provider_config =
      Provider_mock.local_provider_config
        ~base_url
        ~model_id:"mock"
        ~request_path:"/v1/chat/completions"
        ()
    in
    let options = { Agent.default_options with provider_config = Some provider_config } in
    let agent =
      Agent.create
        ~config:(Types.default_config ~model:"test-model")
        ~net:env#net
        ~options
        ()
    in
    match Agent.run ~sw agent "ping" with
    | Ok response ->
      let text =
        List.filter_map
          (function
            | Text s -> Some s
            | _ -> None)
          response.content
        |> String.concat ""
      in
      Alcotest.(check string) "response is pong" "pong" text;
      Eio.Switch.fail sw Exit
    | Error e -> Alcotest.fail (Error.to_string e)
  with
  | Exit -> ()
;;

let test_tool_use () =
  skip_if_bisect "tool_execution";
  let port = fresh_port () in
  let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
  Eio_main.run
  @@ fun env ->
  try
    Eio.Switch.run
    @@ fun sw ->
    let socket =
      Eio.Net.listen
        env#net
        ~sw
        ~backlog:128
        ~reuse_addr:true
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    let server = Cohttp_eio.Server.make ~callback:mock_handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let calc_tool =
      Tool.create ~name:"calculator" ~description:"add" ~parameters:[] (fun input ->
        let a = Yojson.Safe.Util.(input |> member "a" |> to_int) in
        let b = Yojson.Safe.Util.(input |> member "b" |> to_int) in
        Ok { Types.content = string_of_int (a + b); _meta = None })
    in
    let provider_config =
      Provider_mock.local_provider_config
        ~base_url
        ~model_id:"mock"
        ~request_path:"/v1/chat/completions"
        ()
    in
    let options = { Agent.default_options with provider_config = Some provider_config } in
    let agent =
      Agent.create
        ~config:(Types.default_config ~model:"test-model")
        ~net:env#net
        ~tools:[ calc_tool ]
        ~options
        ()
    in
    match Agent.run ~sw agent "use_tool" with
    | Ok response ->
      let text =
        List.filter_map
          (function
            | Text s -> Some s
            | _ -> None)
          response.content
        |> String.concat ""
      in
      Alcotest.(check string) "tool result" "The result is 3" text;
      Eio.Switch.fail sw Exit
    | Error e -> Alcotest.fail (Error.to_string e)
  with
  | Exit -> ()
;;

let () =
  (* Agent.create resolves api_key_env even for Local provider; set a dummy *)
  if Sys.getenv_opt "ANTHROPIC_API_KEY" = None
  then Unix.putenv "ANTHROPIC_API_KEY" "test-mock-key";
  let open Alcotest in
  run
    "Agent Integration"
    [ ( "mock_server"
      , [ test_case "simple_conversation" `Quick test_simple_conversation
        ; test_case "tool_execution" `Quick test_tool_use
        ] )
    ]
;;
