open Alcotest
open Masc

let init_result =
  {|{"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
;;

let account_chatgpt =
  {|{"id":2,"result":{"account":{"type":"chatgpt","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
;;

let thread_result =
  {|{"id":3,"result":{"thread":{"id":"thread-1"},"model":"gpt-fixture"}}|}
;;

let turn_result = {|{"id":4,"result":{"turn":{"id":"turn-1"}}}|}

let agent_message_delta =
  {|{"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"message-1","delta":"MASC_"}}|}
;;

let item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":1,"item":{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}}}|}
;;

let turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[{"type":"agentMessage","id":"message-1","text":"MASC_SUBSCRIPTION_OK","phase":"final_answer"}],"status":"completed"}}}|}
;;

let turn_failed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"fixture provider rejection"}}}}|}
;;

let resumed_turn_result = {|{"id":4,"result":{"turn":{"id":"turn-2"}}}|}

let resumed_item_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-2","completedAtMs":2,"item":{"type":"agentMessage","id":"message-2","text":"MASC_RESUMED_OK","phase":"final_answer"}}}|}
;;

let resumed_turn_completed =
  {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-2","items":[{"type":"agentMessage","id":"message-2","text":"MASC_RESUMED_OK","phase":"final_answer"}],"status":"completed"}}}|}
;;

let shell_quote value =
  "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' value) ^ "'"
;;

let rec drop count values =
  if count <= 0
  then values
  else
    match values with
    | [] -> []
    | _ :: rest -> drop (count - 1) rest
;;

(* macOS charges a one-time check on the first exec of every freshly written
   executable — measured at 0.26-0.33s (tail past 0.5s under load) on the
   reference machine, against 5-16ms for a re-run of the same file. The
   sub-100ms admission timeouts in this suite sat under that cost and timed
   out during the handshake (#31220). Every fixture script therefore takes a
   [--masc-warmup] first argument that exits before touching stdin, and is
   executed once with it right after creation, so the measured run pays only
   the re-run cost. *)

(* Two orders of magnitude above the measured first-exec cost. Only a wedged
   system check should ever reach it. *)
let warmup_deadline_s = 10.0

(* The warmup must be bounded: under full-suite load the first-exec check
   itself can wedge — a stack sample of this binary stuck for 5+ minutes
   showed 100% of samples inside [Sys.command]'s wait4 on the warmup child
   (#32181), so the unbounded wait turned a latency workaround into a
   suite-wide hang. The warmup is best-effort by design: on deadline the
   child is killed and the measured run pays the first-exec cost itself,
   which costs accuracy on one admission timing, not the whole suite. The
   child is spawned directly rather than through [Sys.command]'s shell so
   the deadline kill reaches the script, not an intermediate [sh]. *)
let warm_fresh_executable path =
  match
    Unix.create_process
      path
      [| path; "--masc-warmup" |]
      Unix.stdin
      Unix.stdout
      Unix.stderr
  with
  | exception Unix.Unix_error _ -> ()
  | pid ->
    let deadline = Unix.gettimeofday () +. warmup_deadline_s in
    let rec reap_blocking () =
      match Unix.waitpid [] pid with
      | _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> reap_blocking ()
      | exception Unix.Unix_error _ -> ()
    in
    let rec wait () =
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
        if Unix.gettimeofday () >= deadline
        then begin
          (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
          reap_blocking ()
        end
        else begin
          Unix.sleepf 0.01;
          wait ()
        end
      | _, _ -> ()
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait ()
      | exception Unix.Unix_error _ -> ()
    in
    wait ()
;;

let fixture_script ?capture_path ?initial_line_delay_s ?terminal_line_delay_s
    ?(terminal_line_delay_start_index = 0) ?before_final_stdin_drain_s lines =
  let path = Filename.temp_file "masc-codex-app-server-" ".sh" in
  let output = open_out_bin path in
  let read_request ?(expect_version = false) () =
    output_string output "IFS= read -r request\n";
    if expect_version
    then
      output_string output
        (Printf.sprintf
           "printf '%%s' \"$request\" | grep -F %s >/dev/null || exit 97\n"
           (shell_quote (Printf.sprintf {|"version":"%s"|} Runtime_build_version.current)));
    Option.iter
      (fun capture_path ->
         output_string
           output
           ("printf '%s\\n' \"$request\" >> " ^ shell_quote capture_path ^ "\n"))
      capture_path
  in
  output_string output "#!/bin/sh\n";
  output_string output "case \"$1\" in --masc-warmup) exit 0 ;; esac\n";
  read_request ~expect_version:true ();
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    initial_line_delay_s;
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 0) ^ "\n");
  read_request ();
  read_request ();
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 1) ^ "\n");
  read_request ();
  output_string output ("printf '%s\\n' " ^ shell_quote (List.nth lines 2) ^ "\n");
  read_request ();
  List.iteri
    (fun index line ->
       if index >= terminal_line_delay_start_index
       then
         Option.iter
           (fun seconds ->
              output_string output (Printf.sprintf "sleep %.3f\n" seconds))
           terminal_line_delay_s;
       output_string output ("printf '%s\\n' " ^ shell_quote line ^ "\n"))
    (drop 3 lines);
  Option.iter
    (fun seconds -> output_string output (Printf.sprintf "sleep %.3f\n" seconds))
    before_final_stdin_drain_s;
  output_string output "while IFS= read -r ignored; do :; done\n";
  close_out output;
  Unix.chmod path 0o700;
  warm_fresh_executable path;
  path
;;

let with_fixture ?capture_path ?initial_line_delay_s ?terminal_line_delay_s
    ?terminal_line_delay_start_index ?before_final_stdin_drain_s lines f =
  let path =
    fixture_script
      ?capture_path
      ?initial_line_delay_s
      ?terminal_line_delay_s
      ?terminal_line_delay_start_index
      ?before_final_stdin_drain_s
      lines
  in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let with_fixture_sequence ?capture_path first_lines second_lines f =
  let first_path = fixture_script ?capture_path first_lines in
  let second_path = fixture_script ?capture_path second_lines in
  let counter_path = Filename.temp_file "masc-codex-fixture-count-" ".txt" in
  Sys.remove counter_path;
  let path = Filename.temp_file "masc-codex-fixture-sequence-" ".sh" in
  let output = open_out_bin path in
  output_string output "#!/bin/sh\n";
  output_string output "case \"$1\" in --masc-warmup) exit 0 ;; esac\n";
  output_string output "count=0\n";
  output_string output
    ("if [ -f " ^ shell_quote counter_path ^ " ]; then\n"
     ^ "  IFS= read -r count < " ^ shell_quote counter_path ^ "\n"
     ^ "fi\n");
  output_string output "count=$((count + 1))\n";
  output_string output
    ("printf '%s\\n' \"$count\" > " ^ shell_quote counter_path ^ "\n");
  output_string output
    ("if [ \"$count\" -eq 1 ]; then\n"
     ^ "  exec " ^ shell_quote first_path ^ "\n"
     ^ "else\n"
     ^ "  exec " ^ shell_quote second_path ^ "\n"
     ^ "fi\n");
  close_out output;
  Unix.chmod path 0o700;
  warm_fresh_executable path;
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun candidate ->
           if Sys.file_exists candidate then Sys.remove candidate)
        [ path; first_path; second_path; counter_path ])
    (fun () -> f path)
;;

let run_fixture ?(dynamic_tools = []) ?thread_mode ?(history = []) ?(cwd = "/tmp")
    ?(timeout_s = 2.0) ?admission_timeout_s ?(no_turn_deadline = false)
    ?on_thread_ready_delay_s ?on_turn_started_delay_s ?on_stream_event
    ?(images = []) ?(native = Runtime_native_tools.codex_default) path =
  Eio_main.run (fun env ->
    let clock = Eio.Stdenv.clock env in
    let config =
      { (Runtime_codex_app_server.default_config ()) with
        cli_path = path
      ; native
      ; admission_timeout_s = Option.value admission_timeout_s ~default:timeout_s
      ; timeout_s = if no_turn_deadline then None else Some timeout_s
      }
    in
    let on_thread_ready =
      Option.map
        (fun delay_s ~thread_id:_ ->
           Eio.Time.sleep clock delay_s;
           Ok ())
        on_thread_ready_delay_s
    in
    let on_turn_started =
      Option.map
        (fun delay_s ~thread_id:_ ~turn_id:_ ->
           Eio.Time.sleep clock delay_s;
           Ok ())
        on_turn_started_delay_s
    in
    Runtime_codex_app_server.run_turn
      ~mgr:(Eio.Stdenv.process_mgr env)
      ~clock
      ~cwd:Eio.Path.(Eio.Stdenv.fs env / cwd)
      ~dynamic_tools
      ?thread_mode
      ~history
      ?on_thread_ready
      ?on_turn_started
      ?on_stream_event
      config
      ~prompt:"Return the fixture marker"
      ~images)
;;

let test_dispatch_validation_is_process_free () =
  let config =
    { (Runtime_codex_app_server.default_config ()) with cli_path = "" }
  in
  Eio_main.run (fun env ->
    match
      Runtime_codex_app_server.validate_turn
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
        config
        ~prompt:"fixture"
        ~images:[]
    with
    | Error (Runtime_codex_app_server.Invalid_config "cli_path must not be empty") -> ()
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok () -> fail "invalid deterministic client config passed admission")
;;

let tool_call_request =
  {|{"id":"tool-request-1","method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","tool":"masc_probe","namespace":null,"arguments":{"marker":"from-codex"}}}|}
;;

let native_command_started =
  {|{"method":"item/started","params":{"threadId":"thread-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"native-command-1","command":"pwd","commandActions":[],"cwd":"/tmp","status":"inProgress"}}}|}
;;

let native_command_completed =
  {|{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","completedAtMs":2,"item":{"type":"commandExecution","id":"native-command-1","command":"pwd","commandActions":[],"cwd":"/tmp","status":"completed","aggregatedOutput":"/tmp"}}}|}
;;

let test_dynamic_tool_callback () =
  let call_id = ref None in
  let arguments = ref `Null in
  let stream_events = ref [] in
  let tool : Runtime_codex_app_server.dynamic_tool =
    { name = "masc_probe"
    ; description = "Return a deterministic fixture marker"
    ; input_schema =
        `Assoc
          [ "type", `String "object"
          ; "properties", `Assoc [ "marker", `Assoc [ "type", `String "string" ] ]
          ; "required", `List [ `String "marker" ]
          ]
    ; call =
        (fun ~call_id:id input ->
          call_id := Some id;
          arguments := input;
          { success = true; content = "MASC_TOOL_RESULT"; abort_turn = None })
    }
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; agent_message_delta
    ; tool_call_request
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       match
         run_fixture
           ~dynamic_tools:[ tool ]
           ~on_stream_event:(fun event -> stream_events := event :: !stream_events)
           path
       with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result ->
         check int "measured tool calls" 1 result.dynamic_tool_calls;
         check (option string) "call id" (Some "call-1") !call_id;
         check string
           "arguments"
           {|{"marker":"from-codex"}|}
           (Yojson.Safe.to_string !arguments);
         let open Runtime_codex_app_server in
         (match List.rev !stream_events with
          | [ Turn_started { turn_id = "turn-1"; model = "gpt-fixture" }
            ; Text_delta "MASC_"
            ; Dynamic_tool_started
                { call_id = "call-1"; tool_name = "masc_probe"; arguments }
            ; Dynamic_tool_finished { call_id = "call-1" }
            ; Turn_finished { text = "MASC_SUBSCRIPTION_OK" }
            ] ->
            check string
              "stream arguments"
              {|{"marker":"from-codex"}|}
              (Yojson.Safe.to_string arguments)
          | _ -> fail "Codex live stream events were not projected in wire order"))
;;

let test_native_command_events_stay_distinct_from_dynamic_tools () =
  let stream_events = ref [] in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; native_command_started
    ; native_command_completed
    ; agent_message_delta
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       match
         run_fixture
           ~on_stream_event:(fun event -> stream_events := event :: !stream_events)
           path
       with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result ->
         check int "no MASC dynamic calls" 0 result.dynamic_tool_calls;
         let open Runtime_codex_app_server in
         match List.rev !stream_events with
         | [ Turn_started { turn_id = "turn-1"; model = "gpt-fixture" }
           ; Native_tool_started
               { identity = Some (Runtime_native_tools.Call_id "native-command-1")
               ; tool_name = Some "commandExecution"
               ; origin = Runtime_native_tools.Built_in
               }
           ; Native_tool_finished
               { identity = Some (Runtime_native_tools.Call_id "native-command-1")
               ; tool_name = Some "commandExecution"
               ; origin = Runtime_native_tools.Built_in
               }
           ; Text_delta "MASC_"
           ; Turn_finished { text = "MASC_SUBSCRIPTION_OK" }
           ] -> ()
         | _ -> fail "Codex native command activity was projected as a MASC tool")
;;

let test_dynamic_tool_abort_stops_the_provider_loop () =
  let tool : Runtime_codex_app_server.dynamic_tool =
    { name = "masc_probe"
    ; description = "Abort a repeated provider loop"
    ; input_schema = `Assoc [ "type", `String "object" ]
    ; call =
        (fun ~call_id:_ _ ->
          { success = false
          ; content = "same deterministic failure"
          ; abort_turn =
              Some
                (Repeated_tool_call
                   { tool_name = "masc_probe"; repeated_count = 3 })
          })
    }
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; tool_call_request ]
    (fun path ->
      match run_fixture ~dynamic_tools:[ tool ] path with
      | Error
          (Runtime_codex_app_server.Stopped_by_host
            (Repeated_tool_call { tool_name; repeated_count })) ->
        check string "tool" "masc_probe" tool_name;
        check int "repeat count" 3 repeated_count
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "dynamic tool abort did not stop the Codex turn")
;;

let test_context_error_records_prior_tool_effect () =
  let tool : Runtime_codex_app_server.dynamic_tool =
    { name = "masc_probe"
    ; description = "Record one deterministic tool effect"
    ; input_schema = `Assoc [ "type", `String "object" ]
    ; call =
        (fun ~call_id:_ _ ->
          { Runtime_codex_app_server.success = true
          ; content = "effect applied"
          ; abort_turn = None
          })
    }
  in
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}}|}
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; tool_call_request
    ; failed
    ]
    (fun path ->
       match run_fixture ~dynamic_tools:[ tool ] path with
       | Error
           (Runtime_codex_app_server.Context_window_exceeded
              { message = "context is full"; tool_effect_attempted = true }) ->
         ()
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "context overflow after a tool effect was not reported")
;;

let test_history_is_injected_before_turn () =
  let injected = {|{"id":4,"result":{}}|} in
  let turn_after_injection = {|{"id":5,"result":{"turn":{"id":"turn-1"}}}|} in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; injected
    ; turn_after_injection
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       let history =
         [ { Runtime_codex_app_server.role = User; text = "previous user" }
         ; { Runtime_codex_app_server.role = Assistant; text = "previous assistant" }
         ]
       in
       match run_fixture ~history path with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result -> check string "text" "MASC_SUBSCRIPTION_OK" result.text)
