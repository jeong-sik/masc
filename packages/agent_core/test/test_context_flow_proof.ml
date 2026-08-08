(** End-to-end proof: context_injector → Context.t → before_turn_params → LLM.

    Closes the verification gap: existing tests proved the write side
    (injector writes to Context.t) but never the read side (Context.t data
    reaches the next turn's LLM prompt).

    Three-layer verification per test:
    1. Write side  — Context.t contains the injected key after turn 0
    2. Read side   — before_turn_params hook observes the key on turn 1
    3. LLM delivery — the API request body on turn 1 contains the context string *)

open Agent_sdk
open Types

(* ── Mock HTTP helpers ──────────────────────────────────── *)

let text_body text =
  Printf.sprintf
    {|{"id":"m1","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    text
;;

let tool_use_body ~tool_name ~input_json =
  Printf.sprintf
    {|{"id":"m2","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"%s","arguments":%S}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
    tool_name
    input_json
;;

(** Handler that returns tool_use on call 0, text on call 1+.
    Captures the raw request body on call 1 for LLM delivery verification. *)
let capturing_handler call_count captured_turn1_body _conn _req body =
  let raw = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
  let n = !call_count in
  incr call_count;
  if n = 1 then captured_turn1_body := raw;
  let response_body =
    if n = 0
    then tool_use_body ~tool_name:"echo" ~input_json:{|{"msg":"hi"}|}
    else text_body "done"
  in
  Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
;;

let with_mock_server ~port handler f =
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
    let server = Cohttp_eio.Server.make ~callback:handler () in
    Eio.Fiber.fork ~sw (fun () ->
      Cohttp_eio.Server.run socket server ~on_error:(fun _ -> ()));
    let base_url = Printf.sprintf "http://127.0.0.1:%d" port in
    f ~sw ~net:env#net ~base_url;
    Eio.Switch.fail sw Exit
  with
  | Exit -> ()
;;

let fresh_echo_tool () =
  let calls = ref 0 in
  let tool =
    Tool.create ~name:"echo" ~description:"Echo" ~parameters:[] (fun _input ->
      incr calls;
      Ok { Types.content = "echoed"; _meta = None })
  in
  tool, calls
;;

let local_provider ~base_url =
  Provider_mock.local_provider_config
    ~base_url
    ~model_id:"mock-model"
    ~request_path:"/v1/chat/completions"
    ()
;;

let require_run_success label = function
  | Ok _ -> ()
  | Error error -> Alcotest.failf "%s: %s" label (Error.to_string error)
;;

(** Substring search — checks if [sub] appears anywhere in [s]. *)
let contains_substring s sub =
  let len_s = String.length s
  and len_sub = String.length sub in
  if len_sub > len_s
  then false
  else (
    let found = ref false in
    for i = 0 to len_s - len_sub do
      if (not !found) && String.sub s i len_sub = sub then found := true
    done;
    !found)
;;

(* ── Test 1: Full chain — injector → Context.t → hook → LLM ── *)

(** Proves that data written by context_injector in turn 0 is:
    1. Present in Context.t (write side)
    2. Observable by before_turn_params hook on turn 1 (read side)
    3. Included in the API request body on turn 1 (LLM delivery) *)
let test_full_chain_across_turns () =
  let call_count = ref 0 in
  let captured_turn1_body = ref "" in
  with_mock_server
    ~port:18200
    (capturing_handler call_count captured_turn1_body)
    (fun ~sw ~net ~base_url ->
       let tool, _ = fresh_echo_tool () in
       let ctx = Context.create_sync () in
       (* Layer 1: Injector writes a known marker to Context.t *)
       let injector : Hooks.context_injector =
         fun ~tool_name:_ ~input:_ ~output:_ ->
         Some
           { Hooks.context_updates =
               [ "proof:flow_marker", `String "context_reached_llm" ]
           ; extra_messages = []
           }
       in
       (* Layer 2: Hook reads from Context.t and sets extra_system_context *)
       let hook_observed_on_turn1 = ref None in
       let hooks =
         { Hooks.empty with
           before_turn_params =
             Some
               (fun event ->
                 match event with
                 | Hooks.BeforeTurnParams { turn; current_params; _ } ->
                   let marker = Context.get ctx "proof:flow_marker" in
                   if turn > 0 then hook_observed_on_turn1 := marker;
                   (match marker with
                    | Some (`String s) ->
                      Hooks.AdjustParams
                        { current_params with
                          extra_system_context = Some ("[Temporal] proof_marker=" ^ s)
                        }
                    | _ -> Hooks.Continue)
                 | _ -> Hooks.Continue)
         }
       in
       let options =
         { Agent.default_options with
           provider_config = Some (local_provider ~base_url)
         ; context_injector = Some injector
         ; hooks
         }
       in
       let config = default_config ~model:"mock-model" in
       let agent = Agent.create ~net ~config ~options ~context:ctx ~tools:[ tool ] () in
       Agent.run ~sw agent "test context flow" |> require_run_success "context flow run";
       (* Verify Layer 1: write side *)
       Alcotest.(check bool)
         "Context.t has proof marker"
         true
         (Context.get ctx "proof:flow_marker" = Some (`String "context_reached_llm"));
       (* Verify Layer 2: read side *)
       Alcotest.(check bool)
         "hook observed marker on turn 1"
         true
         (!hook_observed_on_turn1 = Some (`String "context_reached_llm"));
       (* Verify Layer 3: LLM delivery *)
       Alcotest.(check bool)
         "API body contains context string"
         true
         (contains_substring !captured_turn1_body "proof_marker=context_reached_llm"))
;;

(* ── Test 2: No injector → no context pollution ────────── *)

(** Negative test: when no context_injector is configured,
    Context.t remains empty and hook sees nothing. *)
let test_no_injector_no_context () =
  let call_count = ref 0 in
  let captured = ref "" in
  with_mock_server
    ~port:18201
    (capturing_handler call_count captured)
    (fun ~sw ~net ~base_url ->
       let tool, _ = fresh_echo_tool () in
       let ctx = Context.create_sync () in
       let hook_saw_data = ref false in
       let hooks =
         { Hooks.empty with
           before_turn_params =
             Some
               (fun event ->
                 match event with
                 | Hooks.BeforeTurnParams { turn; _ } ->
                   if turn > 0
                   then (
                     let marker = Context.get ctx "proof:flow_marker" in
                     if marker <> None then hook_saw_data := true);
                   Hooks.Continue
                 | _ -> Hooks.Continue)
         }
       in
       let options =
         { Agent.default_options with
           provider_config = Some (local_provider ~base_url)
         ; hooks
         }
       in
       let config = default_config ~model:"mock-model" in
       let agent = Agent.create ~net ~config ~options ~context:ctx ~tools:[ tool ] () in
       Agent.run ~sw agent "test no injector" |> require_run_success "no-injector run";
       Alcotest.(check bool)
         "Context.t stays empty"
         true
         (Context.get ctx "proof:flow_marker" = None);
       Alcotest.(check bool) "hook saw no data" false !hook_saw_data)
;;

(* ── Test 3: Multiple tool calls accumulate ────────────── *)

(** Proves that context_injector accumulates across multiple tool calls
    within the same turn, and all accumulated data is visible on turn 1. *)
let test_accumulation_across_tool_calls () =
  let call_count2 = ref 0 in
  let captured2 = ref "" in
  let multi_tool_handler2 _conn _req body =
    let raw = Eio.Buf_read.(of_flow ~max_size:(1024 * 1024) body |> take_all) in
    let n = !call_count2 in
    incr call_count2;
    if n = 1 then captured2 := raw;
    let response_body =
      if n = 0
      then
        {|{"id":"m3","object":"chat.completion","model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu_1","type":"function","function":{"name":"echo","arguments":"{\"msg\":\"a\"}"}},{"id":"tu_2","type":"function","function":{"name":"echo","arguments":"{\"msg\":\"b\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}|}
      else text_body "done"
    in
    Cohttp_eio.Server.respond_string ~status:`OK ~body:response_body ()
  in
  with_mock_server ~port:18202 multi_tool_handler2 (fun ~sw ~net ~base_url ->
    let tool, tool_calls = fresh_echo_tool () in
    let ctx = Context.create_sync () in
    let inject_count = ref 0 in
    let injector : Hooks.context_injector =
      fun ~tool_name:_ ~input:_ ~output:_ ->
      incr inject_count;
      Some
        { Hooks.context_updates = [ "proof:inject_count", `Int !inject_count ]
        ; extra_messages = []
        }
    in
    let hook_saw_count = ref None in
    let hooks =
      { Hooks.empty with
        before_turn_params =
          Some
            (fun event ->
              match event with
              | Hooks.BeforeTurnParams { turn; current_params; _ } ->
                if turn > 0 then hook_saw_count := Context.get ctx "proof:inject_count";
                (match Context.get ctx "proof:inject_count" with
                 | Some (`Int n) ->
                   Hooks.AdjustParams
                     { current_params with
                       extra_system_context =
                         Some (Printf.sprintf "[Accumulation] count=%d" n)
                     }
                 | _ -> Hooks.Continue)
              | _ -> Hooks.Continue)
      }
    in
    let options =
      { Agent.default_options with
        provider_config = Some (local_provider ~base_url)
      ; context_injector = Some injector
      ; hooks
      }
    in
    let config = default_config ~model:"mock-model" in
    let agent = Agent.create ~net ~config ~options ~context:ctx ~tools:[ tool ] () in
    Agent.run ~sw agent "test accumulation" |> require_run_success "accumulation run";
    (* Tool was called twice *)
    Alcotest.(check int) "tool called twice" 2 !tool_calls;
    (* Injector fired twice, last write wins (count=2) *)
    Alcotest.(check bool)
      "inject_count = 2"
      true
      (Context.get ctx "proof:inject_count" = Some (`Int 2));
    (* Hook observed count=2 on turn 1 *)
    Alcotest.(check bool) "hook saw count=2" true (!hook_saw_count = Some (`Int 2));
    (* LLM body contains accumulation marker *)
    Alcotest.(check bool)
      "API body has accumulation"
      true
      (contains_substring !captured2 "count=2"))
;;

(* ── Test 4: Context.t identity — same object across pipeline ── *)

(** Proves that the Context.t passed to Agent.create is the SAME object
    that context_injector writes to and hooks read from.
    This catches the resume context identity bug where resume created
    a different Context.t instance. *)
let test_context_identity () =
  let call_count = ref 0 in
  let captured = ref "" in
  with_mock_server
    ~port:18203
    (capturing_handler call_count captured)
    (fun ~sw ~net ~base_url ->
       let tool, _ = fresh_echo_tool () in
       let ctx = Context.create_sync () in
       (* Pre-seed context with a value *)
       Context.set ctx "pre_seed" (`String "before_run");
       let injector : Hooks.context_injector =
         fun ~tool_name:_ ~input:_ ~output:_ ->
         (* Verify pre-seed is visible to injector *)
         let pre = Context.get ctx "pre_seed" in
         let pre_ok = pre = Some (`String "before_run") in
         Some
           { Hooks.context_updates = [ "injector:saw_preseed", `Bool pre_ok ]
           ; extra_messages = []
           }
       in
       let hook_saw_preseed = ref false in
       let hook_saw_injector_data = ref false in
       let hooks =
         { Hooks.empty with
           before_turn_params =
             Some
               (fun event ->
                 match event with
                 | Hooks.BeforeTurnParams { turn; _ } ->
                   if turn > 0
                   then (
                     (match Context.get ctx "pre_seed" with
                      | Some (`String "before_run") -> hook_saw_preseed := true
                      | _ -> ());
                     match Context.get ctx "injector:saw_preseed" with
                     | Some (`Bool true) -> hook_saw_injector_data := true
                     | _ -> ());
                   Hooks.Continue
                 | _ -> Hooks.Continue)
         }
       in
       let options =
         { Agent.default_options with
           provider_config = Some (local_provider ~base_url)
         ; context_injector = Some injector
         ; hooks
         }
       in
       let config = default_config ~model:"mock-model" in
       let agent = Agent.create ~net ~config ~options ~context:ctx ~tools:[ tool ] () in
       Agent.run ~sw agent "test identity" |> require_run_success "context identity run";
       (* Same Context.t object used throughout *)
       Alcotest.(check bool) "hook saw pre-seed" true !hook_saw_preseed;
       Alcotest.(check bool) "hook saw injector data" true !hook_saw_injector_data;
       (* Agent.context accessor returns the same object *)
       Alcotest.(check bool)
         "Agent.context is same ctx"
         true
         (Context.get (Agent.context agent) "pre_seed" = Some (`String "before_run")))
;;

(* ── Suite ──────────────────────────────────────────────── *)

let () =
  let open Alcotest in
  run
    "Context_Flow_Proof"
    [ ( "end_to_end"
      , [ test_case
            "injector → Context.t → hook → LLM (full chain)"
            `Quick
            test_full_chain_across_turns
        ; test_case
            "no injector → no context pollution"
            `Quick
            test_no_injector_no_context
        ; test_case
            "multiple tool calls accumulate"
            `Quick
            test_accumulation_across_tool_calls
        ; test_case
            "Context.t identity preserved across pipeline"
            `Quick
            test_context_identity
        ] )
    ]
;;
