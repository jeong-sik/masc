open Alcotest
open Agent_core
open Types

let output content = Ok { content; content_blocks = None; _meta = None }
let unavailable message = { message; recoverable = false; error_class = Some Unknown }

let identity key =
  Tool_contract.Resource_scope.identity ~namespace:"fixture-producer" ~key |> Result.get_ok
;;

let scope ?(access = Tool_contract.Resource_scope.Write) ?(ancestors = []) key =
  Tool_contract.Resource_scope.create ~access ~occupied:(identity key)
    ~ancestors:(List.map identity ancestors)
;;

let call name = Llm_provider.Types.ToolUse { id = "occurrence-" ^ name; name; input = `Assoc [] }

let execute env ?(hooks = Hooks.empty) ?(turn_count = 4) ?on_tool_execution_finished tools calls =
  let agent = Agent.create ~media_store:(Agent_core.History.Memory_store.create ()) ~config:(default_config ~model:"fixture")
      ~net:(Eio.Stdenv.net env) ~tools () in
  let options = Agent.options agent in
  Agent_tools.execute_tools ~context:(Agent.context agent)
    ~tools:(Tool_set.to_list (Agent.tools agent)) ~hooks
    ~event_bus:options.event_bus ~tracer:options.tracer
    ~agent_name:(Agent.state agent).config.name ~turn_count
    ~usage:(Agent.state agent).usage ?on_tool_execution_finished calls
;;

let results = function
  | Ok (report : Agent_tools.execution_report) -> report.completed_results
  | Error failure ->
    failf "unexpected execution failure after %d results"
      (List.length failure.Agent_tools.completed_results)
;;

let contents rows = List.map (fun (row : Agent_tools.tool_execution_result) -> row.content) rows

let prepared_tool ?(parameters = []) ?(call_effect = fun _ -> Tool.Effect_possible) ~name prepare fallback =
  Tool.create ~descriptor:(Tool.ordinary_descriptor_scoped ~call_effect ~prepare)
    ~name ~description:"fixture owned resource effect" ~parameters fallback
;;

let test_disjoint_effects_consume_frozen_calls () =
  Eio_main.run @@ fun env ->
  let left_started, start_left = Eio.Promise.create () in
  let right_started, start_right = Eio.Promise.create () in
  let releases = ref [] and prepared = ref [] and effects = ref [] and hooks_seen = ref [] in
  let fallback = ref 0 in
  let make name self other =
    let parameters =
      [ { name = "value"; description = "value"; param_type = String; required = false } ] in
    let tool = prepared_tool ~parameters ~name
        (fun ~sw input ->
          prepared := (name, input) :: !prepared;
          let released = ref false in
          Eio.Switch.on_release sw (fun () -> released := true; releases := name :: !releases);
          let handler execution_env actual =
            check bool "prepared resources are live" false !released;
            check bool "prepared input is exact" true (Yojson.Safe.equal input actual);
            let invocation = Tool.Execution_env.invocation execution_env |> Option.get in
            check string "original occurrence" ("occurrence-" ^ name)
              (Tool_contract.Invocation.tool_use_id invocation);
            let schedule = Tool_contract.Invocation.schedule invocation in
            check int "actual shared wave" 2 schedule.batch_size;
            check bool "actual invocation records concurrent execution" true
              (schedule.execution_mode = Tool_contract.Concurrent);
            Eio.Promise.resolve self ();
            Eio.Promise.await other;
            effects := name :: !effects;
            output (Yojson.Safe.to_string actual)
          in
          Ok (Some (Tool.scoped_call ~scope:(scope ~ancestors:[ "root" ] name) handler)))
        (fun _ -> incr fallback; output "wrong handler") in
    Tool.with_defaults [ "value", `String name ] tool
  in
  let left = make "left" start_left right_started in
  let right = make "right" start_right left_started in
  check bool "pure descriptor stays Serial" true
    (Tool.execution_mode left ~input:(`Assoc []) = Tool_contract.Serial);
  check bool "scope is not readonly or retry authority" true
    (Tool.call_effect left (`Assoc []) = Tool.Effect_possible);
  let hooks = { Hooks.empty with pre_tool_use = Some (function
    | Hooks.PreToolUse { input; _ } -> hooks_seen := input :: !hooks_seen; Hooks.Continue
    | _ -> fail "unexpected pre-tool event") } in
  let rows = execute env ~hooks [ left; right ] [ call "left"; call "right" ] |> results in
  check (list string) "prepared defaulted inputs reach their own effects"
    [ "{\"value\":\"left\"}"; "{\"value\":\"right\"}" ] (contents rows);
  check int "each call prepared once" 2 (List.length !prepared);
  check int "ordinary fallback is not dispatched" 0 !fallback;
  check (list string) "both actual effects completed" [ "left"; "right" ]
    (List.sort String.compare !effects);
  check (list string) "all prepared resources released after observers" [ "left"; "right" ]
    (List.sort String.compare !releases);
  check bool "public hook still receives exact wire input" true
    (List.for_all (Yojson.Safe.equal (`Assoc [])) !hooks_seen);
  List.iter (fun (row : Agent_tools.tool_execution_result) ->
    check bool "transcript keeps original wire input" true
      (Yojson.Safe.equal (`Assoc []) row.input)) rows
;;