;;

(* The image has to land in the turn/start input list as an inline data URL --
   the app-server README rejects remote HTTP(S) urls, so the encoding is part of
   the contract, not a detail. Reading the captured request means a projection
   that drops the image fails here instead of passing on a fixture reply that
   never depended on it. *)
let test_image_reaches_the_turn_input () =
  let capture_path = Filename.temp_file "masc-codex-image-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove capture_path with _ -> ())
    (fun () ->
      with_fixture
        ~capture_path
        [ init_result
        ; account_chatgpt
        ; thread_result
        ; turn_result
        ; item_completed
        ; turn_completed
        ]
        (fun path ->
          let image =
            { Runtime_codex_app_server.media_type = "image/png"
            ; base64_data = "aGVsbG8="
            }
          in
          match run_fixture ~images:[ image ] path with
          | Error error -> fail (Runtime_codex_app_server.error_to_string error)
          | Ok _ ->
            let input =
              Masc_test_deps.read_file capture_path
              |> String.split_on_char '\n'
              |> List.filter (fun line -> String.trim line <> "")
              |> List.map Yojson.Safe.from_string
              |> List.find (fun json ->
                   Yojson.Safe.Util.member "method" json = `String "turn/start")
              |> Yojson.Safe.Util.member "params"
              |> Yojson.Safe.Util.member "input"
              |> Yojson.Safe.Util.to_list
            in
            (match
               List.find_opt
                 (fun item -> Yojson.Safe.Util.member "type" item = `String "image")
                 input
             with
             | None -> fail "turn/start input carried no image item"
             | Some item ->
               check
                 string
                 "inline data url"
                 "data:image/png;base64,aGVsbG8="
                 (Yojson.Safe.Util.to_string (Yojson.Safe.Util.member "url" item)))))
;;

(* A media type the item cannot carry is rejected before the process boundary,
   so the caller learns which image is wrong instead of reading a turn rejection
   attributed to the thread. *)
let test_unsupported_image_media_type_is_rejected () =
  Eio_main.run (fun env ->
    let config =
      { (Runtime_codex_app_server.default_config ()) with cli_path = "/bin/true" }
    in
    let image =
      { Runtime_codex_app_server.media_type = "image/tiff"; base64_data = "AAAA" }
    in
    match
      Runtime_codex_app_server.validate_turn
        ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
        config
        ~prompt:"x"
        ~images:[ image ]
    with
    | Ok () -> fail "an unsupported media type must not validate"
    | Error (Runtime_codex_app_server.Invalid_config detail) ->
      check bool "names the media type" true
        (String_util.contains_substring detail "image/tiff")
    | Error other -> fail (Runtime_codex_app_server.error_to_string other))
;;

let test_chatgpt_subscription_turn () =
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok result ->
        check string "text" "MASC_SUBSCRIPTION_OK" result.text;
        check string "thread" "thread-1" result.thread_id;
        check string "turn" "turn-1" result.turn_id;
        check string "model" "gpt-fixture" result.model;
        check string "plan" "pro" result.subscription.plan_type;
        check bool "new thread" false result.resumed)
;;

let test_subscription_probe_stops_before_thread () =
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
      let outcome =
        Eio_main.run (fun env ->
          let config =
            { (Runtime_codex_app_server.default_config ()) with
              cli_path = path
            ; timeout_s = Some 2.0
            }
          in
          Runtime_codex_app_server.probe_subscription
            ~mgr:(Eio.Stdenv.process_mgr env)
            ~clock:(Eio.Stdenv.clock env)
            ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
            config)
      in
      match outcome with
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok probe ->
        check string "plan" "pro" probe.subscription.plan_type;
        check (option string) "user agent" (Some "fixture/0.147.0") probe.user_agent)
;;

let test_thread_resume_skips_history_injection () =
  let history =
    [ { Runtime_codex_app_server.role = User; text = "already in official thread" } ]
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
       match
         run_fixture
           ~thread_mode:(Runtime_codex_app_server.Resume { thread_id = "thread-1" })
           ~history
           path
       with
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok result ->
         check bool "resumed" true result.resumed;
         check string "thread" "thread-1" result.thread_id)
;;

