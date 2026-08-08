(** Tests for Consumer API — high-level agent execution with telemetry.

    Uses mock HTTP server for Agent.run, no real LLM. *)

open Agent_sdk
open Alcotest

(* ── Mock server ──────────────────────────────────────────────── *)

let quick_response text =
  Printf.sprintf
    {|{"id":"m","object":"chat.completion","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
    text
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

let start_mock ~sw ~net ~clock response_text =
  let port = fresh_port () in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    ignore clock;
    Cohttp_eio.Server.respond_string ~status:`OK ~body:(quick_response response_text) ()
  in
  let socket =
    Eio.Net.listen
      net
      ~sw
      ~backlog:128
      ~reuse_addr:true
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let server = Cohttp_eio.Server.make ~callback:handler () in
  Eio.Fiber.fork ~sw (fun () ->
    Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
  Printf.sprintf "http://127.0.0.1:%d" port
;;

let make_agent ~net base_url name =
  let config = { (Types.default_config ~model:"test-model") with name } in
  let provider_config =
    Provider_mock.local_provider_config
      ~base_url
      ~model_id:"test-model"
      ~request_path:"/v1/chat/completions"
      ()
  in
  let options = { Agent.default_options with provider_config = Some provider_config } in
  Agent.create ~net ~config ~options ()
;;

(* ── run_agent tests ───────────────────────────────────────────── *)

let test_run_agent_basic () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock ~sw ~net:env#net ~clock "consumer-ok" in
    let agent = make_agent ~net:env#net url "consumer-agent" in
    let result = Consumer.run_agent ~sw ~clock agent "test" in
    (match result.response with
     | Ok resp ->
       let text =
         List.filter_map
           (function
             | Types.Text s -> Some s
             | _ -> None)
           resp.content
         |> String.concat ""
       in
       check string "response text" "consumer-ok" text
     | Error e -> fail (Error.to_string e));
    check bool "elapsed > 0" true (result.elapsed > 0.0);
    check bool "no harness" true (Option.is_none result.harness_verdict);
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_run_agent_with_harness () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock ~sw ~net:env#net ~clock "hello world" in
    let agent = make_agent ~net:env#net url "harness-agent" in
    let harness = Harness.Behavioral.ContainsText "hello" in
    let result = Consumer.run_agent ~sw ~clock ~harness agent "test" in
    (match result.harness_verdict with
     | Some v -> check bool "harness passed" true v.passed
     | None -> fail "expected harness verdict");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let test_run_agent_harness_fails () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url = start_mock ~sw ~net:env#net ~clock "goodbye" in
    let agent = make_agent ~net:env#net url "harness-fail" in
    let harness = Harness.Behavioral.ContainsText "hello" in
    let result = Consumer.run_agent ~sw ~clock ~harness agent "test" in
    (match result.harness_verdict with
     | Some v -> check bool "harness failed" false v.passed
     | None -> fail "expected harness verdict");
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── run_agents tests ──────────────────────────────────────────── *)

let test_run_agents_multiple () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url1 = start_mock ~sw ~net:env#net ~clock "res-1" in
    let url2 = start_mock ~sw ~net:env#net ~clock "res-2" in
    let a1 = make_agent ~net:env#net url1 "multi-1" in
    let a2 = make_agent ~net:env#net url2 "multi-2" in
    let results = Consumer.run_agents ~sw ~clock ~max_fibers:2 [ a1, "go"; a2, "go" ] in
    check int "2 results" 2 (List.length results);
    List.iter
      (fun (name, r) ->
         match r.Consumer.response with
         | Ok _ -> ()
         | Error e -> fail (Printf.sprintf "%s: %s" name (Error.to_string e)))
      results;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Test suite ───────────────────────────────────────────────── *)

let () =
  run
    "consumer"
    [ ( "run_agent"
      , [ test_case "basic" `Quick test_run_agent_basic
        ; test_case "with_harness" `Quick test_run_agent_with_harness
        ; test_case "harness_fails" `Quick test_run_agent_harness_fails
        ] )
    ; "run_agents", [ test_case "multiple" `Quick test_run_agents_multiple ]
    ]
;;