let test_conflicting_predecessors_keep_transitive_order () =
  Eio_main.run @@ fun env ->
  let first_started, start_first = Eio.Promise.create () in
  let sibling_started, start_sibling = Eio.Promise.create () in
  let state = ref 0 and finished = ref [] in
  let make name occupied ?(additional_scopes = []) perform_effect =
    prepared_tool ~name (fun ~sw:_ _ ->
      Ok (Some (Tool.scoped_call ~scope:occupied ~additional_scopes
        (fun _ _ -> perform_effect (); output name))))
      (fun _ -> fail "unprepared effect dispatched")
  in
  let first = make "first" (scope ~ancestors:[ "root" ] "parent") (fun () ->
    Eio.Promise.resolve start_first ();
    Eio.Promise.await sibling_started;
    state := 1) in
  let second = make "second" (scope ~ancestors:[ "root"; "parent" ] "descendant")
      ~additional_scopes:[ scope ~ancestors:[ "root" ] "other" ] (fun () ->
        check int "ancestor effect completed first" 1 !state;
        check bool "prior wave observers completed" true (List.mem "first" !finished);
        state := 2) in
  let third = make "third" (scope ~ancestors:[ "root" ] "other") (fun () ->
    check int "blocked predecessor cannot be overtaken" 2 !state;
    state := 3) in
  let sibling = make "sibling" (scope ~ancestors:[ "root" ] "disjoint") (fun () ->
    Eio.Promise.resolve start_sibling ();
    Eio.Promise.await first_started) in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    finished := tool_name :: !finished in
  let rows = execute env ~on_tool_execution_finished [ first; second; third; sibling ]
      (List.map call [ "first"; "second"; "third"; "sibling" ]) |> results in
  check int "all ordered effects finished" 3 !state;
  check (list string) "results retain planned order across independent waves"
    [ "first"; "second"; "third"; "sibling" ] (contents rows);
  check (list int) "original planned coordinates survive scheduling" [ 0; 1; 2; 3 ]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      Tool_contract.Invocation.planned_index row.invocation) rows);
  check (list int) "ancestor, alias and transitive conflicts wait for prior waves" [ 0; 1; 2; 0 ]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_index) rows)
;;

let test_fallback_unavailable_validation_and_permission () =
  Eio_main.run @@ fun env ->
  let preparations = ref [] and effects = ref [] and releases = ref 0 in
  let parameters =
    [ { name = "value"; description = "mode"; param_type = String; required = true } ] in
  let tool = prepared_tool ~parameters ~name:"resolved"
      (fun ~sw input ->
        let value = Yojson.Safe.Util.(input |> member "value" |> to_string) in
        preparations := value :: !preparations;
        match value with
        | "fallback" -> Ok None
        | "unavailable" -> Error (unavailable "source unavailable")
        | _ ->
          Eio.Switch.on_release sw (fun () -> incr releases);
          Ok (Some (Tool.scoped_call ~scope:(scope value) (fun _ _ ->
            effects := value :: !effects; output value))))
      (fun input ->
        let value = Yojson.Safe.Util.(input |> member "value" |> to_string) in
        effects := value :: !effects; output ("fallback:" ^ value)) in
  let tool_use id input = Llm_provider.Types.ToolUse { id; name = "resolved"; input } in
  let input value = `Assoc [ "value", `String value ] in
  let hooks = { Hooks.empty with pre_tool_use = Some (function
    | Hooks.PreToolUse { input = `Assoc [ "value", `String "denied" ]; _ } -> Hooks.Block "denied"
    | _ -> Hooks.Continue) } in
  let rows = execute env ~hooks [ tool ]
      [ tool_use "fallback" (input "fallback")
      ; tool_use "unavailable" (input "unavailable")
      ; tool_use "invalid" (`Assoc [ "value", `Int 1 ])
      ; tool_use "denied" (input "denied") ] |> results in
  check (list string) "only explicit fallback performs an effect" [ "fallback" ] !effects;
  check (list string) "invalid schema never reaches resource preparation"
    [ "denied"; "fallback"; "unavailable" ] (List.sort String.compare !preparations);
  check int "denied prepared resource is released" 1 !releases;
  match rows with
  | [ fallback; unavailable; invalid; denied ] ->
    check string "serial fallback result" "fallback:fallback" fallback.content;
    check string "unavailable result preserved" "source unavailable" unavailable.content;
    List.iter (fun (row : Agent_tools.tool_execution_result) ->
      check bool "refusal is not a completed effect" true (tool_result_outcome_is_error row.outcome))
      [ unavailable; invalid; denied ]
  | _ -> fail "expected all four exact outcomes"
;;

let test_barriers_and_failure_semantics () =
  Eio_main.run @@ fun env ->
  let phase = ref 0 in
  let step expected = check int "barrier preserves prior completion" expected !phase; incr phase in
  let scoped name expected fail_call = prepared_tool ~name (fun ~sw:_ _ ->
    Ok (Some (Tool.scoped_call ~scope:(scope name) (fun _ _ ->
      step expected;
      if fail_call then Error (unavailable "ordinary tool failure") else output name))))
      (fun _ -> fail "unexpected fallback") in
  let readonly = Tool.create ~name:"read" ~description:"read" ~parameters:[]
      ~descriptor:(Tool.ordinary_descriptor ~call_effect:(fun _ -> Tool.Read_only) Tool_contract.Concurrent)
      (fun _ -> step 1; output "read") in
  let serial = Tool.create ~name:"serial" ~description:"serial" ~parameters:[]
      (fun _ -> step 3; output "serial") in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    if String.equal tool_name "missing" then step 4 in
  let rows = execute env ~on_tool_execution_finished
      [ scoped "first" 0 true; readonly; scoped "middle" 2 false
      ; serial; scoped "last" 5 false ]
      (List.map call [ "first"; "read"; "middle"; "serial"; "missing"; "last" ]) |> results in
  check int "ordinary Tool_failed does not abort subsequent batches" 6 !phase;
  check int "all outcomes retained" 6 (List.length rows);
  check (list int) "readonly serial and unknown calls separate scoped regions" [ 0; 1; 2; 3; 4; 5 ]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_index) rows);
  let dispatched = ref [] and released = ref 0 in
  let make name = prepared_tool ~name (fun ~sw _ ->
    Eio.Switch.on_release sw (fun () -> incr released);
    Ok (Some (Tool.scoped_call ~scope:(scope name) (fun _ _ ->
      dispatched := name :: !dispatched; output name)))) (fun _ -> fail "unexpected fallback") in
  let first = make "before" and later = make "later" in
  let stop = Tool.create ~name:"stop" ~description:"stop" ~parameters:[] (fun _ -> output "stop") in
  let hooks = { Hooks.empty with pre_tool_use = Some (function
    | Hooks.PreToolUse { tool_name = "stop"; _ } -> Hooks.AdjustParams Hooks.default_turn_params
    | _ -> Hooks.Continue) } in
  (match execute env ~hooks [ first; stop; later ] (List.map call [ "before"; "stop"; "later" ]) with
   | Error { Agent_tools.completed_results = [ completed ]
           ; cause = Agent_tools.Hook_failure (Agent_tools.Hook_execution_failed { stage = Hooks.Pre_tool_use; _ }); _ } ->
     check string "earlier result survives hook failure" "before" completed.content
   | Ok _ | Error _ -> fail "illegal parameter adjustment did not abort execution");
  check (list string) "later scoped effect does not run after hook failure" [ "before" ] !dispatched;
  check int "all prepared resources close after abort" 2 !released
