(* test/test_credential_materializer_waitpid_eintr.ml

   Regression guard for issue #13060 (EINTR escape from
   [Unix.waitpid] in [lib/repo_manager/credential_materializer.ml]).

   Background.  Three blocking [Unix.waitpid [] pid] sites in the
   credential materializer used to raise
     [Unix.Unix_error (Unix.EINTR, "waitpid", "")]
   whenever a Posix signal interrupted the wait.  Observed live at
   ~5/hr on 2026-05-05 — every interruption surfaced as
     [tools/call crashed: Unix_error EINTR waitpid]
   for keeper_bash / docker shell / git command paths, contributing
   to the stale_turn cycle.  PR #13088 wraps every blocking
   [Unix.waitpid] in a [waitpid_no_intr] helper that retries on
   EINTR (canonical Posix idiom, mirrors prior-art
   [waitpid_blocking] in [lib/process/process_eio.ml]).

   This test asserts the fix structurally — a future refactor that
   re-introduces a bare [Unix.waitpid] in the file fails CI before
   it can re-arm the EINTR escape.  Behavioural EINTR reproduction
   is non-trivial (deterministically delivering signals to a child
   during waitpid is racy), and the fix is a 1-line idiom with
   established prior art, so the regression we guard against is
   "wrap removed" — a substring/anchor check catches that cheaply.

   This stanza re-adds the regression guard from the closed PR
   #13068, with copilot-pull-request-reviewer's two outstanding
   robustness comments folded in:

   1. Source-path resolution candidates extended with deeper
      "../../" / "../../../" fallbacks, and the failure message now
      prints the candidate list so debugging under unusual dune
      sandbox / CWD layouts is possible.
   2. The [Unix.waitpid] occurrence count strips both OCaml
      comments AND string literals before counting.  This protects
      against a future log/error message that mentions "Unix.waitpid"
      in a string from triggering a false positive, and against the
      explanatory block comment in this module from triggering a
      false positive on the source itself. *)

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

(* Strip OCaml [(* ... *)] comments (nesting-aware) and OCaml
   string literals — both regular ["..."] (with [\\] escapes) and
   quoted ["{|...|}"] / ["{tag|...|tag}"] forms — so that mentions
   of [Unix.waitpid] inside comments or strings do not skew the
   bare-call-site count below.  The output is a code-only view that
   preserves all real expressions and identifiers. *)
let strip_comments_and_strings s =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  let depth = ref 0 in
  while !i < n do
    let c = s.[!i] in
    if !depth > 0 then begin
      if !i + 1 < n && c = '*' && s.[!i + 1] = ')' then begin
        decr depth;
        i := !i + 2
      end else if !i + 1 < n && c = '(' && s.[!i + 1] = '*' then begin
        incr depth;
        i := !i + 2
      end else
        incr i
    end else if !i + 1 < n && c = '(' && s.[!i + 1] = '*' then begin
      incr depth;
      i := !i + 2
    end else if c = '"' then begin
      (* Skip a regular string literal, honouring backslash escapes. *)
      incr i;
      while !i < n && s.[!i] <> '"' do
        if s.[!i] = '\\' && !i + 1 < n then i := !i + 2
        else incr i
      done;
      if !i < n then incr i
    end else if c = '{' then begin
      (* Possibly a quoted string [{tag|...|tag}].  Tag is any run
         of lowercase letters / underscores after the brace.  If
         followed by [|] it opens a quoted string; otherwise emit
         the brace as code. *)
      let j = ref (!i + 1) in
      while !j < n
            && (let cj = s.[!j] in
                (cj >= 'a' && cj <= 'z') || cj = '_')
      do
        incr j
      done;
      if !j < n && s.[!j] = '|' then begin
        let tag = String.sub s (!i + 1) (!j - !i - 1) in
        let close = "|" ^ tag ^ "}" in
        let cl = String.length close in
        i := !j + 1;
        let found = ref false in
        while not !found && !i + cl <= n do
          if String.sub s !i cl = close then begin
            found := true;
            i := !i + cl
          end else
            incr i
        done;
        if not !found then i := n
      end else begin
        Buffer.add_char buf c;
        incr i
      end
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  Buffer.contents buf

let () =
  let parent p = Filename.dirname p in
  let exe = Sys.executable_name in
  let project_root = parent (parent (parent (parent exe))) in
  let candidates =
    [ Filename.concat project_root
        "lib/repo_manager/credential_materializer.ml"
    ; "lib/repo_manager/credential_materializer.ml"
    ; "../lib/repo_manager/credential_materializer.ml"
    ; "../../lib/repo_manager/credential_materializer.ml"
    ; "../../../lib/repo_manager/credential_materializer.ml"
    ]
  in
  let src =
    match List.find_opt Sys.file_exists candidates with
    | Some p -> read_file p
    | None ->
      failwith
        (Printf.sprintf
           "no candidate source path resolved \
            (cwd=%s, exe=%s, candidates=[%s])"
           (Sys.getcwd ()) exe (String.concat "; " candidates))
  in
  (* Anchor 1: helper present.  Needle does not include parameters
     so it matches both the original [waitpid_no_intr pid] form
     (closed PR #13068) and the more general [waitpid_no_intr flags
     pid] form that landed via #13088. *)
  assert_contains
    ~label:"waitpid_no_intr helper definition"
    src
    "let rec waitpid_no_intr";
  (* Anchor 2: helper retries on EINTR specifically — not on any
     [Unix_error].  Needle stops before parameters for the same
     reason as Anchor 1. *)
  assert_contains
    ~label:"EINTR retry arm"
    src
    "Unix.Unix_error (Unix.EINTR, _, _) -> waitpid_no_intr";
  (* Anchor 3: only one bare [Unix.waitpid] call may exist in the
     module — the one inside [waitpid_no_intr].  We count after
     stripping comments AND string literals so that:
     * the explanatory block comment naming [Unix.waitpid] in this
       module does not skew the count (false positive guard);
     * a future log/error message that cites the API by name in a
       string literal does not trip the test (false positive
       guard).
     The bare-token needle is intentional — it catches any
     reintroduced bare call regardless of surrounding syntax
     (including the bracket-less [Unix.waitpid flags pid] form used
     by the current helper after #13088). *)
  let code_only = strip_comments_and_strings src in
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
