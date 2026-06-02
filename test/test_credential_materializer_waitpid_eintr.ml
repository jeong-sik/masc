(* test/test_credential_materializer_waitpid_eintr.ml

   Regression guard for issue #13060 and the later command-plane
   cutover. Credential materialization used to own subprocess pipes
   and blocking [Unix.waitpid] calls directly. That fixed EINTR with a
   local retry helper, but still left this module outside the shared
   Process_eio timeout and FD-accounting plane.

   The invariant is now stronger: credential subprocesses must not use
   direct Unix process primitives at all. They route through
   [Process_eio.run_argv_with_status_split] for read-only gh probes and
   [run_argv_with_stdin_and_status_split] for
   [gh auth login --with-token]. This keeps token stdin handling local
   to Process_eio and lets the global spawn guard account foreground
   subprocess pressure without recording credential-specific env in
   approval-gate telemetry. *)

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
   quoted ["{|...|}"] / ["{tag|...|tag}"] forms — so mentions inside
   comments or strings do not skew the structural call-site checks.
   The output is a code-only view that preserves real expressions and
   identifiers. *)
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
  let code_only = strip_comments_and_strings src in
  let assert_absent needle =
    let count = count_substring ~needle code_only in
    if count <> 0 then
      failwith
        (Printf.sprintf
           "expected no %s call sites in credential_materializer.ml; found %d"
           needle count)
  in
  assert_absent "Unix.create_process";
  assert_absent "Unix.create_process_env";
  assert_absent "Unix.open_process";
  assert_absent "Unix.waitpid";
  assert_absent "Unix.pipe";
  assert_contains
    ~label:"read-only gh probes use Process_eio"
    src
    "Process_eio.run_argv_with_status_split";
  assert_contains
    ~label:"with-token provisioning uses Process_eio stdin API"
    src
    "Process_eio.run_argv_with_stdin_and_status_split";
  let status_split_uses =
    count_substring
      ~needle:"Process_eio.run_argv_with_status_split"
      code_only
  in
  if status_split_uses < 2 then
    failwith
      (Printf.sprintf
         "expected at least 2 read-only Process_eio status-split uses; found %d"
         status_split_uses);
  let stdin_status_split_uses =
    count_substring
      ~needle:"Process_eio.run_argv_with_stdin_and_status_split"
      code_only
  in
  if stdin_status_split_uses < 1 then
      failwith
        (Printf.sprintf
         "expected at least 1 stdin Process_eio status-split use; found %d"
         stdin_status_split_uses);
  print_endline "test_credential_materializer_process_plane: OK"
