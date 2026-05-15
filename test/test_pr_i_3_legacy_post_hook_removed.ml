open Alcotest

(** RFC-0084 PR-I-3 — legacy post-hook surface removal (final).

    After PR-I-2.a..e migrated all 5 in-tree register_post_hook
    call-sites, PR-I-3 removes the legacy [type post_hook],
    [val register_post_hook], [val post_hooks], and
    [val run_post_hooks] from Tool_dispatch.

    The dispatch loop now threads transformation through
    [apply_result_transformer] (PR-I-2.d) and observation through
    [run_typed_post_hooks] (PR-I-1).  Legacy keeper_tools_oas
    call-sites that previously called [Tool_dispatch.run_post_hooks]
    on bypass paths are migrated to the typed observer surface in
    this PR as well.

    Pins:
    - [Tool_dispatch.register_post_hook] not declared in mli
    - [Tool_dispatch.run_post_hooks] not declared in mli
    - [Tool_dispatch.post_hooks] not declared in mli
    - [type post_hook] not declared in mli
    - no [Tool_dispatch.run_post_hooks] references in lib/
    - no [Tool_dispatch.register_post_hook] references in lib/ *)

let read_file path =
  match In_channel.with_open_text path In_channel.input_all with
  | exception _ -> ""
  | content -> content
;;

let count_substring ~haystack ~needle =
  let rec loop i acc =
    let next = String.index_from_opt haystack i needle.[0] in
    match next with
    | None -> acc
    | Some j ->
      let len = String.length needle in
      if j + len <= String.length haystack
         && String.sub haystack j len = needle
      then loop (j + len) (acc + 1)
      else loop (j + 1) acc
  in
  loop 0 0
;;

(* Walk lib/ for any .ml file containing the legacy entry references.
   Limit the walk to a hand-rolled BFS over [lib/] subtree.  Excludes
   the documentation comment in [tool_dispatch.mli] which is
   *removal-notice* prose, not a live reference. *)
let walk_ml_files root =
  let rec aux acc paths =
    match paths with
    | [] -> acc
    | path :: rest ->
      (match Sys.is_directory path with
       | true ->
         let children =
           try
             Sys.readdir path
             |> Array.to_list
             |> List.map (fun child -> Filename.concat path child)
           with _ -> []
         in
         aux acc (children @ rest)
       | false ->
         if Filename.check_suffix path ".ml"
         then aux (path :: acc) rest
         else aux acc rest
       | exception _ -> aux acc rest)
  in
  aux [] [ root ]
;;

let test_no_legacy_register_in_lib () =
  let files = walk_ml_files "lib" in
  let total =
    List.fold_left
      (fun acc path ->
        acc + count_substring ~haystack:(read_file path)
                ~needle:"Tool_dispatch.register_post_hook")
      0 files
  in
  (check int)
    "Tool_dispatch.register_post_hook must be unreferenced across \
     all of lib/ after PR-I-3"
    0 total
;;

let test_no_legacy_run_post_hooks_in_lib () =
  let files = walk_ml_files "lib" in
  let total =
    List.fold_left
      (fun acc path ->
        acc + count_substring ~haystack:(read_file path)
                ~needle:"Tool_dispatch.run_post_hooks")
      0 files
  in
  (check int)
    "Tool_dispatch.run_post_hooks must be unreferenced across \
     all of lib/ after PR-I-3"
    0 total
;;

let test_mli_does_not_declare_legacy_post_hook () =
  let mli = read_file "lib/tool_dispatch.mli" in
  (check int)
    "mli must not declare [type post_hook] after PR-I-3"
    0
    (count_substring ~haystack:mli ~needle:"type post_hook =")
;;

let test_mli_does_not_declare_register_post_hook_val () =
  let mli = read_file "lib/tool_dispatch.mli" in
  (check int)
    "mli must not declare [val register_post_hook] after PR-I-3"
    0
    (count_substring ~haystack:mli ~needle:"val register_post_hook")
;;

let test_mli_does_not_declare_run_post_hooks_val () =
  let mli = read_file "lib/tool_dispatch.mli" in
  (check int)
    "mli must not declare [val run_post_hooks] after PR-I-3"
    0
    (count_substring ~haystack:mli ~needle:"val run_post_hooks ")
;;

let test_typed_surface_still_present () =
  let mli = read_file "lib/tool_dispatch.mli" in
  (check bool)
    "typed post-hook surface still declared in mli after PR-I-3"
    true
    (count_substring ~haystack:mli ~needle:"val register_typed_post_hook" >= 1
     && count_substring ~haystack:mli ~needle:"val run_typed_post_hooks" >= 1
     && count_substring ~haystack:mli ~needle:"set_result_transformer" >= 1)
;;

let () =
  run
    "PR-I-3 legacy post-hook surface removal"
    [ ( "pr-i-3-legacy-removal"
      , [ test_case "no-legacy-register-in-lib" `Quick
            test_no_legacy_register_in_lib
        ; test_case "no-legacy-run-post-hooks-in-lib" `Quick
            test_no_legacy_run_post_hooks_in_lib
        ; test_case "mli-does-not-declare-legacy-post-hook" `Quick
            test_mli_does_not_declare_legacy_post_hook
        ; test_case "mli-does-not-declare-register-post-hook-val" `Quick
            test_mli_does_not_declare_register_post_hook_val
        ; test_case "mli-does-not-declare-run-post-hooks-val" `Quick
            test_mli_does_not_declare_run_post_hooks_val
        ; test_case "typed-surface-still-present" `Quick
            test_typed_surface_still_present
        ] )
    ]
;;
