(** Tests for Tool_dispatch hooks — pre/post hook execution order and semantics *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_result = Masc_mcp.Tool_result

(* Track hook execution order *)
let call_log : string list ref = ref []
let log_call s = call_log := !call_log @ [s]
let reset_log () = call_log := []

let setup () =
  reset_log ();
  Tool_dispatch.clear_hooks ()

(* --- Pre-hook tests --- *)

let test_pre_hook_observes () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_test"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (true, "ok"));
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    None);
  let result = Tool_dispatch.dispatch_structured ~name:"__hook_test" ~args:`Null in
  (* Pre-hook ran, then handler *)
  Alcotest.(check (list string)) "execution order"
    ["pre"; "handler"] !call_log;
  Alcotest.(check bool) "result exists" true (Option.is_some result)

let test_pre_hook_short_circuits () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_blocked"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (true, "should not reach"));
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre_block";
    Some { Tool_result.success = false;
           data = `String "blocked";
           tool_name = name;
           duration_ms = 0.0 });
  let result = Tool_dispatch.dispatch_structured ~name:"__hook_blocked" ~args:`Null in
  (* Handler should NOT have been called *)
  Alcotest.(check (list string)) "only pre ran" ["pre_block"] !call_log;
  match result with
  | Some r ->
    Alcotest.(check bool) "blocked" false r.success;
    Alcotest.(check string) "tool_name preserved" "__hook_blocked" r.tool_name
  | None -> Alcotest.fail "expected Some result from short-circuit"

let test_multiple_pre_hooks_first_wins () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_multi"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (true, "ok"));
  (* First hook: observe only *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre1";
    None);
  (* Second hook: blocks *)
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre2_block";
    Some { Tool_result.success = false;
           data = `String "denied";
           tool_name = name;
           duration_ms = 0.0 });
  (* Third hook: should not run *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre3";
    None);
  let _ = Tool_dispatch.dispatch_structured ~name:"__hook_multi" ~args:`Null in
  (* pre1 passes, pre2 blocks, pre3 and handler never called *)
  Alcotest.(check (list string)) "chain stops at blocker"
    ["pre1"; "pre2_block"] !call_log

(* --- Post-hook tests --- *)

let test_post_hook_observes () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_post"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (true, "original"));
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post";
    r);
  let result = Tool_dispatch.dispatch_structured ~name:"__hook_post" ~args:`Null in
  Alcotest.(check (list string)) "handler then post"
    ["handler"; "post"] !call_log;
  match result with
  | Some r -> Alcotest.(check bool) "success" true r.success
  | None -> Alcotest.fail "expected Some"

let test_post_hook_transforms () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_transform"
    ~handler:(fun ~name:_ ~args:_ ->
      Some (true, "original"));
  Tool_dispatch.register_post_hook (fun r ->
    { r with Tool_result.data = `String "transformed" });
  match Tool_dispatch.dispatch_structured ~name:"__hook_transform" ~args:`Null with
  | Some r ->
    (match r.data with
     | `String "transformed" -> ()
     | _ -> Alcotest.fail "post-hook transform not applied")
  | None -> Alcotest.fail "expected Some"

let test_post_hooks_chain () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_chain"
    ~handler:(fun ~name:_ ~args:_ ->
      Some (true, "0"));
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post1";
    { r with Tool_result.data = `String "1" });
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post2";
    { r with Tool_result.data = `String "2" });
  match Tool_dispatch.dispatch_structured ~name:"__hook_chain" ~args:`Null with
  | Some r ->
    Alcotest.(check (list string)) "post order" ["post1"; "post2"] !call_log;
    (match r.data with
     | `String "2" -> ()
     | _ -> Alcotest.fail "final post-hook should win")
  | None -> Alcotest.fail "expected Some"

(* --- Full lifecycle --- *)

let test_full_lifecycle () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_full"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (true, "data"));
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    None);
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post";
    r);
  let _ = Tool_dispatch.dispatch_structured ~name:"__hook_full" ~args:`Null in
  Alcotest.(check (list string)) "pre → handler → post"
    ["pre"; "handler"; "post"] !call_log

let test_no_hooks_default () =
  setup ();
  (* No hooks registered *)
  Tool_dispatch.register
    ~tool_name:"__hook_none"
    ~handler:(fun ~name:_ ~args:_ -> Some (true, "plain"));
  match Tool_dispatch.dispatch_structured ~name:"__hook_none" ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "success" true r.success;
    Alcotest.(check string) "tool_name" "__hook_none" r.tool_name
  | None -> Alcotest.fail "expected Some"

let test_unknown_tool_skips_hooks () =
  setup ();
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre_should_run";
    None);
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post_should_not_run";
    r);
  match Tool_dispatch.dispatch_structured ~name:"__nonexistent_hook" ~args:`Null with
  | None ->
    (* Pre-hook runs (it doesn't know the tool is missing), post-hook does not *)
    Alcotest.(check (list string)) "only pre ran"
      ["pre_should_run"] !call_log
  | Some _ -> Alcotest.fail "should be None for unknown tool"

let () =
  Alcotest.run "Tool_hooks" [
    "pre_hook", [
      Alcotest.test_case "observe" `Quick test_pre_hook_observes;
      Alcotest.test_case "short-circuit" `Quick test_pre_hook_short_circuits;
      Alcotest.test_case "first blocker wins" `Quick test_multiple_pre_hooks_first_wins;
    ];
    "post_hook", [
      Alcotest.test_case "observe" `Quick test_post_hook_observes;
      Alcotest.test_case "transform" `Quick test_post_hook_transforms;
      Alcotest.test_case "chain order" `Quick test_post_hooks_chain;
    ];
    "lifecycle", [
      Alcotest.test_case "pre→handler→post" `Quick test_full_lifecycle;
      Alcotest.test_case "no hooks default" `Quick test_no_hooks_default;
      Alcotest.test_case "unknown tool" `Quick test_unknown_tool_skips_hooks;
    ];
  ]
