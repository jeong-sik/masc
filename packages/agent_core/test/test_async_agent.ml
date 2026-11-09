(** Tests for Async_agent — Eio fiber-based concurrent agent execution.

    Uses a mock HTTP server (cohttp-eio) to simulate LLM responses.
    No real LLM calls. *)
open Agent_core

open Alcotest

(* ── Mock server helpers ─────────────────────────────────────────── *)

let quick_response text =
  Printf.sprintf
    {|{"id":"m","object":"chat.completion","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}|}
    text
;;

(** Start a test-only OpenAI-compatible server. Returns base_url.
    Optionally delays [delay_sec] before responding. *)
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

let start_mock ~sw ~net ~clock ?(delay_sec = 0.0) response_text =
  let port = fresh_port () in
  let handler _conn _req body =
    let _ = Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all) in
    if delay_sec > 0.0 then Eio.Time.sleep clock delay_sec;
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
  let config =
    { (Types.default_config ~model:"test-model") with name; model = "mock-model" }
  in
  let provider_config =
    Provider_mock.local_provider_config
      ~base_url
      ~model_id:"mock-model"
      ~request_path:"/v1/chat/completions"
      ()
  in
  let options = { Agent.default_options with provider_config = Some provider_config } in
  Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~net ~config ~options ()
;;

let extract_text (resp : Types.api_response) =
  List.filter_map
    (function
      | Llm_provider.Types.Text s -> Some s
      | _ -> None)
    resp.content
  |> String.concat ""
;;

(* ── all (fan-out) ────────────────────────────────────────────────── *)

let test_all_collects () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    let url1 = start_mock ~sw ~net:env#net ~clock "result-1" in
    let url2 = start_mock ~sw ~net:env#net ~clock "result-2" in
    let url3 = start_mock ~sw ~net:env#net ~clock "result-3" in
    let a1 = make_agent ~net:env#net url1 "agent-1" in
    let a2 = make_agent ~net:env#net url2 "agent-2" in
    let a3 = make_agent ~net:env#net url3 "agent-3" in
    let results =
      Async_agent.all ~sw ~clock ~max_fibers:3 [ a1, "go"; a2, "go"; a3, "go" ]
    in
    check int "3 results" 3 (List.length results);
    (* Verify each result *)
    List.iter
      (fun (name, result) ->
         match result with
         | Ok resp ->
           let text = extract_text resp in
           check bool "has result text" true (String.length text > 0);
           check bool "name matches" true (String.length name > 0)
         | Error e -> fail (Printf.sprintf "%s failed: %s" name (Error.to_string e)))
      results;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── all preserves order ──────────────────────────────────────────── *)

let test_all_order () =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  try
    Eio.Switch.run
    @@ fun sw ->
    (* Agents with different delays — output order should match input *)
    let url1 = start_mock ~sw ~net:env#net ~clock ~delay_sec:0.05 "first" in
    let url2 = start_mock ~sw ~net:env#net ~clock ~delay_sec:0.01 "second" in
    let a1 = make_agent ~net:env#net url1 "ordered-1" in
    let a2 = make_agent ~net:env#net url2 "ordered-2" in
    let results = Async_agent.all ~sw ~clock [ a1, "go"; a2, "go" ] in
    let names = List.map fst results in
    check (list string) "order preserved" [ "ordered-1"; "ordered-2" ] names;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

(* ── Test suite ──────────────────────────────────────────────────── *)

let () =
  (* Ensure ANTHROPIC_API_KEY is set for mock server tests *)
  if Sys.getenv_opt "ANTHROPIC_API_KEY" = None
  then Unix.putenv "ANTHROPIC_API_KEY" "test-mock-key";
  run
    "async_agent"
    [ ( "all"
      , [ test_case "collects_all" `Quick test_all_collects
        ; test_case "preserves_order" `Quick test_all_order
        ] )
    ]
;;