let test_thread_resume_sends_dynamic_tools () =
  let capture_path = Filename.temp_file "masc-codex-resume-requests-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove capture_path)
    (fun () ->
       let tool : Runtime_codex_app_server.dynamic_tool =
         { name = "masc_probe"
         ; description = "Return a deterministic fixture marker"
         ; input_schema = `Assoc [ "type", `String "object" ]
         ; call =
             (fun ~call_id:_ _ ->
               { success = true; content = "unused"; abort_turn = None })
         }
       in
       with_fixture
         ~capture_path
         [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
         (fun path ->
            match
              run_fixture
                ~dynamic_tools:[ tool ]
                ~thread_mode:(Runtime_codex_app_server.Resume { thread_id = "thread-1" })
                path
            with
            | Error error -> fail (Runtime_codex_app_server.error_to_string error)
            | Ok _ -> ());
       let requests =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       let resume_request =
         List.find
           (fun json -> Yojson.Safe.Util.member "id" json = `Int 3)
           requests
       in
       let dynamic_tools =
         resume_request
         |> Yojson.Safe.Util.member "params"
         |> Yojson.Safe.Util.member "dynamicTools"
         |> Yojson.Safe.Util.to_list
       in
       check int "resume tool count" 1 (List.length dynamic_tools);
       check string "resume tool name" "masc_probe"
         (dynamic_tools
          |> List.hd
          |> Yojson.Safe.Util.member "name"
          |> Yojson.Safe.Util.to_string))
;;

(* The app-server takes two encodings of [dynamicTools] and refuses a mix. The
   legacy one is tagged ["type": "function"] and cannot defer -- it answers
   [deferLoading: true] with "deferred dynamic tool must include a namespace"
   and has nowhere to put one. So the tag has to be absent and the namespace
   present, together, or the whole thread/start is rejected. A test that
   checked only one of them would pass on a spec the server will not take. *)
let test_dynamic_tools_are_declared_deferred_under_one_namespace () =
  let capture_path = Filename.temp_file "masc-codex-defer-requests-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove capture_path)
    (fun () ->
       let tool : Runtime_codex_app_server.dynamic_tool =
         { name = "masc_probe"
         ; description = "Return a deterministic fixture marker"
         ; input_schema = `Assoc [ "type", `String "object" ]
         ; call =
             (fun ~call_id:_ _ ->
               { success = true; content = "unused"; abort_turn = None })
         }
       in
       with_fixture
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun path ->
            match run_fixture ~dynamic_tools:[ tool ] path with
            | Error error -> fail (Runtime_codex_app_server.error_to_string error)
            | Ok _ -> ());
       let requests =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       let tool_json =
         List.find (fun json -> Yojson.Safe.Util.member "id" json = `Int 3) requests
         |> Yojson.Safe.Util.member "params"
         |> Yojson.Safe.Util.member "dynamicTools"
         |> Yojson.Safe.Util.to_list
         |> List.hd
       in
       check
         bool
         "the legacy type tag is absent, so this is the canonical encoding"
         true
         (Yojson.Safe.Util.member "type" tool_json = `Null);
       check
         string
         "every tool is declared under one namespace"
         "masc"
         (Yojson.Safe.Util.member "namespace" tool_json |> Yojson.Safe.Util.to_string);
       check
         bool
         "and deferred, which is what the namespace is required for"
         true
         (Yojson.Safe.Util.member "deferLoading" tool_json |> Yojson.Safe.Util.to_bool))
;;

let test_thread_resume_rejects_identity_mismatch () =
  let wrong_thread =
    {|{"id":3,"result":{"thread":{"id":"thread-other"},"model":"gpt-fixture"}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; wrong_thread; turn_result; item_completed; turn_completed ]
    (fun path ->
       match
         run_fixture
           ~thread_mode:(Runtime_codex_app_server.Resume { thread_id = "thread-1" })
           path
       with
       | Error (Runtime_codex_app_server.Protocol_error _) -> ()
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "thread/resume admitted a different returned thread id")
;;

let test_api_key_account_is_rejected () =
  let api_key_account =
    {|{"id":2,"result":{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}}|}
  in
  with_fixture
    [ init_result; api_key_account; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Subscription_required _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "API-key account incorrectly admitted as subscription")
;;

let test_malformed_json_fails_closed () =
  with_fixture
    [ "not-json"; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "malformed JSON incorrectly admitted")
;;

let test_duplicate_object_keys_fail_closed () =
  let assert_protocol_error label lines =
    with_fixture lines (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (label ^ ": " ^ Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail (label ^ ": duplicate key incorrectly admitted"))
  in
  assert_protocol_error
    "top-level"
    [ {|{"id":1,"id":1,"result":{"userAgent":"fixture/0.147.0","codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"linux"}}|}
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ];
  assert_protocol_error
    "nested"
    [ init_result
    ; {|{"id":2,"result":{"account":{"type":"chatgpt","type":"apiKey","email":"fixture@example.test","planType":"pro"},"requiresOpenaiAuth":true}}|}
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
;;

let test_notification_without_params_fails_closed () =
  let missing_params = {|{"method":"item/completed"}|} in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; missing_params ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "notification without params incorrectly admitted")
;;

let test_server_request_fails_closed () =
  let request =
    {|{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; request ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Unsupported_server_request method_) ->
        check string
          "method"
          "item/commandExecution/requestApproval"
          method_
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "unsupported server request incorrectly admitted")
;;

(* A live keeper failed every turn on a context overflow the server reported,
   and the receipt carried only the sentence: nothing downstream could tell that
   failure class from any other Turn_failed (#28071). The server's own error
   object is the only place a typed field could come from, and this function was
   dropping everything but [message]. The expectation names the annotation
   literally rather than re-rendering the function, so it fails if the field
   stops being carried. *)
let test_failed_turn_keeps_typed_error_fields () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"ran out of room in the model's context window","code":"context_length_exceeded"}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Turn_failed detail) ->
        check
          bool
          "provider sentence survives"
          true
          (Astring.String.is_infix ~affix:"ran out of room" detail);
        check
          bool
          "typed code survives"
          true
          (Astring.String.is_infix ~affix:"code=context_length_exceeded" detail)
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "failed turn incorrectly reported as completed")
;;

let test_failed_turn_uses_official_context_error_enum () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"ran out of room in the model's context window","codexErrorInfo":"contextWindowExceeded"}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun path ->
      match run_fixture path with
      | Error
          (Runtime_codex_app_server.Context_window_exceeded
             { message; tool_effect_attempted = false }) ->
        check
          string
          "provider message"
          "ran out of room in the model's context window"
          message
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "typed context overflow incorrectly reported as completed")
;;

(* The named-field form could not distinguish "the server sent no scalar" from
   "the scalar is called something else": both printed the sentence with no
   annotation. That is what a live Keeper produced on 2026-08-11 after the narrow
   form deployed. This fixture carries no [code] and no [type], so it renders
   the sentence unannotated under the named form and fails there. The
   expectations are literals rather than a re-render of the function, and one
   of them asserts [message] is *not* repeated as an annotation. *)
let test_failed_turn_keeps_unnamed_error_scalars () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"ran out of room in the model's context window","kind":"context_length","http_status":400,"retryable":false,"details":{"nested":"skipped"}}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Turn_failed detail) ->
        check
          bool
          "provider sentence survives"
          true
          (Astring.String.is_infix ~affix:"ran out of room" detail);
        check
          bool
          "string scalar outside the named list survives"
          true
          (Astring.String.is_infix ~affix:"kind=context_length" detail);
        check
          bool
          "int scalar survives"
          true
          (Astring.String.is_infix ~affix:"http_status=400" detail);
        check
          bool
          "bool scalar survives"
          true
          (Astring.String.is_infix ~affix:"retryable=false" detail);
        check
          bool
          "nested object is skipped"
          false
          (Astring.String.is_infix ~affix:"details=" detail);
        check
          bool
          "message is not repeated as an annotation"
          false
          (Astring.String.is_infix ~affix:"message=" detail)
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "failed turn incorrectly reported as completed")
;;

(* These two sizes are the only report of what a turn actually sends: the
   keeper log's [system_and_user_bytes] sums the prompt strings and omits both
   the history and the tool declarations (#28071). The expectations are computed
   literals, not a second call to the function under test — that would pass for
   any implementation. *)
let test_history_bytes_sums_text_only () =
  let messages =
    [ { Runtime_codex_app_server.role = Runtime_codex_app_server.User
      ; text = "abcde"
      }
    ; { Runtime_codex_app_server.role = Runtime_codex_app_server.Assistant
      ; text = "fghijklmno"
      }
    ]
  in
  check int "sum of both texts" 15 (Runtime_codex_app_server.history_bytes messages);
  check int "empty history is zero" 0 (Runtime_codex_app_server.history_bytes []);
  (* The role is not part of the payload size: two messages differing only in
     role must measure the same, or the number would drift with the split
     between user and assistant turns rather than with the bytes sent. *)
  check
    int
    "role does not change the size"
    (Runtime_codex_app_server.history_bytes
       [ { Runtime_codex_app_server.role = Runtime_codex_app_server.User
         ; text = "same"
         }
       ])
    (Runtime_codex_app_server.history_bytes
       [ { Runtime_codex_app_server.role = Runtime_codex_app_server.Assistant
         ; text = "same"
         }
       ])
;;

let test_dynamic_tool_bytes_counts_name_description_and_schema () =
  let tool name description schema =
    { Runtime_codex_app_server.name
    ; description
    ; input_schema = schema
    ; call =
        (fun ~call_id:_ _ ->
          { Runtime_codex_app_server.success = true
          ; content = ""
          ; abort_turn = None
          })
    }
  in
  (* {"type":"object"} serializes to 17 bytes; name 2 + description 3 + 17 = 22. *)
  let schema = `Assoc [ "type", `String "object" ] in
  check
    int
    "one tool: name + description + serialized schema"
    22
    (Runtime_codex_app_server.dynamic_tool_bytes [ tool "ab" "cde" schema ]);
  check int "no tools is zero" 0 (Runtime_codex_app_server.dynamic_tool_bytes []);
  check
    int
    "two tools add up"
    44
    (Runtime_codex_app_server.dynamic_tool_bytes
       [ tool "ab" "cde" schema; tool "xy" "zzz" schema ])
;;

let test_failed_turn_is_not_completion () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"fixture failure"}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Turn_failed "fixture failure") -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "failed turn incorrectly reported as completed")
;;

let test_retry_notifications_are_observational () =
  (* Live incident 2026-08-10 (masc#27953): one upstream degradation window
     drove three keepers into Recovery_required twice in two hours because the
     turn died at the fourth willRetry:true. The app-server retrying upstream
     is progress, not failure; the stream-idle deadline is the liveness
     boundary. *)
  let retry = {|{"method":"error","params":{"willRetry":true}}|} in
  with_fixture
    ([ init_result; account_chatgpt; thread_result; turn_result ]
     @ List.init 10 (fun _ -> retry)
     @ [ item_completed; turn_completed ])
    (fun path ->
       match run_fixture path with
       | Ok turn ->
         check string "completed after retries" "MASC_SUBSCRIPTION_OK" turn.text
       | Error error -> fail (Runtime_codex_app_server.error_to_string error));
  let terminal =
    {|{"method":"error","params":{"willRetry":false,"error":{"message":"provider gave up"}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; terminal ]
    (fun path ->
       match run_fixture path with
       | Error (Runtime_codex_app_server.Turn_failed "provider gave up") -> ()
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "terminal error notification did not fail the turn")
;;

let test_progress_resets_stream_idle_timeout () =
  let retry = {|{"method":"error","params":{"willRetry":true}}|} in
  with_fixture
    ~terminal_line_delay_s:0.4
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; retry
    ; retry
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       match run_fixture ~timeout_s:0.75 path with
       | Ok turn ->
         check string "progressing turn completes" "MASC_SUBSCRIPTION_OK" turn.text
       | Error error -> fail (Runtime_codex_app_server.error_to_string error))
;;

let test_stream_idle_timeout_is_typed () =
  with_fixture
    ~terminal_line_delay_s:2.0
    [ init_result; account_chatgpt; thread_result; turn_result; turn_completed ]
    (fun path ->
       match run_fixture ~timeout_s:1.0 path with
       | Error
           (Runtime_codex_app_server.Timeout
              { seconds; turn_accepted = true }) ->
         check (float 0.001) "exact idle timeout" 1.0 seconds
       | Error
           (Runtime_codex_app_server.Timeout
              { turn_accepted = false; _ }) ->
         fail "a sent turn/start request was classified as pre-dispatch"
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "silent app-server stream ignored its idle timeout")
;;

let test_stream_idle_timeout_after_turn_acceptance_is_typed () =
  with_fixture
    ~terminal_line_delay_s:2.0
    ~terminal_line_delay_start_index:1
    [ init_result; account_chatgpt; thread_result; turn_result; turn_completed ]
    (fun path ->
       match run_fixture ~timeout_s:1.0 path with
       | Error
           (Runtime_codex_app_server.Timeout
              { seconds; turn_accepted = true }) ->
         check (float 0.001) "exact idle timeout" 1.0 seconds
       | Error
           (Runtime_codex_app_server.Timeout
              { turn_accepted = false; _ }) ->
         fail "turn/start acceptance was lost before the idle timeout"
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "accepted turn ignored its idle timeout")
;;

let test_no_deadline_keeps_handshake_bounded () =
  with_fixture
    ~initial_line_delay_s:0.75
    [ init_result; account_chatgpt; thread_result; turn_result; turn_completed ]
    (fun path ->
       match
         run_fixture
           ~admission_timeout_s:0.3
           ~no_turn_deadline:true
           path
       with
       | Error
           (Runtime_codex_app_server.Timeout
              { seconds; turn_accepted = false }) ->
         check (float 0.001) "admission timeout" 0.3 seconds
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "an unbounded turn disabled the app-server handshake bound")
;;

let test_no_deadline_starts_after_turn_acceptance () =
  with_fixture
    ~terminal_line_delay_s:0.75
    ~terminal_line_delay_start_index:1
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
    (fun path ->
       match
         run_fixture
           ~admission_timeout_s:0.3
           ~no_turn_deadline:true
           path
       with
       | Ok turn -> check string "unbounded result" "MASC_SUBSCRIPTION_OK" turn.text
       | Error error -> fail (Runtime_codex_app_server.error_to_string error))
;;

let test_state_callback_timeout_is_typed () =
  with_fixture [ init_result; account_chatgpt; thread_result ] (fun path ->
    match
      run_fixture
        ~timeout_s:0.3
        ~on_thread_ready_delay_s:0.75
        path
    with
    | Error (Runtime_codex_app_server.Timeout { seconds; _ }) ->
      check (float 0.001) "exact callback timeout" 0.3 seconds
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok _ -> fail "blocking app-server callback ignored its timeout")
;;

let test_no_deadline_keeps_admission_bounded () =
  with_fixture [ init_result; account_chatgpt; thread_result ] (fun path ->
    let outcome =
      Eio_main.run (fun env ->
        let clock = Eio.Stdenv.clock env in
        let config =
          { (Runtime_codex_app_server.default_config ()) with
            cli_path = path
          ; admission_timeout_s = 0.3
          ; timeout_s = None
          }
        in
        Runtime_codex_app_server.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
          ~on_thread_ready:(fun ~thread_id:_ ->
            Eio.Time.sleep clock 0.75;
            Ok ())
          config
          ~prompt:"fixture"
          ~images:[])
    in
    match outcome with
    | Error (Runtime_codex_app_server.Timeout { seconds; turn_accepted = false }) ->
      check (float 0.001) "admission timeout" 0.3 seconds
    | Error (Runtime_codex_app_server.Timeout { turn_accepted = true; _ }) ->
      fail "pre-dispatch admission timeout was marked turn-accepted"
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok _ -> fail "no-deadline turn removed the admission timeout")
;;

let test_no_deadline_begins_after_turn_dispatch () =
  with_fixture
    ~terminal_line_delay_s:0.75
    [ init_result; account_chatgpt; thread_result; turn_result; turn_completed ]
    (fun path ->
       let outcome =
         Eio_main.run (fun env ->
           let config =
             { (Runtime_codex_app_server.default_config ()) with
               cli_path = path
             ; admission_timeout_s = 0.3
             ; timeout_s = None
             }
           in
           Runtime_codex_app_server.run_turn
             ~mgr:(Eio.Stdenv.process_mgr env)
             ~clock:(Eio.Stdenv.clock env)
             ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
             config
             ~prompt:"fixture"
             ~images:[])
       in
       match outcome with
       | Ok turn -> check string "turn completes" "MASC_SUBSCRIPTION_OK" turn.text
       | Error error -> fail (Runtime_codex_app_server.error_to_string error))
;;

let test_no_deadline_keeps_turn_started_callback_bounded () =
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result ]
    (fun path ->
       match
         run_fixture
           ~admission_timeout_s:0.3
           ~no_turn_deadline:true
           ~on_turn_started_delay_s:0.75
           path
       with
       | Error
           (Runtime_codex_app_server.Timeout
              { seconds; turn_accepted = true }) ->
         check (float 0.001) "host callback timeout" 0.3 seconds
       | Error
           (Runtime_codex_app_server.Timeout
              { turn_accepted = false; _ }) ->
         fail "accepted turn callback timeout lost dispatch ambiguity"
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "no-deadline turn made the host state callback unbounded")
;;

let test_no_deadline_keeps_post_accept_writes_bounded () =
  let tool : Runtime_codex_app_server.dynamic_tool =
    { name = "masc_probe"
    ; description = "Return enough data to fill an unread transport pipe"
    ; input_schema = `Assoc [ "type", `String "object" ]
    ; call =
        (fun ~call_id:_ _ ->
          { success = true
          ; content = String.make (1024 * 1024) 'x'
          ; abort_turn = None
          })
    }
  in
  with_fixture
    ~before_final_stdin_drain_s:0.75
    [ init_result; account_chatgpt; thread_result; turn_result; tool_call_request ]
    (fun path ->
       match
         run_fixture
           ~dynamic_tools:[ tool ]
           ~admission_timeout_s:0.3
           ~no_turn_deadline:true
           path
       with
       | Error
           (Runtime_codex_app_server.Timeout
              { seconds; turn_accepted = true }) ->
         check (float 0.001) "post-accept write timeout" 0.3 seconds
       | Error
           (Runtime_codex_app_server.Timeout
              { turn_accepted = false; _ }) ->
         fail "post-accept write timeout lost dispatch ambiguity"
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "no-deadline turn made a post-accept tool write unbounded")
;;

(* The former "dispatch ambiguity precedes turn-start acknowledgement" case
   was deleted rather than repaired (#28485). Born in #28322 asserting a
   write-bound saturation the runtime has never had — [await_response] rejects
   the FIRST unsupported server request and fails the turn, so its
   2048-request flood never reached the reject-write path, and under a 0.05s
   admission bound the observed error raced between [Unsupported_server_request]
   and the idle timeout. The fail-fast contract it could have pinned is
   already pinned deterministically by [test_server_request_fails_closed]
   above. Whether a pre-ack failure should classify as dispatch-ambiguous
   (not safe to retry) is a live design question tracked in the follow-up
   issue; a test for it belongs with that implementation. *)

let test_callback_timeout_origin_is_preserved_without_deadline () =
  with_fixture [ init_result; account_chatgpt; thread_result ] (fun path ->
    check_raises
      "callback-origin timeout escapes unchanged"
      Eio.Time.Timeout
      (fun () ->
         Eio_main.run (fun env ->
           let config =
             { (Runtime_codex_app_server.default_config ()) with
               cli_path = path
             ; timeout_s = None
             }
           in
           Runtime_codex_app_server.run_turn
             ~mgr:(Eio.Stdenv.process_mgr env)
             ~clock:(Eio.Stdenv.clock env)
             ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
             ~on_thread_ready:(fun ~thread_id:_ -> raise Eio.Time.Timeout)
             config
             ~prompt:"fixture"
             ~images:[]
           |> ignore)))
;;

let test_terminal_error_notification_uses_official_context_error_enum () =
  let terminal =
    {|{"method":"error","params":{"threadId":"thread-1","turnId":"turn-1","willRetry":false,"error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; terminal ]
    (fun path ->
       match run_fixture path with
       | Error
           (Runtime_codex_app_server.Context_window_exceeded
              { message = "context is full"; tool_effect_attempted = false }) ->
         ()
       | Error error -> fail (Runtime_codex_app_server.error_to_string error)
       | Ok _ -> fail "typed terminal context overflow did not fail the turn")
;;

let test_nonterminal_notifications_do_not_preempt_completion () =
  let progress =
    {|{"method":"account/rateLimits/updated","params":{"rateLimits":{}}}|}
  in
  let lines =
    [ init_result; account_chatgpt; thread_result; turn_result ]
    @ List.init 256 (fun _ -> progress)
    @ [ item_completed; turn_completed ]
  in
  with_fixture lines (fun path ->
    match run_fixture path with
    | Ok turn ->
      check string "completed after progress" "MASC_SUBSCRIPTION_OK" turn.text
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    )
;;

let test_item_output_deltas_are_typed_and_unbounded () =
  let delta index =
    Printf.sprintf
      {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"command-1","delta":"chunk-%d"}}|}
      index
  in
  with_fixture
    ([ init_result; account_chatgpt; thread_result; turn_result ]
     @ List.init 129 delta
     @ [ item_completed; turn_completed ])
    (fun path ->
      match run_fixture path with
      | Ok result ->
        check string "terminal text" "MASC_SUBSCRIPTION_OK" result.text
      | Error error -> fail (Runtime_codex_app_server.error_to_string error));
  let wrong_identity =
    {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-other","turnId":"turn-1","itemId":"command-1","delta":"chunk"}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; wrong_identity ]
    (fun path ->
      match run_fixture path with
      | Error (Runtime_codex_app_server.Protocol_error _) -> ()
      | Error error -> fail (Runtime_codex_app_server.error_to_string error)
      | Ok _ -> fail "item output delta with the wrong identity was admitted")
;;

(* An empty or whitespace stream chunk is ordinary in a streaming protocol and
   this decoder never reads the payload. It used to reject both, which ended
   the turn, put the official-client session into Recovery_required, and made
   every later turn for that keeper fail closed until an operator resolved it
   by hand: three such chunks accounted for 3,236 rejected turns across three
   Keepers in one retained log window (#27967).

   The rejections that must survive are in the same test, because widening a
   decoder is only correct if it stops accepting nothing else: an empty
   identifier, a delta that is not a string, an absent delta, and a chunk
   belonging to another turn. *)
let test_empty_output_delta_does_not_end_the_turn () =
  let delta payload =
    Printf.sprintf
      {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"command-1","delta":%s}}|}
      payload
  in
  List.iter
    (fun (label, payload) ->
      with_fixture
        [ init_result
        ; account_chatgpt
        ; thread_result
        ; turn_result
        ; delta payload
        ; item_completed
        ; turn_completed
        ]
        (fun path ->
          match run_fixture path with
          | Ok result -> check string label "MASC_SUBSCRIPTION_OK" result.text
          | Error error -> fail (Runtime_codex_app_server.error_to_string error)))
    [ "empty delta", {|""|}
    ; "whitespace delta", {|"   "|}
    ; "newline delta", {|"\n"|}
    ];
  (* itemId is not read here, so its content cannot change what this frame
     decides. It used to be required non-empty and a keeper died on the frames
     that carried it empty; the identity check that does matter -- threadId and
     turnId -- is asserted unchanged in the rejection list below. *)
  List.iter
    (fun (label, notification) ->
      with_fixture
        [ init_result
        ; account_chatgpt
        ; thread_result
        ; turn_result
        ; notification
        ; item_completed
        ; turn_completed
        ]
        (fun path ->
          match run_fixture path with
          | Ok result -> check string label "MASC_SUBSCRIPTION_OK" result.text
          | Error error -> fail (Runtime_codex_app_server.error_to_string error)))
    [ ( "empty itemId"
      , {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"","delta":"chunk"}}|}
      )
    ; ( "absent itemId"
      , {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"chunk"}}|}
      )
    ];
  List.iter
    (fun (label, notification) ->
      with_fixture
        [ init_result; account_chatgpt; thread_result; turn_result; notification ]
        (fun path ->
          match run_fixture path with
          | Error (Runtime_codex_app_server.Protocol_error _) -> ()
          | Error error -> fail (Runtime_codex_app_server.error_to_string error)
          | Ok _ -> fail label))
    [ ( "a non-string delta was admitted", delta "42" )
    ; ( "a delta that is not present was admitted"
      , {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"command-1"}}|}
      )
    ; ( "an empty turnId was admitted"
      , {|{"method":"item/commandExecution/outputDelta","params":{"threadId":"thread-1","turnId":"","itemId":"command-1","delta":"chunk"}}|}
      )
    ]
;;

let codex_runtime_toml ~model cli_path =
  Printf.sprintf
    "[providers.codex]\n\
     protocol = \"codex-app-server\"\n\
     command = %S\n\
     is-non-interactive = true\n\
     \n\
     [models.codex]\n\
     api-name = %S\n\
     max-context = 400000\n\
     \n\
     [codex.codex]\n\
     \n\
     [runtime]\n\
     default = \"codex.codex\"\n"
    cli_path
    model
;;

let with_runtime_config ~model cli_path f =
  let path = Filename.temp_file "masc-codex-runtime-" ".toml" in
  let output = open_out_bin path in
  output_string output (codex_runtime_toml ~model cli_path);
  close_out output;
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let keeper_response_text (result : Runtime_agent.run_result) =
  result.response.content
  |> List.filter_map (function Agent_core.Types.Text text -> Some text | _ -> None)
  |> String.concat ""
;;

let temp_workspace prefix =
  let path = Filename.temp_file prefix "" in
  Unix.unlink path;
  Unix.mkdir path 0o755;
  path
;;

let cleanup_tree root =
  let rec remove path =
    if Sys.file_exists path
    then if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun name -> remove (Filename.concat path name));
        Unix.rmdir path)
      else Unix.unlink path
  in
  try remove root with
  | _ -> ()
;;

let test_declared_cwd_reaches_spawn () =
  let workspace = temp_workspace "masc-codex-cwd-" in
  let marker = Filename.concat workspace "spawn-cwd.txt" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree workspace)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun fixture ->
            let wrapper = Filename.temp_file "masc-codex-cwd-wrapper-" ".sh" in
            Fun.protect
              ~finally:(fun () -> Sys.remove wrapper)
              (fun () ->
                 let output = open_out_bin wrapper in
                 output_string output "#!/bin/sh\n";
                 output_string output ("pwd > " ^ shell_quote marker ^ "\n");
                 output_string output
                   ("exec " ^ shell_quote fixture ^ " \"$@\"\n");
                 close_out output;
                 Unix.chmod wrapper 0o700;
                 (match run_fixture ~cwd:workspace wrapper with
                  | Error error ->
                    fail (Runtime_codex_app_server.error_to_string error)
                  | Ok _ -> ());
                 let input = open_in_bin marker in
                 let observed =
                   Fun.protect
                     ~finally:(fun () -> close_in input)
                     (fun () -> input_line input)
                 in
                 check string
                   "spawn cwd"
                   (Unix.realpath workspace)
                   (Unix.realpath observed))))
;;

let test_protocol_uses_spawn_cwd_and_named_permissions () =
  let workspace = temp_workspace "masc-codex-protocol-cwd-" in
  let capture_path = Filename.temp_file "masc-codex-protocol-" ".jsonl" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_tree workspace;
      Sys.remove capture_path)
    (fun () ->
       with_fixture
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun fixture ->
            match run_fixture ~cwd:workspace fixture with
            | Error error -> fail (Runtime_codex_app_server.error_to_string error)
            | Ok _ -> ());
       let requests =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       let initialize =
         List.find
           (fun json -> Yojson.Safe.Util.member "id" json = `Int 1)
           requests
       in
       let thread_start =
         List.find
           (fun json -> Yojson.Safe.Util.member "id" json = `Int 3)
           requests
       in
       let client_info =
         initialize
         |> Yojson.Safe.Util.member "params"
         |> Yojson.Safe.Util.member "clientInfo"
       in
       let params = Yojson.Safe.Util.member "params" thread_start in
       check string
         "client version SSOT"
         Runtime_build_version.current
         (client_info |> Yojson.Safe.Util.member "version" |> Yojson.Safe.Util.to_string);
       check string
         "protocol cwd"
         (Unix.realpath workspace)
         (params
          |> Yojson.Safe.Util.member "cwd"
          |> Yojson.Safe.Util.to_string
          |> Unix.realpath);
       check string
         "named permissions"
         ":read-only"
         (params |> Yojson.Safe.Util.member "permissions" |> Yojson.Safe.Util.to_string);
       check bool
         "legacy sandbox omitted"
         true
         (Yojson.Safe.Util.member "sandbox" params = `Null))
;;

(* [permissions] takes a named profile id, which is a different value space
   from the CLI's [SandboxMode]. codex-cli 0.153.2 answers
   [permissionProfile/list] with exactly ":read-only", ":workspace" and
   ":danger-full-access", so the full posture has to name ":workspace".
   "workspace-write" is a [SandboxMode] value belonging to the [sandbox] field
   this client never sends, and it names no profile: a thread asking for it
   would be refused on the first turn a keeper ran with full native tools. *)
let test_native_full_names_the_workspace_profile () =
  let workspace = temp_workspace "masc-codex-full-profile-" in
  let capture_path = Filename.temp_file "masc-codex-full-profile-" ".jsonl" in
  Fun.protect
    ~finally:(fun () ->
      cleanup_tree workspace;
      Sys.remove capture_path)
    (fun () ->
       with_fixture
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun fixture ->
            match
              run_fixture
                ~native:Runtime_native_tools.Native_full
                ~cwd:workspace
                fixture
            with
            | Error error -> fail (Runtime_codex_app_server.error_to_string error)
            | Ok _ -> ());
       let requests =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       let thread_start =
         List.find
           (fun json -> Yojson.Safe.Util.member "id" json = `Int 3)
           requests
       in
       let params = Yojson.Safe.Util.member "params" thread_start in
       check string
         "full posture names a listed profile id"
         ":workspace"
         (params |> Yojson.Safe.Util.member "permissions" |> Yojson.Safe.Util.to_string);
       check bool
         "legacy sandbox stays omitted under the full posture"
         true
         (Yojson.Safe.Util.member "sandbox" params = `Null))
;;

let test_child_environment_is_allowlisted () =
  let canary = "MASC_CODEX_SECRET_CANARY" in
  let previous = Sys.getenv_opt canary in
  Unix.putenv canary "must-not-reach-child";
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some value -> Unix.putenv canary value
      | None -> Unix.putenv canary "")
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun fixture ->
            let wrapper = Filename.temp_file "masc-codex-env-wrapper-" ".sh" in
            Fun.protect
              ~finally:(fun () -> Sys.remove wrapper)
              (fun () ->
                 let output = open_out_bin wrapper in
                 output_string output "#!/bin/sh\n";
                 output_string output
                   "if [ \"${MASC_CODEX_SECRET_CANARY+set}\" = set ]; then exit 71; fi\n";
                 output_string output "if [ -z \"${HOME:-}\" ]; then exit 72; fi\n";
                 output_string output ("exec " ^ shell_quote fixture ^ " \"$@\"\n");
                 close_out output;
                 Unix.chmod wrapper 0o700;
                 match run_fixture wrapper with
                 | Error error ->
                   fail (Runtime_codex_app_server.error_to_string error)
                 | Ok _ -> ())))
