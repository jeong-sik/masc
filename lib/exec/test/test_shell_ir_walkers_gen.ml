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
  ; W (Git_clone { repo = "x"; branch = None; depth = None })
  ; W (Curl { url = "http://x"; method_ = `GET; headers = None; body = None; output_file = None; follow_redirects = false; insecure = false })
  ; W (Rm { paths = [ "/tmp/x" ]; recursive = false; force = false })
  ; W (Sudo { target_argv = [ "sh"; "-c"; "echo hi" ] })
  ; W (Find { path = "."; name = None; type_ = None; maxdepth = None })
  ; W (Head { path = "/dev/null"; lines = 10 })
  ; W (Tail { path = "/dev/null"; lines = 10 })
  ; W (Grep { pattern = "."; path = None; recursive = false; case_sensitive = false; files_with_matches = false })
  ; W (Mkdir { path = "/tmp/x"; parents = false })
  ; W (Wc { path = "/dev/null"; mode = None })
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
  ; W (Uniq { count = false; duplicates = false; unique = false; skip_fields = None; skip_chars = None; file = None })
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
  ; W (Wget { url = "http://x"; output = None; continue_ = false; no_check_certificate = false })
  ; W (Ssh { host = "x"; user = None; command = None; port = None; identity_file = None })
  ; W (Scp { source = "a"; dest = "b"; recursive = false; port = None })
  ; W (Tar { action = `Create; archive = "x.tar"; paths = []; compression = `None })
  ; W (Make { target = None; jobs = None })
  ; W (Diff { file1 = "a"; file2 = "b"; unified = false; brief = false })
  ; W (Sed { expression = "s/x/y/"; file = "/tmp/x"; in_place = false; extended_regex = false; suppress_output = false })
  ; W (Rsync { source = "/tmp/a"; dest = "/tmp/b"; archive = false; delete = false; dry_run = false; compress = false; flags = [ "-avz" ] })
  ; W (Node { script = "app.js"; args = [ "--port"; "3000" ]; inline = None })
  ; W (Python { script = "main.py"; args = [ "-v" ]; inline = None })
  ; W (Python3 { script = "main.py"; args = [ "-v" ]; inline = None })
  ; W (Pip { subcommand = "install"; packages = [ "requests"; "flask" ] })
  ; W (Patch { file = Some "foo.c"; patchfile = Some "fix.patch"; strip = 1; reverse = false })
  ; W (Npm { subcommand = "install"; save_dev = true; global = false; force = false; rest = [] })
  ; W (Cargo { subcommand = "build"; release = true; verbose = false; features = None; rest = [] })
  ; W (Go { subcommand = "build"; verbose = false; race = false; rest = [ "-o"; "bin" ] })
  ; W (Gh { subcommand = "pr"; action = Some "list"; draft = false; squash = false; delete_branch = false; body = None; title = None; rest = [] })
  ; W (Chmod { mode = "755"; path = "/tmp/x"; recursive = false })
  ; W (Chown { owner = "root"; path = "/tmp/x"; recursive = false })
  ; W (Docker { subcommand = "run"; rm = false; privileged = false; detach = true; rest = [ "nginx" ] })
  ; W (Opam { subcommand = "install"; yes = true; rest = [ "dune" ] })
  ; W (Npx { subcommand = "tsc"; yes = false; rest = [ "--noEmit" ] })
  ; W (Yarn { subcommand = "install"; dev = false; global = false; production = false; frozen_lockfile = true; rest = [] })
  ; W (Pnpm { subcommand = "run"; save_dev = false; global = false; force = false; production = false; rest = [ "build" ] })
  ; W (Uv { subcommand = "pip"; no_cache = false; system = false; rest = [ "install"; "requests" ] })
  ; W (Glab { subcommand = "mr"; yes = false; force = false; rest = [ "list"; "--state"; "opened" ] })
  ; W (Pytest { subcommand = ""; verbose = true; exitfirst = false; rest = [ "tests/" ] })
  ; W (Terminal_notifier { title = "Done"; message = "Build finished" })
  ; W (Ruff { subcommand = "check"; fix = true; show_source = false; rest = [] })
  ; W (Pyright { subcommand = ""; strict = false; rest = [ "--project"; "." ] })
  ; W (Tsc { subcommand = ""; no_emit = true; watch = false; rest = [] })
  ; W (Ocamlfind { subcommand = "list"; args = [ "-desc" ] })
  ; W (Rustc { subcommand = ""; optimize = false; test = false; rest = [ "--edition"; "2021" ] })
  ; W (Gofmt { subcommand = ""; write = true; list_files = false; rest = [ "main.go" ] })
  ; W (Gradle { subcommand = "build"; no_daemon = true; parallel = false; rest = [] })
  ; W (Ninja { subcommand = ""; jobs = Some 4; rest = [] })
  ; W (Java { subcommand = "MyClass"; args = [ "-cp"; "." ] })
  ; W (Javac { subcommand = "Main.java"; args = [ "-d"; "out" ] })
  ; W (Mvn { subcommand = "clean"; offline = false; batch_mode = true; quiet = false; args = [ "install" ] })
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
    ; W (Git_clone { repo = "git@github.com:x/y.git"; branch = Some "main"; depth = Some 1 })
    ; W
        (Curl
           { url = "http://example.com"
           ; method_ = `POST
           ; headers = Some [ "A", "B" ]
           ; body = Some "data"
           ; output_file = Some "/tmp/out"
           ; follow_redirects = true
           ; insecure = true
           })
    ; W (Rm { paths = [ "a"; "b" ]; recursive = true; force = false })
    ; W (Sudo { target_argv = [ "whoami" ] })
    ; W (Find { path = "/tmp"; name = Some "*.ml"; type_ = Some `File; maxdepth = Some 3 })
    ; W (Head { path = "/etc/hosts"; lines = 5 })
    ; W (Tail { path = "/var/log/syslog"; lines = 20 })
    ; W (Grep { pattern = "TODO"; path = Some "lib/"; recursive = true; case_sensitive = false; files_with_matches = true })
    ; W (Mkdir { path = "/tmp/newdir"; parents = true })
    ; W (Wc { path = "README.md"; mode = Some `Words })
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
    ; W (Uniq { count = true; duplicates = false; unique = true; skip_fields = Some 5; skip_chars = Some 3; file = Some "/tmp/x" })
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
    ; W (Wget { url = "http://example.com/file"; output = Some "/tmp/file"; continue_ = true; no_check_certificate = true })
    ; W (Ssh { host = "server"; user = Some "root"; command = Some "uptime"; port = Some 2222; identity_file = Some "id_rsa" })
    ; W (Scp { source = "/tmp/a"; dest = "server:/tmp/b"; recursive = true; port = Some 2222 })
    ; W (Tar { action = `Extract; archive = "x.tar.gz"; paths = [ "a"; "b" ]; compression = `Gzip })
    ; W (Make { target = Some "install"; jobs = Some 4 })
    ; W (Diff { file1 = "old.ml"; file2 = "new.ml"; unified = true; brief = true })
    ; W (Sed { expression = "s/foo/bar/g"; file = "input.txt"; in_place = true; extended_regex = true; suppress_output = true })
    ; W (Rsync { source = "src/"; dest = "dest/"; archive = true; delete = true; dry_run = false; compress = true; flags = [ "-v" ] })
    ; W (Node { script = "server.js"; args = [ "8080" ]; inline = None })
    ; W (Python { script = "train.py"; args = [ "--epochs"; "10" ]; inline = None })
    ; W (Python3 { script = "train.py"; args = [ "--epochs"; "10" ]; inline = None })
    ; W (Node { script = ""; args = [ "--max-old-space-size=4096" ]; inline = Some "console.log(1)" })
    ; W (Python { script = ""; args = []; inline = Some "print('hi')" })
    ; W (Python3 { script = ""; args = [ "-u" ]; inline = Some "import sys; print(sys.version)" })
    ; W (Pip { subcommand = "install"; packages = [ "numpy" ] })
    ; W (Patch { file = None; patchfile = Some "fix.patch"; strip = 0; reverse = true })
    ; W (Npm { subcommand = "run"; save_dev = false; global = false; force = false; rest = [ "build" ] })
    ; W (Cargo { subcommand = "test"; release = false; verbose = false; features = None; rest = [ "--lib" ] })
    ; W (Go { subcommand = "run"; verbose = true; race = false; rest = [ "main.go" ] })
    ; W (Gh { subcommand = "issue"; action = Some "create"; draft = false; squash = false; delete_branch = false; body = None; title = Some "bug"; rest = [] })
    ; W (Chmod { mode = "644"; path = "/etc/config"; recursive = true })
    ; W (Chown { owner = "user:group"; path = "/var/data"; recursive = true })
    ; W (Docker { subcommand = "build"; rm = false; privileged = false; detach = false; rest = [ "-t"; "myapp"; "." ] })
    ; W (Opam { subcommand = "switch"; yes = false; rest = [ "create"; "5.2.0" ] })
    ; W (Npx { subcommand = "jest"; yes = true; rest = [ "--coverage" ] })
    ; W (Yarn { subcommand = "add"; dev = false; global = false; production = false; frozen_lockfile = false; rest = [ "lodash" ] })
    ; W (Pnpm { subcommand = "dev"; save_dev = false; global = false; force = false; production = false; rest = [] })
    ; W (Uv { subcommand = "sync"; no_cache = false; system = false; rest = [] })
    ; W (Glab { subcommand = "ci"; yes = false; force = false; rest = [ "status" ] })
    ; W (Pytest { subcommand = ""; verbose = false; exitfirst = false; rest = [ "--cov" ] })
    ; W (Terminal_notifier { title = "Test"; message = "All passed" })
    ; W (Ruff { subcommand = "format"; fix = false; show_source = false; rest = [ "--check"; "src/" ] })
    ; W (Pyright { subcommand = ""; strict = true; rest = [] })
    ; W (Tsc { subcommand = ""; no_emit = false; watch = false; rest = [ "--project"; "tsconfig.json" ] })
    ; W (Ocamlfind { subcommand = "query"; args = [ "eio" ] })
    ; W (Rustc { subcommand = ""; optimize = true; test = false; rest = [ "src/main.rs" ] })
    ; W (Gofmt { subcommand = ""; write = false; list_files = true; rest = [ "." ] })
    ; W (Gradle { subcommand = "test"; no_daemon = false; parallel = false; rest = [ "--info" ] })
    ; W (Ninja { subcommand = ""; jobs = None; rest = [ "-C"; "build" ] })
    ; W (Java { subcommand = "app.Main"; args = [ "--port"; "8080" ] })
    ; W (Javac { subcommand = "src/App.java"; args = [ "-d"; "build/" ] })
    ; W (Mvn { subcommand = "test"; offline = true; batch_mode = false; quiet = true; args = [ "-DskipTests=false" ] })
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

