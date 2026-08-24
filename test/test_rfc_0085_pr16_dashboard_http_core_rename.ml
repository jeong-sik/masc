open Alcotest

(** RFC-0085 PR-16 — Retroactive regression test.

    Original PR-16 (#15484) renamed 9 underscore-prefix bindings in
    [lib/server/server_dashboard_http_core.ml].  All are mutable
    refs/atomics/caches — actively used at runtime, so the [_xxx]
    convention misled readers.  Shipped without test; pin now. *)

(* Scan the whole [server_dashboard_http_core*] family, not a single path.
   The original guard pinned [server_dashboard_http_core.ml] alone. That file
   was later split into [_cache.ml] / [_operator.ml] / ... and the underscore
   aliases reappeared in the split files, where this test could not see them —
   it stayed green with 5 of the 7 forbidden names alive. Globbing the prefix
   keeps the guard honest across the next split too. *)
let dir = "lib/server"

let files =
  (* Ast_grep resolves a repo-relative path against DUNE_SOURCEROOT; the
     listing has to start from the same place or it reads the sandbox the test
     runs in, where lib/server does not exist and the glob finds nothing. *)
  Sys.readdir (Ast_grep.resolve_module_path dir)
  |> Array.to_list
  |> List.filter (fun name ->
       String.starts_with ~prefix:"server_dashboard_http_core" name
       && Filename.check_suffix name ".ml")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)
;;

let renamed_identifiers =
  [ "_shell_warmed", "shell_warmed"
  ; "_shell_warming", "shell_warming"
  ; "_last_good_shell", "last_good_shell"
  (* operator_snapshot_broadcast_ref and operator_digest_broadcast_ref were
     here too. #28167 replaced the mutable refs with immutable snapshots and
     both bindings went with them, so the half of this guard that asks for the
     new name was asking a deleted line to still be there. A rename guard
     covers renames; a removal is not one. *)
  ; "_operator_digest_cache", "operator_digest_cache"
  ; "_mission_cache", "mission_cache"
  ]
;;

let test_old_underscore_names_gone () =
  check bool "the module family must not be empty" true (files <> []);
  List.iter
    (fun (old_name, _) ->
      List.iter
        (fun file ->
          let n = Ast_grep.count_value_bindings ~module_path:file ~name:old_name in
          let msg =
            Printf.sprintf "old underscore name %s should be removed from %s"
              old_name file
          in
          check int msg 0 n)
        files)
    renamed_identifiers
;;

let test_new_names_present () =
  List.iter
    (fun (_, new_name) ->
      let n =
        List.fold_left
          (fun acc file ->
            acc + Ast_grep.count_value_bindings ~module_path:file ~name:new_name)
          0 files
      in
      let msg = Printf.sprintf "renamed binding %s must exist" new_name in
      if n < 1 then failf "%s — count=%d" msg n)
    renamed_identifiers
;;

let () =
  run
    "rfc-0085-pr-16-dashboard-http-core-rename"
    [ ( "identifier rename"
      , [ test_case "old underscore names gone" `Quick test_old_underscore_names_gone
        ; test_case "new names present" `Quick test_new_names_present
        ] )
    ]
;;
