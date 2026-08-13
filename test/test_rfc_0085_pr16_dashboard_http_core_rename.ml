open Alcotest

(** RFC-0085 PR-16 — Retroactive regression test.

    Original PR-16 (#15484) renamed seven underscore-prefix bindings in
    [lib/server/server_dashboard_http_core.ml].  All are mutable
    refs/atomics/caches — actively used at runtime, so the [_xxx]
    convention misled readers.  Shipped without test; pin now. *)

(* Scan the whole [server_dashboard_http_core*] family, not a single path.
   The original guard pinned [server_dashboard_http_core.ml] alone. That file
   was later split into [_cache.ml] / [_operator.ml] / ... and the underscore
   aliases reappeared in the split files, where this test could not see them —
   it stayed green with 5 of the 7 forbidden names alive. Globbing the prefix
   keeps the guard honest across the next split too. *)
let source_root =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()
;;

let dir = Filename.concat source_root "lib/server"

let files =
  Sys.readdir dir
  |> Array.to_list
  |> List.filter (fun name ->
       String.starts_with ~prefix:"server_dashboard_http_core" name
       && Filename.check_suffix name ".ml")
  |> List.sort String.compare
  |> List.map (Filename.concat dir)
;;

(* This is only a legacy-removal ratchet. Current implementation names are not
   part of that contract: #28167 legitimately replaced two raw refs with Atomic
   broadcaster cells, which made the old positive-name test reject a correct
   representation change. [Ast_grep] matches exact value bindings, so this
   remains an AST contract rather than a source-substring heuristic. *)
let forbidden_identifiers =
  [ "_shell_warmed"
  ; "_shell_warming"
  ; "_last_good_shell"
  ; "_operator_snapshot_broadcast_ref"
  ; "_operator_digest_broadcast_ref"
  ; "_operator_digest_cache"
  ; "_mission_cache"
  ]
;;

let test_old_underscore_names_gone () =
  check bool "the module family must not be empty" true (files <> []);
  List.iter
    (fun old_name ->
      List.iter
        (fun file ->
          let n = Ast_grep.count_value_bindings ~module_path:file ~name:old_name in
          let msg =
            Printf.sprintf "old underscore name %s should be removed from %s"
              old_name file
          in
          check int msg 0 n)
        files)
    forbidden_identifiers
;;

let () =
  run
    "rfc-0085-pr-16-dashboard-http-core-rename"
    [ ( "identifier rename"
      , [ test_case "old underscore names gone" `Quick test_old_underscore_names_gone
        ] )
    ]
;;