(* --flag=value parsing robustness: of_simple must handle both
   "--flag value" (two tokens) and "--flag=value" (one token). *)
let test_flag_equals_parsing () =
  let open Shell_ir_typed in
  let base bin_name =
    { Shell_ir.bin = bin_ok bin_name
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  (* Git_clone: --depth=5 --branch=develop *)
  let gc =
    of_simple
      { (base "git") with
        args = [ lit "clone"; lit "--depth=5"; lit "--branch=develop"; lit "repo.git" ]
      }
  in
  (match gc with
   | W (Git_clone { depth = Some 5; branch = Some "develop"; repo = "repo.git"; _ }) -> ()
   | w ->
     Alcotest.failf "Git_clone --flag=value: expected depth=5 branch=develop, got %a" pp w);
  (* Gh: --body=hello --title=world *)
  let gh =
    of_simple
      { (base "gh") with
        args =
          [ lit "pr"; lit "create"; lit "--body=hello world"; lit "--title=my pr"; lit "--draft" ]
      }
  in
  (match gh with
   | W (Gh { subcommand = "pr"; action = Some "create"; body = Some "hello world"; title = Some "my pr"; draft = true; _ }) -> ()
   | w ->
     Alcotest.failf "Gh --flag=value: expected body/title parsed, got %a" pp w);
  (* Curl: --request=POST --data=hello *)
  let curl =
    of_simple
      { (base "curl") with
        args = [ lit "--request=POST"; lit "--data=hello"; lit "http://x" ]
      }
  in
  (match curl with
   | W (Curl { method_ = `POST; body = Some "hello"; url = "http://x"; _ }) -> ()
   | w ->
     Alcotest.failf "Curl --flag=value: expected POST+body, got %a" pp w);
  (* Git_log: --max-count=5 *)
  let gl =
    of_simple { (base "git") with args = [ lit "log"; lit "--max-count=5"; lit "--oneline" ] }
  in
  (match gl with
   | W (Git_log { oneline = true; max_count = Some 5; _ }) -> ()
   | w ->
     Alcotest.failf "Git_log --max-count=5: expected 5, got %a" pp w);
  (* Cargo: --features=serde *)
  let cargo =
    of_simple { (base "cargo") with args = [ lit "build"; lit "--features=serde" ] }
  in
  (match cargo with
   | W (Cargo { subcommand = "build"; features = Some "serde"; _ }) -> ()
   | w ->
     Alcotest.failf "Cargo --flag=value: expected features=serde, got %a" pp w);
  (* Ninja: -j8 with -C build — -C becomes subcommand (first non-flag arg) *)
  let ninja =
    of_simple { (base "ninja") with args = [ lit "-j8"; lit "-C"; lit "build" ] }
  in
  (match ninja with
   | W (Ninja { subcommand = "-C"; jobs = Some 8; rest = [ "build" ]; _ }) -> ()
   | w ->
     Alcotest.failf "Ninja -j8: expected sub=-C jobs=8, got %a" pp w);
  (* Ninja: no flags, just subcommand + rest *)
  let ninja2 =
    of_simple { (base "ninja") with args = [ lit "all"; lit "-C"; lit "build" ] }
  in
  (match ninja2 with
   | W (Ninja { subcommand = "all"; jobs = None; rest = [ "-C"; "build" ]; _ }) -> ()
   | w ->
     Alcotest.failf "Ninja plain: expected sub=all, got %a" pp w);
  (* Cut: --delimiter=: --fields=1,3 *)
  let cut =
    of_simple { (base "cut") with args = [ lit "--delimiter=:"; lit "--fields=1,3"; lit "file.txt" ] }
  in
  (match cut with
   | W (Cut { delimiter = Some ":"; fields = "1,3"; file = Some "file.txt"; _ }) -> ()
   | w ->
     Alcotest.failf "Cut --flag=value: expected d=: f=1,3, got %a" pp w);
  (* Du: --max-depth=2 *)
  let du =
    of_simple { (base "du") with args = [ lit "-h"; lit "--max-depth=2"; lit "/tmp" ] }
  in
  (match du with
   | W (Du { human_readable = true; max_depth = Some 2; path = Some "/tmp"; _ }) -> ()
   | w ->
     Alcotest.failf "Du --max-depth=2: expected depth=2, got %a" pp w);
  (* Wget: --output-document=out.html *)
  let wget =
    of_simple { (base "wget") with args = [ lit "--output-document=out.html"; lit "http://x" ] }
  in
  (match wget with
   | W (Wget { output = Some "out.html"; url = "http://x"; _ }) -> ()
   | w ->
     Alcotest.failf "Wget --output-document=: expected out.html, got %a" pp w);
  (* Sort: --key=3 *)
  let sort =
    of_simple { (base "sort") with args = [ lit "-n"; lit "--key=3"; lit "file.txt" ] }
  in
  (match sort with
   | W (Sort { numeric = true; key = Some 3; file = Some "file.txt"; _ }) -> ()
   | w ->
     Alcotest.failf "Sort --key=3: expected key=3, got %a" pp w);
  (* Find: -maxdepth=3 *)
  let find_md =
    of_simple { (base "find") with args = [ lit "/tmp"; lit "-maxdepth=3"; lit "-name"; lit "*.ml" ] }
  in
  (match find_md with
   | W (Find { path = "/tmp"; name = Some "*.ml"; maxdepth = Some 3; _ }) -> ()
   | w ->
     Alcotest.failf "Find -maxdepth=3: expected maxdepth=3, got %a" pp w)
;;

(* POSIX -- end-of-options handling *)
let test_posix_end_of_options () =
  let open Shell_ir_typed in
  let base bin_name =
    { Shell_ir.bin = bin_ok bin_name
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* Sort: -- -file.txt (file starting with -) *)
  let sort =
    of_simple { (base "sort") with args = [ lit "-n"; lit "--"; lit "-file.txt" ] }
  in
  (match sort with
   | W (Sort { numeric = true; file = Some "-file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sort --: expected file=-file.txt, got %a" pp w);
  (* Grep: -- pattern -file *)
  let grep =
    of_simple { (base "grep") with args = [ lit "-r"; lit "--"; lit "pattern"; lit "-file" ] }
  in
  (match grep with
   | W (Grep { pattern = "pattern"; path = Some "-file"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --: expected pattern+path, got %a" pp w);
  (* Find: -- /tmp -name "*.ml" *)
  let find =
    of_simple { (base "find") with args = [ lit "--"; lit "/tmp"; lit "-name"; lit "*.ml" ] }
  in
  (match find with
   | W (Find { path = "/tmp"; _ }) -> ()
   | w -> Alcotest.failf "Find --: expected path=/tmp, got %a" pp w);
  (* Cut: -- -d: -f1 file.txt — after --, -d: is positional *)
  let cut =
    of_simple { (base "cut") with args = [ lit "-f"; lit "1"; lit "--"; lit "-d:"; lit "file.txt" ] }
  in
  (match cut with
   | W (Cut { fields = "1"; file = Some "-d:"; _ }) -> ()
   | w -> Alcotest.failf "Cut --: expected fields=1 file=-d: (first positional after --), got %a" pp w);
  (* Head: -- -logfile.txt *)
  let head =
    of_simple { (base "head") with args = [ lit "-n"; lit "5"; lit "--"; lit "-logfile.txt" ] }
  in
  (match head with
   | W (Head { path = "-logfile.txt"; lines = 5; _ }) -> ()
   | w -> Alcotest.failf "Head --: expected path=-logfile.txt lines=5, got %a" pp w);
  (* Tail: -- -myfile *)
  let tail =
    of_simple { (base "tail") with args = [ lit "-n"; lit "3"; lit "--"; lit "-myfile" ] }
  in
  (match tail with
   | W (Tail { path = "-myfile"; lines = 3; _ }) -> ()
   | w -> Alcotest.failf "Tail --: expected path=-myfile lines=3, got %a" pp w);
  (* Rm: -- -myfile.txt file.txt (both after -- are paths) *)
  let rm =
    of_simple { (base "rm") with args = [ lit "-r"; lit "-f"; lit "--"; lit "-myfile.txt"; lit "file.txt" ] }
  in
  (match rm with
   | W (Rm { paths; recursive = true; force = true; _ }) when paths = [ "-myfile.txt"; "file.txt" ] -> ()
   | w -> Alcotest.failf "Rm --: expected paths=[-myfile.txt; file.txt], got %a" pp w);
  (* Wc: -- -l-file *)
  let wc =
    of_simple { (base "wc") with args = [ lit "-l"; lit "--"; lit "-l-file" ] }
  in
  (match wc with
   | W (Wc { path = "-l-file"; mode = Some `Lines; _ }) -> ()
   | w -> Alcotest.failf "Wc --: expected path=-l-file mode=Lines, got %a" pp w);
  (* Stat: -- -myfile *)
  let stat =
    of_simple { (base "stat") with args = [ lit "--"; lit "-myfile" ] }
  in
  (match stat with
   | W (Stat { path = "-myfile"; format = None; _ }) -> ()
   | w -> Alcotest.failf "Stat --: expected path=-myfile, got %a" pp w);
  (* Du: -- -mydir *)
  let du =
    of_simple { (base "du") with args = [ lit "-h"; lit "--"; lit "-mydir" ] }
  in
  (match du with
   | W (Du { path = Some "-mydir"; human_readable = true; _ }) -> ()
   | w -> Alcotest.failf "Du --: expected path=-mydir human_readable=true, got %a" pp w);
  (* Df: -- -mypath *)
  let df =
    of_simple { (base "df") with args = [ lit "-h"; lit "--"; lit "-mypath" ] }
  in
  (match df with
   | W (Df { path = Some "-mypath"; human_readable = true; _ }) -> ()
   | w -> Alcotest.failf "Df --: expected path=-mypath human_readable=true, got %a" pp w);
  (* Cat: -- -myfile.txt *)
  let cat =
    of_simple { (base "cat") with args = [ lit "--"; lit "-myfile.txt" ] }
  in
  (match cat with
   | W (Cat { path = "-myfile.txt" }) -> ()
   | w -> Alcotest.failf "Cat --: expected path=-myfile.txt, got %a" pp w);
  (* Ls: -la -- -hidden-dir *)
  let ls =
    of_simple { (base "ls") with args = [ lit "-la"; lit "--"; lit "-hidden-dir" ] }
  in
  (match ls with
   | W (Ls { path = Some "-hidden-dir"; flags; _ }) ->
     if not (List.mem `Long flags && List.mem `All flags)
     then Alcotest.failf "Ls --: expected Long+All flags, got %a" pp ls
   | w -> Alcotest.failf "Ls --: expected path=-hidden-dir, got %a" pp w);
  (* Tr: -- 'a-z' 'A-Z' *)
  let tr =
    of_simple { (base "tr") with args = [ lit "-s"; lit "--"; lit "a-z"; lit "A-Z" ] }
  in
  (match tr with
   | W (Tr { set1 = "a-z"; set2 = Some "A-Z"; squeeze = true; _ }) -> ()
   | w -> Alcotest.failf "Tr --: expected set1=a-z set2=A-Z squeeze=true, got %a" pp w);
  (* File: -- -myfile *)
  let file =
    of_simple { (base "file") with args = [ lit "--"; lit "-myfile" ] }
  in
  (match file with
   | W (File { path = "-myfile"; _ }) -> ()
   | w -> Alcotest.failf "File --: expected path=-myfile, got %a" pp w);
  (* Diff: -- -file1.txt -file2.txt *)
  let diff =
    of_simple { (base "diff") with args = [ lit "-u"; lit "--"; lit "-file1.txt"; lit "-file2.txt" ] }
  in
  (match diff with
   | W (Diff { file1 = "-file1.txt"; file2 = "-file2.txt"; unified = true; _ }) -> ()
   | w -> Alcotest.failf "Diff --: expected file1=-file1.txt file2=-file2.txt unified=true, got %a" pp w);
  (* Chmod: -- 755 -myfile *)
  let chmod =
    of_simple { (base "chmod") with args = [ lit "-R"; lit "--"; lit "755"; lit "-myfile" ] }
  in
  (match chmod with
   | W (Chmod { mode = "755"; path = "-myfile"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Chmod --: expected mode=755 path=-myfile recursive=true, got %a" pp w);
  (* Chown: -- user -myfile *)
  let chown =
    of_simple { (base "chown") with args = [ lit "-R"; lit "--"; lit "user"; lit "-myfile" ] }
  in
  (match chown with
   | W (Chown { owner = "user"; path = "-myfile"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Chown --: expected owner=user path=-myfile recursive=true, got %a" pp w);
  (* Mkdir: -- -newdir *)
  let mkdir =
    of_simple { (base "mkdir") with args = [ lit "-p"; lit "--"; lit "-newdir" ] }
  in
  (match mkdir with
   | W (Mkdir { path = "-newdir"; parents = true; _ }) -> ()
   | w -> Alcotest.failf "Mkdir --: expected path=-newdir parents=true, got %a" pp w);
  (* Basename: -- -file.txt .txt *)
  let basename =
    of_simple { (base "basename") with args = [ lit "--"; lit "-file.txt"; lit ".txt" ] }
  in
  (match basename with
   | W (Basename { path = "-file.txt"; suffix = Some ".txt"; _ }) -> ()
   | w -> Alcotest.failf "Basename --: expected path=-file.txt suffix=.txt, got %a" pp w);
  (* Dirname: -- -path/to/file *)
  let dirname =
    of_simple { (base "dirname") with args = [ lit "--"; lit "-path/to/file" ] }
  in
  (match dirname with
   | W (Dirname { path = "-path/to/file"; _ }) -> ()
   | w -> Alcotest.failf "Dirname --: expected path=-path/to/file, got %a" pp w);
  (* Uniq: -c -- -duplicates.txt *)
  let uniq =
    of_simple { (base "uniq") with args = [ lit "-c"; lit "--"; lit "-duplicates.txt" ] }
  in
  (match uniq with
   | W (Uniq { count = true; file = Some "-duplicates.txt"; _ }) -> ()
   | w -> Alcotest.failf "Uniq --: expected count=true file=-duplicates.txt, got %a" pp w)
;;

(* --lines=N form for Head and Tail *)
let test_lines_equals_form () =
  let open Shell_ir_typed in
  let base bin_name =
    { Shell_ir.bin = bin_ok bin_name
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* Head: --lines=25 file.txt *)
  let head =
    of_simple { (base "head") with args = [ lit "--lines=25"; lit "file.txt" ] }
  in
  (match head with
   | W (Head { path = "file.txt"; lines = 25; _ }) -> ()
   | w -> Alcotest.failf "Head --lines=25: expected lines=25, got %a" pp w);
  (* Tail: --lines=7 /var/log/syslog *)
  let tail =
    of_simple { (base "tail") with args = [ lit "--lines=7"; lit "/var/log/syslog" ] }
  in
  (match tail with
   | W (Tail { path = "/var/log/syslog"; lines = 7; _ }) -> ()
   | w -> Alcotest.failf "Tail --lines=7: expected lines=7, got %a" pp w);
  (* Head: --lines=0 (edge case) *)
  let head0 =
    of_simple { (base "head") with args = [ lit "--lines=0"; lit "f" ] }
  in
  (match head0 with
   | W (Head { lines = 0; _ }) -> ()
   | w -> Alcotest.failf "Head --lines=0: expected lines=0, got %a" pp w)
;;

(* Combined short-flag parsing: -rf → -r + -f *)
let test_combined_short_flags () =
  let open Shell_ir_typed in
  let base bin_name =
    { Shell_ir.bin = bin_ok bin_name
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* rm -rf dir/ *)
  let rm_rf =
    of_simple { (base "rm") with args = [ lit "-rf"; lit "dir/" ] }
  in
  (match rm_rf with
   | W (Rm { paths = [ "dir/" ]; recursive = true; force = true; _ }) -> ()
   | w -> Alcotest.failf "rm -rf: expected recursive+force, got %a" pp w);
  (* rm -fr dir/ *)
  let rm_fr =
    of_simple { (base "rm") with args = [ lit "-fr"; lit "dir/" ] }
  in
  (match rm_fr with
   | W (Rm { paths = [ "dir/" ]; recursive = true; force = true; _ }) -> ()
   | w -> Alcotest.failf "rm -fr: expected recursive+force, got %a" pp w);
  (* rm -rfr dir/ (redundant r) *)
  let rm_rfr =
    of_simple { (base "rm") with args = [ lit "-rfr"; lit "dir/" ] }
  in
  (match rm_rfr with
   | W (Rm { paths = [ "dir/" ]; recursive = true; force = true; _ }) -> ()
   | w -> Alcotest.failf "rm -rfr: expected recursive+force, got %a" pp w);
  (* rm -R dir/ (uppercase R = recursive) *)
  let rm_R =
    of_simple { (base "rm") with args = [ lit "-R"; lit "dir/" ] }
  in
  (match rm_R with
   | W (Rm { paths = [ "dir/" ]; recursive = true; force = false; _ }) -> ()
   | w -> Alcotest.failf "rm -R: expected recursive only, got %a" pp w);
  (* rm -f file.txt (single flag, no combine needed) *)
  let rm_f =
    of_simple { (base "rm") with args = [ lit "-f"; lit "file.txt" ] }
  in
  (match rm_f with
   | W (Rm { paths = [ "file.txt" ]; recursive = false; force = true; _ }) -> ()
   | w -> Alcotest.failf "rm -f: expected force only, got %a" pp w);
  (* rm -rf -f dir/ (combined + separate) *)
  let rm_rf_f =
    of_simple { (base "rm") with args = [ lit "-rf"; lit "-f"; lit "dir/" ] }
  in
  (match rm_rf_f with
   | W (Rm { paths = [ "dir/" ]; recursive = true; force = true; _ }) -> ()
   | w -> Alcotest.failf "rm -rf -f: expected recursive+force, got %a" pp w);
  (* sort -rn file.txt *)
  let sort_rn =
    of_simple { (base "sort") with args = [ lit "-rn"; lit "file.txt" ] }
  in
  (match sort_rn with
   | W (Sort { reverse = true; numeric = true; unique = false; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "sort -rn: expected reverse+numeric, got %a" pp w);
  (* sort -rnu file.txt *)
  let sort_rnu =
    of_simple { (base "sort") with args = [ lit "-rnu"; lit "file.txt" ] }
  in
  (match sort_rnu with
   | W (Sort { reverse = true; numeric = true; unique = true; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "sort -rnu: expected all three, got %a" pp w);
  (* du -hs /tmp *)
  let du_hs =
    of_simple { (base "du") with args = [ lit "-hs"; lit "/tmp" ] }
  in
  (match du_hs with
   | W (Du { path = Some "/tmp"; human_readable = true; summary = true; _ }) -> ()
   | w -> Alcotest.failf "du -hs: expected human_readable+summary, got %a" pp w);
  (* du -sh /tmp *)
  let du_sh =
    of_simple { (base "du") with args = [ lit "-sh"; lit "/tmp" ] }
  in
  (match du_sh with
   | W (Du { path = Some "/tmp"; human_readable = true; summary = true; _ }) -> ()
   | w -> Alcotest.failf "du -sh: expected human_readable+summary, got %a" pp w);
  (* wc -lw file.txt (combined: last wins for mutually exclusive mode) *)
  let wc_lw =
    of_simple { (base "wc") with args = [ lit "-lw"; lit "file.txt" ] }
  in
  (match wc_lw with
   | W (Wc { path = "file.txt"; mode = Some `Words; _ }) -> ()
   | w -> Alcotest.failf "wc -lw: expected mode=Words (last wins), got %a" pp w);
  (* wc -lc file.txt *)
  let wc_lc =
    of_simple { (base "wc") with args = [ lit "-lc"; lit "file.txt" ] }
  in
  (match wc_lc with
   | W (Wc { path = "file.txt"; mode = Some `Chars; _ }) -> ()
   | w -> Alcotest.failf "wc -lc: expected mode=Chars (last wins), got %a" pp w);
  (* wc -lwc file.txt *)
  let wc_lwc =
    of_simple { (base "wc") with args = [ lit "-lwc"; lit "file.txt" ] }
  in
  (match wc_lwc with
   | W (Wc { path = "file.txt"; mode = Some `Chars; _ }) -> ()
   | w -> Alcotest.failf "wc -lwc: expected mode=Chars (last wins), got %a" pp w);
  (* tr -ds 'a-z' 'A-Z' *)
  let tr_ds =
    of_simple { (base "tr") with args = [ lit "-ds"; lit "a-z"; lit "A-Z" ] }
  in
  (match tr_ds with
   | W (Tr { set1 = "a-z"; set2 = Some "A-Z"; delete = true; squeeze = true; _ }) -> ()
   | w -> Alcotest.failf "tr -ds: expected delete+squeeze, got %a" pp w);
  (* tr -sd 'a-z' *)
  let tr_sd =
    of_simple { (base "tr") with args = [ lit "-sd"; lit "a-z" ] }
  in
  (match tr_sd with
   | W (Tr { set1 = "a-z"; set2 = None; delete = true; squeeze = true; _ }) -> ()
   | w -> Alcotest.failf "tr -sd: expected delete+squeeze, got %a" pp w);
  (* uniq -cd file.txt *)
  let uniq_cd =
    of_simple { (base "uniq") with args = [ lit "-cd"; lit "file.txt" ] }
  in
  (match uniq_cd with
   | W (Uniq { count = true; duplicates = true; unique = false; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "uniq -cd: expected count+duplicates, got %a" pp w);
  (* uniq -cu file.txt *)
  let uniq_cu =
    of_simple { (base "uniq") with args = [ lit "-cu"; lit "file.txt" ] }
  in
  (match uniq_cu with
   | W (Uniq { count = true; duplicates = false; unique = true; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "uniq -cu: expected count+unique, got %a" pp w);
  (* uniq -dc file.txt *)
  let uniq_dc =
    of_simple { (base "uniq") with args = [ lit "-dc"; lit "file.txt" ] }
  in
  (match uniq_dc with
   | W (Uniq { count = true; duplicates = true; unique = false; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "uniq -dc: expected duplicates+count, got %a" pp w);
  (* uniq -duc file.txt (all three) *)
  let uniq_duc =
    of_simple { (base "uniq") with args = [ lit "-duc"; lit "file.txt" ] }
  in
  (match uniq_duc with
   | W (Uniq { count = true; duplicates = true; unique = true; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "uniq -duc: expected all three, got %a" pp w);
  (* rsync -az src dst *)
  let rsync_az =
    of_simple { (base "rsync") with args = [ lit "-az"; lit "src/"; lit "dst/" ] }
  in
  (match rsync_az with
   | W (Rsync { archive = true; compress = true; dry_run = false; _ }) -> ()
   | w -> Alcotest.failf "rsync -az: expected archive+compress, got %a" pp w);
  (* rsync -anz src dst *)
  let rsync_anz =
    of_simple { (base "rsync") with args = [ lit "-anz"; lit "src/"; lit "dst/" ] }
  in
  (match rsync_anz with
   | W (Rsync { archive = true; dry_run = true; compress = true; _ }) -> ()
   | w -> Alcotest.failf "rsync -anz: expected archive+dry_run+compress, got %a" pp w);
  (* curl -Lk url *)
  let curl_lk =
    of_simple { (base "curl") with args = [ lit "-Lk"; lit "https://example.com" ] }
  in
  (match curl_lk with
   | W (Curl { follow_redirects = true; insecure = true; _ }) -> ()
   | w -> Alcotest.failf "curl -Lk: expected follow_redirects+insecure, got %a" pp w);
  (* curl -kL url *)
  let curl_kl =
    of_simple { (base "curl") with args = [ lit "-kL"; lit "https://example.com" ] }
  in
  (match curl_kl with
   | W (Curl { follow_redirects = true; insecure = true; _ }) -> ()
   | w -> Alcotest.failf "curl -kL: expected follow_redirects+insecure, got %a" pp w);
  (* git push -fu origin main *)
  let git_fu =
    of_simple { (base "git") with args = [ lit "push"; lit "-fu"; lit "origin"; lit "main" ] }
  in
  (match git_fu with
   | W (Git_push { force = true; set_upstream = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push -fu: expected force+set_upstream, got %a" pp w);
  (* git push -uf origin main *)
  let git_uf =
    of_simple { (base "git") with args = [ lit "push"; lit "-uf"; lit "origin"; lit "main" ] }
  in
  (match git_uf with
   | W (Git_push { force = true; set_upstream = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push -uf: expected force+set_upstream, got %a" pp w);
  (* scp -rCv src dst *)
  let scp_rcv =
    of_simple { (base "scp") with args = [ lit "-rCv"; lit "src"; lit "dst" ] }
  in
  (match scp_rcv with
   | W (Scp { recursive = true; _ }) -> ()
   | w -> Alcotest.failf "scp -rCv: expected recursive, got %a" pp w);
  (* scp -Cvr src dst *)
  let scp_cvr =
    of_simple { (base "scp") with args = [ lit "-Cvr"; lit "src"; lit "dst" ] }
  in
  (match scp_cvr with
   | W (Scp { recursive = true; _ }) -> ()
   | w -> Alcotest.failf "scp -Cvr: expected recursive, got %a" pp w);
  (* diff -uq file1 file2 *)
  let diff_uq =
    of_simple { (base "diff") with args = [ lit "-uq"; lit "a.txt"; lit "b.txt" ] }
  in
  (match diff_uq with
   | W (Diff { unified = true; brief = true; _ }) -> ()
   | w -> Alcotest.failf "diff -uq: expected unified+brief, got %a" pp w);
  (* diff -qu file1 file2 *)
  let diff_qu =
    of_simple { (base "diff") with args = [ lit "-qu"; lit "a.txt"; lit "b.txt" ] }
  in
  (match diff_qu with
   | W (Diff { unified = true; brief = true; _ }) -> ()
   | w -> Alcotest.failf "diff -qu: expected unified+brief, got %a" pp w)
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

(* TEL-OK: test-only function; no runtime telemetry required. *)
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
    ; W (Docker { subcommand = "ps"; rm = false; privileged = false; detach = false; rest = [] }), "docker"
    ; W (Npm { subcommand = "test"; save_dev = false; global = false; force = false; rest = [] }), "npm"
    ; W (Cargo { subcommand = "build"; release = false; verbose = false; features = None; rest = [] }), "cargo"
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
        ; Alcotest.test_case "--flag=value parsing robustness" `Quick test_flag_equals_parsing
        ; Alcotest.test_case "POSIX -- end-of-options" `Quick test_posix_end_of_options
        ; Alcotest.test_case "--lines=N form" `Quick test_lines_equals_form
        ; Alcotest.test_case "combined short flags" `Quick test_combined_short_flags
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
