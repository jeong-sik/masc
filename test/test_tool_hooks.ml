(** Tests for Tool_dispatch hooks — pre/post hook execution order and semantics *)

module Tool_dispatch = Masc_mcp.Tool_dispatch
module Tool_result = Masc_mcp.Tool_result
module Tool_token = Masc_mcp.Tool_token

(* Track hook execution order *)
let call_log : string list ref = ref []
let log_call s = call_log := !call_log @ [ s ]
let reset_log () = call_log := []

let setup () =
  reset_log ();
  Tool_dispatch.clear_hooks ()
;;

(* --- Pre-hook tests --- *)

let test_pre_hook_observes () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_test" ~handler:(fun ~name:_ ~args:_ ->
    log_call "handler";
    Some (true, "ok"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_test" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    Tool_dispatch.Pass);
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_test" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  let result = Tool_dispatch.dispatch_structured ~token ~args:`Null in
  (* Pre-hook ran, then handler *)
  Alcotest.(check (list string)) "execution order" [ "pre"; "handler" ] !call_log;
  Alcotest.(check bool) "result exists" true (Option.is_some result)
;;

let test_pre_hook_short_circuits () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_blocked" ~handler:(fun ~name:_ ~args:_ ->
    log_call "handler";
    Some (true, "should not reach"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_blocked" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre_block";
    Tool_dispatch.Reject
      { Tool_result.success = false
      ; data = `String "blocked"
      ; tool_name = name
      ; duration_ms = 0.0
      });
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_blocked" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  let result = Tool_dispatch.dispatch_structured ~token ~args:`Null in
  (* Handler should NOT have been called *)
  Alcotest.(check (list string)) "only pre ran" [ "pre_block" ] !call_log;
  match result with
  | Some r ->
    Alcotest.(check bool) "blocked" false r.success;
    Alcotest.(check string) "tool_name preserved" "__hook_blocked" r.tool_name
  | None -> Alcotest.fail "expected Some result from short-circuit"
;;

let test_multiple_pre_hooks_first_wins () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_multi" ~handler:(fun ~name:_ ~args:_ ->
    log_call "handler";
    Some (true, "ok"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_multi" ~tag:Mod_misc;
  (* First hook: observe only *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre1";
    Tool_dispatch.Pass);
  (* Second hook: blocks *)
  Tool_dispatch.register_pre_hook (fun ~name ~args:_ ->
    log_call "pre2_block";
    Tool_dispatch.Reject
      { Tool_result.success = false
      ; data = `String "denied"
      ; tool_name = name
      ; duration_ms = 0.0
      });
  (* Third hook: should not run *)
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre3";
    Tool_dispatch.Pass);
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_multi" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  let _ = Tool_dispatch.dispatch_structured ~token ~args:`Null in
  (* pre1 passes, pre2 blocks, pre3 and handler never called *)
  Alcotest.(check (list string))
    "chain stops at blocker"
    [ "pre1"; "pre2_block" ]
    !call_log
;;

(* --- Post-hook tests --- *)

let test_post_hook_observes () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_post" ~handler:(fun ~name:_ ~args:_ ->
    log_call "handler";
    Some (true, "original"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_post" ~tag:Mod_misc;
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post";
    r);
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_post" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  let result = Tool_dispatch.dispatch_structured ~token ~args:`Null in
  Alcotest.(check (list string)) "handler then post" [ "handler"; "post" ] !call_log;
  match result with
  | Some r -> Alcotest.(check bool) "success" true r.success
  | None -> Alcotest.fail "expected Some"
;;

let test_post_hook_transforms () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_transform" ~handler:(fun ~name:_ ~args:_ ->
    Some (true, "original"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_transform" ~tag:Mod_misc;
  Tool_dispatch.register_post_hook (fun r ->
    { r with Tool_result.data = `String "transformed" });
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_transform" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  match Tool_dispatch.dispatch_structured ~token ~args:`Null with
  | Some r ->
    (match r.data with
     | `String "transformed" -> ()
     | _ -> Alcotest.fail "post-hook transform not applied")
  | None -> Alcotest.fail "expected Some"
;;

let test_post_hooks_chain () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_chain" ~handler:(fun ~name:_ ~args:_ ->
    Some (true, "0"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_chain" ~tag:Mod_misc;
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post1";
    { r with Tool_result.data = `String "1" });
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post2";
    { r with Tool_result.data = `String "2" });
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_chain" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  match Tool_dispatch.dispatch_structured ~token ~args:`Null with
  | Some r ->
    Alcotest.(check (list string)) "post order" [ "post1"; "post2" ] !call_log;
    (match r.data with
     | `String "2" -> ()
     | _ -> Alcotest.fail "final post-hook should win")
  | None -> Alcotest.fail "expected Some"
;;

(* --- Full lifecycle --- *)

let test_full_lifecycle () =
  setup ();
  Tool_dispatch.register ~tool_name:"__hook_full" ~handler:(fun ~name:_ ~args:_ ->
    log_call "handler";
    Some (true, "data"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_full" ~tag:Mod_misc;
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre";
    Tool_dispatch.Pass);
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post";
    r);
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_full" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  let _ = Tool_dispatch.dispatch_structured ~token ~args:`Null in
  Alcotest.(check (list string))
    "pre → handler → post"
    [ "pre"; "handler"; "post" ]
    !call_log
;;

let test_no_hooks_default () =
  setup ();
  (* No hooks registered *)
  Tool_dispatch.register ~tool_name:"__hook_none" ~handler:(fun ~name:_ ~args:_ ->
    Some (true, "plain"));
  Tool_dispatch.register_name_tag ~tool_name:"__hook_none" ~tag:Mod_misc;
  let token =
    match Tool_dispatch.mint_token ~name:"__hook_none" with
    | Ok t -> t
    | Error e -> Alcotest.fail e
  in
  match Tool_dispatch.dispatch_structured ~token ~args:`Null with
  | Some r ->
    Alcotest.(check bool) "success" true r.success;
    Alcotest.(check string) "tool_name" "__hook_none" r.tool_name
  | None -> Alcotest.fail "expected Some"
;;

let test_unknown_tool_skips_hooks () =
  setup ();
  Tool_dispatch.register_pre_hook (fun ~name:_ ~args:_ ->
    log_call "pre_should_not_run";
    Tool_dispatch.Pass);
  Tool_dispatch.register_post_hook (fun r ->
    log_call "post_should_not_run";
    r);
  match Tool_dispatch.mint_token ~name:"__nonexistent_hook" with
  | Error _ ->
    (* mint_token rejects unregistered tools; no hooks run *)
    Alcotest.(check (list string)) "no hooks ran" [] !call_log
  | Ok _ -> Alcotest.fail "mint_token should return Error for unknown tool"
;;

let () =
  Alcotest.run
    "Tool_hooks"
    [ ( "pre_hook"
      , [ Alcotest.test_case "observe" `Quick test_pre_hook_observes
        ; Alcotest.test_case "short-circuit" `Quick test_pre_hook_short_circuits
        ; Alcotest.test_case
            "first blocker wins"
            `Quick
            test_multiple_pre_hooks_first_wins
        ] )
    ; ( "post_hook"
      , [ Alcotest.test_case "observe" `Quick test_post_hook_observes
        ; Alcotest.test_case "transform" `Quick test_post_hook_transforms
        ; Alcotest.test_case "chain order" `Quick test_post_hooks_chain
        ] )
    ; ( "lifecycle"
      , [ Alcotest.test_case "pre→handler→post" `Quick test_full_lifecycle
        ; Alcotest.test_case "no hooks default" `Quick test_no_hooks_default
        ; Alcotest.test_case "unknown tool" `Quick test_unknown_tool_skips_hooks
        ] )
    ]
;;