;;

let test_terminal_rejection_and_preparation_exception () =
  Eio_main.run @@ fun env ->
  let preparations = ref 0 and effects = ref 0 and releases = ref 0 in
  let scoped = prepared_tool ~name:"scoped" (fun ~sw _ ->
    incr preparations;
    Eio.Switch.on_release sw (fun () -> incr releases);
    failwith "resolver unavailable") (fun _ -> incr effects; output "wrong fallback") in
  let terminal = Tool.create ~name:"terminal" ~description:"terminal" ~parameters:[]
      ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
      (fun _ -> incr effects; output "terminal") in
  let rows = execute env [ scoped; terminal ] [ call "scoped"; call "terminal" ] |> results in
  check int "terminal mix returns both rejections" 2 (List.length rows);
  check int "terminal mix resolves no resource" 0 !preparations;
  check int "terminal mix opens no effect" 0 !effects;
  (match execute env [ scoped ] [ call "scoped" ] with
   | Error { Agent_tools.completed_results = []
           ; cause = Agent_tools.Observer_failure { invocation; exception_ = Failure detail; _ }; _ } ->
     check string "preparation failure retains occurrence" "occurrence-scoped"
       (Tool_contract.Invocation.tool_use_id invocation);
     check string "original preparation error retained" "resolver unavailable" detail
   | Ok _ | Error _ -> fail "preparation exception was not a typed execution failure");
  check int "resolver exception cannot dispatch original handler" 0 !effects;
  check int "resolver exception releases its partial preparation" 1 !releases
;;

let test_scoped_observer_failure_retains_siblings () =
  Eio_main.run @@ fun env ->
  let left_started, start_left = Eio.Promise.create () in
  let right_started, start_right = Eio.Promise.create () in
  let releases = ref 0 and later_effects = ref 0 in
  let make name occupied handler = prepared_tool ~name (fun ~sw _ ->
    Eio.Switch.on_release sw (fun () -> incr releases);
    Ok (Some (Tool.scoped_call ~scope:occupied (fun _ _ -> handler (); output name))))
    (fun _ -> fail "unexpected fallback") in
  let left = make "left" (scope "left") (fun () ->
    Eio.Promise.resolve start_left (); Eio.Promise.await right_started) in
  let right = make "right" (scope "right") (fun () ->
    Eio.Promise.resolve start_right (); Eio.Promise.await left_started) in
  let later = make "later" (scope "left") (fun () -> incr later_effects) in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    if String.equal tool_name "left" then raise Exit in
  (match execute env ~on_tool_execution_finished [ left; right; later ]
      (List.map call [ "left"; "right"; "later" ]) with
   | Error { Agent_tools.completed_results = completed
           ; cause = Agent_tools.Observer_failure { exception_ = Exit; _ }; _ } ->
     check (list string) "both already-completed scoped siblings survive observer failure"
       [ "left"; "right" ] (contents completed)
   | Ok _ | Error _ -> fail "observer failure did not stop the next resource wave");
  check int "conflicting later effect was not dispatched" 0 !later_effects;
  check int "all scoped preparations close after observer failure" 3 !releases
;;

let test_cancellation_releases_prepared_resources () =
  Eio_main.run @@ fun env ->
  List.iter (fun during_prepare ->
    let entered, enter = Eio.Promise.create () in
    let never, _ = Eio.Promise.create () in
    let released = ref false and effects = ref 0 in
    let tool = prepared_tool ~name:"cancelled" (fun ~sw _ ->
      Eio.Switch.on_release sw (fun () -> released := true);
      let wait () = Eio.Promise.resolve enter (); Eio.Promise.await never in
      if during_prepare then wait ();
      Ok (Some (Tool.scoped_call ~scope:(scope "cancelled") (fun _ _ ->
        wait (); incr effects; output "must not complete"))))
      (fun _ -> incr effects; output "wrong fallback") in
    Eio.Fiber.first
      (fun () ->
        ignore (execute env [ tool ] [ call "cancelled" ]);
        fail "cancelled producer returned normally")
      (fun () -> Eio.Promise.await entered);
    check bool "caller cancellation releases pinned preparation" true !released;
    check int "cancelled invocation never performs its deferred effect" 0 !effects)
    [ true; false ]
;;

