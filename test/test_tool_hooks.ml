(** Tests for Tool_dispatch pre-hooks, dispatch observers, and result transformers. *)

module Tool_dispatch = Tool_dispatch
module Tool_result = Tool_result
module Tool_token = Tool_token
module Dispatch_outcome = Dispatch_outcome

(* Track hook execution order *)
let call_log : string list ref = ref []
let log_call s = call_log := !call_log @ [s]
let reset_log () = call_log := []

let tool_ok ?(tool_name = "") message =
  Tool_result.make_ok ~tool_name ~start_time:0.0 ~data:(`String message) ()
;;

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
      Some (tool_ok "ok"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_test" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    Tool_dispatch.Pass);
  let token = match Tool_dispatch.mint_token ~name:"__hook_test" with Ok t -> t | Error e -> Alcotest.fail e in
  let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
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
      Some (tool_ok "should not reach"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_blocked" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre_block";
    Tool_dispatch.Reject
      (Tool_result.Failed
         { Tool_result.class_ = Tool_result.Runtime_failure
         ; message = "blocked"
         ; data = `String "blocked"
         ; tool_name = name
         ; duration_ms = 0.0
         }));
  let token = match Tool_dispatch.mint_token ~name:"__hook_blocked" with Ok t -> t | Error e -> Alcotest.fail e in
  let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
  (* Handler should NOT have been called *)
  Alcotest.(check (list string)) "only pre ran" ["pre_block"] !call_log;
  match result with
  | Some r ->
    Alcotest.(check bool) "blocked" false ((Tool_result.is_success r));
    Alcotest.(check string) "tool_name preserved" "__hook_blocked"
      ((Tool_result.tool_name r))
  | None -> Alcotest.fail "expected Some result from short-circuit"

let test_multiple_pre_hooks_first_wins () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_multi"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (tool_ok "ok"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_multi" ~tag:Mod_misc;
  (* First hook: observe only *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre1";
    Tool_dispatch.Pass);
  (* Second hook: blocks *)
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre2_block";
    Tool_dispatch.Reject
      (Tool_result.Failed
         { Tool_result.class_ = Tool_result.Runtime_failure
         ; message = "denied"
         ; data = `String "denied"
         ; tool_name = name
         ; duration_ms = 0.0
         }));
  (* Third hook: should not run *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre3";
    Tool_dispatch.Pass);
  let token = match Tool_dispatch.mint_token ~name:"__hook_multi" with Ok t -> t | Error e -> Alcotest.fail e in
  let _ = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
  (* pre1 passes, pre2 blocks, pre3 and handler never called *)
  Alcotest.(check (list string)) "chain stops at blocker"
    ["pre1"; "pre2_block"] !call_log

(* --- Dispatch observer / result-transformer tests --- *)

let test_dispatch_observer_observes () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_observer"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (tool_ok "original"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_observer" ~tag:Mod_misc;
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some _ -> log_call "observer"
    | _ -> Alcotest.fail "expected handled dispatch observer");
  let token = match Tool_dispatch.mint_token ~name:"__hook_observer" with Ok t -> t | Error e -> Alcotest.fail e in
  let result = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
  Alcotest.(check (list string)) "handler then observer"
    ["handler"; "observer"] !call_log;
  match result with
  | Some r -> Alcotest.(check bool) "success" true (Tool_result.is_success r)
  | None -> Alcotest.fail "expected Some"

let test_result_transformer_transforms () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_transform"
    ~handler:(fun ~name:_ ~args:_ ->
      Some (tool_ok "original"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_transform" ~tag:Mod_misc;
  Tool_dispatch.set_result_transformer (fun r ->
    match r with
    | Tool_result.Completed output ->
      Tool_result.Completed { output with data = `String "transformed" }
    | Tool_result.Deferred output ->
      Tool_result.Deferred { output with data = `String "transformed" }
    | Tool_result.Failed failure ->
      Tool_result.Failed { failure with data = `String "transformed" });
  let token = match Tool_dispatch.mint_token ~name:"__hook_transform" with Ok t -> t | Error e -> Alcotest.fail e in
  match Tool_dispatch.guarded_dispatch ~token ~args:`Null () with
  | Some r ->
    (match Tool_result.data r with
     | `String "transformed" -> ()
     | _ -> Alcotest.fail "result transformer not applied")
  | None -> Alcotest.fail "expected Some"

let test_dispatch_observers_chain () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_chain"
    ~handler:(fun ~name:_ ~args:_ ->
      Some (tool_ok "0"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_chain" ~tag:Mod_misc;
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some _ -> log_call "observer1"
    | _ -> Alcotest.fail "expected handled dispatch observer");
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some _ -> log_call "observer2"
    | _ -> Alcotest.fail "expected handled dispatch observer");
  let token = match Tool_dispatch.mint_token ~name:"__hook_chain" with Ok t -> t | Error e -> Alcotest.fail e in
  match Tool_dispatch.guarded_dispatch ~token ~args:`Null () with
  | Some r ->
    Alcotest.(check (list string)) "observer order" ["observer1"; "observer2"] !call_log;
    (match Tool_result.data r with
     | `String "0" -> ()
     | _ -> Alcotest.fail "dispatch observers must not transform results")
  | None -> Alcotest.fail "expected Some"