;;

let write_fixture_file path content =
  let output = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr output)
    (fun () -> output_string output content)
;;

let fixture_tool ?(parameters = []) ~name ~description () =
  Agent_core.Tool.create
    ~name
    ~description
    ~parameters
    (fun _ -> Ok { Agent_core.Types.content = "fixture"; _meta = None })
;;

let production_keeper_meta ~base_path ~trace_id =
  let name = "codex-production-fixture" in
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String name
         ; "trace_id", `String trace_id
         ])
  with
  | Ok meta -> meta
  | Error detail -> fail ("production Keeper meta fixture failed: " ^ detail)
;;

let run_production_keeper_turn ~base_path ~trace_id ~user_message ~cli_path ~model
    ~turn_instructions =
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot)
    (fun () ->
       with_runtime_config ~model cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
                Eio.Switch.run (fun sw ->
                  Fs_compat.set_fs (Eio.Stdenv.fs env);
                  Eio_context.set_env env;
                  Eio_context.with_test_env
                    ~net:(Eio.Stdenv.net env)
                    ~clock:(Eio.Stdenv.clock env)
                    ~mono_clock:(Eio.Stdenv.mono_clock env)
                    ~sw
                    (fun () ->
                       match Runtime.init_default ~config_path:runtime_path with
                       | Error error -> fail error
                       | Ok () ->
                         let config = Workspace.default_config base_path in
                         let meta = production_keeper_meta ~base_path ~trace_id in
                         ignore
                           (Keeper_registry.For_testing.register
                              ~base_path
                              meta.name
                              meta);
                         Eio.Switch.on_release sw (fun () ->
                           Keeper_registry.For_testing.unregister
                             ~base_path
                             meta.name);
                         Masc_test_deps.with_publication_recovery_registry
                           ~sw
                           ~fs:(Eio.Stdenv.fs env)
                           ~registry_root:base_path
                           (fun publication_recovery_registry ->
                              let publication_recovery =
                                { Keeper_publication_recovery_availability.provider =
                                    Masc_test_deps.publication_recovery_provider
                                      publication_recovery_registry
                                ; keeper_name = meta.name
                                }
                              in
                              Keeper_agent_run.run_turn
                                ~config
                                ~meta
                                ~publication_recovery
                                ~profile_defaults:
                                  Keeper_types_profile_defaults.empty_keeper_profile_defaults
                                ~turn_ctx_cell:
                                  (Keeper_tool_call_log.create_turn_ctx_cell ())
                                ~base_dir:(Filename.concat base_path "keeper-sessions")
                                ~max_context:400_000
                                ~build_turn_prompt:
                                  (fun ~base_system_prompt ~messages:_ ->
                                    { Keeper_agent_run.system_prompt = base_system_prompt
                                    ; dynamic_context =
                                        (match turn_instructions with
                                         | None -> ""
                                         | Some ti ->
                                           "--- Turn-specific instructions ---\n" ^ ti)
                                    })
                                ~user_message
                                ~turn_kind:Turn_record.Direct
                                ~skill_snapshot:
                                  (Skill_catalog_snapshot.config_unreadable
                                     ~detail:"test fixture has no Skill publication")
                                ~task_skill_selection:(Ok Keeper_task_skill_turn.empty)
                                ~runtime_id:"codex.codex"
                                ()))))))
;;

let run_keeper_turn ?(tools = []) ?hooks ?context_injector ?model_input_projection
    ?(initial_messages = []) ?base_path ?raw_trace_path
    ?on_event ?(keeper_name = "codex-fixture")
    ?(goal = "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools.") ~cli_path
    ~model () =
  let owns_base_path = Option.is_none base_path in
  let base_path =
    Option.value base_path ~default:(temp_workspace "masc-codex-session-")
  in
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore runtime_snapshot;
      if owns_base_path then cleanup_tree base_path)
    (fun () ->
       with_runtime_config ~model cli_path (fun runtime_path ->
         Eio_main.run (fun env ->
           Eio.Switch.run (fun sw ->
             Eio_context.set_env env;
             Eio_context.with_test_env
               ~net:(Eio.Stdenv.net env)
               ~clock:(Eio.Stdenv.clock env)
               ~mono_clock:(Eio.Stdenv.mono_clock env)
               ~sw
               (fun () ->
                  match Runtime.init_default ~config_path:runtime_path with
                  | Error error -> fail error
                  | Ok () ->
                    let raw_trace =
                      Option.map
                        (fun path ->
                           match
                             Agent_core.Raw_trace.create
                               ~session_id:"codex-fixture-session"
                               ~path
                               ()
                           with
                           | Ok sink -> sink
                           | Error error -> fail (Agent_core.Error.to_string error))
                        raw_trace_path
                    in
                    let context =
                      match tools with
                      | [] -> None
                      | _ :: _ -> Some (Agent_core.Context.create ())
                    in
                    Keeper_turn_driver.run_named
                      ~runtime_id:"codex.codex"
                      ~keeper_name
                      ~base_path
                      ~goal
                      ~tools
                      ~agent_core_tools:tools
                      ~initial_messages
                      ?model_input_projection
                      ?hooks
                      ?context_injector
                      ?context
                      ?raw_trace
                      ?on_event
                      ~sw
                      ~net:(Eio.Stdenv.net env)
                      ()
                    |> Result.map (fun selected ->
                      selected.Keeper_turn_driver.run_result))))))
;;

let test_keeper_maps_official_context_error_to_typed_core_error () =
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}}|}
  in
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; failed ]
    (fun cli_path ->
       match run_keeper_turn ~cli_path ~model:"gpt-fixture" () with
       | Error
           (Agent_core.Error.Api
              (Agent_core.Retry.ContextOverflow
                 { message = "context is full"; limit = None })) ->
         ()
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "Keeper erased the typed Codex context overflow")
;;

let test_keeper_does_not_retry_context_error_after_tool_effect () =
  let tool =
    fixture_tool
      ~name:"masc_probe"
      ~description:"Record one deterministic tool effect"
      ()
  in
  let failed =
    {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}}|}
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; tool_call_request
    ; failed
    ]
    (fun cli_path ->
       match
         run_keeper_turn
           ~tools:[ tool ]
           ~cli_path
           ~model:"gpt-fixture"
           ()
       with
       | Error error ->
         (* Since #28178 the provider-attempt effect fence intercepts this
            failure before the raw provider error reaches the caller: an
            observed tool effect forbids same-turn retry. Decode the typed
            envelope rather than matching its rendered prose — the fence is
            what this test is about, and [effect_disposition] is the field
            that carries it. *)
         (match Keeper_internal_error.classify_masc_internal_error error with
          | Some
              (Keeper_internal_error.Provider_attempt_effect_fenced
                 { effect_disposition; diagnostic; _ }) ->
            check
              string
              "the fence observed a tool effect (not Observation_unavailable)"
              "effect_attempted"
              (Keeper_provider_attempt_effect.to_string effect_disposition);
            check
              bool
              "the fence forbids same-turn retry"
              false
              (Keeper_provider_attempt_effect.allows_same_turn_retry
                 effect_disposition);
            check
              bool
              "the fenced envelope keeps the provider diagnostic"
              true
              (Astring.String.is_infix
                 ~affix:"context_window_exceeded_after_tool_effect"
                 diagnostic)
          | _ -> fail (Agent_core.Error.to_string error))
       | Ok _ -> fail "Keeper retried a context overflow after a tool effect")
;;

let test_keeper_shrinks_history_after_typed_context_error () =
  let capture_path = Filename.temp_file "masc-codex-shrink-requests-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove capture_path)
    (fun () ->
       let injected = {|{"id":4,"result":{}}|} in
       let turn_after_injection =
         {|{"id":5,"result":{"turn":{"id":"turn-1"}}}|}
       in
       let overflow =
         {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}}|}
       in
       let initial_messages =
         List.init 64 (fun index ->
           Agent_core.Types.user_msg
             (Printf.sprintf "%02d:%s" index (String.make 4_096 'x')))
       in
       with_fixture_sequence
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; injected
         ; turn_after_injection
         ; overflow
         ]
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; injected
         ; turn_after_injection
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages
                ~keeper_name:"codex-fixture-same-size-shrink"
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              check
                string
                "Keeper response"
                "MASC_SUBSCRIPTION_OK"
                (keeper_response_text result));
       let injected_item_counts =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input
           |> List.map Yojson.Safe.from_string
           |> List.filter_map (fun request ->
             if
               Yojson.Safe.Util.member "method" request
               = `String "thread/inject_items"
             then
               Some
                 (request
                  |> Yojson.Safe.Util.member "params"
                  |> Yojson.Safe.Util.member "items"
                  |> Yojson.Safe.Util.to_list
                  |> List.length)
             else None))
       in
       match injected_item_counts with
       | [ full_count; shrunk_count ] ->
         check int "first attempt keeps full history" 64 full_count;
         check bool "retry keeps non-empty history" true (shrunk_count > 0);
         check bool "retry shrinks provider-bound history" true
           (shrunk_count < full_count)
       | counts ->
         failf
           "expected two history injections, got counts=[%s]"
           (counts |> List.map string_of_int |> String.concat ","))
;;

