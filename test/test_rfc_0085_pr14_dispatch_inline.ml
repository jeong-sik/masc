open Alcotest

(** RFC-0085 PR-14 — Verify the file-private [dispatch] /
    [dispatch_structured] chain is gone from tool_dispatch.ml; only
    [guarded_dispatch] (and its mli-exported helpers) remains.

    Original PR-14 test used [count_calls] (application sites) to
    approximate "no definition", which is indirect.  This revision
    uses [count_value_bindings] (Ppat_var nodes — actual definitions)
    so the assertion is direct: top-level [let dispatch = ...] and
    [let dispatch_structured = ...] must not exist in tool_dispatch.ml. *)

let file = "lib/tool_dispatch.ml"

let test_no_dispatch_top_level_binding () =
  let n = Ast_grep.count_value_bindings ~module_path:file ~name:"dispatch" in
  check int "tool_dispatch.ml must have 0 top-level [let dispatch]" 0 n
;;

let test_no_dispatch_structured_binding () =
  let n =
    Ast_grep.count_value_bindings ~module_path:file ~name:"dispatch_structured"
  in
  check int "tool_dispatch.ml must have 0 top-level [let dispatch_structured]" 0 n
;;

let test_guarded_dispatch_binding_present () =
  let n = Ast_grep.count_value_bindings ~module_path:file ~name:"guarded_dispatch" in
  if n < 1
  then failf "tool_dispatch.ml must define guarded_dispatch ≥ 1; got %d" n
;;

let test_guarded_dispatch_callers_intact () =
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/keeper/keeper_exec_masc.ml"
      ~callee:"Tool_dispatch.guarded_dispatch"
  in
  if n < 1
  then failf "keeper_exec_masc.ml must call guarded_dispatch ≥ 1; got %d" n
;;

let () =
  run
    "rfc-0085-pr-14-dispatch-inline"
    [ ( "chain inline"
      , [ test_case
            "no top-level [let dispatch =] binding"
            `Quick
            test_no_dispatch_top_level_binding
        ; test_case
            "no top-level [let dispatch_structured =] binding"
            `Quick
            test_no_dispatch_structured_binding
        ; test_case
            "guarded_dispatch binding present"
            `Quick
            test_guarded_dispatch_binding_present
        ; test_case
            "guarded_dispatch caller intact"
            `Quick
            test_guarded_dispatch_callers_intact
        ] )
    ]
;;
