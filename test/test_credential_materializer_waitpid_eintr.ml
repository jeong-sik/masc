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
  (* Anchor 3: only one bare [Unix.waitpid] call may exist in the
     module — the one inside [waitpid_no_intr].  Anchoring on
     [Unix.waitpid] (without the trailing [[] pid]) defends against
     renames of the local variable as well as a reintroduced bare
     [Unix.waitpid [] child_pid] in a future refactor.  Comments are
     out of scope: we strip them before counting so the explanatory
     comment that names [Unix.waitpid] does not skew the result. *)
  let strip_ocaml_comments s =
    let buf = Buffer.create (String.length s) in
    let depth = ref 0 in
    let i = ref 0 in
    let n = String.length s in
    while !i < n do
      if !i + 1 < n && s.[!i] = '(' && s.[!i + 1] = '*' then begin
        incr depth; i := !i + 2
      end else if !depth > 0 && !i + 1 < n && s.[!i] = '*' && s.[!i + 1] = ')' then begin
        decr depth; i := !i + 2
      end else begin
        if !depth = 0 then Buffer.add_char buf s.[!i];
        incr i
      end
    done;
    Buffer.contents buf
  in
  let code_only = strip_ocaml_comments src in
  let bare_waitpid = count_substring ~needle:"Unix.waitpid" code_only in
  if bare_waitpid <> 1 then
    failwith
      (Printf.sprintf
         "expected exactly 1 [Unix.waitpid] use in code (inside \
          waitpid_no_intr); found %d.  Every blocking waitpid in \
          credential_materializer.ml must route through \
          waitpid_no_intr — see issue #13060."
         bare_waitpid);
  (* Anchor 4: ≥3 distinct call sites route the result of
     [waitpid_no_intr] through [snd (waitpid_no_intr ...)] — the
     pattern every caller uses to discard the [pid] half.  This is
     a call-site-only pattern (no false credit for the helper
     definition or the recursive tail call) so the count is exactly
     "number of true caller invocations". *)
  let call_sites = count_substring ~needle:"snd (waitpid_no_intr" code_only in
  if call_sites < 3 then
    failwith
      (Printf.sprintf
         "expected ≥3 [snd (waitpid_no_intr ...)] caller invocations; \
          found %d.  See issue #13060."
         call_sites);
  print_endline "test_credential_materializer_waitpid_eintr: OK"