let test_keeper_shrinks_lopsided_history_at_atom_boundary () =
  let capture_path =
    Filename.temp_file "masc-codex-lopsided-shrink-requests-" ".jsonl"
  in
  Fun.protect
    ~finally:(fun () -> Sys.remove capture_path)
    (fun () ->
       let injected = {|{"id":4,"result":{}}|} in
       let turn_after_injection =
         {|{"id":5,"result":{"turn":{"id":"turn-1"}}}|}
       in
       let overflow =
         {|{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"failed","error":{"message":"context is full","codexErrorInfo":"contextWindowExceeded"}}}}|}
       in
       let oldest = String.make 400 'o' in
       let newest = String.make 600 'n' in
       let provider_capacity_bytes = 800 in
       let initial_messages =
         [ Agent_core.Types.user_msg oldest
         ; Agent_core.Types.user_msg newest
         ]
       in
       with_fixture_sequence
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; injected
         ; turn_after_injection
         ; overflow
         ]
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; injected
         ; turn_after_injection
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages
                ~keeper_name:"codex-fixture-lopsided-shrink"
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              check
                string
                "Keeper response"
                "MASC_SUBSCRIPTION_OK"
                (keeper_response_text result));
       let injected_item_texts =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input
           |> List.map Yojson.Safe.from_string
           |> List.filter_map (fun request ->
             if
               Yojson.Safe.Util.member "method" request
               = `String "thread/inject_items"
             then
               Some
                 (request
                  |> Yojson.Safe.Util.member "params"
                  |> Yojson.Safe.Util.member "items"
                  |> Yojson.Safe.Util.to_list
                  |> List.map (fun item ->
                    item
                    |> Yojson.Safe.Util.member "content"
                    |> Yojson.Safe.Util.to_list
                    |> List.hd
                    |> Yojson.Safe.Util.member "text"
                    |> Yojson.Safe.Util.to_string))
             else None))
       in
       match injected_item_texts with
       | [ [ first_oldest; first_newest ]; [ retry_newest ] ] ->
         let encoded_oldest =
           Keeper_official_client_host.encode_history_message
             (Agent_core.Types.user_msg oldest)
         in
         let encoded_newest =
           Keeper_official_client_host.encode_history_message
             (Agent_core.Types.user_msg newest)
         in
         check string
           "first attempt keeps oldest atom"
           encoded_oldest
           first_oldest;
         check string
           "first attempt keeps newest atom"
           encoded_newest
           first_newest;
         check string
           "retry keeps the indivisible newest atom"
           encoded_newest
           retry_newest;
         check bool "rejected history exceeds the fixture provider cap" true
           (String.length encoded_oldest + String.length encoded_newest
            > provider_capacity_bytes);
         check bool "atom-boundary retry fits the fixture provider cap" true
           (String.length encoded_newest <= provider_capacity_bytes)
       | attempts ->
         failf
           "expected [400B+600B; 600B] history injections, got item counts=[%s]"
           (attempts
            |> List.map (fun items -> string_of_int (List.length items))
            |> String.concat ","))
;;

let test_keeper_dispatches_codex_turn_runtime () =
  with_fixture
    [ init_result; account_chatgpt; thread_result; turn_result; item_completed; turn_completed ]
    (fun cli_path ->
       match run_keeper_turn ~cli_path ~model:"gpt-fixture" () with
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok result ->
         check string "Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result);
         check bool "measured observation" true (Option.is_some result.runtime_observation))
;;

let test_keeper_projects_codex_live_stream () =
  let stream_events = ref [] in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic fixture marker"
      ~parameters:
        [ { Agent_core.Types.name = "marker"
          ; description = "Fixture marker"
          ; param_type = String
          ; required = true
          }
        ]
      (fun _ ->
         Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; agent_message_delta
    ; tool_call_request
    ; item_completed
    ; turn_completed
    ]
    (fun cli_path ->
       match
         run_keeper_turn
           ~tools:[ tool ]
           ~on_event:(fun event -> stream_events := event :: !stream_events)
           ~cli_path
           ~model:"gpt-fixture"
           ()
       with
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ ->
         let open Agent_core.Types in
         (match List.rev !stream_events with
          | [ MessageStart { id = "turn-1"; model = "gpt-fixture"; usage = None }
            ; ContentBlockDelta { index = 0; delta = TextDelta "MASC_" }
            ; ContentBlockStart
                { index = 1
                ; content_type = "tool_use"
                ; tool_id = Some "call-1"
                ; tool_name = Some "masc_probe"
                }
            ; ContentBlockDelta
                { index = 1; delta = InputJsonSnapshot arguments }
            ; ContentBlockStop { index = 1 }
            ; ContentBlockDelta
                { index = 0; delta = TextDelta "SUBSCRIPTION_OK" }
            ; MessageDelta { stop_reason = Some EndTurn; usage = None }
            ; MessageStop
            ] ->
            check string
              "Keeper stream arguments"
              {|{"marker":"from-codex"}|}
              arguments
          | _ -> fail "Keeper did not preserve the Codex live event sequence"))
;;

let test_keeper_preserves_typed_history_on_codex_wire () =
  let capture_path = Filename.temp_file "masc-codex-typed-history-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> Sys.remove capture_path)
    (fun () ->
       let assistant_message : Agent_core.Types.message =
         { role = Assistant
         ; content =
             [ ToolUse
                 { id = "prior-call"
                 ; name = "prior_tool"
                 ; input = `Assoc [ "path", `String "README.md" ]
                 }
             ]
         ; name = None
         ; tool_call_id = None
         ; metadata = []
         }
       in
       let tool_message =
         Agent_core.Types.tool_result_msg
           ~tool_use_id:"prior-call"
           ~content:"prior tool output"
           ()
       in
       let injected = {|{"id":4,"result":{}}|} in
       let turn_after_injection =
         {|{"id":5,"result":{"turn":{"id":"turn-1"}}}|}
       in
       with_fixture
         ~capture_path
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; injected
         ; turn_after_injection
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~initial_messages:[ assistant_message; tool_message ]
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok _ -> ());
       let requests =
         In_channel.with_open_bin capture_path (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       let items =
         requests
         |> List.find (fun json -> Yojson.Safe.Util.member "id" json = `Int 4)
         |> Yojson.Safe.Util.member "params"
         |> Yojson.Safe.Util.member "items"
         |> Yojson.Safe.Util.to_list
       in
       check int "typed history item count" 2 (List.length items);
       check
         (list string)
         "wire roles"
         [ "assistant"; "user" ]
         (List.map
            (fun item ->
               item
               |> Yojson.Safe.Util.member "role"
               |> Yojson.Safe.Util.to_string)
            items);
       List.iter2
         (fun expected item ->
            let encoded =
              item
              |> Yojson.Safe.Util.member "content"
              |> Yojson.Safe.Util.to_list
              |> List.hd
              |> Yojson.Safe.Util.member "text"
              |> Yojson.Safe.Util.to_string
              |> Yojson.Safe.from_string
              |> Yojson.Safe.Util.member "message"
            in
            check string
              "canonical history message"
              (Keeper_official_client_context_codec.message_to_json expected
               |> Yojson.Safe.to_string)
              (Yojson.Safe.to_string encoded))
         [ assistant_message; tool_message ]
         items)
;;

let test_keeper_codex_raw_trace_contains_actual_tool_and_response () =
  let base_path = temp_workspace "masc-codex-raw-trace-" in
  let raw_trace_path = Filename.concat base_path "official-codex-raw.jsonl" in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic RAW fixture marker"
      ~parameters:
        [ { Agent_core.Types.name = "marker"
          ; description = "Fixture marker"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
         check string
           "RAW fixture tool sees actual input"
           "from-codex"
           Yojson.Safe.Util.(input |> member "marker" |> to_string);
         Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; tool_call_request
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~tools:[ tool ]
                ~base_path
                ~raw_trace_path
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              (match result.trace_ref with
               | None -> fail "official Codex turn did not return a RAW trace reference"
               | Some trace_ref ->
                 check string "RAW trace path" raw_trace_path trace_ref.path);
              let records =
                match Agent_core.Raw_trace.read_all ~path:raw_trace_path () with
                | Ok records -> records
                | Error error -> fail (Agent_core.Error.to_string error)
              in
              let kinds =
                List.map
                  (fun (record : Agent_core.Raw_trace.record) -> record.record_type)
                  records
              in
              List.iter
                (fun kind ->
                   check bool
                     ("RAW contains " ^ Agent_core.Raw_trace.record_type_to_string kind)
                     true
                     (List.mem kind kinds))
                [ Agent_core.Raw_trace.Run_started
                ; Tool_execution_started
                ; Tool_execution_finished
                ; Assistant_block
                ; Run_finished
                ];
              let tool_start =
                List.find
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.record_type = Tool_execution_started)
                  records
              in
              check string
                "RAW retains actual tool input"
                "from-codex"
                Yojson.Safe.Util.(
                  Option.get tool_start.tool_input |> member "marker" |> to_string);
              let tool_finish =
                List.find
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.record_type = Tool_execution_finished)
                  records
              in
              check
                (option string)
                "RAW retains actual tool output"
                (Some "MASC_TOOL_RESULT")
                tool_finish.tool_result;
              let finished =
                List.find
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.record_type = Run_finished)
                  records
              in
              check
                (option string)
                "RAW retains actual final response"
                (Some "MASC_SUBSCRIPTION_OK")
                finished.final_text))
;;

let test_keeper_codex_raw_trace_separates_native_tool_observation () =
  let base_path = temp_workspace "masc-codex-native-raw-trace-" in
  let raw_trace_path = Filename.concat base_path "official-codex-native-raw.jsonl" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; native_command_started
         ; native_command_completed
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~raw_trace_path
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok _ ->
              let records =
                match Agent_core.Raw_trace.read_all ~path:raw_trace_path () with
                | Ok records -> records
                | Error error -> fail (Agent_core.Error.to_string error)
              in
              let records_of_type record_type =
                List.filter
                  (fun (record : Agent_core.Raw_trace.record) ->
                     record.record_type = record_type)
                  records
              in
              check int
                "one native start"
                1
                (List.length (records_of_type Native_tool_started));
              check int
                "one native finish"
                1
                (List.length (records_of_type Native_tool_finished));
              check int
                "no MASC execution start"
                0
                (List.length (records_of_type Tool_execution_started));
              check int
                "no MASC execution finish"
                0
                (List.length (records_of_type Tool_execution_finished));
              let native_start = List.hd (records_of_type Native_tool_started) in
              (* Native identity lives in its own typed field: the raw-trace
                 writer refuses a native record that also carries
                 [tool_use_id] ("native tool record cannot also carry
                 tool_use_id"), so the id must be read from
                 [native_tool_identity]. *)
              check
                (option string)
                "native call id"
                (Some "native-command-1")
                (match native_start.native_tool_identity with
                 | Some (Agent_core.Raw_trace.Call_id call_id) -> Some call_id
                 | Some (Agent_core.Raw_trace.Provider_step _) | None -> None);
              check
                (option string)
                "native record carries no MASC tool_use_id"
                None
                native_start.tool_use_id;
              check
                (option string)
                "native tool name"
                (Some "commandExecution")
                native_start.tool_name))
;;

let test_keeper_protocol_failure_enters_recovery () =
  let base_path = temp_workspace "masc-codex-runtime-recovery-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ "not-json"
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            (match
               run_keeper_turn
                 ~base_path
                 ~cli_path
                 ~model:"gpt-fixture"
                 ()
             with
             | Error _ -> ()
             | Ok _ -> fail "malformed official-client response completed the Keeper turn");
            let recovery =
              match
                Keeper_official_client_session_store.load
                  ~base_path
                  ~keeper_name:"codex-fixture"
              with
              | Error detail -> fail detail
              | Ok None -> fail "failed Codex turn left no durable recovery state"
              | Ok (Some state) -> state
            in
            (match recovery.phase with
             | Recovery_required required ->
               check bool
                 "runtime failure class"
                 true
                 (required.failure = Protocol_failed);
               check (option string) "no observed session" None required.observed_session_id
             | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
               fail "failed Codex runtime claim was not converted to recovery-required");
            let next_claim =
              Keeper_official_client_session_store.plan_claim
                ~expected:(Some recovery)
                ~client_kind:Codex
                ~runtime_id:recovery.runtime_id
              |> Result.get_ok
            in
            check int
              "failed provider session is superseded at a fresh ordinal"
              1
              next_claim.turn_count;
            check
              (option string)
              "failed provider session is not resumed"
              None
              (Option.map
                 (fun (settlement : Keeper_official_client_session_store.settlement) ->
                    settlement.session_id)
                 next_claim.previous_settlement)))
;;