let test_replaced_handler_cannot_reuse_old_preparation () =
  Eio_main.run @@ fun env ->
  let preparations = ref 0 and ordinary_calls = ref 0 and wrapper_calls = ref 0 in
  let original = prepared_tool ~name:"wrapped" (fun ~sw:_ _ ->
    incr preparations;
    Ok (Some (Tool.scoped_call ~scope:(scope "wrapped") (fun _ _ -> output "stale handler"))))
      (fun _ -> incr ordinary_calls; output "ordinary") in
  let wrapped = { original with Tool.handler = (fun execution_env input ->
    incr wrapper_calls;
    original.Tool.handler execution_env input) } in
  let rows = execute env [ wrapped ] [ call "wrapped" ] |> results in
  check (list string) "actual handler wrapper remains in dispatch" [ "ordinary" ] (contents rows);
  check int "stale scoped resolver is not invoked" 0 !preparations;
  check int "ordinary handler executes once" 1 !ordinary_calls;
  check int "wrapper executes once" 1 !wrapper_calls;
  (match rows with
  | [ row ] -> check bool "replacement retains Serial admission" true
      ((Tool_contract.Invocation.schedule row.invocation).execution_mode = Tool_contract.Serial)
  | _ -> fail "expected the exact wrapped invocation");
  let observations = ref [] in
  let observe handler execution_env input =
    let invocation = Option.get (Tool.Execution_env.invocation execution_env) in
    observations := (Tool_contract.Invocation.tool_use_id invocation, input) :: !observations;
    handler execution_env input in
  let instrumented = Tool.map_handler observe original in
  let rows = execute env [ instrumented ] [ call "wrapped" ] |> results in
  check (list string) "typed instrumentation consumes the prepared handler"
    [ "stale handler" ] (contents rows);
  check int "typed instrumentation retains real preparation" 1 !preparations;
  check int "prepared execution does not run ordinary handler" 1 !ordinary_calls;
  check bool "instrumentation sees exact occurrence and input" true
    (!observations = [ "occurrence-wrapped", `Assoc [] ]);
  (match rows with
   | [ row ] -> check bool "instrumented prepared invocation remains Concurrent" true
       ((Tool_contract.Invocation.schedule row.invocation).execution_mode = Tool_contract.Concurrent)
   | _ -> fail "expected the exact instrumented invocation");
  let invalid = Tool.map_handler observe wrapped in
  let rows = execute env [ invalid ] [ call "wrapped" ] |> results in
  check (list string) "typed instrumentation cannot revive an invalid binding"
    [ "ordinary" ] (contents rows);
  check int "invalid preparation stays unused" 1 !preparations;
  check int "existing replacement wrapper still executes" 2 !wrapper_calls
;;

let test_durable_truth_precedes_current_preparation () =
  let module Internal = Agent_core__ in
  let module Scope = Internal.Execution_agent_scope in
  let module Writer = Internal.Execution_lane_writer in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime = match Internal.Execution_runtime.create ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> fail (Internal.Execution_runtime.create_error_to_string error) in
  let codec = Internal.Execution_codec_executor.of_runtime runtime in
  List.iter (fun settled ->
    let native_path = Filename.temp_file "scoped-durable-truth-" ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) @@ fun () ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let ran = ref 0 and current_preparations = ref 0 and hook_calls = ref 0 in
    let require = function Ok value -> value | Error error -> fail (Scope.error_to_string error) in
    match Writer.run ~codec ~dir (fun ~sw:_ writer ->
      let owner = Scope.start ~writer ~agent_name:"scoped-durable-fixture" |> require in
      let turn = Scope.open_turn owner ~ordinal:0 |> require in
      let provider_config = Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat ~model_id:"fixture"
          ~base_url:"http://unused.invalid" ~api_key:"" ~request_path:"/v1/chat/completions" () in
      let binding = match Binding_identity.of_provider_config
          ~transport:Binding_identity.Injected provider_config with
        | Ok binding -> binding | Error detail -> fail detail in
      let provider = Scope.open_provider_attempt turn ~ordinal:0 binding |> require in
      let response =
        { id = "scoped-durable-response"; model = "fixture"; stop_reason = StopToolUse
        ; content = [ call "durable" ]; usage = None; telemetry = None } in
      Scope.record_provider_response provider response |> require;
      let original = prepared_tool ~name:"durable" (fun ~sw:_ _ ->
        Ok (Some (Tool.scoped_call ~scope:(scope "durable") (fun _ _ ->
          incr ran;
          if settled then output "original committed result"
          else raise (Eio.Cancel.Cancelled Exit)))))
          (fun _ -> fail "unprepared durable effect") in
      let in_provider action = Internal.Execution_context.with_provider_attempt provider action in
      (match in_provider (fun () -> execute env ~turn_count:0 [ original ] [ call "durable" ]) with
       | Ok report when settled -> check (list string) "original actual producer result"
           [ "original committed result" ] (contents report.completed_results)
       | exception Eio.Cancel.Cancelled Exit when not settled -> ()
       | Ok _ | Error _ -> fail "original durable producer did not reach its expected phase");
      let authorities = Scope.provider_invocations provider |> require in
      let authority = match authorities with [ authority ] -> authority
        | _ -> fail "expected one original durable occurrence" in
      check bool "original scoped invocation is canonically Concurrent" true
        ((Tool_contract.Invocation.schedule authority.invocation).execution_mode = Tool_contract.Concurrent);
      let current prepare = prepared_tool ~name:"durable" (fun ~sw:_ _ ->
        incr current_preparations; prepare ())
          (fun _ -> incr ran; output "duplicate") in
      let throwing = current (fun () -> failwith "current resource unavailable") in
      let unavailable = current (fun () -> Error (unavailable "current source unavailable")) in
      let hooks = { Hooks.empty with pre_tool_use = Some (fun _ -> incr hook_calls; Hooks.Continue) } in
      List.iter (fun tools ->
        let replayed = in_provider (fun () -> execute env ~turn_count:0 ~hooks tools [ call "durable" ]) in
        if settled then
          (match replayed with
           | Ok { Agent_tools.completed_results = [ result ]; _ } ->
             check string "canonical result survives current resolver failure or retirement"
               "original committed result" result.content;
             check bool "canonical original schedule is preserved" true
               ((Tool_contract.Invocation.schedule result.invocation).execution_mode = Tool_contract.Concurrent)
           | Ok _ | Error _ -> fail "current preparation masked the exact settled result")
        else
          (match replayed with
           | Error { Agent_tools.completed_results = []; cause = Agent_tools.Durability_failure _; _ } -> ()
           | Ok _ | Error _ -> fail "unknown effect was not refused by canonical settlement"))
        [ [ throwing ]; [ unavailable ]; [] ];
      check int "current resource resolver is not consulted for an attempted original" 0 !current_preparations;
      check int "attempted original is not reauthorized through current hooks" 0 !hook_calls;
      check int "original effect is never dispatched twice" 1 !ran;
      let changed =
        Llm_provider.Types.ToolUse { id = "changed-occurrence"; name = "durable"; input = `Assoc [] }
      in
      (match in_provider (fun () -> execute env ~turn_count:0 [] [ changed ]) with
       | Error { Agent_tools.cause = Agent_tools.Durability_failure _; _ } -> ()
       | Ok _ | Error _ -> fail "changed occurrence reused original durable authority")) with
    | Ok () -> ()
    | Error error -> fail (Writer.scope_failure_to_string error)) [ true; false ]
