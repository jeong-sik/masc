(** RFC-0054 PR-3 → PR-5 — generated walker correctness test.

    PR-5 retired the hand-written walkers in [Shell_ir_typed]; the
    public API ([risk], [sandbox], [to_simple]) now delegates directly
    to [Shell_ir_typed_walkers_gen].  The equivalence tests below are
    retained as a round-trip smoke test (they are trivially true now
    since both sides call the same generated function).  The structural
    invariants — constructor count and declaration order — remain the
    primary regression guard. *)

open Masc_exec

let bin_ok name =
  match Exec_program.of_string name with
  | Ok b -> b
  | Error _ -> assert false
;;

let lit s = Shell_ir.Lit (s, Shell_ir.default_meta)

(* Construct one [W] for each constructor with minimal payload. The
   payload values do not affect [risk] or [sandbox] (both walk only on
   the constructor head), but constructor coverage is checked
   structurally below. *)
let all_wrapped : Shell_ir_typed.wrapped list =
  let open Shell_ir_typed in
  [ W (Ls { path = None; flags = [] })
  ; W (Cat { path = "/dev/null" })
  ; W (Rg { pattern = "."; path = None; case_sensitive = false })
  ; W (Git_status { short = false })
  ; W (Git_clone { repo = "x"; branch = None; depth = 1 })
  ; W (Curl { url = "http://x"; method_ = `GET; headers = None; body = None })
  ; W (Rm { paths = [ "/tmp/x" ]; recursive = false; force = false })
  ; W (Sudo { target_argv = [ "sh"; "-c"; "echo hi" ] })
  ; W (Find { path = "."; name = None; type_ = None })
  ; W (Head { path = "/dev/null"; lines = 10 })
  ; W (Tail { path = "/dev/null"; lines = 10 })
  ; W (Grep { pattern = "."; path = None; recursive = false; case_sensitive = false })
  ; W (Mkdir { path = "/tmp/x"; parents = false })
  ; W (Wc { path = "/dev/null"; mode = `Lines })
  ; W (Git_diff { stat = false; cached = false; paths = [] })
  ; W (Git_log { oneline = false; max_count = None })
  ; W (Git_commit { message = "test"; amend = false })
  ; W (Git_push { force = false; force_with_lease = false; set_upstream = false; remote = None; branch = None })
  ; W (Git_pull { rebase = false; remote = None; branch = None })
  ; W (Pwd ())
  ; W (Echo { args = [ "hello" ] })
  ; W (Which { names = [ "ocaml" ] })
  ; W (Sort { reverse = false; numeric = false; unique = false; key = None; file = None })
  ; W (Cut { delimiter = None; fields = "1"; file = None })
  ; W (Tr { set1 = "a-z"; set2 = None; delete = false; squeeze = false })
  ; W (Date { format = None; utc = false })
  ; W (Env ())
  ; W (Printenv { name = None })
  ; W (Uniq { count = false; duplicates = false; unique = false; file = None })
  ; W (Basename { path = "/tmp"; suffix = None })
  ; W (Dirname { path = "/tmp" })
  ; W (Test { expression = [ "-f"; "x" ] })
  ; W (Stat { format = None; path = "/tmp" })
  ; W (Hostname { short = false })
  ; W (Whoami ())
  ; W (Du { path = None; human_readable = false; summary = false; max_depth = None })
  ; W (Df { path = None; human_readable = false; filesystem_type = None })
  ; W (File { path = "/tmp"; mime = false; brief = false })
  ; W (Printf { format = "%s"; args = [] })
  ; W (Uname { all = false; kernel_name = false; release = false; machine = false })
  ; W (Ps { all = false; full = false; user = None })
  ; W (Tty ())
  ; W (Wget { url = "http://x"; output = None })
  ; W (Ssh { host = "x"; user = None; command = None })
  ; W (Scp { source = "a"; dest = "b"; recursive = false })
  ; W (Tar { action = `Create; archive = "x.tar"; paths = []; gzip = false })
  ; W (Make { target = None; jobs = None })
  ; W (Diff { file1 = "a"; file2 = "b"; unified = false })
  ; W (Sed { expression = "s/x/y/"; file = "/tmp/x"; in_place = false })
  ; W (Rsync { source = "/tmp/a"; dest = "/tmp/b"; flags = [ "-avz" ] })
  ; W (Node { script = "app.js"; args = [ "--port"; "3000" ] })
  ; W (Python { script = "main.py"; args = [ "-v" ] })
  ; W (Python3 { script = "main.py"; args = [ "-v" ] })
  ; W (Pip { subcommand = "install"; packages = [ "requests"; "flask" ] })
  ; W (Patch { file = Some "foo.c"; patchfile = Some "fix.patch"; strip = 1; reverse = false })
  ; W (Npm { subcommand = "install"; args = [ "--save-dev" ] })
  ; W (Cargo { subcommand = "build"; args = [ "--release" ] })
  ; W (Go { subcommand = "build"; args = [ "-o"; "bin" ] })
  ; W (Gh { subcommand = "pr"; args = [ "list"; "--state"; "open" ] })
  ; W (Chmod { mode = "755"; path = "/tmp/x" })
  ; W (Chown { owner = "root"; path = "/tmp/x" })
  ; W (Docker { subcommand = "run"; args = [ "-d"; "nginx" ] })
  ; W (Opam { subcommand = "install"; args = [ "dune" ] })
  ; W (Npx { subcommand = "tsc"; args = [ "--noEmit" ] })
  ; W (Yarn { subcommand = "install"; args = [ "--frozen-lockfile" ] })
  ; W (Pnpm { subcommand = "run"; args = [ "build" ] })
  ; W (Uv { subcommand = "pip"; args = [ "install"; "requests" ] })
  ; W (Glab { subcommand = "mr"; args = [ "list"; "--state"; "opened" ] })
  ; W (Pytest { subcommand = ""; args = [ "-v"; "tests/" ] })
  ; W (Terminal_notifier { title = "Done"; message = "Build finished" })
  ; W (Ruff { subcommand = "check"; args = [ "--fix" ] })
  ; W (Pyright { subcommand = ""; args = [ "--project"; "." ] })
  ; W (Tsc { subcommand = ""; args = [ "--noEmit" ] })
  ; W (Ocamlfind { subcommand = "list"; args = [ "-desc" ] })
  ; W (Rustc { subcommand = ""; args = [ "--edition"; "2021" ] })
  ; W (Gofmt { subcommand = ""; args = [ "-w"; "main.go" ] })
  ; W (Gradle { subcommand = "build"; args = [ "--no-daemon" ] })
  ; W (Ninja { subcommand = ""; args = [ "-j4" ] })
  ; W (Java { subcommand = "MyClass"; args = [ "-cp"; "." ] })
  ; W (Javac { subcommand = "Main.java"; args = [ "-d"; "out" ] })
  ; W (Mvn { subcommand = "clean"; args = [ "install" ] })
  ; W (Cmake { subcommand = "--build"; args = [ "."; "--target"; "install" ] })
  ; W (Dune_local_sh { subcommand = "build"; args = [ "-j4" ] })
  ; W (Osascript { subcommand = "-e"; args = [ "tell app \"Finder\"" ] })
  ; W (Play { subcommand = "song.mp3"; args = [ "rate"; "44100" ] })
  ; W (Rec { subcommand = "output.wav"; args = [ "trim"; "0"; "10" ] })
  ; W (Ffplay { subcommand = "video.mp4"; args = [ "-autoexit" ] })
  ; W (Mpg123 { subcommand = "song.mp3"; args = [ "-q" ] })
  ; W (Open { subcommand = "file.txt"; args = [] })
  ; W (Su { subcommand = "root"; args = [] })
  ; W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/zeros"; "bs=1M"; "count=10" ] })
  ; W (Mkfs { subcommand = "-t"; args = [ "ext4"; "/dev/sdb1" ] })
  ; W
      (Generic
         { Shell_ir.bin = bin_ok "true"
         ; args = []
         ; env = []
         ; cwd = None
         ; redirects = []
         ; sandbox = Sandbox_target.host ()
         })
  ]
;;

let test_risk_parallel_equivalence () =
  List.iter
    (fun w ->
       let hand = Shell_ir_typed.risk w in
       let gen = Shell_ir_typed_walkers_gen.gen_risk w in
       Alcotest.(check bool)
         (Printf.sprintf
            "risk equivalence for %s"
            (match w with
             | Shell_ir_typed.W _ -> "constructor"))
         true
         (hand = gen))
    all_wrapped
;;

let test_sandbox_parallel_equivalence () =
  List.iter
    (fun w ->
       let hand = Shell_ir_typed.sandbox w in
       let gen = Shell_ir_typed_walkers_gen.gen_sandbox w in
       Alcotest.(check bool)
         (Printf.sprintf
            "sandbox equivalence for %s"
            (match w with
             | Shell_ir_typed.W _ -> "constructor"))
         true
         (hand = gen))
    all_wrapped
;;

(* PR-4: gen_to_simple parallel equivalence. The hand-written
   [Shell_ir_typed.to_simple] takes the unwrapped command directly,
   so the test unwraps each [W (...)] and feeds both walkers the
   same input. Equality is structural — each [Shell_ir.simple] field
   must match: bin, args, env, cwd, redirects, sandbox. *)
let simple_eq (a : Shell_ir.simple) (b : Shell_ir.simple) : bool =
  Exec_program.to_string a.bin = Exec_program.to_string b.bin
  && a.args = b.args
  && a.env = b.env
  && a.cwd = b.cwd
  && a.redirects = b.redirects
  && a.sandbox = b.sandbox
;;

let pp_simple ppf (s : Shell_ir.simple) =
  Format.fprintf
    ppf
    "{ bin=%s; args=%d; env=%d; cwd=%s; redirects=%d }"
    (Exec_program.to_string s.bin)
    (List.length s.args)
    (List.length s.env)
    (match s.cwd with
     | None -> "None"
     | Some _ -> "Some _")
    (List.length s.redirects)
;;

let test_to_simple_parallel_equivalence () =
  List.iter
    (fun (Shell_ir_typed.W cmd as w) ->
       let hand = Shell_ir_typed.to_simple cmd in
       let gen = Shell_ir_typed_walkers_gen.gen_to_simple cmd in
       let _ = w in
       if not (simple_eq hand gen)
       then Alcotest.failf "to_simple drift: hand=%a gen=%a" pp_simple hand pp_simple gen)
    all_wrapped
;;

let test_constructor_count () =
  (* Baseline: 71 constructors as of 2026-05-28. If this fails, either
     a constructor was added to shell_ir_typed.ml without updating the
     spec in bin/gen_shell_ir_walkers.ml (regression) or the count is
     intentional and this test should bump along with the spec. *)
  Alcotest.(check int)
    "generated constructor count"
    93
    (List.length Shell_ir_typed_walkers_gen.gen_constructor_names);
  Alcotest.(check int) "test fixture covers all constructors" 93 (List.length all_wrapped)
;;

(* PR-4 round-trip: of_simple ∘ to_simple = identity for every
   non-Generic constructor.  Generic is handled in the fallback test
   below. *)
let test_of_simple_round_trip () =
  let open Shell_ir_typed in
  let cmds : wrapped list =
    [ W (Ls { path = None; flags = [] })
    ; W (Ls { path = Some "/tmp"; flags = [ `Long; `All ] })
    ; W (Cat { path = "/etc/passwd" })
    ; W (Rg { pattern = "TODO"; path = Some "."; case_sensitive = true })
    ; W (Git_status { short = true })
    ; W (Git_clone { repo = "git@github.com:x/y.git"; branch = Some "main"; depth = 1 })
    ; W
        (Curl
           { url = "http://example.com"
           ; method_ = `POST
           ; headers = Some [ "A", "B" ]
           ; body = Some "data"
           })
    ; W (Rm { paths = [ "a"; "b" ]; recursive = true; force = false })
    ; W (Sudo { target_argv = [ "whoami" ] })
    ; W (Find { path = "/tmp"; name = Some "*.ml"; type_ = Some `File })
    ; W (Head { path = "/etc/hosts"; lines = 5 })
    ; W (Tail { path = "/var/log/syslog"; lines = 20 })
    ; W (Grep { pattern = "TODO"; path = Some "lib/"; recursive = true; case_sensitive = false })
    ; W (Mkdir { path = "/tmp/newdir"; parents = true })
    ; W (Wc { path = "README.md"; mode = `Words })
    ; W (Git_diff { stat = true; cached = false; paths = [ "lib/" ] })
    ; W (Git_log { oneline = true; max_count = Some 10 })
    ; W (Git_commit { message = "feat: add feature"; amend = false })
    ; W (Git_push { force = false; force_with_lease = true; set_upstream = true; remote = Some "origin"; branch = Some "main" })
    ; W (Git_pull { rebase = true; remote = Some "origin"; branch = Some "develop" })
    ; W (Pwd ())
    ; W (Echo { args = [ "hello"; "world" ] })
    ; W (Which { names = [ "ocaml"; "dune" ] })
    ; W (Sort { reverse = true; numeric = true; unique = true; key = Some 2; file = Some "/tmp/x" })
    ; W (Cut { delimiter = Some ":"; fields = "1,3"; file = Some "/etc/passwd" })
    ; W (Tr { set1 = "a-z"; set2 = Some "A-Z"; delete = false; squeeze = true })
    ; W (Date { format = Some "+%Y-%m-%d"; utc = true })
    ; W (Env ())
    ; W (Printenv { name = Some "PATH" })
    ; W (Uniq { count = true; duplicates = false; unique = true; file = Some "/tmp/x" })
    ; W (Basename { path = "/tmp/foo.bar"; suffix = Some ".bar" })
    ; W (Dirname { path = "/tmp/foo/bar" })
    ; W (Test { expression = [ "-f"; "/tmp/x" ] })
    ; W (Stat { format = Some "16%N"; path = "/tmp/x" })
    ; W (Hostname { short = true })
    ; W (Whoami ())
    ; W (Du { path = Some "/tmp"; human_readable = true; summary = true; max_depth = Some 2 })
    ; W (Df { path = Some "/"; human_readable = true; filesystem_type = Some "ext4" })
    ; W (File { path = "/bin/ls"; mime = true; brief = true })
    ; W (Printf { format = "hello %s %d"; args = [ "world"; "42" ] })
    ; W (Uname { all = true; kernel_name = true; release = true; machine = true })
    ; W (Ps { all = true; full = true; user = Some "root" })
    ; W (Tty ())
    ; W (Wget { url = "http://example.com/file"; output = Some "/tmp/file" })
    ; W (Ssh { host = "server"; user = Some "root"; command = Some "uptime" })
    ; W (Scp { source = "/tmp/a"; dest = "server:/tmp/b"; recursive = true })
    ; W (Tar { action = `Extract; archive = "x.tar.gz"; paths = [ "a"; "b" ]; gzip = true })
    ; W (Make { target = Some "install"; jobs = Some 4 })
    ; W (Diff { file1 = "old.ml"; file2 = "new.ml"; unified = true })
    ; W (Sed { expression = "s/foo/bar/g"; file = "input.txt"; in_place = true })
    ; W (Rsync { source = "src/"; dest = "dest/"; flags = [ "-av"; "--delete" ] })
    ; W (Node { script = "server.js"; args = [ "8080" ] })
    ; W (Python { script = "train.py"; args = [ "--epochs"; "10" ] })
    ; W (Python3 { script = "train.py"; args = [ "--epochs"; "10" ] })
    ; W (Pip { subcommand = "install"; packages = [ "numpy" ] })
    ; W (Patch { file = None; patchfile = Some "fix.patch"; strip = 0; reverse = true })
    ; W (Npm { subcommand = "run"; args = [ "build" ] })
    ; W (Cargo { subcommand = "test"; args = [ "--lib" ] })
    ; W (Go { subcommand = "run"; args = [ "main.go"; "-v" ] })
    ; W (Gh { subcommand = "issue"; args = [ "create"; "--title"; "bug" ] })
    ; W (Chmod { mode = "644"; path = "/etc/config" })
    ; W (Chown { owner = "user:group"; path = "/var/data" })
    ; W (Docker { subcommand = "build"; args = [ "-t"; "myapp"; "." ] })
    ; W (Opam { subcommand = "switch"; args = [ "create"; "5.2.0" ] })
    ; W (Npx { subcommand = "jest"; args = [ "--coverage" ] })
    ; W (Yarn { subcommand = "add"; args = [ "lodash" ] })
    ; W (Pnpm { subcommand = "dev"; args = [] })
    ; W (Uv { subcommand = "sync"; args = [] })
    ; W (Glab { subcommand = "ci"; args = [ "status" ] })
    ; W (Pytest { subcommand = ""; args = [ "--cov" ] })
    ; W (Terminal_notifier { title = "Test"; message = "All passed" })
    ; W (Ruff { subcommand = "format"; args = [ "--check"; "src/" ] })
    ; W (Pyright { subcommand = ""; args = [ "--strict" ] })
    ; W (Tsc { subcommand = ""; args = [ "--project"; "tsconfig.json" ] })
    ; W (Ocamlfind { subcommand = "query"; args = [ "eio" ] })
    ; W (Rustc { subcommand = ""; args = [ "-O"; "src/main.rs" ] })
    ; W (Gofmt { subcommand = ""; args = [ "-l"; "." ] })
    ; W (Gradle { subcommand = "test"; args = [ "--info" ] })
    ; W (Ninja { subcommand = ""; args = [ "-C"; "build" ] })
    ; W (Java { subcommand = "app.Main"; args = [ "--port"; "8080" ] })
    ; W (Javac { subcommand = "src/App.java"; args = [ "-d"; "build/" ] })
    ; W (Mvn { subcommand = "test"; args = [ "-DskipTests=false" ] })
    ; W (Cmake { subcommand = ".."; args = [ "-DCMAKE_BUILD_TYPE=Release" ] })
    ; W (Dune_local_sh { subcommand = "runtest"; args = [ "-f" ] })
    ; W (Osascript { subcommand = "-e"; args = [ "display dialog \"hello\"" ] })
    ; W (Play { subcommand = "recording.wav"; args = [] })
    ; W (Rec { subcommand = "mic.wav"; args = [ "rate"; "44100" ] })
    ; W (Ffplay { subcommand = "clip.mp4"; args = [ "-nodisp"; "-autoexit" ] })
    ; W (Mpg123 { subcommand = "podcast.mp3"; args = [ "-q"; "--list"; "playlist.m3u" ] })
    ; W (Open { subcommand = "https://example.com"; args = [ "-a"; "Safari" ] })
    ; W (Su { subcommand = "root"; args = [ "-c"; "whoami" ] })
    ; W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/zeros"; "bs=1M"; "count=1" ] })
    ; W (Mkfs { subcommand = "-t"; args = [ "ext4"; "/dev/sdc1" ] })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = Shell_ir_typed.to_simple cmd in
       let back = Shell_ir_typed.of_simple simple in
       if not (w = back)
       then Alcotest.failf "of_simple round-trip failed for %a" Shell_ir_typed.pp w)
    cmds
;;

(* PR-4 fallback: anything with env, redirects, Var args, or an
   unhandled binary kind must round-trip through Generic. *)
let test_of_simple_generic_fallback () =
  let base =
    { Shell_ir.bin = bin_ok "true"
    ; args = [ lit "x" ]
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  (* env non-empty *)
  let w_env = Shell_ir_typed.of_simple { base with env = [ "K", lit "V" ] } in
  Alcotest.(check bool)
    "env fallback"
    true
    (match w_env with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false);
  (* redirects non-empty *)
  let w_redir =
    Shell_ir_typed.of_simple
      { base with
        redirects =
          [ Redirect_scope.File
              { fd = 1
              ; target = Path_scope.classify ~raw:"/tmp/x" ~cwd:"/tmp"
              ; mode = Redirect_scope.Write
              }
          ]
      }
  in
  Alcotest.(check bool)
    "redirect fallback"
    true
    (match w_redir with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false);
  (* Var arg *)
  let w_var = Shell_ir_typed.of_simple { base with args = [ Shell_ir.Var ("X", Shell_ir.default_meta) ] } in
  Alcotest.(check bool)
    "var fallback"
    true
    (match w_var with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false);
  (* unknown binary kind — `awk` is NOT in Exec_program.known, must fall through *)
  let w_unknown =
    Shell_ir_typed.of_simple { base with bin = bin_ok "awk"; args = [ lit "{print $1}" ] }
  in
  Alcotest.(check bool)
    "unknown bin fallback"
    true
    (match w_unknown with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false);
  (* git sub-command we do not parse *)
  let w_git_stash =
    Shell_ir_typed.of_simple
      { base with bin = bin_ok "git"; args = [ lit "stash"; lit "pop" ] }
  in
  Alcotest.(check bool)
    "git stash fallback"
    true
    (match w_git_stash with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false)
;;

(* Batch 11: all_wrapped minimal-payload round-trip. Catches regressions
   in subcommand+args parsing when args are empty or minimal. *)
let test_all_wrapped_minimal_round_trip () =
  List.iter
    (fun (Shell_ir_typed.W cmd as w) ->
       (* Generic cannot round-trip (of_simple re-parses into a typed ctor) *)
       match cmd with
       | Shell_ir_typed.Generic _ -> ()
       | _ ->
         let simple = Shell_ir_typed.to_simple cmd in
         let back = Shell_ir_typed.of_simple simple in
         if not (w = back)
         then
           Alcotest.failf
             "all_wrapped minimal round-trip failed for %a@\n  \
              to_simple: bin=%s args=%d@\n  \
              of_simple: %a"
             Shell_ir_typed.pp
             w
             (Exec_program.to_string simple.bin)
             (List.length simple.args)
             Shell_ir_typed.pp
             back)
    all_wrapped
;;

(* Verify that of_simple correctly identifies the binary from a
   Shell_ir.simple produced by to_simple — tests the bin_variant
   dispatch path in the generated parser. *)
let test_bin_variant_dispatch () =
  let open Shell_ir_typed in
  (* For each non-Generic constructor, to_simple should produce a simple
     whose bin matches the expected Exec_program variant. *)
  let cases =
    [ W (Ls { path = None; flags = [] }), "ls"
    ; W (Cat { path = "/dev/null" }), "cat"
    ; W (Rg { pattern = "."; path = None; case_sensitive = false }), "rg"
    ; W (Rm { paths = []; recursive = false; force = false }), "rm"
    ; W (Docker { subcommand = "ps"; args = [] }), "docker"
    ; W (Npm { subcommand = "test"; args = [] }), "npm"
    ; W (Cargo { subcommand = "build"; args = [] }), "cargo"
    ; W (Su { subcommand = "root"; args = [] }), "su"
    ; W (Dd { subcommand = "if=/dev/null"; args = [] }), "dd"
    ; W (Mkfs { subcommand = "-t"; args = [ "ext4"; "/dev/sdb1" ] }), "mkfs"
    ]
  in
  List.iter
    (fun (W cmd, expected_bin) ->
       let simple = to_simple cmd in
       let actual_bin = Exec_program.to_string simple.bin in
       Alcotest.(check string)
         (Printf.sprintf "bin dispatch for %s" expected_bin)
         expected_bin
         actual_bin)
    cases
;;

let test_constructor_names_in_declaration_order () =
  Alcotest.(check (list string))
    "generated names match declaration order"
    [ "Ls"; "Cat"; "Rg"; "Git_status"; "Git_clone"; "Curl"; "Rm"; "Sudo"
    ; "Find"; "Head"; "Tail"; "Grep"; "Mkdir"; "Wc"
    ; "Git_diff"; "Git_log"; "Git_commit"; "Git_push"; "Git_pull"
    ; "Pwd"; "Echo"; "Which"; "Sort"; "Cut"; "Tr"; "Date"
    ; "Env"; "Printenv"; "Uniq"; "Basename"; "Dirname"; "Test"; "Stat"; "Hostname"; "Whoami"
    ; "Du"; "Df"; "File"; "Printf"; "Uname"; "Ps"; "Tty"
    ; "Wget"; "Ssh"; "Scp"; "Tar"; "Make"; "Diff"; "Sed"
    ; "Rsync"; "Node"; "Python"; "Python3"; "Pip"; "Patch"; "Npm"
    ; "Cargo"; "Go"; "Gh"; "Chmod"; "Chown"; "Docker"; "Opam"; "Npx"
    ; "Yarn"; "Pnpm"; "Uv"; "Glab"; "Pytest"; "Terminal_notifier"
    ; "Ruff"; "Pyright"; "Tsc"; "Ocamlfind"; "Rustc"; "Gofmt"; "Gradle"; "Ninja"
    ; "Java"; "Javac"; "Mvn"; "Cmake"; "Dune_local_sh"
    ; "Osascript"; "Play"; "Rec"; "Ffplay"; "Mpg123"; "Open"
    ; "Su"; "Dd"; "Mkfs"
    ; "Generic"
    ]
    Shell_ir_typed_walkers_gen.gen_constructor_names
;;

let () =
  Alcotest.run
    "shell_ir_walkers_gen"
    [ ( "golden_equivalence"
      , [ Alcotest.test_case
            "risk: hand-written = generated"
            `Quick
            test_risk_parallel_equivalence
        ; Alcotest.test_case
            "sandbox: hand-written = generated"
            `Quick
            test_sandbox_parallel_equivalence
        ; Alcotest.test_case
            "to_simple: hand-written = generated"
            `Quick
            test_to_simple_parallel_equivalence
        ] )
    ; ( "of_simple_round_trip"
      , [ Alcotest.test_case "of_simple ∘ to_simple = id" `Quick test_of_simple_round_trip
        ; Alcotest.test_case
            "Generic fallback coverage"
            `Quick
            test_of_simple_generic_fallback
        ; Alcotest.test_case
            "all_wrapped minimal payload round-trip"
            `Quick
            test_all_wrapped_minimal_round_trip
        ; Alcotest.test_case "bin variant dispatch" `Quick test_bin_variant_dispatch
        ] )
    ; ( "spec_invariants"
      , [ Alcotest.test_case "constructor count baseline" `Quick test_constructor_count
        ; Alcotest.test_case
            "constructor names declaration-order"
            `Quick
            test_constructor_names_in_declaration_order
        ] )
    ]
;;
