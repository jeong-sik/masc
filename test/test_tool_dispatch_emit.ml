open Alcotest

(** Tests for Tool_dispatch_emit finalization.

    The test uses {!Tool_dispatch_emit.finalize_from_handler} directly
    because MCP dispatch paths resolve handlers outside
    {!Tool_dispatch.guarded_dispatch}.  This isolates the post-dispatch
    side-effect contract from MCP wiring noise.

    Verified contracts:
    1. [finalize_from_handler (Some r)] fires the dispatch observer with
       [Handled].
    2. [finalize_from_handler None] fires the dispatch observer with
       [No_handler].
    3. Finalization returns the exact handler result unchanged. *)

let mk_result ~tool_name ~text =
  let start = Unix.gettimeofday () in
  Tool_result.ok ~tool_name ~start_time:start text
;;

let test_finalize_handled_fires_observer () =
  let seen = ref [] in
  let hook (outcome : Dispatch_outcome.t) (r : Tool_result.result option) =
    seen := (outcome, Option.is_some r) :: !seen
  in
  Tool_dispatch.clear_hooks ();
  Tool_dispatch.register_dispatch_observer hook;
  let r = Some (mk_result ~tool_name:"t" ~text:"ok") in
  let _ = Tool_dispatch_emit.finalize_from_handler r in
  Tool_dispatch.clear_hooks ();
  match !seen with
  | [ (Handled, true) ] -> ()
  | other ->
    failf "expected [Handled, Some]; got %d observations" (List.length other)
;;

let test_finalize_no_handler_fires_observer () =
  let seen = ref [] in
  let hook (outcome : Dispatch_outcome.t) (r : Tool_result.result option) =
    seen := (outcome, Option.is_some r) :: !seen
  in
  Tool_dispatch.clear_hooks ();
  Tool_dispatch.register_dispatch_observer hook;
  let _ = Tool_dispatch_emit.finalize_from_handler None in
  Tool_dispatch.clear_hooks ();
  match !seen with
  | [ (No_handler, false) ] -> ()
  | _ -> failf "expected [No_handler, None] observation"
;;

let test_finalize_preserves_handler_result () =
  let observed = ref None in
  Tool_dispatch.clear_hooks ();
  Tool_dispatch.register_dispatch_observer
    (fun (outcome : Dispatch_outcome.t) r ->
      match outcome, r with
      | Handled, Some out -> observed := Some out
      | _ -> fail "expected observer to see handled result");
  let exact_data =
    `Assoc [ "nested", `List [ `String "raw"; `Assoc [ "count", `Int 2 ] ] ]
  in
  let original =
    Tool_result.make_ok
      ~tool_name:"t"
      ~start_time:(Unix.gettimeofday ())
      ~data:exact_data
      ()
  in
  let result = Tool_dispatch_emit.finalize_from_handler (Some original) in
  Tool_dispatch.clear_hooks ();
  check bool "returned exact structured data" true
    (Option.fold
       ~none:false
       ~some:(fun r -> Tool_result.data r = exact_data)
       result);
  check bool "observer saw exact structured data" true
    (Option.fold
       ~none:false
       ~some:(fun r -> Tool_result.data r = exact_data)
       !observed)
;;

let () =
  run
    "tool-dispatch-emit"
    [ ( "dispatch observer fan-out"
      , [ test_case "Handled arm" `Quick test_finalize_handled_fires_observer
        ; test_case "No_handler arm" `Quick test_finalize_no_handler_fires_observer
        ] )
    ; ( "result preservation"
      , [ test_case
            "exact handler result"
            `Quick
            test_finalize_preserves_handler_result
        ] )
    ]
;;
