(* A completion review is a one-shot walk: it runs under a disposable name the
   Keeper registry does not know, so the attempt watchdog has no progress to
   read and measures elapsed time instead. On an AGENT_CORE runtime the walk
   releases the provider lease around its tools and takes it back for each
   model turn, so that elapsed time is each model turn's own, not the
   review's (#41305).

   The proof drives a review-shaped walk through [run_named_with_masc_tools]
   against a loopback endpoint whose every answer takes [model_turn_s]: one
   tool call, then a final answer. Each model turn stays inside the declared
   deadline; the two together outlast it and the watchdog's first two polls.
   The walk must finish on its first runtime, having yielded and resumed the
   lease once. The deadline's lower bound is thirty seconds, so the case is
   slow by construction. *)
open Alcotest
open Masc

let write path content =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel content)
;;

let rec remove path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
;;

let deadline_s = Env_config_keeper.KeeperKeepalive.provider_call_deadline_min_sec

(* Each model turn stays inside the deadline; two of them pass the
   watchdog's poll after it, so a review watched from its start is cut. *)
let model_turn_s = 25.0

let tool_name = "fixture_lookup"

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

let tool_call_answer =
  completion
    ~finish_reason:"tool_calls"
    ~message:
      (`Assoc
          [ "role", `String "assistant"
          ; "content", `Null
          ; ( "tool_calls"
            , `List
                [ `Assoc
                    [ "id", `String "call_fixture"
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

(* Answers the n-th chat completion after [model_turn_s]: a tool call first,
   the final answer after. Anything else is refused at once and recorded. *)
let start_model_endpoint ~sw ~net ~clock =
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
      Eio.Time.sleep clock model_turn_s;
      Cohttp_eio.Server.respond_string
        ~status:`OK
        ~body:(if index = 0 then tool_call_answer else final_answer)
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

let test_a_reviewing_walk_outlives_the_deadline_turn_by_turn () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  let base_path = Filename.temp_dir "one-shot-walk-lease-deadline-" "" in
  let deadline_key = Env_config_keeper.KeeperKeepalive.provider_call_deadline_env_key in
  let inherited_deadline = Sys.getenv_opt deadline_key in
  Config_boot_overrides.reset_for_tests ();
  Keeper_runtime_resolved.reset_for_tests ();
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore runtime_snapshot;
    Config_boot_overrides.reset_for_tests ();
    Keeper_runtime_resolved.reset_for_tests ();
    (match inherited_deadline with
     | Some value -> Unix.putenv deadline_key value
     | None -> Unix.unsetenv deadline_key);
    remove base_path);
  let port, completions, unexpected =
    start_model_endpoint ~sw ~net:env#net ~clock:env#clock
  in
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
  Unix.putenv deadline_key (Printf.sprintf "%g" deadline_s);
  Keeper_runtime_resolved.reset_for_tests ();
  check
    (float 0.0001)
    "the resolved layer serves the declared deadline"
    deadline_s
    (Keeper_runtime_resolved.provider_call_deadline_sec ());
  let lookups = Atomic.make 0 in
  let yields = Atomic.make 0 in
  let resumes = Atomic.make 0 in
  let attempt_errors = ref [] in
  let started = Unix.gettimeofday () in
  let result =
    Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~raw_trace:None
      ~walk_owner:Keeper_turn_driver.One_shot_walk
      ~runtime_id:"fixture.sample"
      ~keeper_name:"completion-review-lease-deadline"
      ~base_path
      ~system_prompt:"Review the submission."
      ~goal:"Look the evidence up, then answer."
      ~masc_tools:
        [ { Masc_domain.name = tool_name
          ; description = "Reads one piece of evidence."
          ; input_schema = `Assoc [ "type", `String "object" ]
          }
        ]
      ~dispatch:(fun ~name ~args:_ ->
        Atomic.incr lookups;
        Tool_result.ok ~tool_name:name ~start_time:(Tool_timing.start ()) "evidence")
      ~on_yield:(fun () -> Atomic.incr yields)
      ~on_resume:(fun () -> Atomic.incr resumes)
      ~on_runtime_attempt_error:(fun ~runtime_id:_ ~attempt:_ ~dispatch:_ error ->
        attempt_errors := error :: !attempt_errors)
      ~sw
      ~net:env#net
      ()
  in
  let elapsed_s = Unix.gettimeofday () -. started in
  check (list string) "the endpoint saw only chat completions" [] (Atomic.get unexpected);
  check
    (list string)
    "no attempt was cut"
    []
    (List.map Agent_core.Error.to_string !attempt_errors);
  (match result with
   | Ok _ -> ()
   | Error error -> failf "the walk failed: %s" (Agent_core.Error.to_string error));
  check int "both model turns were answered" 2 (Atomic.get completions);
  check int "the tool ran once" 1 (Atomic.get lookups);
  check int "the lease was released for the tool" 1 (Atomic.get yields);
  check int "the lease was taken back for the next model turn" 1 (Atomic.get resumes);
  check
    bool
    (Printf.sprintf "the walk outlasted the deadline (%.1fs > %gs)" elapsed_s deadline_s)
    true
    (elapsed_s > deadline_s)
;;

let () =
  Alcotest.run
    "one_shot_walk_lease_deadline"
    [ ( "run_named_with_masc_tools"
      , [ test_case
            "a reviewing walk is watched one model turn at a time"
            `Slow
            test_a_reviewing_walk_outlives_the_deadline_turn_by_turn
        ] )
    ]
;;