;;


let test_unattempted_sibling_preserves_original_wave () =
  let module Internal = Agent_core__ in
  let module Scope = Internal.Execution_agent_scope in
  let module Writer = Internal.Execution_lane_writer in
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let runtime = match Internal.Execution_runtime.create ~sw
      ~domain_mgr:(Eio.Stdenv.domain_mgr env) ~domain_count:1 with
    | Ok runtime -> runtime
    | Error error -> fail (Internal.Execution_runtime.create_error_to_string error) in
  let codec = Internal.Execution_codec_executor.of_runtime runtime in
  List.iter (fun scoped ->
    let native_path = Filename.temp_file "unattempted-sibling-" ".dir" in
    Sys.remove native_path;
    let dir = Eio.Path.(Eio.Stdenv.fs env / native_path) in
    Fun.protect ~finally:(fun () -> Eio.Path.rmtree ~missing_ok:true dir) @@ fun () ->
    Eio.Path.mkdirs ~exists_ok:false ~perm:0o700 dir;
    let require = function Ok value -> value | Error error -> fail (Scope.error_to_string error) in
    match Writer.run ~codec ~dir (fun ~sw writer ->
      let owner = Scope.start ~writer ~agent_name:"unattempted-sibling-fixture" |> require in
      let turn = Scope.open_turn owner ~ordinal:0 |> require in
      let provider_config = Llm_provider.Provider_config.make
          ~kind:Llm_provider.Provider_config.OpenAI_compat ~model_id:"fixture"
          ~base_url:"http://unused.invalid" ~api_key:"" ~request_path:"/v1/chat/completions" () in
      let binding = match Binding_identity.of_provider_config
          ~transport:Binding_identity.Injected provider_config with
        | Ok binding -> binding | Error detail -> fail detail in
      let provider = Scope.open_provider_attempt turn ~ordinal:0 binding |> require in
      let calls = [ call "left"; call "right" ] in
      let response =
        { id = "unattempted-sibling-response"; model = "fixture"; stop_reason = StopToolUse
        ; content = calls; usage = None; telemetry = None } in
      Scope.record_provider_response provider response |> require;
      let counts = Hashtbl.create 2 in
      let count name = match Hashtbl.find_opt counts name with Some value -> value | None -> 0 in
      let perform name _env _input =
        Hashtbl.replace counts name (count name + 1);
        output (name ^ " original result") in
      let preparations = ref [] and hooks_seen = ref [] in
      let make ~current name =
        if scoped then
          prepared_tool ~name (fun ~sw:_ _ ->
            if current && name = "left" then fail "settled sibling re-entered preparation";
            preparations := name :: !preparations;
            Ok (Some (Tool.scoped_call ~scope:(scope name) (perform name))))
            (fun _ -> fail "scoped producer bypassed preparation")
        else
          Tool.of_schema
            ~descriptor:(Tool.ordinary_descriptor ~call_effect:(fun _ -> Tool.Read_only) Tool_contract.Concurrent)
            (Types.tool_schema_of_params ~name ~description:"read-only sibling fixture" ~parameters:[] ())
            (perform name) in
      let original_left = make ~current:false "left" in
      let original_invocation index name =
        Tool_contract.Invocation.create ~tool_use_id:("occurrence-" ^ name) ~turn:0
          ~schedule:{ planned_index=index; batch_index=0; batch_size=2; execution_mode=Tool_contract.Concurrent }
          ~completion:Tool_contract.Continue_after_success in
      let left_invocation = original_invocation 0 "left" in
      let right_invocation = original_invocation 1 "right" in
      let left = Scope.open_invocation provider ~invocation:left_invocation
          ~tool_name:"left" ~input:(`Assoc []) |> require in
      let right = Scope.open_invocation provider ~invocation:right_invocation
          ~tool_name:"right" ~input:(`Assoc []) |> require in
      let prepared = Tool.prepare_call ~sw original_left ~input:(`Assoc []) in
      ignore (Scope.execute left ~invoke:(fun ~start_child:_ ~tool_name:_ ~input:_ ->
        match Tool.execute_prepared ~invocation:left_invocation prepared with
        | Ok result -> result.content, Tool_succeeded
        | Error _ -> fail "original sibling failed before durable settlement") |> require);
      check bool "first sibling is durably settled" true
        ((Scope.invocation_progress left |> require) = Scope.Invocation_attempted_or_settled);
      check bool "second sibling is durably open and unattempted" true
        ((Scope.invocation_progress right |> require) = Scope.Invocation_unattempted);
      let left = make ~current:true "left" and right_tool = make ~current:true "right" in
      let in_provider action = Internal.Execution_context.with_provider_attempt provider action in
      let terminal_right = Tool.create ~descriptor:(Tool.terminal_descriptor Tool_contract.Effect_outcome_unknown)
          ~name:"right" ~description:"changed completion must refuse" ~parameters:[]
          (fun _ -> fail "changed terminal contract executed") in
      (match in_provider (fun () -> execute env ~turn_count:0 [ left; terminal_right ] calls) with
       | Ok report ->
         check int "Terminal mix returns each rejected occurrence" 2 (List.length report.completed_results);
         check bool "current Terminal mix refuses every call" true
           (List.for_all (fun (row : Agent_tools.tool_execution_result) ->
             match row.outcome with
             | Tool_failed { failure_kind=Validation_error; _ } -> true
             | Tool_failed {failure_kind=(Recoverable_tool_error | Non_retryable_tool_error
                 | Reported_tool_error | Unattributed_tool_error); _}
             | Tool_succeeded -> false) report.completed_results)
       | Error _ -> fail "current Terminal mix lost its typed rejection");
      List.iter (fun changed_right ->
        let changed = [ call "left"; changed_right ] in
        match in_provider (fun () -> execute env ~turn_count:0 [ left; right_tool ] changed) with
        | Error { Agent_tools.cause=Agent_tools.Durability_failure _; _ } -> ()
        | Ok _ | Error _ -> fail "changed unattempted occurrence reused old authority")
        [ ToolUse {id="changed-right";name="right";input=`Assoc []}
        ; ToolUse {id="occurrence-right";name="other-right";input=`Assoc []}
        ; ToolUse {id="occurrence-right";name="right";input=`Assoc ["changed",`Bool true]} ];
      check int "rejections never perform the unattempted effect" 0 (count "right");
      preparations := [];
      let hooks = { Hooks.empty with pre_tool_use=Some (function
        | Hooks.PreToolUse { invocation; tool_name; input; _ } ->
          hooks_seen := tool_name :: !hooks_seen;
          check string "only unattempted sibling re-enters current Gate" "right" tool_name;
          check bool "Gate sees original wave and exact input" true
            (Tool_contract.Invocation.schedule invocation = Tool_contract.Invocation.schedule right_invocation
             && Yojson.Safe.equal input (`Assoc []));
          Hooks.Continue
        | _ -> fail "unexpected pre-tool event") } in
      let resumed = in_provider (fun () -> execute env ~turn_count:0 ~hooks [ left; right_tool ] calls) |> results in
      check (list string) "resumption preserves both original results"
        [ "left original result"; "right original result" ] (contents resumed);
      check int "completed sibling has no duplicate effect" 1 (count "left");
      check int "unattempted sibling performs exactly one fresh effect" 1 (count "right");
      check (list string) "only fresh sibling is authorized" [ "right" ] !hooks_seen;
      check (list string) "unattempted scoped sibling is freshly prepared"
        (if scoped then [ "right" ] else []) !preparations;
      List.iter2 (fun (row : Agent_tools.tool_execution_result) original ->
        check string "same original occurrence" (Tool_contract.Invocation.tool_use_id original)
          (Tool_contract.Invocation.tool_use_id row.invocation);
        check bool "original concurrent wave identity is preserved" true
          (Tool_contract.Invocation.schedule row.invocation = Tool_contract.Invocation.schedule original))
        resumed [ left_invocation; right_invocation ];
      check bool "all original invocations now have canonical durable results" true
        (Scope.provider_invocations_settled provider |> require)) with
    | Ok () -> ()
    | Error error -> fail (Writer.scope_failure_to_string error)) [true; false]
