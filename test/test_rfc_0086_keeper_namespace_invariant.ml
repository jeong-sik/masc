open Alcotest
module String_set = Set.Make (String)

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

let keeper_prefix = "keeper_"
let keeper_root () = Masc_test_deps.source_path "lib/keeper"

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

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop idx =
    idx + needle_len <= haystack_len
    &&
    (String.equal (String.sub haystack idx needle_len) needle || loop (idx + 1))
  in
  String.equal needle "" || loop 0
;;

let is_absolute_path path =
  (not (String.equal path ""))
  && Char.equal path.[0] Filename.dir_sep.[0]
;;

let boundary_modules_path =
  "docs/rfc/RFC-0086-keeper-namespace-boundary-modules.txt"

let valid_boundary_basename name =
  (not (String.equal name ""))
  && (not (String.starts_with ~prefix:keeper_prefix name))
  && not
       (String.exists
          (function
            | '/' | '\\' | '.' -> true
            | _ -> false)
          name)
;;

let parse_boundary_module_line ~line_no raw_line =
  let line = String.trim raw_line in
  if String.equal line "" || line.[0] = '#'
  then None
  else (
    match String.split_on_char '|' line with
    | [ raw_name; raw_reason ] ->
      let name = String.trim raw_name in
      let reason = String.trim raw_reason in
      if not (valid_boundary_basename name)
      then
        failf
          "%s:%d invalid boundary basename %S"
          boundary_modules_path
          line_no
          name;
      if String.equal reason ""
      then
        failf
          "%s:%d boundary module %S is missing a reason"
          boundary_modules_path
          line_no
          name;
      Some name
    | _ ->
      failf
        "%s:%d malformed line; expected '<module-basename> | <reason>'"
        boundary_modules_path
        line_no)
;;

let load_intentional_boundary_modules () =
  Masc_test_deps.read_source_file boundary_modules_path
  |> String.split_on_char '\n'
  |> List.mapi (fun idx line -> parse_boundary_module_line ~line_no:(idx + 1) line)
  |> List.filter_map Fun.id
;;

let intentional_boundary_modules = lazy (load_intentional_boundary_modules ())

let intentional_boundary_module_set () =
  Lazy.force intentional_boundary_modules
  |> List.fold_left (fun acc name -> String_set.add name acc) String_set.empty
;;

let test_all_files_have_keeper_prefix () =
  let files = collect_ml_files (keeper_root ()) [] in
  let boundary_modules = intentional_boundary_module_set () in
  let offenders =
    List.filter
      (fun path ->
        let base = basename_no_ext path in
        not
          (String.starts_with ~prefix:keeper_prefix base
           || String_set.mem base boundary_modules))
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

let sorted_unique xs = List.sort_uniq String.compare xs

let test_boundary_registry_is_sorted_unique_and_necessary () =
  let registered = Lazy.force intentional_boundary_modules in
  let sorted_registered = sorted_unique registered in
  if registered <> sorted_registered
  then
    failf
      "%s must be sorted and unique; got [%s], expected [%s]"
      boundary_modules_path
      (String.concat "; " registered)
      (String.concat "; " sorted_registered);
  let files = collect_ml_files (keeper_root ()) [] in
  let required =
    files
    |> List.map basename_no_ext
    |> List.filter (fun base -> not (String.starts_with ~prefix:keeper_prefix base))
    |> sorted_unique
  in
  if registered <> required
  then
    failf
      "%s must list exactly the necessary non-%s lib/keeper basenames; got [%s], \
       expected [%s]"
      boundary_modules_path
      keeper_prefix
      (String.concat "; " registered)
      (String.concat "; " required)
;;

let test_source_path_contract_rejects_unsafe_relatives () =
  let unsafe_relatives =
    [ ""
    ; "/lib/keeper"
    ; "./lib/keeper"
    ; "lib/../keeper"
    ; "lib//keeper"
    ; "lib/keeper/"
    ]
  in
  List.iter
    (fun rel ->
      match Masc_test_deps.source_path rel with
      | _ -> failf "source_path unexpectedly accepted unsafe relative path %S" rel
      | exception Failure msg ->
        check bool
          (Printf.sprintf "source_path error mentions bad path %S" rel)
          true
          (string_contains ~needle:(Printf.sprintf "%S" rel) msg))
    unsafe_relatives
;;

let test_source_path_contract_resolves_valid_relative () =
  (* Positive counterpart to the rejection test: a clean repo-relative
     path resolves to an absolute filesystem path that lands on the real
     keeper directory.  Guards against a future change that quietly
     mangles or relativizes the resolved path. *)
  let resolved = Masc_test_deps.source_path "lib/keeper" in
  check bool "source_path returns an absolute path" true
    (is_absolute_path resolved);
  check bool "source_path lands on a real keeper directory" true
    (Sys.is_directory resolved)
;;

let test_population_sanity () =
  let files = collect_ml_files (keeper_root ()) [] in
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
        ; test_case
            "boundary registry is sorted, unique, and necessary"
            `Quick
            test_boundary_registry_is_sorted_unique_and_necessary
        ; test_case
            "source_path rejects unsafe repo-relative paths"
            `Quick
            test_source_path_contract_rejects_unsafe_relatives
        ; test_case
            "source_path resolves valid repo-relative paths"
            `Quick
            test_source_path_contract_resolves_valid_relative
        ] )
    ]
;;
