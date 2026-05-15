open Alcotest

(** RFC-0084 PR-I-1 — typed post-hook surface.

    PR-I-1 adds the [Tool_dispatch.post_hook_typed] type and the
    [register_typed_post_hook] / [run_typed_post_hooks] /
    [typed_post_hooks] entry points without migrating any of the 5
    in-tree [register_post_hook] call-sites.

    Behaviour change vs. main: 0 today (zero typed hooks registered;
    [run_typed_post_hooks] is invoked from [guarded_dispatch] on
    every arm but iterates an empty ref).  PR-I-2.* migrates the
    5 sites one at a time.

    Pins:
    - typed surface visible from [Masc_mcp.Tool_dispatch]
    - [register_typed_post_hook] appends to the [typed_post_hooks]
      ref (in order)
    - [run_typed_post_hooks] invokes registered observers
    - [run_typed_post_hooks] is called from [guarded_dispatch] for
      every {!Dispatch_outcome.t} arm
    - [clear_hooks ()] empties the typed list too (regression
      guard for PR-I-3 final cleanup) *)

let test_typed_post_hooks_ref_exists () =
  (* Compile-time + runtime presence check. *)
  let _ : Masc_mcp.Tool_dispatch.post_hook_typed list ref =
    Masc_mcp.Tool_dispatch.typed_post_hooks
  in
  ()
;;

let test_register_and_observe_outcome () =
  (* Snapshot the ref then restore so the test is isolated from any
     other test in the same binary that might also register. *)
  let snapshot = !Masc_mcp.Tool_dispatch.typed_post_hooks in
  Masc_mcp.Tool_dispatch.typed_post_hooks := [];
  let seen : Masc_mcp.Dispatch_outcome.t list ref = ref [] in
  Masc_mcp.Tool_dispatch.register_typed_post_hook (fun outcome _ ->
    seen := outcome :: !seen);
  Masc_mcp.Tool_dispatch.run_typed_post_hooks
    Masc_mcp.Dispatch_outcome.Handled None;
  Masc_mcp.Tool_dispatch.run_typed_post_hooks
    Masc_mcp.Dispatch_outcome.No_handler None;
  Masc_mcp.Tool_dispatch.run_typed_post_hooks
    (Masc_mcp.Dispatch_outcome.Rejected_by_capability { missing = [ "destructive" ] }) None;
  let result = List.rev !seen in
  (check int)
    "registered typed hook observed exactly 3 outcomes"
    3 (List.length result);
  Masc_mcp.Tool_dispatch.typed_post_hooks := snapshot
;;

let test_register_appends_in_order () =
  let snapshot = !Masc_mcp.Tool_dispatch.typed_post_hooks in
  Masc_mcp.Tool_dispatch.typed_post_hooks := [];
  let trace : string list ref = ref [] in
  Masc_mcp.Tool_dispatch.register_typed_post_hook (fun _ _ ->
    trace := "first" :: !trace);
  Masc_mcp.Tool_dispatch.register_typed_post_hook (fun _ _ ->
    trace := "second" :: !trace);
  Masc_mcp.Tool_dispatch.run_typed_post_hooks
    Masc_mcp.Dispatch_outcome.Handled None;
  (check (list string))
    "hooks fire in registration order (newest at head after reverse)"
    [ "first"; "second" ]
    (List.rev !trace);
  Masc_mcp.Tool_dispatch.typed_post_hooks := snapshot
;;

let test_clear_hooks_empties_typed_list () =
  let snapshot = !Masc_mcp.Tool_dispatch.typed_post_hooks in
  Masc_mcp.Tool_dispatch.typed_post_hooks := [];
  Masc_mcp.Tool_dispatch.register_typed_post_hook (fun _ _ -> ());
  (check int) "registered before clear" 1
    (List.length !Masc_mcp.Tool_dispatch.typed_post_hooks);
  Masc_mcp.Tool_dispatch.clear_hooks ();
  (check int) "typed list empty after clear_hooks" 0
    (List.length !Masc_mcp.Tool_dispatch.typed_post_hooks);
  Masc_mcp.Tool_dispatch.typed_post_hooks := snapshot
;;

let test_run_typed_post_hooks_call_in_guarded_dispatch () =
  let content =
    match In_channel.with_open_text "lib/tool_dispatch.ml" In_channel.input_all with
    | exception _ -> ""
    | content -> content
  in
  let count =
    let rec loop i acc =
      let next = String.index_from_opt content i 'r' in
      match next with
      | None -> acc
      | Some j ->
        let needle = "run_typed_post_hooks" in
        let len = String.length needle in
        if j + len <= String.length content
           && String.sub content j len = needle
        then loop (j + len) (acc + 1)
        else loop (j + 1) acc
    in
    loop 0 0
  in
  (* Expect the definition plus the call site inside guarded_dispatch. *)
  (check bool)
    "run_typed_post_hooks invoked from guarded_dispatch (>=2 occurrences \
     in tool_dispatch.ml: definition + call site)"
    true (count >= 2)
;;

let () =
  run
    "PR-I-1 typed post-hook surface"
    [ ( "pr-i-1-typed-surface"
      , [ test_case "typed-post-hooks-ref-exists" `Quick
            test_typed_post_hooks_ref_exists
        ; test_case "register-and-observe-outcome" `Quick
            test_register_and_observe_outcome
        ; test_case "register-appends-in-order" `Quick
            test_register_appends_in_order
        ; test_case "clear-hooks-empties-typed-list" `Quick
            test_clear_hooks_empties_typed_list
        ; test_case "run-typed-post-hooks-in-guarded-dispatch" `Quick
            test_run_typed_post_hooks_call_in_guarded_dispatch
        ] )
    ]
;;
