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
    3. [apply_result_transformer] is applied to [Some r] before
       observers see it. *)

let mk_result ~tool_name ~text =
  let start = Unix.gettimeofday () in
  Tool_result.ok ~tool_name ~start_time:start text
;;

let string_ends_with ~suffix s =
  let n = String.length s in
  let slen = String.length suffix in
  n >= slen && String.sub s (n - slen) slen = suffix
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

let test_finalize_applies_transformer_before_observer () =
  let called = ref 0 in
  let observed_message = ref None in
  let transformer (r : Tool_result.result) : Tool_result.result =
    incr called;
    match r with
    | Tool_result.Completed output ->
      Tool_result.Completed
        { output with data = `String ((Tool_result.message r) ^ "[capped]") }
    | Tool_result.Deferred output ->
      Tool_result.Deferred
        { output with data = `String ((Tool_result.message r) ^ "[capped]") }
    | Tool_result.Failed failure ->
      Tool_result.Failed { failure with message = failure.message ^ "[capped]" }
  in
  Tool_dispatch.clear_hooks ();
  Tool_dispatch.set_result_transformer transformer;
  Tool_dispatch.register_dispatch_observer
    (fun (outcome : Dispatch_outcome.t) r ->
      match outcome, r with
      | Handled, Some out -> observed_message := Some (Tool_result.message out)
      | _ -> fail "expected observer to see handled result");
  let r = Some (mk_result ~tool_name:"t" ~text:"raw") in
  let r' = Tool_dispatch_emit.finalize_from_handler r in
  Tool_dispatch.clear_hooks ();
  check int "transformer ran once" 1 !called;
  let suffix = "[capped]" in
  (match r' with
   | Some out ->
     let out_msg = (Tool_result.message out) in
     check bool "transformer suffix appended" true
       (string_ends_with ~suffix out_msg)
   | None -> fail "expected Some result");
  match !observed_message with
  | Some message ->
    check bool "observer saw transformed result" true
      (string_ends_with ~suffix message)
  | None -> fail "expected observer to run"
;;

let () =
  run
    "tool-dispatch-emit"
    [ ( "dispatch observer fan-out"
      , [ test_case "Handled arm" `Quick test_finalize_handled_fires_observer
        ; test_case "No_handler arm" `Quick test_finalize_no_handler_fires_observer
        ] )
    ; ( "result transformer"
      , [ test_case
            "applied before observer"
            `Quick
            test_finalize_applies_transformer_before_observer
        ] )
    ]
;;
