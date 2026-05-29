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
  ; W (Go { subcommand = "build"; verbose = false; race = false; rest = [ "./..." ] })
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
  ; W (Pyright { subcommand = ""; strict = false; rest = [] })
  ; W (Tsc { subcommand = ""; no_emit = true; watch = false; rest = [] })
  ; W (Ocamlfind { subcommand = "list"; args = [ "-desc" ] })
  ; W (Rustc { subcommand = ""; optimize = false; test = false; rest = [ "src/main.rs" ] })
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
  ; W (Mkfs { subcommand = "/dev/sdb1"; args = [] })
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
  (* Baseline: 93 constructors as of 2026-05-29. If this fails, either
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
    ; W (Node { script = ""; args = [ "--verbose" ]; inline = Some "console.log(1)" })
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
    ; W (Tsc { subcommand = "build"; no_emit = false; watch = false; rest = [ "src/" ] })
    ; W (Ocamlfind { subcommand = "query"; args = [ "eio" ] })
    ; W (Rustc { subcommand = ""; optimize = true; test = false; rest = [ "src/main.rs" ] })
    ; W (Gofmt { subcommand = ""; write = false; list_files = true; rest = [ "." ] })
    ; W (Gradle { subcommand = "test"; no_daemon = false; parallel = false; rest = [ "--info" ] })
    ; W (Ninja { subcommand = "build"; jobs = None; rest = [] })
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
    ; W (Su { subcommand = "root"; args = [ "whoami" ] })
    ; W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/zeros"; "bs=1M"; "count=1" ] })
    ; W (Mkfs { subcommand = "/dev/sdc1"; args = [] })
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
  (* Curl: --header=Content-Type:application/json *)
  let curl_h =
    of_simple
      { (base "curl") with
        args =
          [ lit "--header=Content-Type:application/json"; lit "-X"; lit "POST"; lit "http://x" ]
      }
  in
  (match curl_h with
   | W (Curl { headers = Some [ ("Content-Type", "application/json") ]; method_ = `POST; _ }) ->
     ()
   | w ->
     Alcotest.failf "Curl --header=value: expected header parsed, got %a" pp w);
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
  (* Ninja: -j8 with -C build — -C is value-consuming flag, "build" passes through to become subcommand *)
  let ninja =
    of_simple { (base "ninja") with args = [ lit "-j8"; lit "-C"; lit "build" ] }
  in
  (match ninja with
   | W (Ninja { subcommand = "build"; jobs = Some 8; rest = []; _ }) -> ()
   | w ->
     Alcotest.failf "Ninja -j8 -C build: expected sub=build jobs=8, got %a" pp w);
  (* Ninja: subcommand + -C build — -C build is discarded, rest=[] *)
  let ninja2 =
    of_simple { (base "ninja") with args = [ lit "all"; lit "-C"; lit "build" ] }
  in
  (match ninja2 with
   | W (Ninja { subcommand = "all"; jobs = None; rest = [ "build" ]; _ }) -> ()
   | w ->
     Alcotest.failf "Ninja all -C build: expected sub=all rest=[build], got %a" pp w);
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
  (* Grep: -e -dashed-pattern (explicit pattern flag) *)
  let grep_e =
    of_simple { (base "grep") with args = [ lit "-r"; lit "-e"; lit "-dashed-pattern"; lit "." ] }
  in
  (match grep_e with
   | W (Grep { pattern = "-dashed-pattern"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep -e: expected pattern=-dashed-pattern, got %a" pp w);
  (* Grep: --color=auto pattern file (--flag=VALUE form skipped) *)
  let grep_color =
    of_simple { (base "grep") with args = [ lit "--color=auto"; lit "pattern"; lit "file" ] }
  in
  (match grep_color with
   | W (Grep { pattern = "pattern"; path = Some "file"; _ }) -> ()
   | w -> Alcotest.failf "Grep --color=auto: expected pattern=path, got %a" pp w);
  (* Grep: -elongpattern file (combined -ePATTERN form, length>4 so no expansion) *)
  let grep_epat =
    of_simple { (base "grep") with args = [ lit "-elongpattern"; lit "file" ] }
  in
  (match grep_epat with
   | W (Grep { pattern = "longpattern"; path = Some "file"; _ }) -> ()
   | w -> Alcotest.failf "Grep -ePATTERN: expected pattern=longpattern, got %a" pp w);
  (* Grep: --include=*.ml pattern dir (--flag=VALUE form skipped, = present) *)
  let grep_include_eq =
    of_simple { (base "grep") with args = [ lit "-r"; lit "--include=*.ml"; lit "pattern"; lit "dir" ] }
  in
  (match grep_include_eq with
   | W (Grep { pattern = "pattern"; path = Some "dir"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --include=VALUE: expected pattern=path, got %a" pp w);
  (* Grep: --include *.ml pattern dir (two-token value-consuming flag) *)
  let grep_include_2tok =
    of_simple { (base "grep") with args = [ lit "-r"; lit "--include"; lit "*.ml"; lit "pattern"; lit "dir" ] }
  in
  (match grep_include_2tok with
   | W (Grep { pattern = "pattern"; path = Some "dir"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --include VALUE: expected pattern=path, got %a" pp w);
  (* Grep: --exclude *.log pattern dir (two-token value-consuming flag) *)
  let grep_exclude =
    of_simple { (base "grep") with args = [ lit "-r"; lit "--exclude"; lit "*.log"; lit "pattern"; lit "dir" ] }
  in
  (match grep_exclude with
   | W (Grep { pattern = "pattern"; path = Some "dir"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --exclude VALUE: expected pattern=path, got %a" pp w);
  (* Grep: --exclude-dir .git pattern dir (two-token value-consuming flag) *)
  let grep_excludedir =
    of_simple { (base "grep") with args = [ lit "-r"; lit "--exclude-dir"; lit ".git"; lit "pattern"; lit "dir" ] }
  in
  (match grep_excludedir with
   | W (Grep { pattern = "pattern"; path = Some "dir"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --exclude-dir VALUE: expected pattern=path, got %a" pp w);
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
   | w -> Alcotest.failf "Uniq --: expected count=true file=-duplicates.txt, got %a" pp w);
  (* Tar: -czf archive.tar.gz -- file1.txt file2.txt *)
  let tar =
    of_simple { (base "tar") with args = [ lit "-czf"; lit "archive.tar.gz"; lit "--"; lit "file1.txt"; lit "file2.txt" ] }
  in
  (match tar with
   | W (Tar { action = `Create; compression = `Gzip; archive = "archive.tar.gz"; paths = [ "file1.txt"; "file2.txt" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --: expected Create Gzip archive.tar.gz paths=[file1.txt;file2.txt], got %a" pp w);
  (* Tar: -x --file=archive.tar (equal-sign form) *)
  let tar_file_eq =
    of_simple { (base "tar") with args = [ lit "-x"; lit "--file=archive.tar" ] }
  in
  (match tar_file_eq with
   | W (Tar { action = `Extract; archive = "archive.tar"; compression = `None; _ }) -> ()
   | w -> Alcotest.failf "Tar --file=: expected Extract archive.tar, got %a" pp w);
  (* Tar: -cfarchive.tar.gz --gzip src (combined -cf + --gzip long form) *)
  let tar_gzip_long =
    of_simple { (base "tar") with args = [ lit "-cfarchive.tar.gz"; lit "--gzip"; lit "src" ] }
  in
  (match tar_gzip_long with
   | W (Tar { action = `Create; compression = `Gzip; archive = "archive.tar.gz"; paths = [ "src" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --gzip: expected Create Gzip archive.tar.gz, got %a" pp w);
  (* Tar: -x --file archive.tar (two-token --file form) *)
  let tar_file_two =
    of_simple { (base "tar") with args = [ lit "-x"; lit "--file"; lit "archive.tar" ] }
  in
  (match tar_file_two with
   | W (Tar { action = `Extract; archive = "archive.tar"; _ }) -> ()
   | w -> Alcotest.failf "Tar --file: expected Extract archive.tar, got %a" pp w);
  (* Make: -- install *)
  let make =
    of_simple { (base "make") with args = [ lit "--"; lit "install" ] }
  in
  (match make with
   | W (Make { target = Some "install"; _ }) -> ()
   | w -> Alcotest.failf "Make --: expected target=Some install, got %a" pp w);
  (* Make: -- -target (dash-prefixed positional after --) *)
  let make_dash =
    of_simple { (base "make") with args = [ lit "-j"; lit "4"; lit "--"; lit "-target" ] }
  in
  (match make_dash with
   | W (Make { target = Some "-target"; jobs = Some 4; _ }) -> ()
   | w -> Alcotest.failf "Make -- -target: expected target=-target jobs=4, got %a" pp w);
  (* Wget: -- https://example.com/file *)
  let wget =
    of_simple { (base "wget") with args = [ lit "--"; lit "https://example.com/file" ] }
  in
  (match wget with
   | W (Wget { url = "https://example.com/file"; _ }) -> ()
   | w -> Alcotest.failf "Wget --: expected url=https://example.com/file, got %a" pp w);
  (* Wget: -O out -- -file.txt (dash-prefixed positional after --) *)
  let wget_dash =
    of_simple { (base "wget") with args = [ lit "-O"; lit "out"; lit "--"; lit "-file.txt" ] }
  in
  (match wget_dash with
   | W (Wget { url = "-file.txt"; output = Some "out"; _ }) -> ()
   | w -> Alcotest.failf "Wget -- -file: expected url=-file.txt output=out, got %a" pp w);
  (* Scp: -- -src/file -dest/file *)
  let scp =
    of_simple { (base "scp") with args = [ lit "-r"; lit "--"; lit "-src/file"; lit "-dest/file" ] }
  in
  (match scp with
   | W (Scp { source = "-src/file"; dest = "-dest/file"; recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Scp --: expected source=-src/file dest=-dest/file recursive=true, got %a" pp w);
  (* Scp: -P2222 src dst (combined port form) *)
  let scp_p =
    of_simple { (base "scp") with args = [ lit "-P2222"; lit "src"; lit "dst" ] }
  in
  (match scp_p with
   | W (Scp { source = "src"; dest = "dst"; port = Some 2222; _ }) -> ()
   | w -> Alcotest.failf "Scp -P2222: expected port=2222, got %a" pp w);
  (* Ssh: -- -host echo hello *)
  let ssh =
    of_simple { (base "ssh") with args = [ lit "--"; lit "-host"; lit "echo"; lit "hello" ] }
  in
  (match ssh with
   | W (Ssh { host = "-host"; command = Some "echo hello"; _ }) -> ()
   | w -> Alcotest.failf "Ssh --: expected host=-host command=echo hello, got %a" pp w);
  (* Ssh: -p22 user@host (combined port form) *)
  let ssh_p22 =
    of_simple { (base "ssh") with args = [ lit "-p22"; lit "user@host"; lit "uptime" ] }
  in
  (match ssh_p22 with
   | W (Ssh { host = "host"; user = Some "user"; port = Some 22; command = Some "uptime"; _ }) -> ()
   | w -> Alcotest.failf "Ssh -p22: expected port=22, got %a" pp w);
  (* Sed: -- s/a/b/ -file.txt *)
  let sed =
    of_simple { (base "sed") with args = [ lit "-n"; lit "--"; lit "s/a/b/"; lit "-file.txt" ] }
  in
  (match sed with
   | W (Sed { expression = "s/a/b/"; file = "-file.txt"; suppress_output = true; _ }) -> ()
   | w -> Alcotest.failf "Sed --: expected expr=s/a/b/ file=-file.txt suppress=true, got %a" pp w);
  (* Rg: -i -- pattern -file.txt *)
  let rg =
    of_simple { (base "rg") with args = [ lit "-i"; lit "--"; lit "pattern"; lit "-file.txt" ] }
  in
  (match rg with
   | W (Rg { pattern = "pattern"; path = Some "-file.txt"; case_sensitive = false; _ }) -> ()
   | w -> Alcotest.failf "Rg --: expected pattern=path path=-file.txt case_sensitive=false, got %a" pp w);
  (* Git_clone: --depth 1 -- -repo-name *)
  let git_clone =
    of_simple { (base "git") with args = [ lit "clone"; lit "--depth"; lit "1"; lit "--"; lit "-repo-name" ] }
  in
  (match git_clone with
   | W (Git_clone { repo = "-repo-name"; depth = Some 1; _ }) -> ()
   | w -> Alcotest.failf "Git_clone --: expected repo=-repo-name depth=1, got %a" pp w);
  (* Curl: -L -- -url-path *)
  let curl =
    of_simple { (base "curl") with args = [ lit "-L"; lit "--"; lit "-url-path" ] }
  in
  (match curl with
   | W (Curl { url = "-url-path"; follow_redirects = true; _ }) -> ()
   | w -> Alcotest.failf "Curl --: expected url=-url-path follow_redirects=true, got %a" pp w);
  (* Git_commit: -m msg -- -file (after --, args are ignored) *)
  let git_commit =
    of_simple { (base "git") with args = [ lit "commit"; lit "-m"; lit "msg"; lit "--"; lit "-file" ] }
  in
  (match git_commit with
   | W (Git_commit { message = "msg"; _ }) -> ()
   | w -> Alcotest.failf "Git_commit --: expected message=msg, got %a" pp w);
  (* Git_push: -f -- origin main *)
  let git_push =
    of_simple { (base "git") with args = [ lit "push"; lit "-f"; lit "--"; lit "origin"; lit "main" ] }
  in
  (match git_push with
   | W (Git_push { force = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "Git_push --: expected force=true remote=origin branch=main, got %a" pp w);
  (* Git_pull: --rebase -- origin main *)
  let git_pull =
    of_simple { (base "git") with args = [ lit "pull"; lit "--rebase"; lit "--"; lit "origin"; lit "main" ] }
  in
  (match git_pull with
   | W (Git_pull { rebase = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "Git_pull --: expected rebase=true remote=origin branch=main, got %a" pp w);
  (* Git_diff: --stat -- -file1 -file2 *)
  let git_diff =
    of_simple { (base "git") with args = [ lit "diff"; lit "--stat"; lit "--"; lit "-file1"; lit "-file2" ] }
  in
  (match git_diff with
   | W (Git_diff { stat = true; paths = [ "-file1"; "-file2" ]; _ }) -> ()
   | w -> Alcotest.failf "Git_diff --: expected stat=true paths=[-file1;-file2], got %a" pp w);
  (* Date: -u -- +%Y-%m-%d *)
  let date =
    of_simple { (base "date") with args = [ lit "-u"; lit "--"; lit "+%Y-%m-%d" ] }
  in
  (match date with
   | W (Date { format = Some "+%Y-%m-%d"; utc = true; _ }) -> ()
   | w -> Alcotest.failf "Date --: expected format=+%%Y-%%m-%%d utc=true, got %a" pp w);
  (* Hostname: -s -- *)
  let hostname =
    of_simple { (base "hostname") with args = [ lit "-s"; lit "--" ] }
  in
  (match hostname with
   | W (Hostname { short = true; _ }) -> ()
   | w -> Alcotest.failf "Hostname --: expected short=true, got %a" pp w);
  (* Uname: -a -- *)
  let uname =
    of_simple { (base "uname") with args = [ lit "-a"; lit "--" ] }
  in
  (match uname with
   | W (Uname { all = true; _ }) -> ()
   | w -> Alcotest.failf "Uname --: expected all=true, got %a" pp w);
  (* Ps: -ef -- *)
  let ps =
    of_simple { (base "ps") with args = [ lit "-ef"; lit "--" ] }
  in
  (match ps with
   | W (Ps { all = true; full = true; _ }) -> ()
   | w -> Alcotest.failf "Ps --: expected all=true full=true, got %a" pp w);
  (* Gh: pr create --draft -- --extra-flag *)
  let gh =
    of_simple { (base "gh") with args = [ lit "pr"; lit "create"; lit "--draft"; lit "--"; lit "--extra-flag" ] }
  in
  (match gh with
   | W (Gh { subcommand = "pr"; action = Some "create"; draft = true; rest; _ }) ->
     if not (List.mem "--extra-flag" rest)
     then Alcotest.failf "Gh --: expected --extra-flag in rest, got rest=[%s]" (String.concat "; " rest)
   | w -> Alcotest.failf "Gh --: expected subcommand=pr action=create draft=true, got %a" pp w)
;;

(* Rg: value-consuming flags (--type, --glob, --max-depth, etc.) *)
let test_rg_value_consuming_flags () =
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
  (* rg --type py pattern — pattern should be "pattern", not "py" *)
  let rg_type =
    of_simple { (base "rg") with args = [ lit "--type"; lit "py"; lit "pattern" ] }
  in
  (match rg_type with
   | W (Rg { pattern = "pattern"; case_sensitive = true; _ }) -> ()
   | w -> Alcotest.failf "Rg --type: expected pattern=pattern, got %a" pp w);
  (* rg --glob '*.ml' pattern path *)
  let rg_glob =
    of_simple { (base "rg") with args = [ lit "--glob"; lit "*.ml"; lit "pattern"; lit "src" ] }
  in
  (match rg_glob with
   | W (Rg { pattern = "pattern"; path = Some "src"; _ }) -> ()
   | w -> Alcotest.failf "Rg --glob: expected pattern=pattern path=src, got %a" pp w);
  (* rg --max-depth 3 pattern *)
  let rg_depth =
    of_simple { (base "rg") with args = [ lit "--max-depth"; lit "3"; lit "pattern" ] }
  in
  (match rg_depth with
   | W (Rg { pattern = "pattern"; _ }) -> ()
   | w -> Alcotest.failf "Rg --max-depth: expected pattern=pattern, got %a" pp w);
  (* rg -C 5 pattern — short flag value-consuming *)
  let rg_context =
    of_simple { (base "rg") with args = [ lit "-C"; lit "5"; lit "pattern" ] }
  in
  (match rg_context with
   | W (Rg { pattern = "pattern"; _ }) -> ()
   | w -> Alcotest.failf "Rg -C: expected pattern=pattern, got %a" pp w);
  (* rg --type=py pattern — --flag=VALUE form *)
  let rg_type_eq =
    of_simple { (base "rg") with args = [ lit "--type=py"; lit "pattern" ] }
  in
  (match rg_type_eq with
   | W (Rg { pattern = "pattern"; _ }) -> ()
   | w -> Alcotest.failf "Rg --type=py: expected pattern=pattern, got %a" pp w);
  (* rg -i --type py pattern — combined: ignore-case + type + pattern *)
  let rg_combined =
    of_simple { (base "rg") with args = [ lit "-i"; lit "--type"; lit "py"; lit "pattern"; lit "src" ] }
  in
  (match rg_combined with
   | W (Rg { pattern = "pattern"; path = Some "src"; case_sensitive = false; _ }) -> ()
   | w -> Alcotest.failf "Rg -i --type py: expected pattern=pattern path=src case_sensitive=false, got %a" pp w)
;;

let test_wget_value_consuming_flags () =
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
  (* wget --header "Accept: text/html" URL — header value should not become URL *)
  let w1 =
    of_simple { (base "wget") with args = [ lit "--header"; lit "Accept: text/html"; lit "https://example.com" ] }
  in
  (match w1 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --header: expected url=example.com, got %a" pp w);
  (* wget --timeout 30 URL — timeout value should be skipped *)
  let w2 =
    of_simple { (base "wget") with args = [ lit "--timeout"; lit "30"; lit "https://example.com" ] }
  in
  (match w2 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --timeout: expected url=example.com, got %a" pp w);
  (* wget --user agent --password secret URL — both value flags skipped *)
  let w3 =
    of_simple { (base "wget") with args = [ lit "--user"; lit "agent"; lit "--password"; lit "secret"; lit "https://example.com" ] }
  in
  (match w3 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --user --password: expected url=example.com, got %a" pp w);
  (* wget -A '*.html' URL — short flag value-consuming *)
  let w4 =
    of_simple { (base "wget") with args = [ lit "-A"; lit "*.html"; lit "https://example.com" ] }
  in
  (match w4 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget -A: expected url=example.com, got %a" pp w);
  (* wget -c --tries 3 -O out.html URL — combined boolean + value + output *)
  let w5 =
    of_simple { (base "wget") with args = [ lit "-c"; lit "--tries"; lit "3"; lit "-O"; lit "out.html"; lit "https://example.com" ] }
  in
  (match w5 with
   | W (Wget { url = "https://example.com"; output = Some "out.html"; continue_ = true; _ }) -> ()
   | w -> Alcotest.failf "Wget combined: expected url=example.com output=out.html continue_=true, got %a" pp w)
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

(* --jobs=N and --jobs VALUE form for Make and Ninja *)
let test_jobs_equals_form () =
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
  (* Make: --jobs=8 target *)
  let make =
    of_simple { (base "make") with args = [ lit "--jobs=8"; lit "all" ] }
  in
  (match make with
   | W (Make { target = Some "all"; jobs = Some 8; _ }) -> ()
   | w -> Alcotest.failf "Make --jobs=8: expected jobs=8, got %a" pp w);
  (* Make: --jobs 4 target *)
  let make2 =
    of_simple { (base "make") with args = [ lit "--jobs"; lit "4"; lit "test" ] }
  in
  (match make2 with
   | W (Make { target = Some "test"; jobs = Some 4; _ }) -> ()
   | w -> Alcotest.failf "Make --jobs 4: expected jobs=4, got %a" pp w);
  (* Ninja: --jobs=16 subcommand *)
  let ninja =
    of_simple { (base "ninja") with args = [ lit "--jobs=16"; lit "build" ] }
  in
  (match ninja with
   | W (Ninja { subcommand = "build"; jobs = Some 16; _ }) -> ()
   | w -> Alcotest.failf "Ninja --jobs=16: expected jobs=16, got %a" pp w);
  (* Ninja: --jobs 2 subcommand *)
  let ninja2 =
    of_simple { (base "ninja") with args = [ lit "--jobs"; lit "2"; lit "test" ] }
  in
  (match ninja2 with
   | W (Ninja { subcommand = "test"; jobs = Some 2; _ }) -> ()
   | w -> Alcotest.failf "Ninja --jobs 2: expected jobs=2, got %a" pp w)
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
   | w -> Alcotest.failf "diff -qu: expected unified+brief, got %a" pp w);
  (* git commit -am "message" *)
  let git_am =
    of_simple { (base "git") with args = [ lit "commit"; lit "-am"; lit "Initial commit" ] }
  in
  (match git_am with
   | W (Git_commit { message = "Initial commit"; amend = true; _ }) -> ()
   | w -> Alcotest.failf "git commit -am: expected message+amend, got %a" pp w);
  (* git commit -ma "message" *)
  let git_ma =
    of_simple { (base "git") with args = [ lit "commit"; lit "-ma"; lit "Fix bug" ] }
  in
  (match git_ma with
   | W (Git_commit { message = "Fix bug"; amend = true; _ }) -> ()
   | w -> Alcotest.failf "git commit -ma: expected message+amend, got %a" pp w)
;;

let test_git_push_value_consuming_flags () =
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
  (* git push --repo upstream main — --repo consumes "upstream" as value, "main" becomes remote *)
  let w1 =
    of_simple { (base "git") with args = [ lit "push"; lit "--repo"; lit "upstream"; lit "main" ] }
  in
  (match w1 with
   | W (Git_push { remote = Some "main"; branch = None; _ }) -> ()
   | w -> Alcotest.failf "git push --repo upstream main: expected remote=main branch=None, got %a" pp w);
  (* git push --set-upstream-to origin/main — should not become remote *)
  let w2 =
    of_simple { (base "git") with args = [ lit "push"; lit "--set-upstream-to"; lit "origin/main"; lit "origin"; lit "main" ] }
  in
  (match w2 with
   | W (Git_push { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push --set-upstream-to: expected origin main, got %a" pp w);
  (* git push --force-with-lease=origin/main — = form should be skipped *)
  let w3 =
    of_simple { (base "git") with args = [ lit "push"; lit "--force-with-lease=origin/main"; lit "origin"; lit "main" ] }
  in
  (match w3 with
   | W (Git_push { force_with_lease = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push --force-with-lease=: expected force_with_lease, got %a" pp w);
  (* git push -o ci.skip origin main — -o consumes "ci.skip" *)
  let w4 =
    of_simple { (base "git") with args = [ lit "push"; lit "-o"; lit "ci.skip"; lit "origin"; lit "main" ] }
  in
  (match w4 with
   | W (Git_push { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push -o ci.skip: expected origin main, got %a" pp w);
  (* git push --tags --dry-run origin — boolean + boolean + value flag *)
  let w5 =
    of_simple { (base "git") with args = [ lit "push"; lit "--tags"; lit "--dry-run"; lit "origin" ] }
  in
  (match w5 with
   | W (Git_push { remote = Some "origin"; branch = None; _ }) -> ()
   | w -> Alcotest.failf "git push --tags --dry-run origin: expected origin, got %a" pp w)
;;

let test_git_pull_value_consuming_flags () =
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
  (* git pull --repo upstream main — --repo consumes "upstream", "main" becomes remote *)
  let w1 =
    of_simple { (base "git") with args = [ lit "pull"; lit "--repo"; lit "upstream"; lit "main" ] }
  in
  (match w1 with
   | W (Git_pull { remote = Some "main"; branch = None; _ }) -> ()
   | w -> Alcotest.failf "git pull --repo upstream main: expected remote=main branch=None, got %a" pp w);
  (* git pull --depth 1 origin main — --depth consumes "1" *)
  let w2 =
    of_simple { (base "git") with args = [ lit "pull"; lit "--depth"; lit "1"; lit "origin"; lit "main" ] }
  in
  (match w2 with
   | W (Git_pull { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git pull --depth 1: expected origin main, got %a" pp w);
  (* git pull --rebase origin main — --rebase is boolean, not value-consuming *)
  let w3 =
    of_simple { (base "git") with args = [ lit "pull"; lit "--rebase"; lit "origin"; lit "main" ] }
  in
  (match w3 with
   | W (Git_pull { rebase = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git pull --rebase: expected rebase=true origin main, got %a" pp w)
;;

let test_git_log_value_consuming_flags () =
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
  (* git log --format="%h %s" — --format consumes the format string *)
  let w1 =
    of_simple { (base "git") with args = [ lit "log"; lit "--format"; lit "%h %s" ] }
  in
  (match w1 with
   | W (Git_log { oneline = false; max_count = None; _ }) -> ()
   | w -> Alcotest.failf "git log --format: expected defaults, got %a" pp w);
  (* git log --since="2026-01-01" --author="user" — two value flags *)
  let w2 =
    of_simple { (base "git") with args = [ lit "log"; lit "--since"; lit "2026-01-01"; lit "--author"; lit "user" ] }
  in
  (match w2 with
   | W (Git_log { oneline = false; max_count = None; _ }) -> ()
   | w -> Alcotest.failf "git log --since --author: expected defaults, got %a" pp w);
  (* git log --oneline -n5 --format=medium — oneline + max_count + = form *)
  let w3 =
    of_simple { (base "git") with args = [ lit "log"; lit "--oneline"; lit "-n5"; lit "--format=medium" ] }
  in
  (match w3 with
   | W (Git_log { oneline = true; max_count = Some 5; _ }) -> ()
   | w -> Alcotest.failf "git log --oneline -n5 --format=medium: expected oneline max_count=5, got %a" pp w)
;;

(* Batch 12: value-consuming flags for Docker, Go, Cargo, Npm, Mvn, Gradle *)
let test_batch12_value_consuming_flags () =
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
  (* Docker: --name myapp → name parsed, --env FOO=bar → env parsed *)
  let d1 =
    of_simple { (base "docker") with args = [ lit "run"; lit "--name"; lit "myapp"; lit "img" ] }
  in
  (match d1 with
   | W (Docker { subcommand = "run"; rest; _ }) ->
     if List.exists ((=) "myapp") rest then
       Alcotest.failf "Docker --name myapp: 'myapp' should be consumed, not in rest (%a)" pp d1
   | w -> Alcotest.failf "Docker run --name myapp: expected Docker, got %a" pp w);
  (* Docker: --flag=VALUE form *)
  let d2 =
    of_simple { (base "docker") with args = [ lit "run"; lit "--name=myapp"; lit "img" ] }
  in
  (match d2 with
   | W (Docker { subcommand = "run"; rest; _ }) ->
     if List.exists ((=) "myapp") rest then
       Alcotest.failf "Docker --name=myapp: 'myapp' should be consumed (%a)" pp d2
   | w -> Alcotest.failf "Docker --name=myapp: expected Docker, got %a" pp w);
  (* Go: -o bin → consumed, rest empty *)
  let g1 =
    of_simple { (base "go") with args = [ lit "build"; lit "-o"; lit "bin"; lit "./..." ] }
  in
  (match g1 with
   | W (Go { subcommand = "build"; rest; _ }) ->
     if List.exists ((=) "bin") rest then
       Alcotest.failf "Go build -o bin: 'bin' should be consumed (%a)" pp g1;
     if not (List.exists ((=) "./...") rest) then
       Alcotest.failf "Go build -o bin ./...: './...' should be in rest (%a)" pp g1
   | w -> Alcotest.failf "Go build -o bin: expected Go, got %a" pp w);
  (* Cargo: --target x86_64 → consumed *)
  let c1 =
    of_simple { (base "cargo") with args = [ lit "build"; lit "--target"; lit "x86_64"; lit "--release" ] }
  in
  (match c1 with
   | W (Cargo { subcommand = "build"; release = true; rest; _ }) ->
     if List.exists ((=) "x86_64") rest then
       Alcotest.failf "Cargo --target x86_64: 'x86_64' should be consumed (%a)" pp c1
   | w -> Alcotest.failf "Cargo --target: expected Cargo, got %a" pp w);
  (* Npm: --registry https://x → consumed *)
  let n1 =
    of_simple { (base "npm") with args = [ lit "install"; lit "--registry"; lit "https://x"; lit "pkg" ] }
  in
  (match n1 with
   | W (Npm { subcommand = "install"; rest; _ }) ->
     if List.exists ((=) "https://x") rest then
       Alcotest.failf "Npm --registry: url should be consumed (%a)" pp n1;
     if not (List.exists ((=) "pkg") rest) then
       Alcotest.failf "Npm --registry ... pkg: 'pkg' should be in rest (%a)" pp n1
   | w -> Alcotest.failf "Npm --registry: expected Npm, got %a" pp w);
  (* Mvn: -D key=val → two-token form consumed *)
  let m1 =
    of_simple { (base "mvn") with args = [ lit "install"; lit "-D"; lit "skipTests=true" ] }
  in
  (match m1 with
   | W (Mvn { subcommand = "install"; args; _ }) ->
     if List.exists ((=) "skipTests=true") args then
       Alcotest.failf "Mvn -D skipTests=true: value should be consumed (%a)" pp m1
   | w -> Alcotest.failf "Mvn -D: expected Mvn, got %a" pp w);
  (* Mvn: --batch-mode --quiet boolean flags preserved *)
  let m2 =
    of_simple { (base "mvn") with args = [ lit "test"; lit "--batch-mode"; lit "--quiet" ] }
  in
  (match m2 with
   | W (Mvn { subcommand = "test"; batch_mode = true; quiet = true; _ }) -> ()
   | w -> Alcotest.failf "Mvn --batch-mode --quiet: expected flags, got %a" pp w);
  (* Gradle: --build-file custom.gradle → consumed *)
  let gr1 =
    of_simple { (base "gradle") with args = [ lit "build"; lit "--build-file"; lit "custom.gradle" ] }
  in
  (match gr1 with
   | W (Gradle { subcommand = "build"; rest; _ }) ->
     if List.exists ((=) "custom.gradle") rest then
       Alcotest.failf "Gradle --build-file: 'custom.gradle' should be consumed (%a)" pp gr1
   | w -> Alcotest.failf "Gradle --build-file: expected Gradle, got %a" pp w);
  (* Gradle: --gradle-user-home=/opt/gradle → =VALUE form *)
  let gr2 =
    of_simple { (base "gradle") with args = [ lit "build"; lit "--gradle-user-home=/opt/gradle" ] }
  in
  (match gr2 with
   | W (Gradle { subcommand = "build"; rest; _ }) ->
     if List.exists ((=) "/opt/gradle") rest then
       Alcotest.failf "Gradle --gradle-user-home=VALUE: should be consumed (%a)" pp gr2
   | w -> Alcotest.failf "Gradle --gradle-user-home=: expected Gradle, got %a" pp w)
;;

(* Batch 13: value-consuming flag handling for Node/Python/Python3/Pip/Ruff/Tsc.
   Ensures that --flag VALUE pairs are consumed together, not split into
   separate positional arguments. *)
let test_batch13_value_consuming_flags () =
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
  (* Node: --require module is consumed, script remains *)
  let w_node =
    of_simple { (base "node") with args = [ lit "--require"; lit "module"; lit "script.js" ] }
  in
  (match w_node with
   | W (Node { script = "script.js"; args = []; inline = None }) -> ()
   | w -> Alcotest.failf "Node --require: expected script=script.js, got %a" pp w);
  (* Node: --max-old-space-size=4096 is consumed (eq form) *)
  let w_node_eq =
    of_simple { (base "node") with args = [ lit "--max-old-space-size=4096"; lit "app.js" ] }
  in
  (match w_node_eq with
   | W (Node { script = "app.js"; args = []; inline = None }) -> ()
   | w -> Alcotest.failf "Node --max-old-space-size=4096: expected script=app.js, got %a" pp w);
  (* Python: -m is value-consuming flag; both -m and module are consumed *)
  let w_python =
    of_simple { (base "python") with args = [ lit "-m"; lit "module"; lit "script.py" ] }
  in
  (match w_python with
   | W (Python { script = "script.py"; args = []; inline = None }) -> ()
   | w -> Alcotest.failf "Python -m module: expected script=script.py, got %a" pp w);
  (* Python: -W value-consuming flag *)
  let w_python_w =
    of_simple { (base "python") with args = [ lit "-W"; lit "error"; lit "main.py" ] }
  in
  (match w_python_w with
   | W (Python { script = "main.py"; args = []; inline = None }) -> ()
   | w -> Alcotest.failf "Python -W error: expected script=main.py, got %a" pp w);
  (* Python3: -m value-consuming flag *)
  let w_python3 =
    of_simple { (base "python3") with args = [ lit "-m"; lit "uvicorn"; lit "app:main" ] }
  in
  (match w_python3 with
   | W (Python3 { script = "app:main"; args = []; inline = None }) -> ()
   | w -> Alcotest.failf "Python3 -m uvicorn: expected script=app:main, got %a" pp w);
  (* Pip: --index-url value is consumed, package remains *)
  let w_pip =
    of_simple
      { (base "pip") with
        args = [ lit "install"; lit "--index-url"; lit "https://example.com/simple"; lit "flask" ]
      }
  in
  (match w_pip with
   | W (Pip { subcommand = "install"; packages = [ "flask" ] }) -> ()
   | w -> Alcotest.failf "Pip --index-url: expected packages=[flask], got %a" pp w);
  (* Pip: --index-url=VALUE (eq form) is consumed *)
  let w_pip_eq =
    of_simple
      { (base "pip") with
        args = [ lit "install"; lit "--index-url=https://example.com/simple"; lit "requests" ]
      }
  in
  (match w_pip_eq with
   | W (Pip { subcommand = "install"; packages = [ "requests" ] }) -> ()
   | w -> Alcotest.failf "Pip --index-url=VALUE: expected packages=[requests], got %a" pp w);
  (* Ruff: --select value is consumed, rest path remains *)
  let w_ruff =
    of_simple
      { (base "ruff") with args = [ lit "check"; lit "--select"; lit "E501"; lit "src/" ] }
  in
  (match w_ruff with
   | W (Ruff { subcommand = "check"; fix = false; show_source = false; rest = [ "src/" ] }) -> ()
   | w -> Alcotest.failf "Ruff --select: expected rest=[src/], got %a" pp w);
  (* Tsc: --target value is consumed, rest path remains *)
  let w_tsc =
    of_simple
      { (base "tsc") with args = [ lit "build"; lit "--target"; lit "ES2020"; lit "src/" ] }
  in
  (match w_tsc with
   | W (Tsc { subcommand = "build"; no_emit = false; watch = false; rest = [ "src/" ] }) -> ()
   | w -> Alcotest.failf "Tsc --target: expected rest=[src/], got %a" pp w)
;;

let test_batch14_value_consuming_flags () =
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
  (* Opam: --switch VALUE is consumed, package remains *)
  let w_opam =
    of_simple
      { (base "opam") with args = [ lit "install"; lit "--switch"; lit "5.1.0"; lit "dune" ] }
  in
  (match w_opam with
   | W (Opam { subcommand = "install"; yes = false; rest = [ "dune" ] }) -> ()
   | w -> Alcotest.failf "Opam --switch: expected rest=[dune], got %a" pp w);
  (* Opam: --switch=VALUE (eq form) *)
  let w_opam_eq =
    of_simple
      { (base "opam") with args = [ lit "install"; lit "--switch=5.1.0"; lit "dune" ] }
  in
  (match w_opam_eq with
   | W (Opam { subcommand = "install"; rest = [ "dune" ] }) -> ()
   | w -> Alcotest.failf "Opam --switch=VALUE: expected rest=[dune], got %a" pp w);
  (* Npx: --package VALUE is consumed, command remains *)
  let w_npx =
    of_simple
      { (base "npx") with args = [ lit "--package"; lit "typescript"; lit "tsc"; lit "--noEmit" ] }
  in
  (match w_npx with
   | W (Npx { subcommand = "tsc"; rest = [ "--noEmit" ] }) -> ()
   | w -> Alcotest.failf "Npx --package: expected subcommand=tsc, got %a" pp w);
  (* Yarn: --cwd VALUE is consumed, subcommand remains *)
  let w_yarn =
    of_simple
      { (base "yarn") with args = [ lit "--cwd"; lit "/app"; lit "install" ] }
  in
  (match w_yarn with
   | W (Yarn { subcommand = "install"; rest = [] }) -> ()
   | w -> Alcotest.failf "Yarn --cwd: expected subcommand=install, got %a" pp w);
  (* Yarn: --network-timeout=VALUE (eq form) *)
  let w_yarn_eq =
    of_simple
      { (base "yarn") with args = [ lit "install"; lit "--network-timeout=60000" ] }
  in
  (match w_yarn_eq with
   | W (Yarn { subcommand = "install"; rest = [] }) -> ()
   | w -> Alcotest.failf "Yarn --network-timeout=VALUE: expected rest=[], got %a" pp w);
  (* Pnpm: --filter VALUE is consumed, subcommand remains *)
  let w_pnpm =
    of_simple
      { (base "pnpm") with args = [ lit "run"; lit "--filter"; lit "@scope/pkg"; lit "build" ] }
  in
  (match w_pnpm with
   | W (Pnpm { subcommand = "run"; rest = [ "build" ] }) -> ()
   | w -> Alcotest.failf "Pnpm --filter: expected rest=[build], got %a" pp w);
  (* Pnpm: --store-dir=VALUE (eq form) *)
  let w_pnpm_eq =
    of_simple
      { (base "pnpm") with args = [ lit "install"; lit "--store-dir=/tmp/store" ] }
  in
  (match w_pnpm_eq with
   | W (Pnpm { subcommand = "install"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pnpm --store-dir=VALUE: expected rest=[], got %a" pp w);
  (* Uv: --python VALUE is consumed, package remains *)
  let w_uv =
    of_simple
      { (base "uv") with args = [ lit "pip"; lit "--python"; lit "3.11"; lit "install"; lit "flask" ] }
  in
  (match w_uv with
   | W (Uv { subcommand = "pip"; rest = [ "install"; "flask" ] }) -> ()
   | w -> Alcotest.failf "Uv --python: expected rest=[install;flask], got %a" pp w);
  (* Uv: --cache-dir=VALUE (eq form, before positional args) *)
  let w_uv_eq =
    of_simple
      { (base "uv") with args = [ lit "pip"; lit "--cache-dir=/tmp/uv-cache"; lit "install"; lit "requests" ] }
  in
  (match w_uv_eq with
   | W (Uv { subcommand = "pip"; rest = [ "install"; "requests" ] }) -> ()
   | w -> Alcotest.failf "Uv --cache-dir=VALUE: expected rest=[install;requests], got %a" pp w);
  (* Glab: --repo VALUE is consumed, subcommand args remain *)
  let w_glab =
    of_simple
      { (base "glab") with args = [ lit "mr"; lit "--repo"; lit "owner/repo"; lit "list" ] }
  in
  (match w_glab with
   | W (Glab { subcommand = "mr"; rest = [ "list" ] }) -> ()
   | w -> Alcotest.failf "Glab --repo: expected rest=[list], got %a" pp w);
  (* Glab: --hostname=VALUE (eq form, before positional args) *)
  let w_glab_eq =
    of_simple
      { (base "glab") with args = [ lit "mr"; lit "--hostname=gitlab.example.com"; lit "list" ] }
  in
  (match w_glab_eq with
   | W (Glab { subcommand = "mr"; rest = [ "list" ] }) -> ()
   | w -> Alcotest.failf "Glab --hostname=VALUE: expected rest=[list], got %a" pp w);
  (* Pytest: -k VALUE is consumed, test path is subcommand *)
  let w_pytest =
    of_simple
      { (base "pytest") with args = [ lit "tests/"; lit "-k"; lit "test_login" ] }
  in
  (match w_pytest with
   | W (Pytest { subcommand = "tests/"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pytest -k: expected sub=tests/ rest=[], got %a" pp w);
  (* Pytest: --tb=VALUE (eq form, path is subcommand) *)
  let w_pytest_eq =
    of_simple
      { (base "pytest") with args = [ lit "tests/"; lit "--tb=short" ] }
  in
  (match w_pytest_eq with
   | W (Pytest { subcommand = "tests/"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pytest --tb=VALUE: expected sub=tests/ rest=[], got %a" pp w);
  (* Pyright: --pythonversion VALUE is consumed, path becomes subcommand *)
  let w_pyright =
    of_simple
      { (base "pyright") with args = [ lit "src/"; lit "--pythonversion"; lit "3.11" ] }
  in
  (match w_pyright with
   | W (Pyright { subcommand = "src/"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pyright --pythonversion: expected sub=src/ rest=[], got %a" pp w);
  (* Pyright: --project=VALUE (eq form, path is subcommand) *)
  let w_pyright_eq =
    of_simple
      { (base "pyright") with args = [ lit "src/"; lit "--project=." ] }
  in
  (match w_pyright_eq with
   | W (Pyright { subcommand = "src/"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pyright --project=VALUE: expected sub=src/ rest=[], got %a" pp w)
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
        ; Alcotest.test_case "Rg value-consuming flags" `Quick test_rg_value_consuming_flags
        ; Alcotest.test_case "Wget value-consuming flags" `Quick test_wget_value_consuming_flags
        ; Alcotest.test_case "--lines=N form" `Quick test_lines_equals_form
        ; Alcotest.test_case "--jobs=N form" `Quick test_jobs_equals_form
        ; Alcotest.test_case "combined short flags" `Quick test_combined_short_flags
        ; Alcotest.test_case "Git_push value-consuming flags" `Quick test_git_push_value_consuming_flags
        ; Alcotest.test_case "Git_pull value-consuming flags" `Quick test_git_pull_value_consuming_flags
        ; Alcotest.test_case "Git_log value-consuming flags" `Quick test_git_log_value_consuming_flags
        ; Alcotest.test_case "Batch 12: Docker/Go/Cargo/Npm/Mvn/Gradle value flags" `Quick test_batch12_value_consuming_flags
        ; Alcotest.test_case
            "Batch13 Node/Python/Pip/Ruff/Tsc value flags"
            `Quick
            test_batch13_value_consuming_flags
        ; Alcotest.test_case
            "Batch14 Opam/Npx/Yarn/Pnpm/Uv/Glab/Pytest/Pyright value flags"
            `Quick
            test_batch14_value_consuming_flags
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
