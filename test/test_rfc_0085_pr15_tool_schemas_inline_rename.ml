open Alcotest

(** RFC-0085 PR-15 — Retroactive regression test.

    Original PR-15 (#15483) renamed 4 misleading underscore-prefix
    bindings in [tool_schemas/tool_schemas_inline.ml] and
    [tool_schemas/tool_schemas_inline_infra.ml] but shipped *no* test.
    Each identifier is actively used (List.mem / list concat) so the
    underscore prefix violated OCaml convention (intentionally-unused).

    This retroactive test pins the rename so any future reintroduction
    of [_inline_*] or [_codegen_*] prefix on these names fails CI. *)

let renamed_identifiers =
  [ ( "lib/tool_schemas/tool_schemas_inline.ml"
    , "_inline_coord_codegen_names"
    , "inline_coord_codegen_names" )
  ; ( "lib/tool_schemas/tool_schemas_inline.ml"
    , "_inline_coord_from_codegen"
    , "inline_coord_from_codegen" )
  ; ( "lib/tool_schemas/tool_schemas_inline_infra.ml"
    , "_codegen_inline_infra_names"
    , "codegen_inline_infra_names" )
  ; ( "lib/tool_schemas/tool_schemas_inline_infra.ml"
    , "_inline_infra_from_codegen"
    , "inline_infra_from_codegen" )
  ]
;;

let test_old_underscore_names_gone () =
  List.iter
    (fun (path, old_name, _new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:old_name in
      let msg =
        Printf.sprintf "old underscore name %s should be removed in %s" old_name path
      in
      check int msg 0 n)
    renamed_identifiers
;;

let test_new_names_present () =
  List.iter
    (fun (path, _old_name, new_name) ->
      let n = Ast_grep.count_value_bindings ~module_path:path ~name:new_name in
      let msg =
        Printf.sprintf "renamed binding %s must exist in %s" new_name path
      in
      if n < 1 then failf "%s — count=%d" msg n)
    renamed_identifiers
;;

let test_list_mem_caller_preserved () =
  (* The renamed bindings exist because List.mem / list concat call
     them — verify those caller sites still resolve (compile-time
     check via build, runtime check here that the file shape kept the
     same caller pattern). *)
  let n =
    Ast_grep.count_calls
      ~module_path:"lib/tool_schemas/tool_schemas_inline.ml"
      ~callee:"List.mem"
  in
  if n < 1 then failf "tool_schemas_inline.ml expects ≥1 List.mem caller; got %d" n
;;

let () =
  run
    "rfc-0085-pr-15-tool-schemas-inline-rename"
    [ ( "identifier rename"
      , [ test_case
            "old underscore names gone"
            `Quick
            test_old_underscore_names_gone
        ; test_case "new names present" `Quick test_new_names_present
        ; test_case
            "List.mem caller preserved"
            `Quick
            test_list_mem_caller_preserved
        ] )
    ]
;;