let test_dashboard_official_client_recovery_projection_and_resolution () =
  let base_path = temp_workspace "masc-official-client-dashboard-recovery-" in
  let config = Workspace.default_config base_path in
  let keeper_name = "codex-fixture" in
  let success_capture = Filename.temp_file "masc-codex-recovery-retry-" ".jsonl" in
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
           [ "name", `String keeper_name
           ; "trace_id", `String "trace-official-client-recovery"
           ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  ignore (Keeper_registry.For_testing.register ~base_path keeper_name meta);
  Fun.protect
    ~finally:(fun () ->
      Keeper_registry.For_testing.unregister ~base_path keeper_name;
      cleanup_tree base_path;
      Sys.remove success_capture)
    (fun () ->
       let stimulus : Keeper_event_queue.stimulus =
         { post_id = "official-client-recovery-stimulus"
         ; urgency = Keeper_event_queue.Normal
         ; arrived_at = 1.0
         ; payload = Keeper_event_queue.Bootstrap
         }
       in
       (match
          Keeper_registry_event_queue.enqueue_durable_result
            ~base_path
            keeper_name
            stimulus
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       let selection =
         match
           Keeper_registry_event_queue.select_when_result
             ~base_path
             keeper_name
             ~now:(Unix.gettimeofday ())
             ~ready:(fun _ -> true)
         with
         | Ok (Some selection) -> selection
         | Ok None -> fail "durable recovery stimulus was not selected"
         | Error detail -> fail detail
       in
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; turn_failed
         ]
         (fun cli_path ->
            match run_keeper_turn ~base_path ~cli_path ~model:"gpt-fixture" () with
            | Error _ -> ()
            | Ok _ -> fail "provider-rejected official-client turn completed");
       (match
          Keeper_registry_event_queue.validate_pending_selection_result
            ~base_path
            keeper_name
            ~selection
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       let recovery =
         match Keeper_official_client_session_store.load ~base_path ~keeper_name with
         | Error detail -> fail detail
         | Ok None -> fail "real Keeper failure left no recovery state"
         | Ok (Some recovery) -> recovery
       in
       let recovery_id =
         match recovery.phase with
         | Recovery_required required ->
           check bool
             "recovery follows provider rejection"
             true
             (required.failure = Provider_rejected);
           check (option string)
             "recovery observed exact session"
             (Some "thread-1")
             required.observed_session_id;
           check (option string)
             "recovery observed exact turn"
             (Some "turn-1")
             required.observed_turn_id;
           required.recovery_id
         | Ready | Start _ | Active _ | Turn_inflight _ | Settled _ ->
           fail "dashboard recovery fixture was not recovery-required"
       in
       let snapshot =
         Server_dashboard_official_client_session.snapshot ~base_path ~keeper_name
         |> Result.get_ok
       in
       let open Yojson.Safe.Util in
       check string
         "dashboard schema"
         "masc.dashboard.official-client-session.v1"
         (snapshot |> member "schema" |> to_string);
       check string
         "dashboard client kind"
         "codex"
         (snapshot |> member "session" |> member "client_kind" |> to_string);
       check string
         "dashboard recovery phase"
         "recovery_required"
         (snapshot |> member "session" |> member "phase" |> member "kind" |> to_string);
       check string
         "dashboard recovery fence"
         recovery_id
         (snapshot
          |> member "session"
          |> member "phase"
          |> member "recovery_id"
          |> to_string);
       let retry_body =
         `Assoc
           [ "keeper_name", `String keeper_name
           ; "recovery_id", `String recovery_id
           ; "resolution", `String "retry_previous"
           ]
         |> Yojson.Safe.to_string
       in
       (match
          Server_dashboard_official_client_session.resolve_body
            ~config
            ~actor:"dashboard-admin"
            ~body:retry_body
        with
        | Error { kind = Conflict; code = "retry_previous_unavailable"; _ } -> ()
        | Error error ->
          fail
            (Printf.sprintf
               "retry_previous had wrong rejection: %s: %s"
               error.code
               error.message)
        | Ok _ -> fail "retry_previous silently restarted a fresh session");
       let body =
         `Assoc
           [ "keeper_name", `String keeper_name
           ; "recovery_id", `String recovery_id
           ; "resolution", `String "restart_fresh"
           ]
         |> Yojson.Safe.to_string
       in
       let resolved =
         Server_dashboard_official_client_session.resolve_body
           ~config
           ~actor:"dashboard-admin"
           ~body
         |> Result.get_ok
       in
       check string
         "dashboard resolved phase"
         "ready"
         (resolved |> member "session" |> member "phase" |> member "kind" |> to_string);
       check string
         "dashboard resolution actor"
         "dashboard-admin"
         (resolved
          |> member "session"
          |> member "last_recovery_resolution"
         |> member "resolved_by"
         |> to_string);
       check string
         "dashboard resolution applied"
         "applied"
         (resolved |> member "resolution_application" |> to_string);
       check bool
         "dashboard resolution audit recorded"
         true
         (resolved |> member "audit" |> member "recorded" |> to_bool);
       let replayed =
         Server_dashboard_official_client_session.resolve_body
           ~config
           ~actor:"dashboard-admin-retry"
           ~body
         |> Result.get_ok
       in
       check string
         "dashboard response loss replays committed resolution"
         "replayed"
         (replayed |> member "resolution_application" |> to_string);
       check string
         "replayed resolution preserves original actor"
         "dashboard-admin"
         (replayed
          |> member "session"
          |> member "last_recovery_resolution"
          |> member "resolved_by"
          |> to_string);
       let selected_after_resolution =
         match
           Keeper_registry_event_queue.select_when_result
             ~base_path
             keeper_name
             ~now:(Unix.gettimeofday ())
             ~ready:(fun _ -> true)
         with
         | Ok (Some selection) -> selection
         | Ok None -> fail "resolution lost the retained durable stimulus"
         | Error detail -> fail detail
       in
       check bool
         "resolution reuses the exact durable stimulus"
         true
         (selected_after_resolution = selection);
       with_fixture
         ~capture_path:success_capture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match run_keeper_turn ~base_path ~cli_path ~model:"gpt-fixture" () with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              check string
                "post-resolution Keeper response"
                "MASC_SUBSCRIPTION_OK"
                (keeper_response_text result));
       let success_requests =
         In_channel.with_open_bin success_capture (fun input ->
           In_channel.input_lines input |> List.map Yojson.Safe.from_string)
       in
       check int
         "resolution admits exactly one provider turn"
         1
         (success_requests
          |> List.filter (fun json ->
            Yojson.Safe.Util.member "method" json = `String "turn/start")
          |> List.length);
       (match
          Keeper_registry_event_queue.ack_pending_result
            ~base_path
            keeper_name
            ~selection:selected_after_resolution
        with
        | Ok () -> ()
        | Error detail -> fail detail);
       let queue_after_success =
         match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
         | Ok queue -> queue
         | Error detail -> fail detail
       in
       check int
         "successful retry acknowledges the durable stimulus"
         0
         (Keeper_event_queue.length queue_after_success);
       let settled =
         match Keeper_official_client_session_store.load ~base_path ~keeper_name with
         | Error detail -> fail detail
         | Ok None -> fail "post-resolution Keeper turn lost its durable state"
         | Ok (Some settled) -> settled
       in
       (match settled.phase with
        | Settled { session_id; turn_id } ->
          check string "post-resolution session" "thread-1" session_id;
          check string "post-resolution turn" "turn-1" turn_id
        | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
          fail "post-resolution Keeper turn did not settle");
       let duplicate_body =
         Printf.sprintf
           {|{"keeper_name":%S,"keeper_name":%S,"recovery_id":%S,"resolution":"restart_fresh"}|}
           keeper_name
           keeper_name
           recovery_id
       in
       match
         Server_dashboard_official_client_session.resolve_body
           ~config
           ~actor:"dashboard-admin"
           ~body:duplicate_body
       with
       | Error { kind = Bad_request; _ } -> ()
       | Error _ -> fail "duplicate dashboard request had the wrong error class"
       | Ok _ -> fail "duplicate dashboard request fields were admitted")
;;

let test_keeper_resumes_persisted_codex_thread () =
  let base_path = temp_workspace "masc-codex-resume-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result -> check int "initial turn count" 1 result.turns);
       let before_turn_ordinal = ref 0 in
       let after_turn_ordinal = ref 0 in
       let hooks : Agent_core.Hooks.hooks =
         { Agent_core.Hooks.empty with
           before_turn =
             Some
               (function
                 | BeforeTurn { turn; _ } ->
                   before_turn_ordinal := turn;
                   Continue
                 | _ -> Continue)
         ; after_turn =
             Some
               (function
                 | AfterTurn { turn; _ } ->
                   after_turn_ordinal := turn;
                   Continue
                 | _ -> Continue)
         }
       in
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; resumed_turn_result
         ; resumed_item_completed
         ; resumed_turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~hooks
                ~goal:"Return the resumed fixture marker"
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              check string "resumed response" "MASC_RESUMED_OK" (keeper_response_text result);
              check string "official thread" "thread-1" result.session_id;
              check int "cumulative turns" 2 result.turns;
              check int "before-turn ordinal" 2 !before_turn_ordinal;
              check int "after-turn ordinal" 2 !after_turn_ordinal);
       match
         Keeper_official_client_session_store.load
           ~base_path
           ~keeper_name:"codex-fixture"
       with
       | Error detail -> fail detail
       | Ok None -> fail "resumed Codex binding disappeared"
       | Ok (Some binding) -> check int "stored turns" 2 binding.turn_count)
;;

let test_keeper_dynamic_context_stays_on_codex_instruction_wire () =
  let base_path = temp_workspace "masc-codex-context-wire-" in
  let start_capture = Filename.temp_file "masc-codex-context-start-" ".jsonl" in
  let resume_capture = Filename.temp_file "masc-codex-context-resume-" ".jsonl" in
  let dynamic_context = "DYNAMIC_CONTEXT_RAW\nsecond line" in
  let goal = "WIRE_GOAL_EXACT\nsecond line" in
  let hooks : Agent_core.Hooks.hooks =
    { Agent_core.Hooks.empty with
      before_turn_params =
        Some
          (function
            | BeforeTurnParams { current_params; _ } ->
              AdjustParams
                { current_params with
                  extra_system_context = Some dynamic_context
                }
            | _ -> Continue)
    }
  in
  let request capture_path method_ =
    In_channel.with_open_bin capture_path (fun input ->
      In_channel.input_lines input
      |> List.map Yojson.Safe.from_string
      |> List.find (fun json ->
        Yojson.Safe.Util.member "method" json = `String method_))
  in
  let request_param_string name request =
    request
    |> Yojson.Safe.Util.member "params"
    |> Yojson.Safe.Util.member name
    |> Yojson.Safe.Util.to_string
  in
  let turn_prompt capture_path =
    request capture_path "turn/start"
    |> Yojson.Safe.Util.member "params"
    |> Yojson.Safe.Util.member "input"
    |> Yojson.Safe.Util.to_list
    (* Not [List.hd]: images precede the text in the input list, so a head that
       happens to be the text today would read an image url on an image turn. *)
    |> List.find (fun item -> Yojson.Safe.Util.member "type" item = `String "text")
    |> Yojson.Safe.Util.member "text"
    |> Yojson.Safe.Util.to_string
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_tree base_path;
      Sys.remove start_capture;
      Sys.remove resume_capture)
    (fun () ->
       with_fixture
         ~capture_path:start_capture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~hooks
                ~goal
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result -> check int "initial context turn" 1 result.turns);
       with_fixture
         ~capture_path:resume_capture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; resumed_turn_result
         ; resumed_item_completed
         ; resumed_turn_completed
         ]
         (fun cli_path ->
            match
              run_keeper_turn
                ~base_path
                ~hooks
                ~goal
                ~cli_path
                ~model:"gpt-fixture"
                ()
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result -> check int "resumed context turn" 2 result.turns);
       let start_instructions =
         request start_capture "thread/start"
         |> request_param_string "developerInstructions"
       in
       let resume_instructions =
         request resume_capture "thread/resume"
         |> request_param_string "developerInstructions"
       in
       check string
         "start and resume receive identical developer instructions"
         start_instructions
         resume_instructions;
       (* This fixture has two non-empty instruction sections, in this order:
          the Native_read posture note and the typed dynamic-context envelope.
          Read both from their production owners. Searching for a JSON-looking
          paragraph would let the posture note disappear or move unnoticed. *)
       let posture_note =
         match
           Keeper_codex_runtime.For_testing.native_posture_note
             Runtime_native_tools.Native_read
         with
         | [] -> fail "Native_read posture note disappeared"
         | sections -> String.concat "\n\n" sections
       in
       let instruction_prefix = posture_note ^ "\n\n" in
       let prefix_bytes = String.length instruction_prefix in
       let context_envelope_text =
         if String.length start_instructions < prefix_bytes then
           fail "developer instructions are shorter than the posture prefix"
         else (
           check string
             "Native_read posture note is the developer-instruction prefix"
             instruction_prefix
             (String.sub start_instructions 0 prefix_bytes);
           String.sub start_instructions prefix_bytes
             (String.length start_instructions - prefix_bytes))
       in
       let expected_context_envelope =
         { (Agent_core.Types.system_msg dynamic_context) with
           metadata = Agent_core.Types.Extra_system_context_provenance.metadata
         }
         |> Keeper_official_client_host.encode_history_message
       in
       check string
         "dynamic context uses the canonical instruction envelope"
         expected_context_envelope
         context_envelope_text;
       let context_envelope = Yojson.Safe.from_string context_envelope_text in
       let open Yojson.Safe.Util in
       check string
         "dynamic context envelope schema"
         Keeper_official_client_context_codec.schema
         (context_envelope |> member "schema" |> to_string);
       let context_message = context_envelope |> member "message" in
       check string
         "dynamic context keeps System role"
         "system"
         (context_message |> member "role" |> to_string);
       check string
         "dynamic context stays exact in the instruction envelope"
         dynamic_context
         (context_message
          |> member "content_blocks"
          |> index 0
          |> member "text"
          |> to_string);
       (match
          context_message
          |> member "metadata"
          |> to_assoc
          |> Agent_core.Types.Extra_system_context_provenance.classify
        with
        | Agent_core.Types.Extra_system_context_provenance.Present -> ()
        | Absent | Invalid | Duplicate ->
          fail "dynamic context lost its typed provenance");
       check string "start prompt stays exact" goal (turn_prompt start_capture);
       check string "resume prompt stays exact" goal (turn_prompt resume_capture))
;;

(* A changed tool surface must not RESUME the settled thread. It used to be
   pinned as "the turn fails", which also left the session with no way forward:
   Settled never becomes Recovery_required, so no operator action cleared it
   and every later turn returned the same config error (#27992). The turn now
   proceeds as a fresh session -- new thread, ordinal back to 1 -- which keeps
   the property and drops the dead end. *)
let test_keeper_starts_fresh_on_changed_tool_surface () =
  let base_path = temp_workspace "masc-codex-tool-change-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         (* Two turns' worth: the second is a fresh session, so it starts a
            thread of its own rather than resuming thread-1. *)
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            (match
               run_keeper_turn
                 ~base_path
                 ~cli_path
                 ~model:"gpt-fixture"
                 ()
             with
             | Error error -> fail (Agent_core.Error.to_string error)
             | Ok _ -> ());
            let tool = fixture_tool ~name:"new_tool" ~description:"new surface" () in
            (match
               run_keeper_turn
                 ~base_path
                 ~tools:[ tool ]
                 ~cli_path
                 ~model:"gpt-fixture"
                 ()
             with
             | Error error ->
               fail
                 ("changed tool surface must start a fresh session, not fail: "
                  ^ Agent_core.Error.to_string error)
             | Ok _ -> ());
            (* The store is where resume-versus-fresh is visible: a resumed
               session would carry ordinal 2 and the previous settlement. *)
            match
              Keeper_official_client_session_store.load
                ~base_path
                ~keeper_name:"codex-fixture"
            with
            | Error detail -> fail detail
            | Ok None -> fail "binding disappeared after a changed tool surface"
            | Ok (Some binding) ->
              check int "changed surface restarts the ordinal" 1 binding.turn_count))
;;

let assert_production_keeper_result result =
  check string
    "production Keeper response"
    "MASC_SUBSCRIPTION_OK"
    result.Keeper_agent_run.response_text;
  check int "production Keeper turn count" 1 result.turn_count;
  check int "production after-turn ordinal" 1 result.final_agent_core_turn_ordinal;
  check bool "production measured observation" true
    (Option.is_some result.runtime_observation);
  check bool "official client does not fabricate AGENT_CORE checkpoint" true
    (Option.is_none result.checkpoint)
;;

let test_production_keeper_dispatches_codex_runtime () =
  let base_path = temp_workspace "masc-codex-production-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~base_path
                ~trace_id:"codex-production-trace-1"
                ~user_message:
                  "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
                ~cli_path
                ~model:"gpt-fixture"
                ~turn_instructions:None
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result -> assert_production_keeper_result result))
;;

let test_production_keeper_resumes_across_trace_rotation () =
  let base_path = temp_workspace "masc-codex-production-resume-" in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path)
    (fun () ->
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~base_path
                ~trace_id:"codex-production-trace-1"
                ~user_message:"Start the production fixture thread."
                ~cli_path
                ~model:"gpt-fixture"
                ~turn_instructions:None
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok _ -> ());
       with_fixture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; resumed_turn_result
         ; resumed_item_completed
         ; resumed_turn_completed
         ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~base_path
                ~trace_id:"codex-production-trace-2"
                ~user_message:"Resume the production fixture thread."
                ~cli_path
                ~model:"gpt-fixture"
                ~turn_instructions:None
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result ->
              check string
                "production resumed response"
                "MASC_RESUMED_OK"
                result.Keeper_agent_run.response_text);
       match
         Keeper_official_client_session_store.load
           ~base_path
           ~keeper_name:"codex-production-fixture"
       with
       | Error detail -> fail detail
       | Ok None -> fail "production Codex current-owner state disappeared"
       | Ok (Some state) ->
         check int "production cumulative turns" 2 state.turn_count;
         (match state.phase with
          | Settled { session_id; _ } ->
            check string "production thread" "thread-1" session_id
          | Ready | Start _ | Active _ | Turn_inflight _ | Recovery_required _ ->
            fail "production Codex state did not settle"))
;;

let test_production_dynamic_context_reaches_codex_instruction_wire () =
  let base_path = temp_workspace "masc-codex-production-context-" in
  let capture = Filename.temp_file "masc-codex-production-context-" ".jsonl" in
  (* #28169: enter through [build_turn_prompt] — the production assembly that
     [Keeper_agent_run.run_turn] owns — not through a test-injected
     before_turn_params hook. A failure here means the loss sits between the
     prompt assembly and the official-client instruction wire, which is the
     layer the hook-injected sibling test above cannot see. *)
  let turn_instructions = "PRODUCTION_TURN_INSTRUCTIONS\nsecond line" in
  let expected_dynamic_context =
    "--- Turn-specific instructions ---\n" ^ turn_instructions
  in
  Fun.protect
    ~finally:(fun () -> cleanup_tree base_path; Sys.remove capture)
    (fun () ->
       with_fixture
         ~capture_path:capture
         [ init_result
         ; account_chatgpt
         ; thread_result
         ; turn_result
         ; item_completed
         ; turn_completed
         ]
         (fun cli_path ->
            match
              run_production_keeper_turn
                ~turn_instructions:(Some turn_instructions)
                ~base_path
                ~trace_id:"codex-production-context-1"
                ~user_message:
                  "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
                ~cli_path
                ~model:"gpt-fixture"
            with
            | Error error -> fail (Agent_core.Error.to_string error)
            | Ok result -> assert_production_keeper_result result);
       let developer_instructions =
         In_channel.with_open_bin capture (fun input ->
             In_channel.input_lines input
             |> List.map Yojson.Safe.from_string
             |> List.find (fun json ->
                  Yojson.Safe.Util.member "method" json = `String "thread/start")
             |> Yojson.Safe.Util.member "params"
             |> Yojson.Safe.Util.member "developerInstructions"
             |> Yojson.Safe.Util.to_string)
       in
       let posture_note =
         match
           Keeper_codex_runtime.For_testing.native_posture_note
             Runtime_native_tools.Native_read
         with
         | [] -> fail "Native_read posture note disappeared"
         | sections -> String.concat "\n\n" sections
       in
       ignore posture_note;
       (* [run_production_keeper_turn] assembles the real keeper system prompt
          ahead of the posture note (see [Keeper_codex_runtime]: system_prompt ::
          posture_note @ developer_messages), so unlike the hook-injected sibling
          test the posture note is NOT the byte prefix of the wire. And the
          production assembly appends more blocks after the turn instructions —
          today the temporal summary — so the envelope text itself is not a
          byte-exact window either. Assert the #28169 invariants instead: the
          turn instructions appear inside one envelope message on the wire with
          System role, typed provenance, and the exact instruction text intact.
          Locate this turn's envelope by scanning for the instruction text and
          trimming to the enclosing JSON object, which assumes neither a
          position nor which other blocks share the envelope. *)
       let find_sub text sub =
         let n = String.length sub in
         let rec go i =
           if i + n > String.length text then None
           else if String.sub text i n = sub then Some i
           else go (i + 1)
         in
         go 0
       in
       let find_sub_from text from sub =
         let n = String.length sub in
         let rec go i =
           if i + n > String.length text then None
           else if String.sub text i n = sub then Some i
           else go (i + 1)
         in
         go (max from 0)
       in
       let context_envelope =
         (* The wire stores developer instructions as JSON strings: newlines in
            the instruction text arrive escaped as [\n]. Encode the expected
            text with Yojson so the substring scan compares like with like. *)
         let encoded_needle =
           Yojson.Safe.to_string (`String expected_dynamic_context)
         in
         let needle =
           (* Yojson quotes the string but keeps its escaping: this is the
              exact JSON-escaped form the wire carries inside the envelope. *)
           let n = String.length encoded_needle in
           String.sub encoded_needle 1 (n - 2)
         in
         match find_sub developer_instructions needle with
         | None ->
           fail
             "production turn instructions are not on the \
              developer-instruction wire"
         | Some marker_at ->
           (* The envelope object opens at the nearest preceding schema object
              start, not at the nearest open brace of the text block that
              happens to hold the instructions. *)
           let envelope_open = "{\"schema\":" in
           let open_obj =
             let rec back i =
               if i < 0 then 0
               else if
                 i + String.length envelope_open
                 <= String.length developer_instructions
                 && String.sub developer_instructions i
                      (String.length envelope_open)
                    = envelope_open
               then i
               else back (i - 1)
             in
             back marker_at
           in
           let marker_end = marker_at + String.length needle in
           (* The envelope closes after the typed provenance marker; finding
              that end marker is robust to nested braces inside content_blocks
              (a plain forward scan for '}' would stop at the text block's own
              closing brace). *)
           let provenance_end =
             "\"agent_core.extra_system_context.v1\":true}}}"
           in
           let close_obj =
             match find_sub_from developer_instructions marker_end provenance_end with
             | Some i -> i + String.length provenance_end
             | None -> String.length developer_instructions
           in
           let candidate =
             String.sub developer_instructions open_obj (close_obj - open_obj)
           in
           Yojson.Safe.from_string candidate
       in
       let open Yojson.Safe.Util in
       check string
         "production dynamic context envelope schema"
         Keeper_official_client_context_codec.schema
         (context_envelope |> member "schema" |> to_string);
       let context_message = context_envelope |> member "message" in
       check string
         "production dynamic context keeps System role"
         "system"
         (context_message |> member "role" |> to_string);
       let wire_text =
         context_message
         |> member "content_blocks"
         |> index 0
         |> member "text"
         |> to_string
       in
       (* The production assembly appends the temporal summary into the same
          envelope after the turn instructions, so the instructions are the
          prefix of the wire text rather than the whole of it. *)
       if
         String.length wire_text < String.length expected_dynamic_context
         || String.sub wire_text 0 (String.length expected_dynamic_context)
            <> expected_dynamic_context
       then
         check string
           "production turn instructions stay exact on the wire"
           expected_dynamic_context
           wire_text
       else
         check string
           "production turn instructions stay exact on the wire"
           expected_dynamic_context
           (String.sub wire_text 0 (String.length expected_dynamic_context));
       (match
          context_message
          |> member "metadata"
          |> to_assoc
          |> Agent_core.Types.Extra_system_context_provenance.classify
        with
        | Agent_core.Types.Extra_system_context_provenance.Present -> ()
        | Absent | Invalid | Duplicate ->
          fail "production dynamic context lost its typed provenance"))
;;

let test_keeper_projects_typed_tools_and_hooks () =
  let tool_calls = ref 0 in
  let before_turn_calls = ref 0 in
  let before_params_calls = ref 0 in
  let pre_tool_calls = ref 0 in
  let post_tool_calls = ref 0 in
  let after_turn_calls = ref 0 in
  let on_stop_calls = ref 0 in
  let projection_saw_context = ref false in
  let injector_calls = ref 0 in
  let tool =
    Agent_core.Tool.create
      ~name:"masc_probe"
      ~description:"Return a deterministic Keeper fixture marker"
      ~parameters:
        [ { Agent_core.Types.name = "marker"
          ; description = "Fixture marker"
          ; param_type = String
          ; required = true
          }
        ]
      (fun input ->
        incr tool_calls;
        check string
          "typed tool input"
          "from-codex"
          Yojson.Safe.Util.(input |> member "marker" |> to_string);
        Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
  in
  let hooks : Agent_core.Hooks.hooks =
    { Agent_core.Hooks.empty with
      before_turn =
        Some
          (fun _ ->
            incr before_turn_calls;
            Continue)
    ; before_turn_params =
        Some
          (function
            | BeforeTurnParams { current_params; _ } ->
              incr before_params_calls;
              AdjustParams
                { current_params with extra_system_context = Some "fixture-context" }
            | _ -> Continue)
    ; pre_tool_use =
        Some
          (fun _ ->
            incr pre_tool_calls;
            Continue)
    ; post_tool_use =
        Some
          (fun _ ->
            incr post_tool_calls;
            Continue)
    ; after_turn =
        Some
          (fun _ ->
            incr after_turn_calls;
            Continue)
    ; on_stop =
        Some
          (fun _ ->
            incr on_stop_calls;
            Continue)
    }
  in
  let model_input_projection messages =
    projection_saw_context :=
      List.exists
        (fun (message : Agent_core.Types.message) ->
          message.role = System
          && String.equal
               "fixture-context"
               (Agent_core.Types.text_of_content message.content)
          && Agent_core.Types.Extra_system_context_provenance.classify
               message.metadata
             = Agent_core.Types.Extra_system_context_provenance.Present)
        messages;
    Ok messages
  in
  let context_injector ~tool_name:_ ~input:_ ~output:_ =
    incr injector_calls;
    Some
      { Agent_core.Hooks.context_updates = [ "fixture_tool_seen", `Bool true ]
      ; extra_messages = []
      }
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; tool_call_request
    ; item_completed
    ; turn_completed
    ]
    (fun cli_path ->
       match
         run_keeper_turn
           ~tools:[ tool ]
           ~hooks
           ~context_injector
           ~model_input_projection
           ~cli_path
           ~model:"gpt-fixture"
           ()
       with
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok result ->
         check string "Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result);
         List.iter
           (fun (label, expected, actual) -> check int label expected !actual)
           [ "tool handler", 1, tool_calls
           ; "before turn hook", 1, before_turn_calls
           ; "before params hook", 1, before_params_calls
           ; "pre tool hook", 1, pre_tool_calls
           ; "post tool hook", 1, post_tool_calls
           ; "after turn hook", 1, after_turn_calls
           ; "on stop hook", 1, on_stop_calls
           ; "context injector", 1, injector_calls
           ];
         check bool "projection saw hook context" true !projection_saw_context)