;;

let test_shared_reads_and_private_writes_keep_writer_order () =
  Eio_main.run @@ fun env ->
  let module Access = Tool_contract.Resource_scope in
  let left_started, start_left = Eio.Promise.create () in
  let right_started, start_right = Eio.Promise.create () in
  let sibling_started, start_sibling = Eio.Promise.create () in
  let shared = ref "before" and observations = ref [] in
  let make name occupied ?(additional_scopes = []) perform =
    prepared_tool ~name (fun ~sw:_ _ ->
      Ok (Some (Tool.scoped_call ~scope:occupied ~additional_scopes
        (fun _ _ -> perform (); output name))))
      (fun _ -> fail "unprepared resource access dispatched") in
  let read name signal other occupied =
    make name occupied ~additional_scopes:[scope ("private-" ^ name)] (fun () ->
      Eio.Promise.resolve signal ();
      Eio.Promise.await other;
      Eio.Promise.await sibling_started;
      observations := (name, !shared) :: !observations) in
  let left = read "left" start_left right_started (scope ~access:Access.Read "shared") in
  let right = read "right" start_right left_started
      (scope ~access:Access.Read ~ancestors:["shared"] "child") in
  let writer = make "writer" (scope "shared") (fun () ->
    check (list (pair string string)) "both overlapping reads finish before write"
      ["left", "before"; "right", "before"]
      (List.sort (fun (left, _) (right, _) -> String.compare left right) !observations);
    shared := "after") in
  let later = make "later" (scope ~access:Access.Read ~ancestors:["shared"] "child")
      (fun () -> check string "later reader cannot overtake the writer" "after" !shared) in
  let sibling = make "sibling" (scope "unrelated") (fun () ->
    Eio.Promise.resolve start_sibling ();
    Eio.Promise.await left_started;
    Eio.Promise.await right_started) in
  check bool "read claims do not make a mixed call readonly" true
    (Tool.call_effect left (`Assoc []) = Tool.Effect_possible);
  let rows = execute env [left; right; writer; later; sibling]
      (List.map call ["left"; "right"; "writer"; "later"; "sibling"]) |> results in
  check (list string) "actual results retain original call order"
    ["left"; "right"; "writer"; "later"; "sibling"] (contents rows);
  check (list int) "shared reads overlap and writes retain both directions of ordering"
    [0; 0; 1; 2; 0]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_index) rows)
;;

let test_scoped_effect_contracts_follow_defaulted_execution_input () =
  Eio_main.run @@ fun env ->
  let reads_only = function
    | `Assoc fields ->
      (match List.assoc_opt "write" fields with
       | None | Some (`Bool false) -> true
       | Some (`Bool true | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _) -> false)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false in
  let call_effect input = if reads_only input then Tool.Read_only else Tool.Effect_possible in
  let parameters = [{name="write"; description="Mutate the observed source"; param_type=Boolean; required=false}] in
  let source = ref "before" and observed = ref [] in
  let left_started, start_left = Eio.Promise.create () in
  let right_started, start_right = Eio.Promise.create () in
  let make name ~write_default ~on_read =
    let run input =
      let readonly = reads_only input in
      observed := (name, readonly) :: !observed;
      if readonly then on_read () else source := "after";
      output name in
    prepared_tool ~parameters ~call_effect ~name (fun ~sw:_ input ->
      let access = if reads_only input then Tool_contract.Resource_scope.Read
        else Tool_contract.Resource_scope.Write in
      Ok (Some (Tool.scoped_call ~scope:(scope ~access "defaulted-source")
        (fun _ input -> run input)))) run
    |> Tool.with_defaults ["write", `Bool write_default] in
  let left = make "left" ~write_default:false ~on_read:(fun () ->
    Eio.Promise.resolve start_left (); Eio.Promise.await right_started;
    check string "left observes the original bytes before writer" "before" !source) in
  let right = make "right" ~write_default:false ~on_read:(fun () ->
    Eio.Promise.resolve start_right (); Eio.Promise.await left_started;
    check string "right observes the original bytes before writer" "before" !source) in
  let writer = make "writer" ~write_default:true ~on_read:(fun () -> ()) in
  let later = make "later" ~write_default:false ~on_read:(fun () ->
    check string "later read observes the defaulted writer" "after" !source) in
  List.iter (fun (tool, expected) ->
    check bool (tool.Tool.schema.name ^ " effect uses effective defaulted input") true
      (Tool.call_effect tool (`Assoc []) = expected))
    [left, Tool.Read_only; right, Tool.Read_only; writer, Tool.Effect_possible; later, Tool.Read_only];
  let rows = execute env [left; right; writer; later]
      (List.map call ["left"; "right"; "writer"; "later"]) |> results in
  check (list int) "defaulted reads overlap without overtaking the writer" [0; 0; 1; 2]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_index) rows);
  check (list (pair string bool)) "executed modes match the producer effect declarations"
    ["later", true; "left", true; "right", true; "writer", false]
    (List.sort (fun (left, _) (right, _) -> String.compare left right) !observed);
  let replacement = {left with Tool.handler = (fun _ _ -> source := "replacement"; output "replacement")} in
  check bool "replaced handler cannot retain stale read-only authority" true
    (Tool.call_effect replacement (`Assoc []) = Tool.Effect_possible);
  List.iter (fun (name, descriptor) ->
    let tool = Tool.create ~descriptor ~name ~description:"Defaulted mutation fixture" ~parameters
        (fun input ->
          check bool "actual fallback handler receives the mutating default" false (reads_only input);
          source := name;
          output name)
      |> Tool.with_defaults ["write", `Bool true] in
    check bool "defaulted mutation is not classified as readonly" true
      (Tool.call_effect tool (`Assoc []) = Tool.Effect_possible);
    check bool "defaulted mutation never gains conditional concurrency" true
      (Tool.execution_mode tool ~input:(`Assoc []) = Tool_contract.Serial);
    ignore (execute env [tool] [call name] |> results);
    check string "the declared mutating path actually executes" name !source)
    ["static", Tool.ordinary_descriptor ~call_effect Tool_contract.Serial;
     "conditional", Tool.ordinary_descriptor_concurrent_when reads_only]
