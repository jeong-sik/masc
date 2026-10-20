(* A completion review is a one-shot walk that runs until the model answers.
   task-2402 (2026-10-20): the operator's runtime-params file set
   [keeper.turn.max_tool_rounds] to 15, every AGENT_CORE run carried it, and
   the review's first verifier slot failed after about 33 minutes with "Run
   kept continuing after tool execution past its declared ceiling: 15 rounds,
   limit 15". A cumulative tool-round ceiling is a budget gate the
   constitution forbids (forbidden#budget_gate), and a timer that retried the
   review would only have repeated the run into the same wall.

   The proof restores a runtime-params file that still carries that key, as a
   deployed base path does, and drives a review-shaped walk through
   [run_named_with_masc_tools] against a loopback endpoint that asks for more
   tool rounds than the file names before it answers. The walk must finish on
   its runtime with every tool round run. *)
open Alcotest
open Masc

let write path content = Out_channel.with_open_bin path (fun out -> output_string out content)

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let tool_name = "fixture_lookup"

(* The ceiling the stale file names, and the rounds the model asks for. *)
let stale_ceiling = 2
let tool_rounds = stale_ceiling + 3

let completion ~message ~finish_reason =
  Yojson.Safe.to_string
    (`Assoc
        [ "id", `String "chatcmpl-fixture"
        ; "object", `String "chat.completion"
        ; "created", `Int 1
        ; "model", `String "fixture-model"
        ; ( "choices"
          , `List
              [ `Assoc
                  [ "index", `Int 0
                  ; "message", message
                  ; "finish_reason", `String finish_reason
                  ]
              ] )
        ; ( "usage"
          , `Assoc
              [ "prompt_tokens", `Int 10
              ; "completion_tokens", `Int 5
              ; "total_tokens", `Int 15
              ] )
        ])
;;

let tool_call_answer index =
  completion
    ~finish_reason:"tool_calls"
    ~message:
      (`Assoc
          [ "role", `String "assistant"
          ; "content", `Null
          ; ( "tool_calls"
            , `List
                [ `Assoc
                    [ "id", `String (Printf.sprintf "call_fixture_%d" index)
                    ; "type", `String "function"
                    ; ( "function"
                      , `Assoc [ "name", `String tool_name; "arguments", `String "{}" ] )
                    ]
                ] )
          ])
;;

let final_answer =
  completion
    ~finish_reason:"stop"
    ~message:(`Assoc [ "role", `String "assistant"; "content", `String "Reviewed." ])
;;

(* Answers the first [tool_rounds] chat completions with a tool call and the
   next with the final answer. Anything else is refused and recorded. *)
let start_model_endpoint ~sw ~net =
  let socket =
    Eio.Net.listen ~sw ~backlog:8 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let completions = Atomic.make 0 in
  let unexpected = Atomic.make [] in
  let handler _conn request body =
    ignore (Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all));
    let path = Cohttp.Request.uri request |> Uri.path in
    match Cohttp.Request.meth request with
    | `POST when String.ends_with ~suffix:"/chat/completions" path ->
      let index = Atomic.fetch_and_add completions 1 in
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:(if index < tool_rounds then tool_call_answer index else final_answer)
        ()
    | _ ->
      Atomic.set unexpected (path :: Atomic.get unexpected);
      Cohttp_eio.Server.respond_string ~status:`Not_found ~body:"" ()
  in
  Eio.Fiber.fork_daemon ~sw (fun () ->
    Cohttp_eio.Server.run socket (Cohttp_eio.Server.make ~callback:handler ())
      ~on_error:(fun exn -> raise exn));
  match Eio.Net.listening_addr socket with
  | `Tcp (_, port) -> port, completions, unexpected
  | `Unix _ -> fail "expected a TCP listening socket"
;;

let test_a_review_walk_runs_every_tool_round_the_model_asks_for () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let base_path = Filename.temp_dir "review-walk-tool-rounds-" "" in
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    remove base_path);
  let masc_dir = Common.masc_dir_from_base_path ~base_path in
  Fs_compat.mkdir_p masc_dir;
  write
    (Filename.concat masc_dir "runtime_params.json")
    (Printf.sprintf {|{ "keeper.turn.max_tool_rounds": %d }|} stale_ceiling);
  Runtime_params.restore ~base_path;
  let port, completions, unexpected = start_model_endpoint ~sw ~net:env#net in
  let config_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  Fs_compat.mkdir_p (Filename.dirname config_path);
  write
    config_path
    (Printf.sprintf
       {|[runtime]
default = "fixture.sample"
[providers.fixture]
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:%d"
[models.sample]
api-name = "fixture-model"
max-context = 200000
tools-support = true
[fixture.sample]
|}
       port);
  (match Runtime.init_default ~config_path with
   | Ok () -> ()
   | Error detail -> fail detail);
  let lookups = Atomic.make 0 in
  let attempt_errors = ref [] in
  let result =
    Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~raw_trace:None
      ~walk_owner:Keeper_turn_driver.One_shot_walk
      ~runtime_id:"fixture.sample"
      ~keeper_name:"completion-review-tool-rounds"
      ~base_path
      ~system_prompt:"Review the submission."
      ~goal:"Look the evidence up as often as you need, then answer."
      ~masc_tools:
        [ { Masc_domain.name = tool_name
          ; description = "Reads one piece of evidence."
          ; input_schema = `Assoc [ "type", `String "object" ]
          }
        ]
      ~dispatch:(fun ~name ~args:_ ->
        Atomic.incr lookups;
        Tool_result.ok ~tool_name:name ~start_time:(Tool_timing.start ()) "evidence")
      ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
        attempt_errors := error :: !attempt_errors)
      ~sw
      ~net:env#net
      ()
  in
  check (list string) "the endpoint saw only chat completions" [] (Atomic.get unexpected);
  check
    (list string)
    "no attempt was refused"
    []
    (List.map Agent_core.Error.to_string !attempt_errors);
  (match result with
   | Ok _ -> ()
   | Error error -> failf "the walk failed: %s" (Agent_core.Error.to_string error));
  check int "every tool round the model asked for ran" tool_rounds (Atomic.get lookups);
  check int "the model answered after its last tool round" (tool_rounds + 1)
    (Atomic.get completions)
;;

let () =
  Alcotest.run
    "review_walk_tool_rounds"
    [ ( "run_named_with_masc_tools"
      , [ test_case
            "a review walk runs every tool round the model asks for"
            `Quick
            test_a_review_walk_runs_every_tool_round_the_model_asks_for
        ] )
    ]
;;
