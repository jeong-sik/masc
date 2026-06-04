(** Source-level wiring guard for PR3 of the [Keeper_tool_execute_path]
    [sandbox_repo_not_ready] error message.

    This test pins the operator-facing message format added in PR3:
    the [repo_cwd_not_ready_error] formatter must carry a docker
    sandbox mount hint so an operator who sees the error in a
    docker-backed keeper can immediately tell whether the failure
    is a host-side checkout problem (reclone) or a docker mount
    layout problem (worktree subdir not visible to the container).

    PR3 also removes the host-stat fast-path ([safe_is_dir probe_path])
    at the top of [validate_repo_path_ready] — that fast-path was a
    false-positive for docker sandbox cwd where the path is not present
    on the host.  The git probe alone is the source of truth.

    Pinned invariants:
    - the original "Repair or reclone" hint is still present
      (regression guard — never remove without operator migration)
    - the docker mount hint added in PR3 is present
    - [Option.value ~default:"<none>"] fallback for git_toplevel is
      still wired (so operators can tell "git probe failed" from
      "git probe returned a non-matching toplevel")
    - the host-stat fast-path has been removed; the git
      [rev-parse --show-toplevel] probe is still the authority

    Substrings are intentionally short and chosen to land on a
    single source line (no OCaml `\` line continuation), because
    line continuation stitches the literal across line breaks at
    compile time and the stitched result is not visible at the
    source-text level.  Each test here is a regression guard, not
    a full string match — the load-bearing assertion is "the
    substring is present in the source", which suffices to catch
    the realistic failure modes (someone deletes the docker hint,
    re-introduces the safe_is_dir fast-path, or removes the
    Option.value fallback). *)

open Alcotest

let read_source path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let buf = Buffer.create 16384 in
      (try
         while true do
           Buffer.add_string buf (input_line ic);
           Buffer.add_char buf '\n'
         done
       with End_of_file -> ());
      Buffer.contents buf)

let find_source_path () =
  List.find_opt Sys.file_exists
    [
      "lib/keeper/keeper_tool_execute_path.ml"
    ; "../lib/keeper/keeper_tool_execute_path.ml"
    ; "../../lib/keeper/keeper_tool_execute_path.ml"
    ]

let src_opt () = Option.map read_source (find_source_path ())

let has_substring_opt src_opt needle =
  match src_opt with
  | None -> false
  | Some src ->
    let n = String.length needle in
    let rec loop i =
      if i + n > String.length src then false
      else if String.sub src i n = needle then true
      else loop (i + 1)
    in
    loop 0

let test_reclone_hint_present () =
  check bool
    "original reclone hint still present (regression guard)"
    true
    (has_substring_opt
       (src_opt ())
       "Repair or reclone")

let test_retry_cwd_hint_present () =
  check bool
    "retry-cwd hint still present"
    true
    (has_substring_opt
       (src_opt ())
       "then retry with cwd=\\\"repos/")

let test_docker_mount_hint_present () =
  check bool
    "docker sandbox hint is present (PR3 add)"
    true
    (has_substring_opt (src_opt ()) "If the call");
  check bool
    "docker hint mentions docker playground mount"
    true
    (has_substring_opt (src_opt ()) "the docker playground mount");
  check bool
    "docker hint mentions worktree subdirectory"
    true
    (has_substring_opt (src_opt ()) "worktree subdirectory");
  check bool
    "docker hint offers in-place repo root cwd alternative"
    true
    (has_substring_opt (src_opt ()) "set cwd to the in-place repo root")

let test_git_toplevel_none_fallback_present () =
  check bool
    "Option.value ~default:\"<none>\" git_toplevel fallback present"
    true
    (has_substring_opt
       (src_opt ())
       "Option.value ~default:\"<none>\" git_toplevel")

let test_safe_is_dir_fast_path_removed () =
  (* PR3 removes the host-stat fast-path so the git probe alone is
     the source of truth — docker sandbox cwd is not present on
     the host, so a host stat is a false positive. *)
  check bool
    "host-stat fast-path (safe_is_dir probe_path) is removed"
    false
    (has_substring_opt (src_opt ()) "safe_is_dir probe_path")

let test_git_rev_parse_probe_present () =
  check bool
    "git rev-parse --show-toplevel probe is still the authority"
    true
    (has_substring_opt (src_opt ()) "rev-parse")

let () =
  run "keeper_tool_execute_path_message"
    [
      ( "sandbox_repo_not_ready error message (PR3)"
      , [
          test_case "reclone hint regression guard" `Quick
            test_reclone_hint_present
        ; test_case "retry-cwd hint regression guard" `Quick
            test_retry_cwd_hint_present
        ; test_case "docker mount hint (PR3 add)" `Quick
            test_docker_mount_hint_present
        ; test_case "git_toplevel <none> fallback" `Quick
            test_git_toplevel_none_fallback_present
        ] )
    ; ( "validate_repo_path_ready probe simplification (PR3)"
      , [
          test_case "host-stat fast-path removed" `Quick
            test_safe_is_dir_fast_path_removed
        ; test_case "git rev-parse probe present" `Quick
            test_git_rev_parse_probe_present
        ] )
    ]