let test_result_transformer_chain_replaces_previous () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_transform_replace"
    ~handler:(fun ~name:_ ~args:_ ->
      Some (tool_ok "0"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_transform_replace" ~tag:Mod_misc;
  let with_data (s : string) (r : Tool_result.result) : Tool_result.result =
    match r with
    | Tool_result.Completed output ->
      Tool_result.Completed { output with data = `String s }
    | Tool_result.Deferred output -> Tool_result.Deferred { output with data = `String s }
    | Tool_result.Failed failure -> Tool_result.Failed { failure with data = `String s }
  in
  Tool_dispatch.set_result_transformer (fun r ->
    log_call "transformer1";
    with_data "1" r);
  Tool_dispatch.set_result_transformer (fun r ->
    log_call "transformer2";
    with_data "2" r);
  let token = match Tool_dispatch.mint_token ~name:"__hook_transform_replace" with Ok t -> t | Error e -> Alcotest.fail e in
  match Tool_dispatch.guarded_dispatch ~token ~args:`Null () with
  | Some r ->
    Alcotest.(check (list string)) "latest transformer only" ["transformer2"] !call_log;
    (match Tool_result.data r with
     | `String "2" -> ()
     | _ -> Alcotest.fail "latest result transformer should win")
  | None -> Alcotest.fail "expected Some"

(* --- Full lifecycle --- *)

let test_full_lifecycle () =
  setup ();
  Tool_dispatch.register
    ~tool_name:"__hook_full"
    ~handler:(fun ~name:_ ~args:_ ->
      log_call "handler";
      Some (tool_ok "data"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_full" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    Tool_dispatch.Pass);
  Tool_dispatch.register_dispatch_observer (fun outcome result ->
    match outcome, result with
    | Dispatch_outcome.Handled, Some _ -> log_call "observer"
    | _ -> Alcotest.fail "expected handled dispatch observer");
  let token = match Tool_dispatch.mint_token ~name:"__hook_full" with Ok t -> t | Error e -> Alcotest.fail e in
  let _ = Tool_dispatch.guarded_dispatch ~token ~args:`Null () in
  Alcotest.(check (list string)) "pre → handler → observer"
    ["pre"; "handler"; "observer"] !call_log

let test_no_hooks_default () =
  setup ();
  (* No hooks registered *)
  Tool_dispatch.register
    ~tool_name:"__hook_none"
    ~handler:(fun ~name ~args:_ ->
      Some (tool_ok ~tool_name:name "plain"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_none" ~tag:Mod_misc;
  let token = match Tool_dispatch.mint_token ~name:"__hook_none" with Ok t -> t | Error e -> Alcotest.fail e in
  match Tool_dispatch.guarded_dispatch ~token ~args:`Null () with
  | Some r ->
    Alcotest.(check bool) "success" true (Tool_result.is_success r);
    Alcotest.(check string) "tool_name" "__hook_none" (Tool_result.tool_name r)
  | None -> Alcotest.fail "expected Some"

let test_unknown_tool_skips_hooks () =
  setup ();
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre_should_not_run";
    Tool_dispatch.Pass);
  Tool_dispatch.register_dispatch_observer (fun _outcome _result ->
    log_call "observer_should_not_run");
  match Tool_dispatch.mint_token ~name:"__nonexistent_hook" with
  | Error _ ->
    (* mint_token rejects unregistered tools; no hooks run *)
    Alcotest.(check (list string)) "no hooks ran" [] !call_log
  | Ok _ -> Alcotest.fail "mint_token should return Error for unknown tool"

let () =
  Alcotest.run "Tool_hooks" [
    "pre_hook", [
      Alcotest.test_case "observe" `Quick test_pre_hook_observes;
      Alcotest.test_case "short-circuit" `Quick test_pre_hook_short_circuits;
      Alcotest.test_case "first blocker wins" `Quick test_multiple_pre_hooks_first_wins;
    ];
    "dispatch_observer", [
      Alcotest.test_case "observe" `Quick test_dispatch_observer_observes;
      Alcotest.test_case "transform" `Quick test_result_transformer_transforms;
      Alcotest.test_case "chain order" `Quick test_dispatch_observers_chain;
      Alcotest.test_case
        "latest transformer wins"
        `Quick
        test_result_transformer_chain_replaces_previous;
    ];
    "lifecycle", [
      Alcotest.test_case "pre→handler→observer" `Quick test_full_lifecycle;
      Alcotest.test_case "no hooks default" `Quick test_no_hooks_default;
      Alcotest.test_case "unknown tool" `Quick test_unknown_tool_skips_hooks;
    ];
  ]