;;

let test_ready_successor_chain_does_not_wait_for_unrelated_root () =
  Eio_main.run @@ fun env ->
  let slow_started, start_slow = Eio.Promise.create () in
  let tail_finished, finish_tail = Eio.Promise.create () in
  let slow_finished = ref false and chain = ref 0 and finished = ref [] and released = ref [] in
  let make name occupied ?(additional_scopes=[]) handler =
    prepared_tool ~name (fun ~sw _ ->
      Eio.Switch.on_release sw (fun () -> released := name :: !released);
      Ok (Some (Tool.scoped_call ~scope:occupied ~additional_scopes (fun _ _ ->
        handler (); output name)))) (fun _ -> fail "unprepared effect dispatched") in
  let slow = make "slow" (scope "slow") (fun () ->
    Eio.Promise.resolve start_slow ();
    Eio.Promise.await tail_finished;
    slow_finished := true) in
  let quick = make "quick" (scope "chain-a") (fun () ->
    Eio.Promise.await slow_started;
    chain := 1) in
  let middle = make "middle" (scope "chain-a") ~additional_scopes:[scope "chain-b"] (fun () ->
    check bool "unrelated root is still open when its peer's successor starts" false !slow_finished;
    check bool "the real predecessor's observers have settled" true (List.mem "quick" !finished);
    check int "the predecessor's effect is available" 1 !chain;
    chain := 2) in
  let tail = make "tail" (scope "chain-b") (fun () ->
    check bool "the next successor also does not wait for the slow root" false !slow_finished;
    check bool "the multi-resource predecessor has settled" true (List.mem "middle" !finished);
    check int "the transitive effect is available" 2 !chain;
    chain := 3;
    Eio.Promise.resolve finish_tail ()) in
  let barrier = Tool.create ~name:"barrier" ~description:"opaque serial boundary" ~parameters:[]
      (fun _ ->
        check bool "opaque Serial still waits for the whole scoped region" true !slow_finished;
        check int "all predecessor effects settled before the barrier" 3 !chain;
        output "barrier") in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    finished := tool_name :: !finished in
  let rows = execute env ~on_tool_execution_finished [slow;quick;middle;tail;barrier]
      (List.map call ["slow";"quick";"middle";"tail";"barrier"]) |> results in
  check (list string) "results keep original order despite early successors"
    ["slow";"quick";"middle";"tail";"barrier"] (contents rows);
  check (list int) "static wave coordinates and following barrier are preserved" [0;0;1;2;3]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_index) rows);
  check (list int) "static cohort sizes do not become dynamic queue counts" [2;2;1;1;1]
    (List.map (fun (row : Agent_tools.tool_execution_result) ->
      (Tool_contract.Invocation.schedule row.invocation).batch_size) rows);
  check (list string) "all pinned resources close after the region"
    ["middle";"quick";"slow";"tail"] (List.sort String.compare !released)
;;

let test_known_peer_failure_prevents_new_resource_successor () =
  Eio_main.run @@ fun env ->
  let survivor_started, start_survivor = Eio.Promise.create () in
  let failure_seen, see_failure = Eio.Promise.create () in
  let later_effects = ref 0 and released = ref 0 in
  let make name occupied handler = prepared_tool ~name (fun ~sw _ ->
    Eio.Switch.on_release sw (fun () -> incr released);
    Ok (Some (Tool.scoped_call ~scope:occupied (fun _ _ -> handler (); output name))))
      (fun _ -> fail "unprepared effect dispatched") in
  let fatal = make "fatal" (scope "fatal") (fun () -> Eio.Promise.await survivor_started) in
  let survivor = make "survivor" (scope "survivor") (fun () ->
    Eio.Promise.resolve start_survivor ();
    Eio.Promise.await failure_seen) in
  let later = make "later" (scope "survivor") (fun () -> incr later_effects) in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    if String.equal tool_name "fatal" then (Eio.Promise.resolve see_failure (); raise Exit) in
  (match execute env ~on_tool_execution_finished [fatal;survivor;later]
      (List.map call ["fatal";"survivor";"later"]) with
   | Error {Agent_tools.completed_results;cause=Agent_tools.Observer_failure {exception_=Exit;_};_} ->
     check (list string) "the admitted root cohort still settles" ["fatal";"survivor"] (contents completed_results)
   | Ok _ | Error _ -> fail "the known observer failure was lost");
  check int "a successful predecessor cannot admit a successor after a peer failure" 0 !later_effects;
  check int "unstarted prepared resources are released too" 3 !released
