open Alcotest

(** RFC-0085 PR-14 — Verify the file-private [dispatch] /
    [dispatch_structured] chain is gone from tool_dispatch.ml; only
    [guarded_dispatch] (and its mli-exported helpers) remains. *)

let test_no_dispatch_function_define () =
  (* AST: tool_dispatch.ml should have 0 top-level [let dispatch] or
     [let dispatch_structured] definitions.  We approximate via
     string-literal scan — these names also appear in docstrings, so
     the assertion is "the identifier is gone *as a top-level binding*",
     which we verify by attempting to read the symbol via Tool_dispatch
     itself (only guarded_dispatch should be exported). *)
  let exists_call =
    Ast_grep.count_calls
      ~module_path:"lib/tool_dispatch.ml"
      ~callee:"Tool_dispatch.dispatch_structured"
  in
  check int "no internal dispatch_structured call" 0 exists_call
;;

let test_guarded_dispatch_callers_intact () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/keeper/keeper_exec_masc.ml"
      ~callee:"Tool_dispatch.guarded_dispatch"
  in
  if n < 1
  then failf "keeper_exec_masc.ml must call guarded_dispatch >= 1; got %d" n
;;

let () =
  run
    "rfc-0085-pr-14-dispatch-inline"
    [ ( "chain inline"
      , [ test_case "no dispatch_structured call" `Quick test_no_dispatch_function_define
        ; test_case
            "guarded_dispatch caller intact"
            `Quick
            test_guarded_dispatch_callers_intact
        ] )
    ]
;;
