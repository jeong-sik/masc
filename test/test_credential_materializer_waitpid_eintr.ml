(* test/test_credential_materializer_waitpid_eintr.ml

   Regression guard for issue #13060:

   Three [Unix.waitpid [] pid] sites in
   lib/repo_manager/credential_materializer.ml previously raised
   [Unix.Unix_error (Unix.EINTR, "waitpid", "")] whenever a Posix
   signal interrupted the wait.  Observed live at ~5/hr on
   2026-05-05 — every interruption surfaced as
     [tools/call crashed: Unix_error EINTR waitpid]
   for keeper_bash / docker shell / git command paths, contributing
   to the stale_turn cycle.

   The fix wraps [Unix.waitpid] in a [waitpid_no_intr] helper that
   retries on EINTR (canonical Posix idiom, mirrors prior-art
   [waitpid_blocking] in lib/process/process_eio.ml:281).  All
   blocking [Unix.waitpid [] pid] call sites in this file route
   through the helper.

   This test asserts the fix structurally — a future refactor that
   re-introduces a bare [Unix.waitpid [] pid] in the file fails CI
   before it can re-arm the EINTR escape.  Behavioural EINTR
   reproduction is non-trivial (deterministically delivering
   signals to a child during waitpid is racy), and the fix is a
   1-line idiom with established prior art, so the regression we
   guard against is "wrap removed" — a substring/anchor check
   catches that cheaply. *)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> In_channel.input_all ic)

let count_substring ~needle s =
  let n = String.length needle in
  let h = String.length s in
  let rec loop i acc =
    if i + n > h then acc
    else if String.sub s i n = needle then loop (i + 1) (acc + 1)
    else loop (i + 1) acc
  in
  loop 0 0

let assert_contains ~label haystack needle =
  if count_substring ~needle haystack < 1 then
    failwith
      (Printf.sprintf
         "[%s] expected source to contain %S — see issue #13060"
         label needle)

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root
        "lib/repo_manager/credential_materializer.ml"
    ; "lib/repo_manager/credential_materializer.ml"
    ; "../lib/repo_manager/credential_materializer.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "no candidate source path resolved (cwd=%s, exe=%s)"
           (Sys.getcwd ()) exe)
  in
  (* Anchor 1: helper present. *)
  assert_contains
    ~label:"waitpid_no_intr helper definition"
    src
    "let rec waitpid_no_intr pid";
  (* Anchor 2: helper retries on EINTR, not just any error. *)
  assert_contains
    ~label:"EINTR retry arm"
    src
    "Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_no_intr pid";
  (* Anchor 3: no bare blocking [Unix.waitpid [] pid] outside the
     helper.  The helper itself contains [Unix.waitpid [] pid] on
     its single defining line, so we expect *exactly one*
     occurrence of that exact pattern. *)
  let bare_blocking_uses = count_substring ~needle:"Unix.waitpid [] pid" src in
  if bare_blocking_uses <> 1 then
    failwith
      (Printf.sprintf
         "expected exactly 1 [Unix.waitpid [] pid] occurrence \
          (the helper definition); found %d.  Every blocking \
          waitpid in credential_materializer.ml must route \
          through waitpid_no_intr — see issue #13060."
         bare_blocking_uses);
  (* Anchor 4: at least one call site uses the helper.  Catches
     a refactor that deletes all helper call sites without also
     deleting the helper. *)
  let helper_uses = count_substring ~needle:"waitpid_no_intr pid" src in
  if helper_uses < 4 then
    failwith
      (Printf.sprintf
         "expected ≥4 references to [waitpid_no_intr pid] (1 \
          definition + ≥3 call sites); found %d"
         helper_uses);
  print_endline "test_credential_materializer_waitpid_eintr: OK"