;;

let test_started_successor_settles_after_later_peer_failure () =
  Eio_main.run @@ fun env ->
  let child_started, start_child = Eio.Promise.create () in
  let failure_seen, see_failure = Eio.Promise.create () in
  let child_effects = ref 0 and later_effects = ref 0 and barrier_effects = ref 0 and released = ref 0 in
  let make name occupied handler = prepared_tool ~name (fun ~sw _ ->
    Eio.Switch.on_release sw (fun () -> incr released);
    Ok (Some (Tool.scoped_call ~scope:occupied (fun _ _ -> handler (); output name))))
      (fun _ -> fail "unprepared effect dispatched") in
  let fatal = make "fatal" (scope "fatal") (fun () -> Eio.Promise.await child_started) in
  let quick = make "quick" (scope "chain") (fun () -> ()) in
  let child = make "child" (scope "chain") (fun () ->
    Eio.Promise.resolve start_child ();
    Eio.Promise.await failure_seen;
    incr child_effects) in
  let later = make "later" (scope "chain") (fun () -> incr later_effects) in
  let barrier = Tool.create ~name:"barrier" ~description:"opaque boundary" ~parameters:[]
      (fun _ -> incr barrier_effects; output "barrier") in
  let on_tool_execution_finished ~invocation:_ ~tool_name ~content:_ ~is_error:_ =
    if String.equal tool_name "fatal" then (Eio.Promise.resolve see_failure (); raise Exit) in
  (match execute env ~on_tool_execution_finished [fatal;quick;child;later;barrier]
      (List.map call ["fatal";"quick";"child";"later";"barrier"]) with
   | Error {Agent_tools.completed_results;cause=Agent_tools.Observer_failure {exception_=Exit;_};_} ->
     check (list string) "all actual completed effects survive in original order"
       ["fatal";"quick";"child"] (contents completed_results)
   | Ok _ | Error _ -> fail "the peer failure or completed successor was lost");
  check int "the already-started successor completes its real effect" 1 !child_effects;
  check int "a later resource successor is not started after the failure" 0 !later_effects;
  check int "the following opaque boundary is not started" 0 !barrier_effects;
  check int "all four prepared resource owners close" 4 !released
;;

let test_cancellation_closes_resource_predecessor_waiters () =
  Eio_main.run @@ fun env ->
  let entered, enter = Eio.Promise.create () in
  let never, _ = Eio.Promise.create () in
  let released = ref [] and child_effects = ref 0 in
  let make name handler = prepared_tool ~name (fun ~sw _ ->
    Eio.Switch.on_release sw (fun () -> released := name :: !released);
    Ok (Some (Tool.scoped_call ~scope:(scope "shared") (fun _ _ -> handler (); output name))))
      (fun _ -> fail "unprepared effect dispatched") in
  let parent = make "parent" (fun () -> Eio.Promise.resolve enter (); Eio.Promise.await never) in
  let child = make "child" (fun () -> incr child_effects) in
  Eio.Fiber.first
    (fun () ->
      ignore (execute env [parent;child] (List.map call ["parent";"child"]));
      fail "cancelled scoped execution returned normally")
    (fun () -> Eio.Promise.await entered);
  check int "a waiting successor has no fabricated effect" 0 !child_effects;
  check (list string) "caller cancellation releases the running and waiting owners"
    ["child";"parent"] (List.sort String.compare !released)
;;

let () =
  run "resource-scoped execution"
    [ "actual batch execution",
      [ test_case "ready successor chain does not wait for unrelated root" `Quick
          test_ready_successor_chain_does_not_wait_for_unrelated_root
      ; test_case "known peer failure prevents new resource successor" `Quick
          test_known_peer_failure_prevents_new_resource_successor
      ; test_case "started successor settles after later peer failure" `Quick
          test_started_successor_settles_after_later_peer_failure
      ; test_case "cancellation closes resource predecessor waiters" `Quick
          test_cancellation_closes_resource_predecessor_waiters
      ; test_case "disjoint effects consume exact prepared calls" `Quick test_disjoint_effects_consume_frozen_calls
      ; test_case "shared reads and private writes preserve writer order" `Quick test_shared_reads_and_private_writes_keep_writer_order
      ; test_case "scoped effects and scheduling use executed defaults" `Quick test_scoped_effect_contracts_follow_defaulted_execution_input
      ; test_case "conflicts preserve transitive planned order" `Quick test_conflicting_predecessors_keep_transitive_order
      ; test_case "fallback unavailable validation and permission" `Quick test_fallback_unavailable_validation_and_permission
      ; test_case "barriers and ordinary versus hook failure" `Quick test_barriers_and_failure_semantics
      ; test_case "terminal rejection and resolver exception" `Quick test_terminal_rejection_and_preparation_exception
      ; test_case "scoped observer failure retains completed siblings" `Quick test_scoped_observer_failure_retains_siblings
      ; test_case "real caller cancellation closes preparation" `Quick test_cancellation_releases_prepared_resources
      ; test_case "replacement handler invalidates stale preparation" `Quick test_replaced_handler_cannot_reuse_old_preparation
      ; test_case "unattempted sibling preserves original wave" `Quick test_unattempted_sibling_preserves_original_wave
      ; test_case "durable truth precedes current preparation" `Quick test_durable_truth_precedes_current_preparation
      ] ]