;;

let test_keeper_rejects_unprojected_turn_parameters () =
  let hooks : Agent_core.Hooks.hooks =
    { Agent_core.Hooks.empty with
      before_turn_params =
        Some
          (function
            | BeforeTurnParams { current_params; _ } ->
              AdjustParams { current_params with temperature = Some 0.2 }
            | _ -> Continue)
    }
  in
  with_fixture
    [ init_result
    ; account_chatgpt
    ; thread_result
    ; turn_result
    ; item_completed
    ; turn_completed
    ]
    (fun cli_path ->
       match run_keeper_turn ~hooks ~cli_path ~model:"gpt-fixture" () with
       | Error
           (Agent_core.Error.Config
             (Agent_core.Error.InvalidConfig { field; detail = _ })) ->
         check string "rejected parameter" "temperature" field
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "unprojected temperature was silently ignored")
;;


let test_live_chatgpt_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let result =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_codex_app_server.default_config ()) with
            timeout_s = Some 60.0
          }
        in
        Runtime_codex_app_server.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
          config
          ~prompt:"Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
          ~images:[])
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result ->
      check string "live response" "MASC_SUBSCRIPTION_OK" result.text;
      check bool "subscription plan is present" true
        (String.trim result.subscription.plan_type <> "")
;;

let test_live_dynamic_tool_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let tool_calls = ref 0 in
    let tool : Runtime_codex_app_server.dynamic_tool =
      { name = "masc_probe"
      ; description = "Return the exact marker MASC_TOOL_RESULT"
      ; input_schema =
          `Assoc [ "type", `String "object"; "properties", `Assoc [] ]
      ; call =
          (fun ~call_id:_ _ ->
            incr tool_calls;
            { success = true; content = "MASC_TOOL_RESULT"; abort_turn = None })
      }
    in
    let result =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_codex_app_server.default_config ()) with
            timeout_s = Some 60.0
          }
        in
        Runtime_codex_app_server.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
          ~dynamic_tools:[ tool ]
          config
          ~prompt:
            "Call masc_probe exactly once, then reply with exactly MASC_TOOL_OK."
          ~images:[])
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result ->
      check int "live dynamic tool calls" 1 !tool_calls;
      check int "live measured tool calls" 1 result.dynamic_tool_calls;
      check string "live tool response" "MASC_TOOL_OK" result.text
;;

let test_live_history_injection_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let result =
      Eio_main.run (fun env ->
        let config =
          { (Runtime_codex_app_server.default_config ()) with
            timeout_s = Some 60.0
          }
        in
        Runtime_codex_app_server.run_turn
          ~mgr:(Eio.Stdenv.process_mgr env)
          ~clock:(Eio.Stdenv.clock env)
          ~cwd:Eio.Path.(Eio.Stdenv.fs env / "/tmp")
          ~history:
            [ { role = User; text = "The continuity marker is MASC_HISTORY_OK." }
            ; { role = Assistant; text = "I will retain that marker." }
            ]
          config
          ~prompt:"Reply with exactly the continuity marker from the prior history."
          ~images:[])
    in
    match result with
    | Error error -> fail (Runtime_codex_app_server.error_to_string error)
    | Ok result -> check string "live history response" "MASC_HISTORY_OK" result.text
;;

let test_live_keeper_chatgpt_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    match run_keeper_turn ~cli_path:"codex" ~model:"gpt-5.6-sol" () with
    | Error error -> fail (Agent_core.Error.to_string error)
    | Ok result ->
      check string "live Keeper response" "MASC_SUBSCRIPTION_OK" (keeper_response_text result)
;;

let test_live_keeper_dynamic_tool_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let tool_calls = ref 0 in
    let stream_events = ref [] in
    let tool =
      Agent_core.Tool.create
        ~name:"masc_probe"
        ~description:"Return the exact marker MASC_TOOL_RESULT"
        ~parameters:[]
        (fun _ ->
          incr tool_calls;
          Ok { Agent_core.Types.content = "MASC_TOOL_RESULT"; _meta = None })
    in
    let base_path = temp_workspace "masc-codex-live-tool-raw-" in
    let raw_trace_path = Filename.concat base_path "live-tool-raw.jsonl" in
    Fun.protect
      ~finally:(fun () -> cleanup_tree base_path)
      (fun () ->
         match
           run_keeper_turn
             ~tools:[ tool ]
             ~on_event:(fun event -> stream_events := event :: !stream_events)
             ~base_path
             ~raw_trace_path
             ~goal:
               "Call the dynamic tool masc_probe exactly once. After it returns, reply with exactly MASC_TOOL_OK and no other text."
             ~cli_path:"codex"
             ~model:"gpt-5.6-sol"
             ()
         with
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok result ->
           check int "live typed tool calls" 1 !tool_calls;
           let stream_events = List.rev !stream_events in
           check bool
             "live Keeper emitted text delta"
             true
             (List.exists
                (function
                  | Agent_core.Types.ContentBlockDelta
                      { delta = Agent_core.Types.TextDelta text; _ } ->
                    String.trim text <> ""
                  | _ -> false)
                stream_events);
           let tool_index =
             List.find_map
               (function
                 | Agent_core.Types.ContentBlockStart
                     { index; tool_id = Some _; tool_name = Some "masc_probe"; _ } ->
                   Some index
                 | _ -> None)
               stream_events
           in
           let tool_index =
             match tool_index with
             | Some index -> index
             | None -> fail "live Keeper omitted masc_probe tool start"
           in
           check bool
             "live Keeper emitted tool args snapshot"
             true
             (List.exists
                (function
                  | Agent_core.Types.ContentBlockDelta
                      { index; delta = Agent_core.Types.InputJsonSnapshot _ } ->
                    index = tool_index
                  | _ -> false)
                stream_events);
           check bool
             "live Keeper emitted matching tool stop"
             true
             (List.exists
                (function
                  | Agent_core.Types.ContentBlockStop { index } ->
                    index = tool_index
                  | _ -> false)
                stream_events);
           check string
             "live tool Keeper response"
             "MASC_TOOL_OK"
             (keeper_response_text result);
           (match result.trace_ref with
            | None -> fail "live Keeper tool turn omitted its RAW trace reference"
            | Some trace_ref -> check string "live RAW path" raw_trace_path trace_ref.path);
           let records =
             match Agent_core.Raw_trace.read_all ~path:raw_trace_path () with
             | Ok records -> records
             | Error error -> fail (Agent_core.Error.to_string error)
           in
           let find kind =
             List.find_opt
               (fun (record : Agent_core.Raw_trace.record) ->
                  record.record_type = kind)
               records
           in
           (match find Agent_core.Raw_trace.Tool_execution_finished with
            | Some record ->
              check
                (option string)
                "live RAW tool output"
                (Some "MASC_TOOL_RESULT")
                record.tool_result
            | None -> fail "live RAW omitted Tool_execution_finished");
           match find Agent_core.Raw_trace.Run_finished with
           | Some record ->
             check
               (option string)
               "live RAW final response"
               (Some "MASC_TOOL_OK")
               record.final_text
           | None -> fail "live RAW omitted Run_finished")
;;

let test_live_keeper_resumes_official_thread () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let base_path = temp_workspace "masc-codex-live-resume-" in
    Fun.protect
      ~finally:(fun () -> cleanup_tree base_path)
      (fun () ->
         (match
            run_keeper_turn
              ~base_path
              ~goal:
                "Remember marker MASC_RESUME_MEMORY. Reply exactly MASC_RESUME_FIRST."
              ~cli_path:"codex"
              ~model:"gpt-5.6-sol"
              ()
          with
          | Error error -> fail (Agent_core.Error.to_string error)
          | Ok result ->
            check string
              "first live response"
              "MASC_RESUME_FIRST"
              (keeper_response_text result));
         match
           run_keeper_turn
             ~base_path
             ~goal:"Reply exactly with the remembered marker."
             ~cli_path:"codex"
             ~model:"gpt-5.6-sol"
             ()
         with
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok result ->
           check string
             "resumed live response"
             "MASC_RESUME_MEMORY"
             (keeper_response_text result);
           check int "resumed live turn count" 2 result.turns)
;;

let test_live_production_keeper_subscription () =
  if Sys.getenv_opt "MASC_CODEX_APP_SERVER_LIVE" <> Some "1"
  then Alcotest.skip ()
  else
    let base_path = temp_workspace "masc-codex-live-production-" in
    Fun.protect
      ~finally:(fun () -> cleanup_tree base_path)
      (fun () ->
         match
           run_production_keeper_turn
             ~base_path
             ~trace_id:"codex-live-production-trace"
             ~user_message:
               "Reply with exactly MASC_SUBSCRIPTION_OK and do not use tools."
             ~cli_path:"codex"
             ~model:"gpt-5.6-sol"
             ~turn_instructions:None
         with
         | Error error -> fail (Agent_core.Error.to_string error)
         | Ok result -> assert_production_keeper_result result)
;;

let test_official_client_host_text_projection_is_hard_cut () =
  (match
     Keeper_official_client_host.text_of_blocks
       ~runtime_label:"fixture"
       ~field:"messages"
       [ Agent_core.Types.Text "first"; Text "second" ]
   with
   | Ok text -> check string "text blocks preserve order" "first\nsecond" text
   | Error error -> fail (Agent_core.Error.to_string error));
  match
    Keeper_official_client_host.text_of_blocks
      ~runtime_label:"fixture"
      ~field:"messages"
      [ Agent_core.Types.Thinking { content = "private"; signature = None } ]
  with
  | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; _ })) ->
    check string "rejected field" "messages" field
  | Error error -> fail (Agent_core.Error.to_string error)
  | Ok _ -> fail "non-text official-client projection was silently admitted"
;;

let test_native_action_observer_keeps_exact_provider_identity () =
  let seen = ref [] in
  let observe ~official_turn ~identity ~tool_name =
    seen := (official_turn, identity, tool_name) :: !seen
  in
  Keeper_codex_runtime.For_testing.observe_stream_native_action ~turn_count:7 ~observe
    (Runtime_codex_app_server.Native_tool_started
       { Runtime_native_tools.identity = Some (Call_id "codex-call")
       ; tool_name = Some "Read"
       ; origin = Built_in
       });
  Keeper_codex_runtime.For_testing.observe_stream_native_action ~turn_count:8 ~observe
    (Runtime_codex_app_server.Native_tool_started
       { Runtime_native_tools.identity = None
       ; tool_name = Some "Read"
       ; origin = Built_in
       });
  check
    bool
    "exact only"
    true
    (match List.rev !seen with
     | [ 7, Runtime_native_tools.Call_id "codex-call", "Read" ] -> true
     | _ -> false)
;;

let () =
  run "runtime codex app-server"
    [ ( "native action", [ test_case "exact provider identity" `Quick test_native_action_observer_keeps_exact_provider_identity ] )
    ; ( "images"
      , [ test_case "image reaches the turn input" `Quick
            test_image_reaches_the_turn_input
        ; test_case "unsupported media type is rejected" `Quick
            test_unsupported_image_media_type_is_rejected
        ] )
    ; ( "subscription boundary"
      , [ test_case "ChatGPT turn completes" `Quick test_chatgpt_subscription_turn
        ; test_case
            "probe stops before thread"
            `Quick
            test_subscription_probe_stops_before_thread
        ; test_case "declared cwd reaches spawn" `Quick test_declared_cwd_reaches_spawn
        ; test_case
            "protocol and spawn share cwd authority"
            `Quick
            test_protocol_uses_spawn_cwd_and_named_permissions
        ; test_case
            "full posture names the workspace profile"
            `Quick
            test_native_full_names_the_workspace_profile
        ; test_case
            "child environment is allowlisted"
            `Quick
            test_child_environment_is_allowlisted
        ; test_case "API key is rejected" `Quick test_api_key_account_is_rejected
        ; test_case "malformed JSON fails closed" `Quick test_malformed_json_fails_closed
        ; test_case
            "duplicate object keys fail closed"
            `Quick
            test_duplicate_object_keys_fail_closed
        ; test_case
            "notification without params fails closed"
            `Quick
            test_notification_without_params_fails_closed
        ; test_case "server request fails closed" `Quick test_server_request_fails_closed
        ; test_case "failed turn keeps typed error fields" `Quick
            test_failed_turn_keeps_typed_error_fields
        ; test_case "failed turn uses official context error enum" `Quick
            test_failed_turn_uses_official_context_error_enum
        ; test_case "failed turn keeps unnamed error scalars" `Quick
            test_failed_turn_keeps_unnamed_error_scalars
        ; test_case "history bytes sum text only" `Quick
            test_history_bytes_sums_text_only
        ; test_case "dynamic tool bytes count name, description, schema" `Quick
            test_dynamic_tool_bytes_counts_name_description_and_schema
        ; test_case "failed turn stays failed" `Quick test_failed_turn_is_not_completion
        ; test_case
            "retry notifications are observational"
            `Quick
            test_retry_notifications_are_observational
        ; test_case
            "progress resets stream idle timeout"
            `Quick
            test_progress_resets_stream_idle_timeout
        ; test_case
            "stream idle timeout is typed"
            `Quick
            test_stream_idle_timeout_is_typed
        ; test_case
            "stream idle timeout preserves turn acceptance"
            `Quick
            test_stream_idle_timeout_after_turn_acceptance_is_typed
        ; test_case
            "no deadline keeps handshake bounded"
            `Quick
            test_no_deadline_keeps_handshake_bounded
        ; test_case
            "no deadline starts after turn acceptance"
            `Quick
            test_no_deadline_starts_after_turn_acceptance
        ; test_case
            "state callback timeout is typed"
            `Quick
            test_state_callback_timeout_is_typed
        ; test_case
            "no deadline keeps admission bounded"
            `Quick
            test_no_deadline_keeps_admission_bounded
        ; test_case
            "no deadline begins after turn dispatch"
            `Quick
            test_no_deadline_begins_after_turn_dispatch
        ; test_case
            "no deadline keeps turn-started callback bounded"
            `Quick
            test_no_deadline_keeps_turn_started_callback_bounded
        ; test_case
            "no deadline keeps post-accept writes bounded"
            `Quick
            test_no_deadline_keeps_post_accept_writes_bounded
        ; test_case
            "callback timeout origin is preserved without deadline"
            `Quick
            test_callback_timeout_origin_is_preserved_without_deadline
        ; test_case
            "terminal error notification uses official context error enum"
            `Quick
            test_terminal_error_notification_uses_official_context_error_enum
         ; test_case
             "nonterminal notifications do not preempt completion"
             `Quick
             test_nonterminal_notifications_do_not_preempt_completion
         ; test_case
             "item output deltas are typed and unbounded"
             `Quick
             test_item_output_deltas_are_typed_and_unbounded
         ; test_case
             "an empty output delta does not end the turn"
             `Quick
             test_empty_output_delta_does_not_end_the_turn
        ; test_case
            "dispatch validation is process-free"
            `Quick
            test_dispatch_validation_is_process_free
        ; test_case "dynamic tool callback" `Quick test_dynamic_tool_callback
        ; test_case
            "native command stays distinct from dynamic tools"
            `Quick
            test_native_command_events_stay_distinct_from_dynamic_tools
        ; test_case
            "dynamic tool abort stops provider loop"
            `Quick
            test_dynamic_tool_abort_stops_the_provider_loop
        ; test_case
            "context error records prior tool effect"
            `Quick
            test_context_error_records_prior_tool_effect
        ; test_case "history injects before turn" `Quick test_history_is_injected_before_turn
        ; test_case
            "thread resume skips history injection"
            `Quick
            test_thread_resume_skips_history_injection
        ; test_case
            "thread resume sends dynamic tools"
            `Quick
            test_thread_resume_sends_dynamic_tools
        ; test_case
            "dynamic tools are declared deferred under one namespace"
            `Quick
            test_dynamic_tools_are_declared_deferred_under_one_namespace
        ; test_case
            "thread resume rejects identity mismatch"
            `Quick
            test_thread_resume_rejects_identity_mismatch
        ; test_case
            "Keeper dispatches Codex runtime"
            `Quick
            test_keeper_dispatches_codex_turn_runtime
        ; test_case
            "Keeper maps official context error to typed core error"
            `Quick
            test_keeper_maps_official_context_error_to_typed_core_error
        ; test_case
            "Keeper does not retry context error after tool effect"
            `Quick
            test_keeper_does_not_retry_context_error_after_tool_effect
        ; test_case
            "Keeper shrinks history after typed context error"
            `Quick
            test_keeper_shrinks_history_after_typed_context_error
        ; test_case
            "Keeper shrinks lopsided history at an atom boundary"
            `Quick
            test_keeper_shrinks_lopsided_history_at_atom_boundary
        ; test_case
            "Keeper projects Codex live stream"
            `Quick
            test_keeper_projects_codex_live_stream
        ; test_case
            "Keeper preserves typed history on Codex wire"
            `Quick
            test_keeper_preserves_typed_history_on_codex_wire
        ; test_case
            "Keeper Codex RAW contains tool and response"
            `Quick
            test_keeper_codex_raw_trace_contains_actual_tool_and_response
        ; test_case
            "Keeper Codex RAW separates native tools"
            `Quick
            test_keeper_codex_raw_trace_separates_native_tool_observation
        ; test_case
            "Keeper protocol failure enters recovery"
            `Quick
            test_keeper_protocol_failure_enters_recovery
        ; test_case
            "dashboard official-client recovery projection and resolution"
            `Quick
            test_dashboard_official_client_recovery_projection_and_resolution
        ; test_case
            "Keeper resumes persisted Codex thread"
            `Quick
            test_keeper_resumes_persisted_codex_thread
        ; test_case
            "Keeper dynamic context stays on Codex instruction wire"
            `Quick
            test_keeper_dynamic_context_stays_on_codex_instruction_wire
        ; test_case
            "Keeper starts fresh on a changed Codex tool surface"
            `Quick
            test_keeper_starts_fresh_on_changed_tool_surface
        ; test_case
            "production Keeper dispatches Codex runtime"
            `Quick
            test_production_keeper_dispatches_codex_runtime
        ; test_case
            "production Keeper resumes across trace rotation"
            `Quick
            test_production_keeper_resumes_across_trace_rotation
        ; test_case
            "production dynamic context reaches Codex instruction wire"
            `Quick
            test_production_dynamic_context_reaches_codex_instruction_wire
        ; test_case
            "Keeper projects typed tools and hooks"
            `Quick
            test_keeper_projects_typed_tools_and_hooks
        ; test_case
            "Keeper rejects unprojected turn parameters"
            `Quick
            test_keeper_rejects_unprojected_turn_parameters
        ; test_case
            "shared host text projection is hard-cut"
            `Quick
            test_official_client_host_text_projection_is_hard_cut
        ] )
    ; ( "live subscription"
      , [ test_case
            "official Codex app-server"
            `Slow
            test_live_chatgpt_subscription
        ; test_case
            "official Codex dynamic tool"
            `Slow
            test_live_dynamic_tool_subscription
        ; test_case
            "official Codex history injection"
            `Slow
            test_live_history_injection_subscription
        ; test_case
            "Keeper through official Codex app-server"
            `Slow
            test_live_keeper_chatgpt_subscription
        ; test_case
            "Keeper typed tool through official Codex app-server"
            `Slow
            test_live_keeper_dynamic_tool_subscription
        ; test_case
            "Keeper resumes official Codex thread"
            `Slow
            test_live_keeper_resumes_official_thread
        ; test_case
            "production Keeper through official Codex app-server"
            `Slow
            test_live_production_keeper_subscription
        ] )
    ]
;;
