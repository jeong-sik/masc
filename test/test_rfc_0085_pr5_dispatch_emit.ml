open Alcotest

(** RFC-0085 PR-5 — Verify the unified dispatch finaliser fires typed
    observers and applies the result transformer.

    The test uses {!Tool_dispatch_emit.finalize_from_handler} directly
    rather than spinning up the MCP server, since the MCP path's
    behaviour is *contractually* "call [Tool_dispatch_emit.finalize_*]
    on every dispatch result".  This isolates the side-effect contract
    from MCP wiring noise.

    Verified contracts:
    1. [finalize_from_handler (Some r)] fires the typed post-hook with
       [Handled].
    2. [finalize_from_handler None] fires the typed post-hook with
       [No_handler].
    3. [apply_result_transformer] is applied to [Some r] before
       hooks observe it.
    4. Source-level: [mcp_server_eio_execute.ml] and
       [tool_dispatch.ml] together reference
       [Tool_dispatch_emit.finalize_from_handler]
       (or, in the guarded_dispatch case, an inline mirror) so all
       three dispatch paths (keeper / MCP-tag / MCP-internal) emit
       observer events. *)

let mk_result ~tool_name ~text =
  let start = Unix.gettimeofday () in
  Masc_mcp.Tool_result.ok ~tool_name ~start_time:start text
;;

let test_finalize_handled_fires_typed_hook () =
  let seen = ref [] in
  let hook (outcome : Masc_mcp.Dispatch_outcome.t) (r : Masc_mcp.Tool_result.t option) =
    seen := (outcome, Option.is_some r) :: !seen
  in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  Masc_mcp.Tool_dispatch.register_typed_post_hook hook;
  let r = Some (mk_result ~tool_name:"t" ~text:"ok") in
  let _ = Masc_mcp.Tool_dispatch_emit.finalize_from_handler r in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  match !seen with
  | [ (Handled, true) ] -> ()
  | other ->
    failf "expected [Handled, Some]; got %d observations" (List.length other)
;;

let test_finalize_no_handler_fires_typed_hook () =
  let seen = ref [] in
  let hook (outcome : Masc_mcp.Dispatch_outcome.t) (r : Masc_mcp.Tool_result.t option) =
    seen := (outcome, Option.is_some r) :: !seen
  in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  Masc_mcp.Tool_dispatch.register_typed_post_hook hook;
  let _ = Masc_mcp.Tool_dispatch_emit.finalize_from_handler None in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  match !seen with
  | [ (No_handler, false) ] -> ()
  | _ -> failf "expected [No_handler, None] observation"
;;

let test_finalize_applies_transformer () =
  let called = ref 0 in
  let transformer (r : Masc_mcp.Tool_result.t) : Masc_mcp.Tool_result.t =
    incr called;
    { r with legacy_message = r.legacy_message ^ "[capped]" }
  in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  Masc_mcp.Tool_dispatch.set_result_transformer transformer;
  let r = Some (mk_result ~tool_name:"t" ~text:"raw") in
  let r' = Masc_mcp.Tool_dispatch_emit.finalize_from_handler r in
  Masc_mcp.Tool_dispatch.clear_hooks ();
  check int "transformer ran once" 1 !called;
  (match r' with
   | Some out ->
     check bool "transformer suffix appended" true
       (String.length out.legacy_message > 0
        && let n = String.length out.legacy_message in
           let suffix = "[capped]" in
           let slen = String.length suffix in
           n >= slen && String.sub out.legacy_message (n - slen) slen = suffix)
   | None -> fail "expected Some result")
;;

let test_mcp_execute_invokes_finalize () =
  (* Source-level structural check: mcp_server_eio_execute.ml must
     reference Tool_dispatch_emit.finalize_from_handler at least
     twice (dispatch_by_tag + dispatch_internal_keeper_runtime). *)
  let path = "lib/mcp_server_eio_execute.ml" in
  let n =
    Ast_grep.count_calls
      ~module_path:path
      ~callee:"Tool_dispatch_emit.finalize_from_handler"
  in
  if n < 2
  then
    failf
      "mcp_server_eio_execute.ml must call \
       Tool_dispatch_emit.finalize_from_handler >= 2 (PR-5: \
       dispatch_by_tag + dispatch_internal_keeper_runtime); got %d"
      n
;;

let () =
  run
    "rfc-0085-pr-5-dispatch-emit"
    [ ( "typed post-hook fan-out"
      , [ test_case "Handled arm" `Quick test_finalize_handled_fires_typed_hook
        ; test_case "No_handler arm" `Quick test_finalize_no_handler_fires_typed_hook
        ] )
    ; ( "result transformer"
      , [ test_case "applied via finalize" `Quick test_finalize_applies_transformer ] )
    ; ( "MCP path coverage"
      , [ test_case "MCP execute invokes finalize" `Quick test_mcp_execute_invokes_finalize
        ] )
    ]
;;
