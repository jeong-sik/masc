open Alcotest

(** RFC-0086 — keeper namespace bulk promotion invariant.

    G-A (Phase 2.A wave 1, #15474): every .ml/.mli file under
    [lib/keeper/] carries the [keeper_] prefix.  Confirmed manually at
    250 files / 0 non-prefix on main HEAD (ac2138887c, 2026-05-15).

    This test pins the invariant so a future mechanical-rename
    regression (e.g. someone adds [lib/keeper/foo.ml] without the
    prefix) fails at CI rather than slipping past dune build.

    Approach: file-system scan (Sys.readdir / Unix.lstat) — naming
    convention is a structural property of the filesystem layout, not
    of any individual .ml AST, so an AST-grep would be the wrong axis
    here. *)

let keeper_root = "lib/keeper"

let rec collect_ml_files dir acc =
  let entries = try Sys.readdir dir with Sys_error _ -> [||] in
  Array.fold_left
    (fun acc name ->
      let p = Filename.concat dir name in
      if (try Sys.is_directory p with Sys_error _ -> false)
      then collect_ml_files p acc
      else if Filename.check_suffix p ".ml" || Filename.check_suffix p ".mli"
      then p :: acc
      else acc)
    acc
    entries
;;

let basename_no_ext path =
  let b = Filename.basename path in
  try Filename.chop_extension b with Invalid_argument _ -> b
;;

let test_all_files_have_keeper_prefix () =
  let files = collect_ml_files keeper_root [] in
  let offenders =
    List.filter
      (fun path ->
        let base = basename_no_ext path in
        not (String.length base >= 7 && String.sub base 0 7 = "keeper_"))
      files
  in
  match offenders with
  | [] -> ()
  | xs ->
    failf
      "lib/keeper/ files missing [keeper_] prefix (%d): %s"
      (List.length xs)
      (String.concat ", " xs)
;;

let test_population_sanity () =
  let files = collect_ml_files keeper_root [] in
  (* Population sanity: a sudden drop to near-zero or jump beyond
     historical range would indicate a directory move / restructure
     worth re-validating.  Range chosen with margin around the
     observed 250 .ml + ~250 .mli ≈ 500 (lower 200, upper 1500). *)
  let n = List.length files in
  if n < 200 || n > 1500
  then
    failf
      "lib/keeper/ population out of expected range — got %d (expected 200..1500)"
      n
;;

let () =
  run
    "rfc-0086-keeper-namespace-invariant"
    [ ( "prefix"
      , [ test_case
            "every lib/keeper/**/*.ml{,i} has keeper_ prefix"
            `Quick
            test_all_files_have_keeper_prefix
        ; test_case "population sanity (200..1500)" `Quick test_population_sanity
        ] )
    ]
;;
