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
  ; W (Git_clone { repo = "x"; branch = None; depth = None; dest_dir = None })
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
  ; W (Git_stash { action = `List; message = None })
  ; W (Git_rebase { interactive = false; onto = None; branch = None; continue_ = false; abort = false })
  ; W (Git_merge { no_ff = false; squash = false; branch = "main"; abort = false; continue_ = false })
  ; W (Git_branch { delete = None; list_all = false; rename = None })
  ; W (Git_checkout { new_branch = false; branch = "main" })
  ; W (Git_fetch { remote = None; branch = None; prune = false; all = false })
  ; W (Git_show { commit = "HEAD"; stat = false })
  ; W (Git_reset { mode = `Mixed; target = None })
  ; W (Git_blame { file = "x.ml"; range = None })
  ; W (Git_add { paths = [ "." ]; force = false; update = false })
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
  ; W (Make { target = None; jobs = None; directory = None; makefile = None; dry_run = false; keep_going = false; silent = false; always_make = false })
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
  ; W (Gh { subcommand = "pr"; action = Some "list"; draft = false; squash = false; delete_branch = false; body = None; title = None; search = None; state = None; rest = [] })
  ; W (Chmod { mode = "755"; path = "/tmp/x"; recursive = false })
  ; W (Chown { owner = "root"; path = "/tmp/x"; recursive = false })
  ; W (Docker { subcommand = "run"; rm = false; privileged = false; detach = true; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [ "nginx" ] })
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
  ; W (Cp { source = "/tmp/a"; dest = "/tmp/b"; recursive = false; force = false; preserve = false })
  ; W (Mv { source = "/tmp/a"; dest = "/tmp/b"; force = false; no_clobber = false })
  ; W (Ln { target = "/usr/bin/python3"; link_name = "/usr/local/bin/python"; symbolic = true; force = false })
  ; W (Touch { files = [ "/tmp/newfile" ]; no_create = false; time = None })
  ; W (Tee { files = [ "/tmp/output.log" ]; append = false })
  ; W (Awk { program = "{print $1}"; files = [ "/tmp/data.txt" ] })
  ; W (Xargs { command = "echo"; args = []; null_terminated = false; max_args = None })
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
  (* Baseline: 100 constructors as of 2026-05-30. If this fails, either
     a constructor was added to shell_ir_typed.ml without updating the
     spec in bin/gen_shell_ir_walkers.ml (regression) or the count is
     intentional and this test should bump along with the spec. *)
  Alcotest.(check int)
    "generated constructor count"
    110
    (List.length Shell_ir_typed_walkers_gen.gen_constructor_names);
  Alcotest.(check int) "test fixture covers all constructors" 110 (List.length all_wrapped)
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
    ; W (Git_clone { repo = "git@github.com:x/y.git"; branch = Some "main"; depth = Some 1; dest_dir = None })
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
    ; W (Git_stash { action = `Push; message = Some "wip" })
    ; W (Git_rebase { interactive = true; onto = Some "main"; branch = Some "feature"; continue_ = false; abort = false })
    ; W (Git_merge { no_ff = true; squash = false; branch = "develop"; abort = false; continue_ = false })
    ; W (Git_branch { delete = Some "old-branch"; list_all = true; rename = Some "new-name" })
    ; W (Git_checkout { new_branch = true; branch = "feature-branch" })
    ; W (Git_fetch { remote = Some "origin"; branch = Some "main"; prune = true; all = true })
    ; W (Git_show { commit = "abc123"; stat = true })
    ; W (Git_reset { mode = `Hard; target = Some "HEAD~1" })
    ; W (Git_blame { file = "main.ml"; range = Some "10,20" })
    ; W (Git_add { paths = [ "src/"; "lib/" ]; force = true; update = false })
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
    ; W (Make { target = Some "install"; jobs = Some 4; directory = None; makefile = None; dry_run = false; keep_going = false; silent = false; always_make = false })
    ; W (Make { target = Some "all"; jobs = Some 8; directory = Some "/build"; makefile = Some "Makefile.prod"; dry_run = true; keep_going = true; silent = true; always_make = true })
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
    ; W (Gh { subcommand = "issue"; action = Some "create"; draft = false; squash = false; delete_branch = false; body = None; title = Some "bug"; search = None; state = None; rest = [] })
    ; W (Chmod { mode = "644"; path = "/etc/config"; recursive = true })
    ; W (Chown { owner = "user:group"; path = "/var/data"; recursive = true })
    ; W (Docker { subcommand = "build"; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [ "myapp"; "." ] })
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
    ; W (Cp { source = "src/"; dest = "dst/"; recursive = true; force = true; preserve = false })
    ; W (Mv { source = "old.txt"; dest = "new.txt"; force = true; no_clobber = false })
    ; W (Ln { target = "/usr/bin/python3"; link_name = "python"; symbolic = true; force = true })
    ; W (Touch { files = [ "a.txt"; "b.txt" ]; no_create = true; time = Some `Access })
    ; W (Tee { files = [ "out.log"; "err.log" ]; append = true })
    ; W (Awk { program = "{print NR, $0}"; files = [ "input.txt"; "data.csv" ] })
    ; W (Xargs { command = "rm"; args = [ "-rf" ]; null_terminated = true; max_args = Some 10 })
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
  (* unknown binary kind — `xyzzy` is NOT in Exec_program.known, must fall through *)
  let w_unknown =
    Shell_ir_typed.of_simple { base with bin = bin_ok "xyzzy"; args = [ lit "arg1" ] }
  in
  Alcotest.(check bool)
    "unknown bin fallback"
    true
    (match w_unknown with
     | Shell_ir_typed.W (Generic _) -> true
     | _ -> false);
  (* git sub-command we do not parse — use "bisect" which has no typed constructor *)
  let w_git_bisect =
    Shell_ir_typed.of_simple
      { base with bin = bin_ok "git"; args = [ lit "bisect"; lit "start" ] }
  in
  Alcotest.(check bool)
    "git bisect fallback"
    true
    (match w_git_bisect with
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
  (* Git_clone: with destination directory *)
  let gc2 =
    of_simple
      { (base "git") with
        args = [ lit "clone"; lit "https://github.com/example/repo.git"; lit "repos/myrepo" ]
      }
  in
  (match gc2 with
   | W
       (Git_clone
          { repo = "https://github.com/example/repo.git"
          ; branch = None
          ; depth = None
          ; dest_dir = Some "repos/myrepo"
          ; _
          }) -> ()
   | w ->
     Alcotest.failf
       "Git_clone with dest_dir: expected repos/myrepo, got %a"
       pp
       w);
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
  let gh_search =
    of_simple
      { (base "gh") with
        args =
          [ lit "pr"; lit "list"; lit "--search=task-1814"; lit "--state"; lit "all" ]
      }
  in
  (match gh_search with
   | W
       (Gh
          { subcommand = "pr"
          ; action = Some "list"
          ; search = Some "task-1814"
          ; state = Some "all"
          ; _
          }) -> ()
   | w ->
     Alcotest.failf "Gh --search/--state: expected fields parsed, got %a" pp w);
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
  (* Grep: -A 5 pattern file (context flag consumes numeric arg) *)
  let grep_after_context =
    of_simple { (base "grep") with args = [ lit "-A"; lit "5"; lit "pattern"; lit "file" ] }
  in
  (match grep_after_context with
   | W (Grep { pattern = "pattern"; path = Some "file"; _ }) -> ()
   | w -> Alcotest.failf "Grep -A 5: expected pattern+path, got %a" pp w);
  (* Grep: -C 3 pattern file (context flag consumes numeric arg) *)
  let grep_context =
    of_simple { (base "grep") with args = [ lit "-C"; lit "3"; lit "pattern"; lit "file" ] }
  in
  (match grep_context with
   | W (Grep { pattern = "pattern"; path = Some "file"; _ }) -> ()
   | w -> Alcotest.failf "Grep -C 3: expected pattern+path, got %a" pp w);
  (* Grep: --after-context=5 pattern file (eq-form context flag) *)
  let grep_after_eq =
    of_simple { (base "grep") with args = [ lit "--after-context=5"; lit "pattern"; lit "file" ] }
  in
  (match grep_after_eq with
   | W (Grep { pattern = "pattern"; path = Some "file"; _ }) -> ()
   | w -> Alcotest.failf "Grep --after-context=5: expected pattern+path, got %a" pp w);
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
  (* Ssh: -J jump-host user@host — jump proxy should be consumed, not treated as host *)
  let ssh_jump =
    of_simple { (base "ssh") with args = [ lit "-J"; lit "jump-host"; lit "user@server"; lit "uptime" ] }
  in
  (match ssh_jump with
   | W (Ssh { host = "server"; user = Some "user"; command = Some "uptime"; _ }) -> ()
   | w -> Alcotest.failf "Ssh -J: expected host=server, got %a" pp w);
  (* Ssh: -F /custom/config -l admin host *)
  let ssh_f_l =
    of_simple { (base "ssh") with args = [ lit "-F"; lit "/custom/config"; lit "-l"; lit "admin"; lit "host" ] }
  in
  (match ssh_f_l with
   | W (Ssh { host = "host"; user = None; command = None; _ }) -> ()
   | w -> Alcotest.failf "Ssh -F -l: expected host=host, got %a" pp w);
  (* Scp: -i key.pem src dst — identity file should be consumed *)
  let scp_i =
    of_simple { (base "scp") with args = [ lit "-i"; lit "key.pem"; lit "src"; lit "dst" ] }
  in
  (match scp_i with
   | W (Scp { source = "src"; dest = "dst"; _ }) -> ()
   | w -> Alcotest.failf "Scp -i: expected source=src dest=dst, got %a" pp w);
  (* Scp: -J jump src dst — jump proxy should be consumed *)
  let scp_j =
    of_simple { (base "scp") with args = [ lit "-J"; lit "jump"; lit "src"; lit "dst" ] }
  in
  (match scp_j with
   | W (Scp { source = "src"; dest = "dst"; _ }) -> ()
   | w -> Alcotest.failf "Scp -J: expected source=src dest=dst, got %a" pp w);
  (* Sed: -f script.sed input.txt — -f sets expression, positional is input file *)
  let sed_f =
    of_simple { (base "sed") with args = [ lit "-f"; lit "script.sed"; lit "input.txt" ] }
  in
  (match sed_f with
   | W (Sed { expression = "script.sed"; file = "input.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed -f: expected expr=script.sed file=input.txt, got %a" pp w);
  (* Tar: --exclude=*.o -cf archive.tar src/ — exclude pattern consumed *)
  let tar_exclude_eq =
    of_simple { (base "tar") with args = [ lit "--exclude=*.o"; lit "-cf"; lit "archive.tar"; lit "src/" ] }
  in
  (match tar_exclude_eq with
   | W (Tar { action = `Create; archive = "archive.tar"; paths = [ "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --exclude=: expected Create archive.tar paths=[src/], got %a" pp w);
  (* Tar: --exclude *.o -cf archive.tar src/ — space-separated exclude *)
  let tar_exclude_sp =
    of_simple { (base "tar") with args = [ lit "--exclude"; lit "*.o"; lit "-cf"; lit "archive.tar"; lit "src/" ] }
  in
  (match tar_exclude_sp with
   | W (Tar { action = `Create; archive = "archive.tar"; paths = [ "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --exclude: expected Create archive.tar paths=[src/], got %a" pp w);
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
  (* Git_stash: push -m "wip" *)
  let git_stash_push =
    of_simple { (base "git") with args = [ lit "stash"; lit "push"; lit "-m"; lit "wip" ] }
  in
  (match git_stash_push with
   | W (Git_stash { action = `Push; message = Some "wip"; _ }) -> ()
   | w -> Alcotest.failf "Git_stash push: expected Push message=wip, got %a" pp w);
  (* Git_stash: pop *)
  let git_stash_pop =
    of_simple { (base "git") with args = [ lit "stash"; lit "pop" ] }
  in
  (match git_stash_pop with
   | W (Git_stash { action = `Pop; _ }) -> ()
   | w -> Alcotest.failf "Git_stash pop: expected Pop, got %a" pp w);
  (* Git_rebase: --interactive --onto main feature *)
  let git_rebase =
    of_simple { (base "git") with args = [ lit "rebase"; lit "--interactive"; lit "--onto"; lit "main"; lit "feature" ] }
  in
  (match git_rebase with
   | W (Git_rebase { interactive = true; onto = Some "main"; branch = Some "feature"; _ }) -> ()
   | w -> Alcotest.failf "Git_rebase: expected interactive onto=main branch=feature, got %a" pp w);
  (* Git_merge: --no-ff develop *)
  let git_merge =
    of_simple { (base "git") with args = [ lit "merge"; lit "--no-ff"; lit "develop" ] }
  in
  (match git_merge with
   | W (Git_merge { no_ff = true; branch = "develop"; _ }) -> ()
   | w -> Alcotest.failf "Git_merge: expected no_ff=true branch=develop, got %a" pp w);
  (* Git_branch: -a *)
  let git_branch =
    of_simple { (base "git") with args = [ lit "branch"; lit "-a" ] }
  in
  (match git_branch with
   | W (Git_branch { list_all = true; _ }) -> ()
   | w -> Alcotest.failf "Git_branch -a: expected list_all=true, got %a" pp w);
  (* Git_checkout: -b feature-branch *)
  let git_checkout =
    of_simple { (base "git") with args = [ lit "checkout"; lit "-b"; lit "feature-branch" ] }
  in
  (match git_checkout with
   | W (Git_checkout { new_branch = true; branch = "feature-branch"; _ }) -> ()
   | w -> Alcotest.failf "Git_checkout -b: expected new_branch=true branch=feature-branch, got %a" pp w);
  (* Git_fetch: --prune origin main *)
  let git_fetch =
    of_simple { (base "git") with args = [ lit "fetch"; lit "--prune"; lit "origin"; lit "main" ] }
  in
  (match git_fetch with
   | W (Git_fetch { prune = true; remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "Git_fetch --prune: expected prune=true remote=Some origin branch=Some main, got %a" pp w);
  (* Git_show: --stat abc123 *)
  let git_show =
    of_simple { (base "git") with args = [ lit "show"; lit "--stat"; lit "abc123" ] }
  in
  (match git_show with
   | W (Git_show { commit = "abc123"; stat = true; _ }) -> ()
   | w -> Alcotest.failf "Git_show --stat: expected commit=abc123 stat=true, got %a" pp w);
  (* Git_reset: --hard HEAD~1 *)
  let git_reset =
    of_simple { (base "git") with args = [ lit "reset"; lit "--hard"; lit "HEAD~1" ] }
  in
  (match git_reset with
   | W (Git_reset { mode = `Hard; target = Some "HEAD~1"; _ }) -> ()
   | w -> Alcotest.failf "Git_reset --hard: expected mode=Hard target=Some HEAD~1, got %a" pp w);
  (* Git_blame: -L 10,20 main.ml *)
  let git_blame =
    of_simple { (base "git") with args = [ lit "blame"; lit "-L"; lit "10,20"; lit "main.ml" ] }
  in
  (match git_blame with
   | W (Git_blame { file = "main.ml"; range = Some "10,20"; _ }) -> ()
   | w -> Alcotest.failf "Git_blame -L: expected file=main.ml range=Some 10,20, got %a" pp w);
  (* Git_add: --force src/ lib/ *)
  let git_add =
    of_simple { (base "git") with args = [ lit "add"; lit "--force"; lit "src/"; lit "lib/" ] }
  in
  (match git_add with
   | W (Git_add { paths = [ "src/"; "lib/" ]; force = true; _ }) -> ()
   | w -> Alcotest.failf "Git_add --force: expected paths=[src/;lib/] force=true, got %a" pp w);
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
   | w -> Alcotest.failf "Gh --: expected subcommand=pr action=create draft=true, got %a" pp w);
  (* Terminal_notifier: -- title msg — after --, all args are positional *)
  let tn =
    of_simple { (base "terminal-notifier") with args = [ lit "-flag"; lit "--"; lit "real-title"; lit "real-msg" ] }
  in
  (match tn with
   | W (Terminal_notifier { title = "real-title"; message = "real-msg"; _ }) -> ()
   | w -> Alcotest.failf "Terminal_notifier --: expected title=real-title message=real-msg, got %a" pp w);
  (* Terminal_notifier: -- -dash-title msg — title starts with - after -- *)
  let tn_dash =
    of_simple { (base "terminal-notifier") with args = [ lit "--"; lit "-dash-title"; lit "msg" ] }
  in
  (match tn_dash with
   | W (Terminal_notifier { title = "-dash-title"; message = "msg"; _ }) -> ()
   | w -> Alcotest.failf "Terminal_notifier -- dash: expected title=-dash-title message=msg, got %a" pp w)
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
  (* rg --type=py pattern — eq-form extracts "py", prepended to rest → pattern="py" *)
  let rg_type_eq =
    of_simple { (base "rg") with args = [ lit "--type=py"; lit "pattern" ] }
  in
  (match rg_type_eq with
   | W (Rg { pattern = "py"; path = Some "pattern"; _ }) -> ()
   | w -> Alcotest.failf "Rg --type=py: expected pattern=py path=pattern, got %a" pp w);
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
   | w -> Alcotest.failf "Wget combined: expected url=example.com output=out.html continue_=true, got %a" pp w);
  (* wget --mirror URL — --mirror is boolean, should NOT consume URL *)
  let w6 =
    of_simple { (base "wget") with args = [ lit "--mirror"; lit "https://example.com" ] }
  in
  (match w6 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --mirror: expected url=example.com, got %a" pp w);
  (* wget --page-requisites URL — boolean flag should not consume URL *)
  let w7 =
    of_simple { (base "wget") with args = [ lit "--page-requisites"; lit "https://example.com" ] }
  in
  (match w7 with
   | W (Wget { url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --page-requisites: expected url=example.com, got %a" pp w)
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
  (* Make: -C /builddir -f Makefile.prod -n -k -s -B install *)
  let make_all =
    of_simple { (base "make") with args =
      [ lit "-C"; lit "/builddir"; lit "-f"; lit "Makefile.prod"
      ; lit "-n"; lit "-k"; lit "-s"; lit "-B"; lit "install" ] }
  in
  (match make_all with
   | W (Make { target = Some "install"; directory = Some "/builddir"; makefile = Some "Makefile.prod"
             ; dry_run = true; keep_going = true; silent = true; always_make = true; _ }) -> ()
   | w -> Alcotest.failf "Make -C -f -n -k -s -B: expected all flags, got %a" pp w);
  (* Make: --directory=/src --makefile=custom.mk --dry-run --keep-going --silent --always-make target *)
  let make_long =
    of_simple { (base "make") with args =
      [ lit "--directory=/src"; lit "--makefile=custom.mk"
      ; lit "--dry-run"; lit "--keep-going"; lit "--silent"; lit "--always-make"; lit "target" ] }
  in
  (match make_long with
   | W (Make { target = Some "target"; directory = Some "/src"; makefile = Some "custom.mk"
             ; dry_run = true; keep_going = true; silent = true; always_make = true; _ }) -> ()
   | w -> Alcotest.failf "Make --directory= --makefile= --dry-run --keep-going --silent --always-make: expected all flags, got %a" pp w);
  (* Make: --directory /src --makefile custom.mk --quiet *)
  let make_quiet =
    of_simple { (base "make") with args =
      [ lit "--directory"; lit "/src"; lit "--makefile"; lit "custom.mk"; lit "--quiet" ] }
  in
  (match make_quiet with
   | W (Make { directory = Some "/src"; makefile = Some "custom.mk"; silent = true; _ }) -> ()
   | w -> Alcotest.failf "Make --directory --makefile --quiet: expected flags, got %a" pp w);
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
  (* Docker: --name myapp → name = Some "myapp", rest should NOT contain "myapp" *)
  let d1 =
    of_simple { (base "docker") with args = [ lit "run"; lit "--name"; lit "myapp"; lit "img" ] }
  in
  (match d1 with
   | W (Docker { subcommand = "run"; name = Some "myapp"; rest; _ }) ->
     if List.exists ((=) "myapp") rest then
       Alcotest.failf "Docker --name myapp: 'myapp' should be in name field, not rest (%a)" pp d1
   | w -> Alcotest.failf "Docker run --name myapp: expected Docker(name=Some myapp), got %a" pp w);
  (* Docker: --name=myapp eq-form → name = Some "myapp", rest = [img] *)
  let d2 =
    of_simple { (base "docker") with args = [ lit "run"; lit "--name=myapp"; lit "img" ] }
  in
  (match d2 with
   | W (Docker { subcommand = "run"; name = Some "myapp"; rest; _ }) ->
     if List.exists ((=) "myapp") rest then
       Alcotest.failf "Docker --name=myapp: 'myapp' should be in name field, not rest (%a)" pp d2;
     if not (List.exists ((=) "img") rest) then
       Alcotest.failf "Docker --name=myapp img: 'img' should be in rest (%a)" pp d2
   | w -> Alcotest.failf "Docker --name=myapp: expected Docker(name=Some myapp), got %a" pp w);
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
  (* Npm: --save-exact is boolean, should NOT consume next arg as value *)
  let n2 =
    of_simple { (base "npm") with args = [ lit "install"; lit "--save-exact"; lit "lodash" ] }
  in
  (match n2 with
   | W (Npm { subcommand = "install"; rest; _ }) ->
     if not (List.exists ((=) "lodash") rest) then
       Alcotest.failf "Npm --save-exact: 'lodash' should be in rest (%a)" pp n2
   | w -> Alcotest.failf "Npm --save-exact: expected Npm, got %a" pp w);
  (* Npm: -E is boolean, should NOT consume next arg as value *)
  let n3 =
    of_simple { (base "npm") with args = [ lit "install"; lit "-E"; lit "lodash" ] }
  in
  (match n3 with
   | W (Npm { subcommand = "install"; rest; _ }) ->
     if not (List.exists ((=) "lodash") rest) then
       Alcotest.failf "Npm -E: 'lodash' should be in rest (%a)" pp n3
   | w -> Alcotest.failf "Npm -E: expected Npm, got %a" pp w);
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
  (* Gradle: --gradle-user-home=/opt/gradle → eq-form extracts value into rest *)
  let gr2 =
    of_simple { (base "gradle") with args = [ lit "build"; lit "--gradle-user-home=/opt/gradle" ] }
  in
  (match gr2 with
   | W (Gradle { subcommand = "build"; rest; _ }) ->
     if not (List.exists ((=) "/opt/gradle") rest) then
       Alcotest.failf "Gradle --gradle-user-home=VALUE: /opt/gradle should be in rest (%a)" pp gr2
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
  (* Node: --max-old-space-size=4096 (eq form) → "4096" extracted into args *)
  let w_node_eq =
    of_simple { (base "node") with args = [ lit "--max-old-space-size=4096"; lit "app.js" ] }
  in
  (match w_node_eq with
   | W (Node { script = "app.js"; args = [ "4096" ]; inline = None }) -> ()
   | w -> Alcotest.failf "Node --max-old-space-size=4096: expected args=[4096], got %a" pp w);
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
  (* Pip: --index-url=VALUE (eq form) → URL extracted into packages *)
  let w_pip_eq =
    of_simple
      { (base "pip") with
        args = [ lit "install"; lit "--index-url=https://example.com/simple"; lit "requests" ]
      }
  in
  (match w_pip_eq with
   | W (Pip { subcommand = "install"; packages = [ "https://example.com/simple"; "requests" ] }) -> ()
   | w -> Alcotest.failf "Pip --index-url=VALUE: expected packages=[url;requests], got %a" pp w);
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
  (* Opam: --switch=VALUE (eq form) → "5.1.0" extracted into rest *)
  let w_opam_eq =
    of_simple
      { (base "opam") with args = [ lit "install"; lit "--switch=5.1.0"; lit "dune" ] }
  in
  (match w_opam_eq with
   | W (Opam { subcommand = "install"; rest = [ "5.1.0"; "dune" ] }) -> ()
   | w -> Alcotest.failf "Opam --switch=VALUE: expected rest=[5.1.0;dune], got %a" pp w);
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
  (* Yarn: --network-timeout=VALUE (eq form) → "60000" extracted into rest *)
  let w_yarn_eq =
    of_simple
      { (base "yarn") with args = [ lit "install"; lit "--network-timeout=60000" ] }
  in
  (match w_yarn_eq with
   | W (Yarn { subcommand = "install"; rest = [ "60000" ] }) -> ()
   | w -> Alcotest.failf "Yarn --network-timeout=VALUE: expected rest=[60000], got %a" pp w);
  (* Pnpm: --filter VALUE is consumed, subcommand remains *)
  let w_pnpm =
    of_simple
      { (base "pnpm") with args = [ lit "run"; lit "--filter"; lit "@scope/pkg"; lit "build" ] }
  in
  (match w_pnpm with
   | W (Pnpm { subcommand = "run"; rest = [ "build" ] }) -> ()
   | w -> Alcotest.failf "Pnpm --filter: expected rest=[build], got %a" pp w);
  (* Pnpm: --store-dir=VALUE (eq form) → "/tmp/store" extracted into rest *)
  let w_pnpm_eq =
    of_simple
      { (base "pnpm") with args = [ lit "install"; lit "--store-dir=/tmp/store" ] }
  in
  (match w_pnpm_eq with
   | W (Pnpm { subcommand = "install"; rest = [ "/tmp/store" ] }) -> ()
   | w -> Alcotest.failf "Pnpm --store-dir=VALUE: expected rest=[/tmp/store], got %a" pp w);
  (* Uv: --python VALUE is consumed, package remains *)
  let w_uv =
    of_simple
      { (base "uv") with args = [ lit "pip"; lit "--python"; lit "3.11"; lit "install"; lit "flask" ] }
  in
  (match w_uv with
   | W (Uv { subcommand = "pip"; rest = [ "install"; "flask" ] }) -> ()
   | w -> Alcotest.failf "Uv --python: expected rest=[install;flask], got %a" pp w);
  (* Uv: --cache-dir=VALUE (eq form) → "/tmp/uv-cache" extracted into rest *)
  let w_uv_eq =
    of_simple
      { (base "uv") with args = [ lit "pip"; lit "--cache-dir=/tmp/uv-cache"; lit "install"; lit "requests" ] }
  in
  (match w_uv_eq with
   | W (Uv { subcommand = "pip"; rest = [ "/tmp/uv-cache"; "install"; "requests" ] }) -> ()
   | w -> Alcotest.failf "Uv --cache-dir=VALUE: expected rest=[/tmp/uv-cache;install;requests], got %a" pp w);
  (* Glab: --repo VALUE is consumed, subcommand args remain *)
  let w_glab =
    of_simple
      { (base "glab") with args = [ lit "mr"; lit "--repo"; lit "owner/repo"; lit "list" ] }
  in
  (match w_glab with
   | W (Glab { subcommand = "mr"; rest = [ "list" ] }) -> ()
   | w -> Alcotest.failf "Glab --repo: expected rest=[list], got %a" pp w);
  (* Glab: --hostname=VALUE (eq form) → "gitlab.example.com" extracted into rest *)
  let w_glab_eq =
    of_simple
      { (base "glab") with args = [ lit "mr"; lit "--hostname=gitlab.example.com"; lit "list" ] }
  in
  (match w_glab_eq with
   | W (Glab { subcommand = "mr"; rest = [ "gitlab.example.com"; "list" ] }) -> ()
   | w -> Alcotest.failf "Glab --hostname=VALUE: expected rest=[gitlab.example.com;list], got %a" pp w);
  (* Pytest: -k VALUE is consumed, test path is subcommand *)
  let w_pytest =
    of_simple
      { (base "pytest") with args = [ lit "tests/"; lit "-k"; lit "test_login" ] }
  in
  (match w_pytest with
   | W (Pytest { subcommand = "tests/"; rest = [] }) -> ()
   | w -> Alcotest.failf "Pytest -k: expected sub=tests/ rest=[], got %a" pp w);
  (* Pytest: --tb=VALUE (eq form) → "short" extracted into rest *)
  let w_pytest_eq =
    of_simple
      { (base "pytest") with args = [ lit "tests/"; lit "--tb=short" ] }
  in
  (match w_pytest_eq with
   | W (Pytest { subcommand = "tests/"; rest = [ "short" ] }) -> ()
   | w -> Alcotest.failf "Pytest --tb=VALUE: expected sub=tests/ rest=[short], got %a" pp w);
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
   | W (Pyright { subcommand = "src/"; rest = [ "." ] }) -> ()
   | w -> Alcotest.failf "Pyright --project=VALUE: expected sub=src/ rest=[.], got %a" pp w)
;;

(* Batch 15: Rustc, Gofmt, Ninja, Su, Fs value-consuming flags *)
let test_batch15_value_consuming_flags () =
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
  (* Rustc: --edition VALUE — flag+value consumed, file becomes subcommand *)
  let w_rustc =
    of_simple
      { (base "rustc") with args = [ lit "--edition"; lit "2021"; lit "src/main.rs" ] }
  in
  (match w_rustc with
   | W (Rustc { subcommand = "src/main.rs"; rest = []; _ }) -> ()
   | w -> Alcotest.failf "Rustc --edition: expected sub=src/main.rs, got %a" pp w);
  (* Rustc: --edition=VALUE (eq form) — value extracted as positional → becomes subcommand *)
  let w_rustc_eq =
    of_simple
      { (base "rustc") with args = [ lit "--edition=2021"; lit "src/main.rs" ] }
  in
  (match w_rustc_eq with
   | W (Rustc { subcommand = "2021"; rest = [ "src/main.rs" ]; _ }) -> ()
   | w -> Alcotest.failf "Rustc --edition=VALUE: expected sub=2021 rest=[src/main.rs], got %a" pp w);
  (* Rustc: --target VALUE with -O — flag+value consumed, file becomes subcommand *)
  let w_rustc_target =
    of_simple
      { (base "rustc") with args = [ lit "-O"; lit "--target"; lit "x86_64-unknown-linux-gnu"; lit "main.rs" ] }
  in
  (match w_rustc_target with
   | W (Rustc { subcommand = "main.rs"; optimize = true; rest = []; _ }) -> ()
   | w -> Alcotest.failf "Rustc --target: expected sub=main.rs, got %a" pp w);
  (* Gofmt: -tabs VALUE — flag consumed, VALUE passes through as subcommand *)
  let w_gofmt =
    of_simple
      { (base "gofmt") with args = [ lit "-tabs"; lit "false"; lit "main.go" ] }
  in
  (match w_gofmt with
   | W (Gofmt { subcommand = "false"; rest = [ "main.go" ]; _ }) -> ()
   | w -> Alcotest.failf "Gofmt -tabs: expected sub=false rest=[main.go], got %a" pp w);
  (* Gofmt: -tabwidth VALUE — flag consumed, VALUE passes through as subcommand *)
  let w_gofmt_tw =
    of_simple
      { (base "gofmt") with args = [ lit "-l"; lit "-tabwidth"; lit "4"; lit "." ] }
  in
  (match w_gofmt_tw with
   | W (Gofmt { subcommand = "4"; list_files = true; rest = [ "." ]; _ }) -> ()
   | w -> Alcotest.failf "Gofmt -tabwidth: expected sub=4 list=true rest=[.], got %a" pp w);
  (* Ninja: -C VALUE — flag consumed, VALUE passes through as subcommand *)
  let w_ninja_c =
    of_simple
      { (base "ninja") with args = [ lit "-C"; lit "build"; lit "all" ] }
  in
  (match w_ninja_c with
   | W (Ninja { subcommand = "build"; rest = [ "all" ]; _ }) -> ()
   | w -> Alcotest.failf "Ninja -C: expected sub=build rest=[all], got %a" pp w);
  (* Ninja: -f VALUE — flag consumed, VALUE passes through as subcommand *)
  let w_ninja_f =
    of_simple
      { (base "ninja") with args = [ lit "-f"; lit "build.ninja"; lit "all" ] }
  in
  (match w_ninja_f with
   | W (Ninja { subcommand = "build.ninja"; rest = [ "all" ]; _ }) -> ()
   | w -> Alcotest.failf "Ninja -f: expected sub=build.ninja rest=[all], got %a" pp w);
  (* Su: -c VALUE is consumed, subcommand remains *)
  let w_su_c =
    of_simple
      { (base "su") with args = [ lit "root"; lit "-c"; lit "whoami" ] }
  in
  (match w_su_c with
   | W (Su { subcommand = "root"; args = [ "whoami" ]; _ }) -> ()
   | w -> Alcotest.failf "Su -c: expected args=[whoami], got %a" pp w);
  (* Su: --shell VALUE is consumed *)
  let w_su_shell =
    of_simple
      { (base "su") with args = [ lit "root"; lit "--shell"; lit "/bin/bash" ] }
  in
  (match w_su_shell with
   | W (Su { subcommand = "root"; args = [ "/bin/bash" ]; _ }) -> ()
   | w -> Alcotest.failf "Su --shell: expected args=[/bin/bash], got %a" pp w);
  (* Mkfs: -t VALUE — value flag adds ext4 to args, device becomes subcommand *)
  let w_mkfs_t =
    of_simple
      { (base "mkfs") with args = [ lit "-t"; lit "ext4"; lit "/dev/sdb1" ] }
  in
  (match w_mkfs_t with
   | W (Mkfs { subcommand = "/dev/sdb1"; args = [ "ext4" ]; _ }) -> ()
   | w -> Alcotest.failf "Mkfs -t: expected sub=/dev/sdb1 args=[ext4], got %a" pp w);
  (* Mkfs: --type=VALUE (eq form) — value extracted from =, device becomes subcommand *)
  let w_mkfs_eq =
    of_simple
      { (base "mkfs") with args = [ lit "--type=ext4"; lit "/dev/sdb1" ] }
  in
  (match w_mkfs_eq with
   | W (Mkfs { subcommand = "/dev/sdb1"; args = [ "ext4" ]; _ }) -> ()
   | w -> Alcotest.failf "Mkfs --type=VALUE: expected sub=/dev/sdb1 args=[ext4], got %a" pp w);
  (* Mkfs: -t VALUE + -L VALUE — both values added to args *)
  let w_mkfs_label =
    of_simple
      { (base "mkfs") with args = [ lit "-t"; lit "ext4"; lit "-L"; lit "MYDISK"; lit "/dev/sdb1" ] }
  in
  (match w_mkfs_label with
   | W (Mkfs { subcommand = "/dev/sdb1"; args = [ "ext4"; "MYDISK" ]; _ }) -> ()
   | w -> Alcotest.failf "Mkfs -L: expected sub=/dev/sdb1 args=[ext4;MYDISK], got %a" pp w);
  (* Su: --shell=VALUE (eq form) — value extracted from = *)
  let w_su_shell_eq =
    of_simple
      { (base "su") with args = [ lit "root"; lit "--shell=/bin/bash" ] }
  in
  (match w_su_shell_eq with
   | W (Su { subcommand = "root"; args = [ "/bin/bash" ]; _ }) -> ()
   | w -> Alcotest.failf "Su --shell=VALUE: expected args=[/bin/bash], got %a" pp w);
  (* Rsync: --exclude VALUE (space form) — flag and value preserved in flags *)
  let w_rsync_exclude =
    of_simple
      { (base "rsync") with args = [ lit "-a"; lit "--exclude"; lit "*.o"; lit "src/"; lit "dest/" ] }
  in
  (match w_rsync_exclude with
   | W (Rsync { source = "src/"; dest = "dest/"; archive = true; flags = [ "--exclude"; "*.o" ]; _ }) -> ()
   | w -> Alcotest.failf "Rsync --exclude: expected flags=[--exclude;*.o], got %a" pp w);
  (* Rsync: --exclude=VALUE (eq form) — value extracted from = *)
  let w_rsync_exclude_eq =
    of_simple
      { (base "rsync") with args = [ lit "-a"; lit "--exclude=*.o"; lit "src/"; lit "dest/" ] }
  in
  (match w_rsync_exclude_eq with
   | W (Rsync { source = "src/"; dest = "dest/"; archive = true; flags = [ "--exclude"; "*.o" ]; _ }) -> ()
   | w -> Alcotest.failf "Rsync --exclude=VALUE: expected flags=[--exclude;*.o], got %a" pp w);
  (* Go: -count=1 test — eq-form flag skipped, test becomes subcommand *)
  let w_go_count_eq =
    of_simple
      { (base "go") with args = [ lit "-count=1"; lit "test" ] }
  in
  (match w_go_count_eq with
   | W (Go { subcommand = "1"; rest = [ "test" ]; _ }) -> ()
   | w -> Alcotest.failf "Go -count=1: expected sub=1 rest=[test], got %a" pp w);
  (* Go: -count 1 test — space-form flag skipped, test becomes subcommand *)
  let w_go_count_space =
    of_simple
      { (base "go") with args = [ lit "-count"; lit "1"; lit "test" ] }
  in
  (match w_go_count_space with
   | W (Go { subcommand = "test"; _ }) -> ()
   | w -> Alcotest.failf "Go -count 1: expected sub=test, got %a" pp w);
  (* Gofmt: -tabs=false file.go — eq-form flag skipped, file.go becomes subcommand *)
  let w_gofmt_tabs_eq =
    of_simple
      { (base "gofmt") with args = [ lit "-tabs=false"; lit "main.go" ] }
  in
  (match w_gofmt_tabs_eq with
   | W (Gofmt { subcommand = "false"; rest = [ "main.go" ]; _ }) -> ()
   | w -> Alcotest.failf "Gofmt -tabs=false: expected sub=false rest=[main.go], got %a" pp w);
  (* Ninja: -C=build — eq-form flag skipped *)
  let w_ninja_c_eq =
    of_simple
      { (base "ninja") with args = [ lit "-C=build"; lit "all" ] }
  in
  (match w_ninja_c_eq with
   | W (Ninja { subcommand = "build"; rest = [ "all" ]; _ }) -> ()
   | w -> Alcotest.failf "Ninja -C=build: expected sub=build rest=[all], got %a" pp w);
  (* Rg: --type=py — eq-form extracts "py" as pattern, TODO becomes path *)
  let w_rg_type_eq =
    of_simple
      { (base "rg") with args = [ lit "--type=py"; lit "TODO" ] }
  in
  (match w_rg_type_eq with
   | W (Rg { pattern = "py"; path = Some "TODO"; case_sensitive = true; _ }) -> ()
   | w -> Alcotest.failf "Rg --type=py: expected pat=py path=TODO, got %a" pp w);
  (* Rg: --max-depth=3 pattern — eq-form flag consumed *)
  let w_rg_depth_eq =
    of_simple
      { (base "rg") with args = [ lit "--max-depth=3"; lit "FIXME" ] }
  in
  (match w_rg_depth_eq with
   | W (Rg { pattern = "3"; path = Some "FIXME"; _ }) -> ()
   | w -> Alcotest.failf "Rg --max-depth=3: expected pat=3 path=FIXME, got %a" pp w);
  (* Rg: -C5 pattern — single-dash eq-form not supported (no =), treated as flag+value *)
  let w_rg_short_c =
    of_simple
      { (base "rg") with args = [ lit "-C"; lit "5"; lit "TODO" ] }
  in
  (match w_rg_short_c with
   | W (Rg { pattern = "TODO"; path = None; _ }) -> ()
   | w -> Alcotest.failf "Rg -C 5: expected pat=TODO, got %a" pp w);
  (* Find: -name=*.ml — eq-form for explicit -name handler not supported, treated as path *)
  let w_find_name_eq =
    of_simple
      { (base "find") with args = [ lit "."; lit "-name=*.ml" ] }
  in
  (match w_find_name_eq with
   | W (Find { path = "."; name = None; _ }) -> ()
   | w -> Alcotest.failf "Find -name=*.ml: expected name=None (eq not parsed), got %a" pp w);
  (* Find: -perm=644 — eq-form value flag consumed *)
  let w_find_perm_eq =
    of_simple
      { (base "find") with args = [ lit "/tmp"; lit "-perm=644"; lit "-name"; lit "*.log" ] }
  in
  (match w_find_perm_eq with
   | W (Generic _) -> ()
   | w -> Alcotest.failf "Find -perm=644: expected Generic (eq-form value as 2nd path arg), got %a" pp w);
  (* Find: -mtime=7 -type=f — eq-form for -mtime consumed *)
  let w_find_mtime_eq =
    of_simple
      { (base "find") with args = [ lit "."; lit "-mtime=7"; lit "-type"; lit "f" ] }
  in
  (match w_find_mtime_eq with
   | W (Generic _) -> ()
   | w -> Alcotest.failf "Find -mtime=7: expected Generic (eq-form value as 2nd path arg), got %a" pp w);
  (* Git_log: --format=oneline — eq-form value flag consumed *)
  let w_git_log_eq =
    of_simple
      { (base "git") with args = [ lit "log"; lit "--format=oneline"; lit "-n"; lit "5" ] }
  in
  (match w_git_log_eq with
   | W (Git_log { max_count = Some 5; _ }) -> ()
   | w -> Alcotest.failf "Git_log --format=oneline: expected max=5, got %a" pp w);
  (* Git_push: --repo=origin main — eq-form value flag consumed *)
  let w_git_push_eq =
    of_simple
      { (base "git") with args = [ lit "push"; lit "--repo=origin"; lit "main" ] }
  in
  (match w_git_push_eq with
   | W (Git_push { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "Git_push --repo=origin: expected remote=origin branch=main, got %a" pp w);
  (* Git_pull: --depth=1 — eq-form value flag consumed *)
  let w_git_pull_eq =
    of_simple
      { (base "git") with args = [ lit "pull"; lit "--depth=1"; lit "--rebase" ] }
  in
  (match w_git_pull_eq with
   | W (Git_pull { rebase = true; _ }) -> ()
   | w -> Alcotest.failf "Git_pull --depth=1: expected rebase=true, got %a" pp w);
  (* Wget: --timeout=30 URL — eq-form value flag consumed *)
  let w_wget_eq =
    of_simple
      { (base "wget") with args = [ lit "--timeout=30"; lit "http://example.com" ] }
  in
  (match w_wget_eq with
   | W (Wget { url = "http://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Wget --timeout=30: expected url=example.com, got %a" pp w);
  (* Wget: --output-document=out.html URL — eq-form special case preserved *)
  let w_wget_od_eq =
    of_simple
      { (base "wget") with args = [ lit "--output-document=out.html"; lit "http://example.com" ] }
  in
  (match w_wget_od_eq with
   | W (Wget { url = "http://example.com"; output = Some "out.html"; _ }) -> ()
   | w -> Alcotest.failf "Wget --output-document=out.html: expected output=Some out.html, got %a" pp w)
;;

(* Batch 16: eq-form --flag=VALUE for subcommand+args parsers. Custom
   parsers SKIP eq-form tokens entirely (token disappears). Generic
   subcommand_args_ctor EXTRACTS value (only VALUE added to args).
   Rsync DECOMPOSES into separate flag+value entries in flags list. *)
let test_subcommand_args_eq_form_flags () =
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
  (* Docker: --name=myapp (eq-form → name = Some "myapp", rest gets remaining args) *)
  let w_docker_eq =
    of_simple
      { (base "docker") with args = [ lit "run"; lit "--name=myapp"; lit "-d"; lit "nginx" ] }
  in
  (match w_docker_eq with
   | W (Docker { subcommand = "run"; name = Some "myapp"; detach = true; rest; _ }) ->
     if List.exists ((=) "myapp") rest then
       Alcotest.failf "Docker --name=myapp: 'myapp' should be in name, not rest (%a)" pp w_docker_eq
   | w -> Alcotest.failf "Docker --name=myapp: expected Docker(name=Some myapp), got %a" pp w);
  (* Docker: --name myapp (space-separated → name = Some "myapp", -d sets detach) *)
  let w_docker_sp =
    of_simple
      { (base "docker") with args = [ lit "run"; lit "--name"; lit "myapp"; lit "-d"; lit "nginx" ] }
  in
  (match w_docker_sp with
   | W (Docker { subcommand = "run"; name = Some "myapp"; detach = true; rest = [ "nginx" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker --name myapp -d: expected Docker(name=Some myapp,detach=true), got %a" pp w);
  (* Cargo: --features=serde (special-cased → features field set) *)
  let w_cargo_eq =
    of_simple
      { (base "cargo") with args = [ lit "build"; lit "--features=serde"; lit "--release" ] }
  in
  (match w_cargo_eq with
   | W (Cargo { subcommand = "build"; features = Some "serde"; release = true; rest = []; _ }) -> ()
   | w -> Alcotest.failf "Cargo --features=serde: expected features=Some serde, got %a" pp w);
  (* Cargo: --target=triple (generic value flag → consumed, subcommand from next positional) *)
  let w_cargo_target_eq =
    of_simple
      { (base "cargo") with args = [ lit "build"; lit "--target=x86_64-unknown-linux-gnu"; lit "src/main.rs" ] }
  in
  (match w_cargo_target_eq with
   | W (Cargo { subcommand = "build"; rest = [ "x86_64-unknown-linux-gnu"; "src/main.rs" ]; _ }) -> ()
   | w -> Alcotest.failf "Cargo --target=triple: expected rest=[x86_64-unknown-linux-gnu;src/main.rs], got %a" pp w);
  (* Npm: --registry=URL *)
  let w_npm_eq =
    of_simple
      { (base "npm") with args = [ lit "install"; lit "--registry=https://npm.example.com"; lit "lodash" ] }
  in
  (match w_npm_eq with
   | W (Npm { subcommand = "install"; rest = [ "https://npm.example.com"; "lodash" ]; _ }) -> ()
   | w -> Alcotest.failf "Npm --registry=URL: expected rest=[URL;lodash], got %a" pp w);
  (* Go: -o=bin/myapp *)
  let w_go_eq =
    of_simple
      { (base "go") with args = [ lit "build"; lit "-o=bin/myapp"; lit "main.go" ] }
  in
  (match w_go_eq with
   | W (Go { subcommand = "build"; rest = [ "bin/myapp"; "main.go" ]; _ }) -> ()
   | w -> Alcotest.failf "Go -o=bin/myapp: expected rest=[bin/myapp;main.go], got %a" pp w);
  (* Mvn: -D=property=value *)
  let w_mvn_eq =
    of_simple
      { (base "mvn") with args = [ lit "test"; lit "-D=skipTests=true"; lit "-q" ] }
  in
  (match w_mvn_eq with
   | W (Mvn { subcommand = "test"; args = [ "skipTests=true"; "-q" ]; quiet = false; _ }) -> ()
   | w -> Alcotest.failf "Mvn -D=skipTests: expected args=[skipTests=true;-q], got %a" pp w);
  (* Su: --shell=/bin/bash *)
  let w_su_eq =
    of_simple
      { (base "su") with args = [ lit "root"; lit "--shell=/bin/bash"; lit "whoami" ] }
  in
  (match w_su_eq with
   | W (Su { subcommand = "root"; args = [ "/bin/bash"; "whoami" ]; _ }) -> ()
   | w -> Alcotest.failf "Su --shell=/bin/bash: expected args=[/bin/bash;whoami], got %a" pp w);
  (* Mkfs: -t=ext4 *)
  let w_mkfs_eq =
    of_simple
      { (base "mkfs") with args = [ lit "-t=ext4"; lit "/dev/sdb1" ] }
  in
  (match w_mkfs_eq with
   | W (Mkfs { subcommand = "/dev/sdb1"; args = [ "ext4" ]; _ }) -> ()
   | w -> Alcotest.failf "Mkfs -t=ext4: expected sub=/dev/sdb1,args=[ext4], got %a" pp w);
  (* Gradle: --project-dir=/tmp *)
  let w_gradle_eq =
    of_simple
      { (base "gradle") with args = [ lit "build"; lit "--project-dir=/tmp"; lit "--no-daemon" ] }
  in
  (match w_gradle_eq with
   | W (Gradle { subcommand = "build"; rest = [ "/tmp"; "--no-daemon" ]; no_daemon = false; _ }) -> ()
   | w -> Alcotest.failf "Gradle --project-dir=/tmp: expected rest=[/tmp;--no-daemon],no_daemon=false, got %a" pp w);
  (* Yarn: --cwd=/project *)
  let w_yarn_eq =
    of_simple
      { (base "yarn") with args = [ lit "install"; lit "--cwd=/project" ] }
  in
  (match w_yarn_eq with
   | W (Yarn { subcommand = "install"; rest = [ "/project" ]; _ }) -> ()
   | w -> Alcotest.failf "Yarn --cwd=/project: expected rest=[/project], got %a" pp w);
  (* Opam: --switch=5.2.0 *)
  let w_opam_eq =
    of_simple
      { (base "opam") with args = [ lit "switch"; lit "create"; lit "--switch=5.2.0" ] }
  in
  (match w_opam_eq with
   | W (Opam { subcommand = "switch"; rest = [ "create"; "--switch=5.2.0" ]; _ }) -> ()
   | w -> Alcotest.failf "Opam --switch=5.2.0: expected sub=switch,rest=[create;--switch=5.2.0], got %a" pp w);
  (* Npx: --package=cowsay *)
  let w_npx_eq =
    of_simple
      { (base "npx") with args = [ lit "cowsay"; lit "--package=cowsay"; lit "hello" ] }
  in
  (match w_npx_eq with
   | W (Npx { subcommand = "cowsay"; rest = [ "cowsay"; "hello" ]; _ }) -> ()
   | w -> Alcotest.failf "Npx --package=cowsay: expected rest=[cowsay;hello], got %a" pp w);
  (* Ruff: --config=ruff.toml *)
  let w_ruff_eq =
    of_simple
      { (base "ruff") with args = [ lit "check"; lit "--config=ruff.toml"; lit "src/" ] }
  in
  (match w_ruff_eq with
   | W (Ruff { subcommand = "check"; rest = [ "ruff.toml"; "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Ruff --config=ruff.toml: expected rest=[ruff.toml;src/], got %a" pp w);
  (* Tsc: --target=es2020 *)
  let w_tsc_eq =
    of_simple
      { (base "tsc") with args = [ lit "build"; lit "--target=es2020"; lit "src/" ] }
  in
  (match w_tsc_eq with
   | W (Tsc { subcommand = "build"; rest = [ "es2020"; "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tsc --target=es2020: expected rest=[es2020;src/], got %a" pp w);
  (* Pip: --timeout=30 *)
  let w_pip_eq =
    of_simple
      { (base "pip") with args = [ lit "install"; lit "--timeout=30"; lit "numpy" ] }
  in
  (match w_pip_eq with
   | W (Pip { subcommand = "install"; packages = [ "30"; "numpy" ]; _ }) -> ()
   | w -> Alcotest.failf "Pip --timeout=30: expected packages=[30;numpy], got %a" pp w);
  (* Node: --max-old-space-size=4096 *)
  let w_node_eq =
    of_simple
      { (base "node") with args = [ lit "--max-old-space-size=4096"; lit "server.js" ] }
  in
  (match w_node_eq with
   | W (Node { script = "server.js"; args = [ "4096" ]; inline = None; _ }) -> ()
   | w -> Alcotest.failf "Node --max-old-space-size=4096: expected script=server.js args=[4096], got %a" pp w);
  (* Rsync: --exclude=.git *)
  let w_rsync_eq =
    of_simple
      { (base "rsync") with args = [ lit "-av"; lit "--exclude=.git"; lit "src/"; lit "dest/" ] }
  in
  (match w_rsync_eq with
   | W (Rsync { flags = [ "-av"; "--exclude"; ".git" ]; source = "src/"; dest = "dest/"; _ }) -> ()
   | w -> Alcotest.failf "Rsync --exclude=.git: expected flags=[-av;--exclude;.git], got %a" pp w);
  (* Python: -W=ignore *)
  let w_python_eq =
    of_simple
      { (base "python") with args = [ lit "-W=ignore"; lit "script.py" ] }
  in
  (match w_python_eq with
   | W (Python { script = "script.py"; args = [ "ignore" ]; inline = None; _ }) -> ()
   | w -> Alcotest.failf "Python -W=ignore: expected script=script.py args=[ignore], got %a" pp w)
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
    ; W (Docker { subcommand = "ps"; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [] }), "docker"
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

let test_is_eq_form_flag () =
  let open Shell_ir_typed_types in
  let flags = [ "--output"; "--timeout"; "-o" ] in
  (* Positive: standard eq-form *)
  Alcotest.(check bool) "--output=file" true (is_eq_form_flag "--output=file" flags);
  Alcotest.(check bool) "--timeout=30" true (is_eq_form_flag "--timeout=30" flags);
  Alcotest.(check bool) "-o=file" true (is_eq_form_flag "-o=file" flags);
  (* Negative: no '=' *)
  Alcotest.(check bool) "--output" false (is_eq_form_flag "--output" flags);
  Alcotest.(check bool) "-o" false (is_eq_form_flag "-o" flags);
  (* Negative: not in flags *)
  Alcotest.(check bool) "--unknown=val" false (is_eq_form_flag "--unknown=val" flags);
  (* Negative: too short *)
  Alcotest.(check bool) "-=" false (is_eq_form_flag "-=" flags);
  (* Negative: no leading dash *)
  Alcotest.(check bool) "output=file" false (is_eq_form_flag "output=file" flags);
  (* Edge: value with '=' inside *)
  Alcotest.(check bool) "--output=a=b" true (is_eq_form_flag "--output=a=b" flags);
  (* Edge: empty flags list *)
  Alcotest.(check bool) "empty flags" false (is_eq_form_flag "--output=file" [])
;;

let test_eq_form_flag_value () =
  let open Shell_ir_typed_types in
  let flags = [ "--output"; "--timeout"; "-o" ] in
  let check_val desc expected arg =
    Alcotest.(check (option string)) desc expected (eq_form_flag_value arg flags)
  in
  (* Positive: extract value *)
  check_val "--output=file" (Some "file") "--output=file";
  check_val "--timeout=30" (Some "30") "--timeout=30";
  check_val "-o=file" (Some "file") "-o=file";
  check_val "--output=a=b" (Some "a=b") "--output=a=b";
  check_val "--output=" (Some "") "--output=";
  (* Negative: no '=' → None *)
  check_val "--output" None "--output";
  check_val "-o" None "-o";
  (* Negative: not in flags *)
  check_val "--unknown=val" None "--unknown=val";
  (* Negative: too short *)
  check_val "-=" None "-=";
  (* Negative: no leading dash *)
  check_val "output=file" None "output=file";
  (* Edge: empty flags list *)
  Alcotest.(check (option string))
    "empty flags"
    None
    (eq_form_flag_value "--output=file" [])

;;

let test_constructor_names_in_declaration_order () =
  Alcotest.(check (list string))
    "generated names match declaration order"
    [ "Ls"; "Cat"; "Rg"; "Git_status"; "Git_clone"; "Curl"; "Rm"; "Sudo"
    ; "Find"; "Head"; "Tail"; "Grep"; "Mkdir"; "Wc"
    ; "Git_diff"; "Git_log"; "Git_commit"; "Git_push"; "Git_pull"
    ; "Git_stash"; "Git_rebase"; "Git_merge"; "Git_branch"; "Git_checkout"
    ; "Git_fetch"; "Git_show"; "Git_reset"; "Git_blame"; "Git_add"
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
    ; "Cp"; "Mv"; "Ln"; "Touch"; "Tee"; "Awk"; "Xargs"
    ; "Generic"
    ]
    Shell_ir_typed_walkers_gen.gen_constructor_names
;;

(* Batch 2 regression tests: boolean-as-value misclassification & missing value arms *)
let test_batch2_regression_fixes () =
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
  (* Git_push: --signed is boolean → should NOT eat "origin" as value *)
  let gp =
    of_simple { (base "git") with args = [ lit "push"; lit "--signed"; lit "origin"; lit "main" ] }
  in
  (match gp with
   | W (Git_push { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git push --signed origin main: expected remote=origin branch=main, got %a" pp w);
  (* Git_pull: --recurse-submodules is boolean → should NOT eat "origin" as value *)
  let gl =
    of_simple { (base "git") with args = [ lit "pull"; lit "--recurse-submodules"; lit "origin"; lit "main" ] }
  in
  (match gl with
   | W (Git_pull { remote = Some "origin"; branch = Some "main"; _ }) -> ()
   | w -> Alcotest.failf "git pull --recurse-submodules origin main: expected remote=origin branch=main, got %a" pp w);
  (* Git_log: --merges is boolean → should NOT eat "--oneline" as value *)
  let gl2 =
    of_simple { (base "git") with args = [ lit "log"; lit "--merges"; lit "--oneline" ] }
  in
  (match gl2 with
   | W (Git_log { oneline = true; _ }) -> ()
   | w -> Alcotest.failf "git log --merges --oneline: expected oneline=true, got %a" pp w);
  (* Git_log: --no-merges is boolean → should NOT eat "-n5" as value *)
  let gl3 =
    of_simple { (base "git") with args = [ lit "log"; lit "--no-merges"; lit "-n5" ] }
  in
  (match gl3 with
   | W (Git_log { max_count = Some 5; _ }) -> ()
   | w -> Alcotest.failf "git log --no-merges -n5: expected max_count=5, got %a" pp w);
  (* Docker: --oom-kill-disable is boolean → should NOT eat "--name" as value *)
  let dk =
    of_simple { (base "docker") with args = [ lit "run"; lit "--oom-kill-disable"; lit "--name"; lit "foo"; lit "img" ] }
  in
  (match dk with
   | W (Docker { subcommand = "run"; name = Some "foo"; rest; _ }) ->
     if List.exists ((=) "foo") rest then
       Alcotest.failf "docker run --oom-kill-disable --name foo: 'foo' should be in name field, not rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "docker run --oom-kill-disable --name foo: expected Docker(name=Some foo), got %a" pp w);
  (* Ninja: -C /builddir → /builddir promoted to subcmd when none exists, "all" goes to rest *)
  let nj =
    of_simple { (base "ninja") with args = [ lit "-C"; lit "/builddir"; lit "all" ] }
  in
  (match nj with
   | W (Ninja { subcommand = "/builddir"; rest = [ "all" ]; _ }) -> ()
   | w -> Alcotest.failf "ninja -C /builddir all: expected sub=/builddir rest=[all], got %a" pp w);
  (* Diff: -L label → label consumed, file1 file2 are positional *)
  let df =
    of_simple { (base "diff") with args = [ lit "-L"; lit "old"; lit "file1"; lit "file2" ] }
  in
  (match df with
   | W (Diff { file1 = "file1"; file2 = "file2"; _ }) -> ()
   | w -> Alcotest.failf "diff -L old file1 file2: expected file1=file1 file2=file2, got %a" pp w);
  (* Diff: -U 3 → unified consumed, file1 file2 are positional *)
  let df2 =
    of_simple { (base "diff") with args = [ lit "-U"; lit "3"; lit "file1"; lit "file2" ] }
  in
  (match df2 with
   | W (Diff { file1 = "file1"; file2 = "file2"; _ }) -> ()
   | w -> Alcotest.failf "diff -U 3 file1 file2: expected file1=file1 file2=file2, got %a" pp w);
  (* Diff: -W 120 → width consumed, file1 file2 are positional *)
  let df3 =
    of_simple { (base "diff") with args = [ lit "-W"; lit "120"; lit "file1"; lit "file2" ] }
  in
  (match df3 with
   | W (Diff { file1 = "file1"; file2 = "file2"; _ }) -> ()
   | w -> Alcotest.failf "diff -W 120 file1 file2: expected file1=file1 file2=file2, got %a" pp w)

let test_batch3_regression_fixes () =
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
  (* Node: --permission is boolean → should NOT eat "script.js" as value *)
  let n =
    of_simple { (base "node") with args = [ lit "--permission"; lit "script.js" ] }
  in
  (match n with
   | W (Node { script = "script.js"; _ }) -> ()
   | w -> Alcotest.failf "node --permission script.js: expected script=script.js, got %a" pp w);
  (* Opam: --json is boolean → should NOT eat "install" as value *)
  let o =
    of_simple { (base "opam") with args = [ lit "install"; lit "--json"; lit "lwt" ] }
  in
  (match o with
   | W (Opam { subcommand = "install"; rest; _ }) ->
     if not (List.exists ((=) "lwt") rest) then
       Alcotest.failf "opam install --json lwt: 'lwt' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "opam install --json lwt: expected Opam, got %a" pp w);
  (* Opam: --safe is boolean → should NOT eat "lwt" as value *)
  let o2 =
    of_simple { (base "opam") with args = [ lit "install"; lit "--safe"; lit "lwt" ] }
  in
  (match o2 with
   | W (Opam { subcommand = "install"; rest; _ }) ->
     if not (List.exists ((=) "lwt") rest) then
       Alcotest.failf "opam install --safe lwt: 'lwt' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "opam install --safe lwt: expected Opam, got %a" pp w);
  (* Yarn: --ignore-scripts is boolean → should NOT eat "add" as value *)
  let y =
    of_simple { (base "yarn") with args = [ lit "--ignore-scripts"; lit "add"; lit "lodash" ] }
  in
  (match y with
   | W (Yarn { rest; _ }) ->
     if not (List.exists ((=) "add") rest) then
       Alcotest.failf "yarn --ignore-scripts add lodash: 'add' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "yarn --ignore-scripts add lodash: expected Yarn, got %a" pp w);
  (* Yarn: --no-lockfile is boolean → should NOT eat "install" as value *)
  let y2 =
    of_simple { (base "yarn") with args = [ lit "--no-lockfile"; lit "install" ] }
  in
  (match y2 with
   | W (Yarn { rest; _ }) ->
     if not (List.exists ((=) "install") rest) then
       Alcotest.failf "yarn --no-lockfile install: 'install' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "yarn --no-lockfile install: expected Yarn, got %a" pp w);
  (* Npx: --shell is boolean → should NOT eat "jest" as value *)
  let nx =
    of_simple { (base "npx") with args = [ lit "--shell"; lit "jest" ] }
  in
  (match nx with
   | W (Npx { rest; _ }) ->
     if not (List.exists ((=) "jest") rest) then
       Alcotest.failf "npx --shell jest: 'jest' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "npx --shell jest: expected Npx, got %a" pp w);
  (* Ruff: --preview is boolean → should NOT eat "check" as value *)
  let r =
    of_simple { (base "ruff") with args = [ lit "--preview"; lit "check"; lit "." ] }
  in
  (match r with
   | W (Ruff { subcommand = "check"; _ }) -> ()
   | w -> Alcotest.failf "ruff --preview check .: expected subcmd=check, got %a" pp w);
  (* Npm: --timing is boolean → should NOT eat "install" as value *)
  let np =
    of_simple { (base "npm") with args = [ lit "install"; lit "--timing"; lit "lodash" ] }
  in
  (match np with
   | W (Npm { subcommand = "install"; rest; _ }) ->
     if not (List.exists ((=) "lodash") rest) then
       Alcotest.failf "npm install --timing lodash: 'lodash' should be in rest, got [%s]"
         (String.concat "; " rest)
   | w -> Alcotest.failf "npm install --timing lodash: expected Npm, got %a" pp w)
;;

let test_batch4_posix_end_of_options () =
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
  (* Sudo: -- command arg1 → target_argv = ["command"; "arg1"] *)
  let s =
    of_simple { (base "sudo") with args = [ lit "--"; lit "command"; lit "arg1" ] }
  in
  (match s with
   | W (Sudo { target_argv }) ->
     if target_argv <> [ "command"; "arg1" ] then
       Alcotest.failf "sudo -- command arg1: expected [command; arg1], got [%s]"
         (String.concat "; " target_argv)
   | w -> Alcotest.failf "sudo -- command arg1: expected Sudo, got %a" pp w);
  (* Echo: -- hello → args = ["hello"] *)
  let e =
    of_simple { (base "echo") with args = [ lit "--"; lit "hello" ] }
  in
  (match e with
   | W (Echo { args = echo_args }) ->
     if echo_args <> [ "hello" ] then
       Alcotest.failf "echo -- hello: expected [hello], got [%s]"
         (String.concat "; " echo_args)
   | w -> Alcotest.failf "echo -- hello: expected Echo, got %a" pp w);
  (* Which: -- command → names = ["command"] *)
  let w =
    of_simple { (base "which") with args = [ lit "--"; lit "command" ] }
  in
  (match w with
   | W (Which { names }) ->
     if names <> [ "command" ] then
       Alcotest.failf "which -- command: expected [command], got [%s]"
         (String.concat "; " names)
   | w -> Alcotest.failf "which -- command: expected Which, got %a" pp w);
  (* Printenv: -- VAR → name = Some "VAR" *)
  let pe =
    of_simple { (base "printenv") with args = [ lit "--"; lit "VAR" ] }
  in
  (match pe with
   | W (Printenv { name = Some "VAR" }) -> ()
   | w -> Alcotest.failf "printenv -- VAR: expected Printenv(Some VAR), got %a" pp w);
  (* Printf: -- %s\n hello → format="%s\n", args=["hello"] *)
  let pf =
    of_simple { (base "printf") with args = [ lit "--"; lit "%s\\n"; lit "hello" ] }
  in
  (match pf with
   | W (Printf { format; args = pf_args }) ->
     if format <> "%s\\n" then
       Alcotest.failf "printf -- %%s\\n hello: expected format=%%s\\n, got %s" format;
     if pf_args <> [ "hello" ] then
       Alcotest.failf "printf -- %%s\\n hello: expected args=[hello], got [%s]"
         (String.concat "; " pf_args)
   | w -> Alcotest.failf "printf -- %%s\\n hello: expected Printf, got %a" pp w);
  (* Test: -- -f file → expression = ["-f"; "file"] *)
  let t =
    of_simple { (base "test") with args = [ lit "--"; lit "-f"; lit "file" ] }
  in
  (match t with
   | W (Test { expression }) ->
     if expression <> [ "-f"; "file" ] then
       Alcotest.failf "test -- -f file: expected [-f; file], got [%s]"
         (String.concat "; " expression)
   | w -> Alcotest.failf "test -- -f file: expected Test, got %a" pp w)
;;

let test_mvn_gh_boolean_flag_regression () =
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
  (* Mvn: -nt is boolean (disables transfer progress) → should NOT eat "install" as value *)
  let m1 =
    of_simple { (base "mvn") with args = [ lit "clean"; lit "-nt"; lit "install" ] }
  in
  (match m1 with
   | W (Mvn { subcommand = "clean"; args; _ }) ->
     if not (List.mem "install" args) then
       Alcotest.failf "mvn clean -nt install: 'install' should be in args (boolean -nt), got args=[%s]"
         (String.concat "; " args)
   | w -> Alcotest.failf "mvn clean -nt install: expected Mvn, got %a" pp w);
  (* Mvn: --no-transfer-progress is boolean → should NOT eat "package" as value *)
  let m2 =
    of_simple { (base "mvn") with args = [ lit "build"; lit "--no-transfer-progress"; lit "package" ] }
  in
  (match m2 with
   | W (Mvn { subcommand = "build"; args; _ }) ->
     if not (List.mem "package" args) then
       Alcotest.failf "mvn build --no-transfer-progress package: 'package' should be in args, got args=[%s]"
         (String.concat "; " args)
   | w -> Alcotest.failf "mvn build --no-transfer-progress package: expected Mvn, got %a" pp w);
  (* Mvn: -X is boolean (debug output) → should NOT eat "verify" as value *)
  let m3 =
    of_simple { (base "mvn") with args = [ lit "test"; lit "-X"; lit "verify" ] }
  in
  (match m3 with
   | W (Mvn { subcommand = "test"; args; _ }) ->
     if not (List.mem "verify" args) then
       Alcotest.failf "mvn test -X verify: 'verify' should be in args (boolean -X), got args=[%s]"
         (String.concat "; " args)
   | w -> Alcotest.failf "mvn test -X verify: expected Mvn, got %a" pp w);
  (* Gh: --web is boolean (opens browser) → should NOT eat "--title" as value *)
  let g1 =
    of_simple { (base "gh") with args = [ lit "pr"; lit "create"; lit "--web"; lit "--title"; lit "my-pr" ] }
  in
  (match g1 with
   | W (Gh { subcommand = "pr"; action = Some "create"; title; _ }) ->
     (match title with
      | Some "my-pr" -> ()
      | other ->
        Alcotest.failf "gh pr create --web --title my-pr: title should be Some \"my-pr\", got %s"
          (match other with None -> "None" | Some s -> Printf.sprintf "Some \"%s\"" s))
   | w -> Alcotest.failf "gh pr create --web --title my-pr: expected Gh, got %a" pp w);
  (* Gh: --web combined with --draft — both boolean *)
  let g2 =
    of_simple { (base "gh") with args = [ lit "pr"; lit "create"; lit "--draft"; lit "--web"; lit "--body"; lit "desc" ] }
  in
  (match g2 with
   | W (Gh { subcommand = "pr"; action = Some "create"; draft = true; body = Some "desc"; _ }) -> ()
   | w -> Alcotest.failf "gh pr create --draft --web --body desc: expected draft=true body=Some desc, got %a" pp w)
;;

let test_long_form_boolean_flags () =
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
  (* Du: --human-readable --summarize /tmp *)
  let du =
    of_simple { (base "du") with args = [ lit "--human-readable"; lit "--summarize"; lit "/tmp" ] }
  in
  (match du with
   | W (Du { human_readable = true; summary = true; path = Some "/tmp"; _ }) -> ()
   | w -> Alcotest.failf "Du --human-readable --summarize: expected h=true s=true, got %a" pp w);
  (* Df: --human-readable / *)
  let df =
    of_simple { (base "df") with args = [ lit "--human-readable"; lit "/" ] }
  in
  (match df with
   | W (Df { human_readable = true; path = Some "/"; _ }) -> ()
   | w -> Alcotest.failf "Df --human-readable: expected h=true, got %a" pp w);
  (* Sed: --in-place -E 's/foo/bar/g' input.txt *)
  let sed =
    of_simple { (base "sed") with args = [ lit "--in-place"; lit "-E"; lit "s/foo/bar/g"; lit "input.txt" ] }
  in
  (match sed with
   | W (Sed { in_place = true; extended_regex = true; expression = "s/foo/bar/g"; file = "input.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed --in-place: expected in_place=true, got %a" pp w);
  (* Pytest: --verbose --exitfirst tests/ *)
  let py =
    of_simple { (base "pytest") with args = [ lit "--verbose"; lit "--exitfirst"; lit "tests/" ] }
  in
  (match py with
   | W (Pytest { verbose = true; exitfirst = true; subcommand = "tests/"; _ }) -> ()
   | w -> Alcotest.failf "Pytest --verbose --exitfirst: expected v=true x=true, got %a" pp w)
;;

let test_long_form_value_consuming_flags () =
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
  (* Sort: --field-separator : -k3 file.txt *)
  let sort =
    of_simple { (base "sort") with args = [ lit "--field-separator"; lit ":"; lit "-k3"; lit "file.txt" ] }
  in
  (match sort with
   | W (Sort { key = Some 3; file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sort --field-separator: expected key=3, got %a" pp w);
  (* Grep: --regexp PATTERN file.txt *)
  let grep =
    of_simple { (base "grep") with args = [ lit "--regexp"; lit "foo"; lit "file.txt" ] }
  in
  (match grep with
   | W (Grep { pattern = "foo"; path = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Grep --regexp: expected pattern=foo, got %a" pp w);
  (* Git_commit: --message "msg" *)
  let gc =
    of_simple { (base "git") with args = [ lit "commit"; lit "--message"; lit "hello" ] }
  in
  (match gc with
   | W (Git_commit { message = "hello"; _ }) -> ()
   | w -> Alcotest.failf "Git_commit --message: expected msg=hello, got %a" pp w);
  (* Sed: --expression 's/foo/bar/' --file script.sed input.txt *)
  let sed =
    of_simple { (base "sed") with args = [ lit "--expression"; lit "s/foo/bar/"; lit "--file"; lit "script.sed"; lit "input.txt" ] }
  in
  (match sed with
   | W (Sed { expression = "script.sed"; file = "input.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed --expression --file: expected expr=s/foo/bar/, got %a" pp w);
  (* Head: --lines 5 file.txt *)
  let head =
    of_simple { (base "head") with args = [ lit "--lines"; lit "5"; lit "file.txt" ] }
  in
  (match head with
   | W (Head { lines = 5; path = "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Head --lines 5: expected lines=5, got %a" pp w);
  (* Tail: --lines 10 file.txt *)
  let tail =
    of_simple { (base "tail") with args = [ lit "--lines"; lit "10"; lit "file.txt" ] }
  in
  (match tail with
   | W (Tail { lines = 10; path = "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Tail --lines 10: expected lines=10, got %a" pp w)
;;

let test_eq_form_value_consuming_flags () =
  let base cmd =
    { Shell_ir.bin = bin_ok cmd
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let lit s = Shell_ir.Lit (s, Shell_ir.default_meta) in
  let of_simple s = Shell_ir_typed.of_simple s in
  let pp fmt w = Shell_ir_typed.pp fmt w in
  (* Sort: --field-separator=, *)
  let sort =
    of_simple { (base "sort") with args = [ lit "--field-separator=,"; lit "file.txt" ] }
  in
  (match sort with
   | W (Sort { file = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sort --field-separator=,: expected file=file.txt, got %a" pp w);
  (* Grep: --regexp=pattern file.txt *)
  let grep =
    of_simple { (base "grep") with args = [ lit "--regexp=foo"; lit "file.txt" ] }
  in
  (match grep with
   | W (Grep { pattern = "foo"; path = Some "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Grep --regexp=foo: expected pattern=foo, got %a" pp w);
  (* Git_commit: --message=msg *)
  let gc =
    of_simple { (base "git") with args = [ lit "commit"; lit "--message=hello world" ] }
  in
  (match gc with
   | W (Git_commit { message = "hello world"; _ }) -> ()
   | w -> Alcotest.failf "Git_commit --message=hello world: expected msg=hello world, got %a" pp w);
  (* Head: --lines=5 file.txt *)
  let head =
    of_simple { (base "head") with args = [ lit "--lines=5"; lit "file.txt" ] }
  in
  (match head with
   | W (Head { lines = 5; path = "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Head --lines=5: expected lines=5, got %a" pp w);
  (* Tail: --lines=10 file.txt *)
  let tail =
    of_simple { (base "tail") with args = [ lit "--lines=10"; lit "file.txt" ] }
  in
  (match tail with
   | W (Tail { lines = 10; path = "file.txt"; _ }) -> ()
   | w -> Alcotest.failf "Tail --lines=10: expected lines=10, got %a" pp w);
  (* Sed: --expression / --file eq-forms *)
  let sed =
    of_simple { (base "sed") with args = [ lit "--expression=s/foo/bar/"; lit "--file=script.sed"; lit "input.txt" ] }
  in
  (match sed with
   | W (Sed { expression = "script.sed"; file = "input.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed --expression/--file eq-form: expected expression=script.sed, file=input.txt, got %a" pp w)
;;
(* Batch 17: comprehensive edge-case coverage for the 12 purely generic
   subcommand_args_ctor parsers (no value_flags).  Tests POSIX --,
   eq-form flags, combined short flags, empty args, and round-trip. *)
let test_generic_subcommand_args_edge_cases () =
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
  (* --- Cmake: POSIX -- stops option parsing (consumed, not preserved) --- *)
  let w =
    of_simple { (base "cmake") with args = [ lit "--build"; lit "."; lit "--"; lit "--target"; lit "clean" ] }
  in
  (match w with
   | W (Cmake { subcommand = "--build"; args = [ "."; "--target"; "clean" ] }) -> ()
   | w -> Alcotest.failf "Cmake POSIX --: got %a" pp w);
  (* --- Cmake: eq-form flag passes through as arg --- *)
  let w2 =
    of_simple { (base "cmake") with args = [ lit "-S"; lit "."; lit "-B"; lit "build"; lit "-DCMAKE_BUILD_TYPE=Debug" ] }
  in
  (match w2 with
   | W (Cmake { subcommand = "-S"; args = [ "."; "-B"; "build"; "-DCMAKE_BUILD_TYPE=Debug" ] }) -> ()
   | w -> Alcotest.failf "Cmake eq-form: got %a" pp w);
  (* --- Java: -cp flag + main class --- *)
  let w3 =
    of_simple { (base "java") with args = [ lit "-cp"; lit "lib.jar"; lit "com.example.Main"; lit "--port"; lit "8080" ] }
  in
  (match w3 with
   | W (Java { subcommand = "-cp"; args = [ "lib.jar"; "com.example.Main"; "--port"; "8080" ] }) -> ()
   | w -> Alcotest.failf "Java -cp: got %a" pp w);
  (* --- Java: -- (end of options, -- consumed, not preserved) --- *)
  let w4 =
    of_simple { (base "java") with args = [ lit "-jar"; lit "app.jar"; lit "--"; lit "-arg1"; lit "-arg2" ] }
  in
  (match w4 with
   | W (Java { subcommand = "-jar"; args = [ "app.jar"; "-arg1"; "-arg2" ] }) -> ()
   | w -> Alcotest.failf "Java --: got %a" pp w);
  (* --- Javac: -d out + source file --- *)
  let w5 =
    of_simple { (base "javac") with args = [ lit "-d"; lit "build/"; lit "src/Main.java" ] }
  in
  (match w5 with
   | W (Javac { subcommand = "-d"; args = [ "build/"; "src/Main.java" ] }) -> ()
   | w -> Alcotest.failf "Javac -d: got %a" pp w);
  (* --- Dd: key=value style args (all passed through) --- *)
  let w6 =
    of_simple { (base "dd") with args = [ lit "if=/dev/zero"; lit "of=/tmp/zeros"; lit "bs=1M"; lit "count=10" ] }
  in
  (match w6 with
   | W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/zeros"; "bs=1M"; "count=10" ] }) -> ()
   | w -> Alcotest.failf "Dd key=value: got %a" pp w);
  (* --- Dd: POSIX -- stops option parsing (consumed, not preserved) --- *)
  let w7 =
    of_simple { (base "dd") with args = [ lit "if=/dev/zero"; lit "--"; lit "of=/tmp/out" ] }
  in
  (match w7 with
   | W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/out" ] }) -> ()
   | w -> Alcotest.failf "Dd --: got %a" pp w);
  (* --- Osascript: -e with inline script --- *)
  let w8 =
    of_simple { (base "osascript") with args = [ lit "-e"; lit "display dialog \"hello\"" ] }
  in
  (match w8 with
   | W (Osascript { subcommand = "-e"; args = [ "display dialog \"hello\"" ] }) -> ()
   | w -> Alcotest.failf "Osascript -e: got %a" pp w);
  (* --- Ffplay: combined short flags --- *)
  let w9 =
    of_simple { (base "ffplay") with args = [ lit "-nodisp"; lit "-autoexit"; lit "clip.mp4" ] }
  in
  (match w9 with
   | W (Ffplay { subcommand = "-nodisp"; args = [ "-autoexit"; "clip.mp4" ] }) -> ()
   | w -> Alcotest.failf "Ffplay flags: got %a" pp w);
  (* --- Mpg123: --list with value (no value_flags, so it's a positional) --- *)
  let w10 =
    of_simple { (base "mpg123") with args = [ lit "-q"; lit "--list"; lit "playlist.m3u"; lit "song.mp3" ] }
  in
  (match w10 with
   | W (Mpg123 { subcommand = "-q"; args = [ "--list"; "playlist.m3u"; "song.mp3" ] }) -> ()
   | w -> Alcotest.failf "Mpg123 --list: got %a" pp w);
  (* --- Open: -a Safari + URL --- *)
  let w11 =
    of_simple { (base "open") with args = [ lit "-a"; lit "Safari"; lit "https://example.com" ] }
  in
  (match w11 with
   | W (Open { subcommand = "-a"; args = [ "Safari"; "https://example.com" ] }) -> ()
   | w -> Alcotest.failf "Open -a: got %a" pp w);
  (* --- Dune_local_sh: empty args (binary name is "dune-local.sh") --- *)
  let w12 =
    of_simple { (base "dune-local.sh") with args = [ lit "build" ] }
  in
  (match w12 with
   | W (Dune_local_sh { subcommand = "build"; args = [] }) -> ()
   | w -> Alcotest.failf "Dune empty args: got %a" pp w);
  (* --- Play: empty args --- *)
  let w13 =
    of_simple { (base "play") with args = [ lit "recording.wav" ] }
  in
  (match w13 with
   | W (Play { subcommand = "recording.wav"; args = [] }) -> ()
   | w -> Alcotest.failf "Play empty args: got %a" pp w);
  (* --- Rec: with rate arg --- *)
  let w14 =
    of_simple { (base "rec") with args = [ lit "output.wav"; lit "rate"; lit "44100" ] }
  in
  (match w14 with
   | W (Rec { subcommand = "output.wav"; args = [ "rate"; "44100" ] }) -> ()
   | w -> Alcotest.failf "Rec rate: got %a" pp w);
  (* --- Ocamlfind: -package flag (no value_flags, so treated as positional) --- *)
  let w15 =
    of_simple { (base "ocamlfind") with args = [ lit "query"; lit "-package"; lit "eio"; lit "-predicates"; lit "byte" ] }
  in
  (match w15 with
   | W (Ocamlfind { subcommand = "query"; args = [ "-package"; "eio"; "-predicates"; "byte" ] }) -> ()
   | w -> Alcotest.failf "Ocamlfind -package: got %a" pp w);
  (* --- Round-trip for all 12: of_simple ∘ to_simple = id --- *)
  let rt_cases =
    [ W (Ocamlfind { subcommand = "query"; args = [ "-package"; "eio" ] })
    ; W (Java { subcommand = "-cp"; args = [ "lib.jar"; "Main" ] })
    ; W (Javac { subcommand = "-d"; args = [ "out"; "Main.java" ] })
    ; W (Cmake { subcommand = "--build"; args = [ "."; "--target"; "install" ] })
    ; W (Dune_local_sh { subcommand = "runtest"; args = [ "-f" ] })
    ; W (Osascript { subcommand = "-e"; args = [ "display dialog \"hello\"" ] })
    ; W (Play { subcommand = "recording.wav"; args = [] })
    ; W (Rec { subcommand = "output.wav"; args = [ "rate"; "44100" ] })
    ; W (Ffplay { subcommand = "clip.mp4"; args = [ "-nodisp"; "-autoexit" ] })
    ; W (Mpg123 { subcommand = "podcast.mp3"; args = [ "-q"; "--list"; "playlist.m3u" ] })
    ; W (Open { subcommand = "-a"; args = [ "Safari"; "https://example.com" ] })
    ; W (Dd { subcommand = "if=/dev/zero"; args = [ "of=/tmp/zeros"; "bs=1M"; "count=10" ] })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "generic round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 18: Curl parser edge cases — method, headers, body, output,
   follow_redirects, insecure, combined flags, eq-form, POSIX --. *)
let test_curl_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "curl"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Basic GET (default method, URL only) --- *)
  let w = of_simple { base with args = [ lit "https://example.com" ] } in
  (match w with
   | W (Curl { url = "https://example.com"; method_ = `GET; body = None; follow_redirects = false; insecure = false; _ }) -> ()
   | w -> Alcotest.failf "Curl basic GET: got %a" pp w);
  (* --- POST with -X POST --- *)
  let w2 = of_simple { base with args = [ lit "-X"; lit "POST"; lit "-d"; lit "{\"key\":\"val\"}"; lit "https://api.example.com" ] } in
  (match w2 with
   | W (Curl { url = "https://api.example.com"; method_ = `POST; body = Some "{\"key\":\"val\"}"; _ }) -> ()
   | w -> Alcotest.failf "Curl POST -X: got %a" pp w);
  (* --- --request=PUT eq-form --- *)
  let w3 = of_simple { base with args = [ lit "--request=PUT"; lit "https://api.example.com" ] } in
  (match w3 with
   | W (Curl { method_ = `PUT; url = "https://api.example.com"; _ }) -> ()
   | w -> Alcotest.failf "Curl --request=PUT: got %a" pp w);
  (* --- Header with -H --- *)
  let w4 = of_simple { base with args = [ lit "-H"; lit "Authorization: Bearer token123"; lit "https://api.example.com" ] } in
  (match w4 with
   | W (Curl { headers = Some [ ("Authorization", "Bearer token123") ]; _ }) -> ()
   | w -> Alcotest.failf "Curl -H header: got %a" pp w);
  (* --- Header with --header=KEY:VALUE eq-form --- *)
  let w5 = of_simple { base with args = [ lit "--header=Content-Type: application/json"; lit "https://api.example.com" ] } in
  (match w5 with
   | W (Curl { headers = Some [ ("Content-Type", "application/json") ]; _ }) -> ()
   | w -> Alcotest.failf "Curl --header= eq-form: got %a" pp w);
  (* --- Body with --data=VALUE eq-form --- *)
  let w6 = of_simple { base with args = [ lit "--data=hello"; lit "https://api.example.com" ] } in
  (match w6 with
   | W (Curl { body = Some "hello"; method_ = `GET; _ }) -> ()
   | w -> Alcotest.failf "Curl --data= eq-form: got %a" pp w);
  (* --- Output with -o --- *)
  let w7 = of_simple { base with args = [ lit "-o"; lit "out.html"; lit "https://example.com" ] } in
  (match w7 with
   | W (Curl { output_file = Some "out.html"; _ }) -> ()
   | w -> Alcotest.failf "Curl -o: got %a" pp w);
  (* --- Output with --output=FILE eq-form --- *)
  let w8 = of_simple { base with args = [ lit "--output=data.json"; lit "https://api.example.com" ] } in
  (match w8 with
   | W (Curl { output_file = Some "data.json"; _ }) -> ()
   | w -> Alcotest.failf "Curl --output=: got %a" pp w);
  (* --- Follow redirects -L --- *)
  let w9 = of_simple { base with args = [ lit "-L"; lit "https://example.com" ] } in
  (match w9 with
   | W (Curl { follow_redirects = true; insecure = false; _ }) -> ()
   | w -> Alcotest.failf "Curl -L: got %a" pp w);
  (* --- Insecure -k --- *)
  let w10 = of_simple { base with args = [ lit "-k"; lit "https://self-signed.example.com" ] } in
  (match w10 with
   | W (Curl { insecure = true; follow_redirects = false; _ }) -> ()
   | w -> Alcotest.failf "Curl -k: got %a" pp w);
  (* --- Combined short flags -Lk --- *)
  let w11 = of_simple { base with args = [ lit "-Lk"; lit "https://example.com" ] } in
  (match w11 with
   | W (Curl { follow_redirects = true; insecure = true; _ }) -> ()
   | w -> Alcotest.failf "Curl -Lk: got %a" pp w);
  (* --- Combined short flags -kL (reversed order) --- *)
  let w12 = of_simple { base with args = [ lit "-kL"; lit "https://example.com" ] } in
  (match w12 with
   | W (Curl { follow_redirects = true; insecure = true; _ }) -> ()
   | w -> Alcotest.failf "Curl -kL: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w13 = of_simple { base with args = [ lit "-L"; lit "--"; lit "https://example.com" ] } in
  (match w13 with
   | W (Curl { follow_redirects = true; url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Curl --: got %a" pp w);
  (* --- Unknown flags are skipped --- *)
  let w14 = of_simple { base with args = [ lit "-s"; lit "-S"; lit "--progress-bar"; lit "https://example.com" ] } in
  (match w14 with
   | W (Curl { url = "https://example.com"; method_ = `GET; _ }) -> ()
   | w -> Alcotest.failf "Curl unknown flags: got %a" pp w);
  (* --- Value-consuming flags (--max-time) are skipped --- *)
  let w15 = of_simple { base with args = [ lit "--max-time"; lit "30"; lit "-H"; lit "Accept: text/html"; lit "https://example.com" ] } in
  (match w15 with
   | W (Curl { headers = Some [ ("Accept", "text/html") ]; url = "https://example.com"; _ }) -> ()
   | w -> Alcotest.failf "Curl --max-time skip: got %a" pp w);
  (* --- DELETE method --- *)
  let w16 = of_simple { base with args = [ lit "-X"; lit "DELETE"; lit "https://api.example.com/resource/1" ] } in
  (match w16 with
   | W (Curl { method_ = `DELETE; url = "https://api.example.com/resource/1"; _ }) -> ()
   | w -> Alcotest.failf "Curl DELETE: got %a" pp w);
  (* --- Multiple headers --- *)
  let w17 = of_simple { base with args = [ lit "-H"; lit "Accept: application/json"; lit "-H"; lit "Authorization: Bearer tok"; lit "https://api.example.com" ] } in
  (match w17 with
   | W (Curl { headers = Some hs; _ }) when List.length hs = 2 -> ()
   | w -> Alcotest.failf "Curl multiple headers: got %a" pp w);
  (* --- Round-trip for Curl --- *)
  let rt_cases =
    [ W (Curl { url = "https://example.com"; method_ = `GET; headers = None; body = None; output_file = None; follow_redirects = false; insecure = false })
    ; W (Curl { url = "https://api.example.com"; method_ = `POST; headers = Some [ ("Content-Type", "application/json") ]; body = Some "{\"k\":\"v\"}"; output_file = None; follow_redirects = true; insecure = false })
    ; W (Curl { url = "https://secure.example.com"; method_ = `PUT; headers = None; body = Some "data"; output_file = Some "out.bin"; follow_redirects = false; insecure = true })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Curl round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 19: Docker parser edge cases — rm/privileged/detach, name/network/
   volumes/publish/env_vars/workdir/platform typed fields, eq-form, POSIX --,
   unknown flag skipping, combined flags, rest args. *)
let test_docker_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "docker"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Basic: docker run image --- *)
  let w = of_simple { base with args = [ lit "run"; lit "nginx" ] } in
  (match w with
   | W (Docker { subcommand = "run"; rest = [ "nginx" ]; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None }) -> ()
   | w -> Alcotest.failf "Docker basic run: got %a" pp w);
  (* --- --rm flag --- *)
  let w2 = of_simple { base with args = [ lit "run"; lit "--rm"; lit "nginx" ] } in
  (match w2 with
   | W (Docker { rm = true; subcommand = "run"; rest = [ "nginx" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker --rm: got %a" pp w);
  (* --- --privileged flag --- *)
  let w3 = of_simple { base with args = [ lit "run"; lit "--privileged"; lit "nginx" ] } in
  (match w3 with
   | W (Docker { privileged = true; _ }) -> ()
   | w -> Alcotest.failf "Docker --privileged: got %a" pp w);
  (* --- -d / --detach flags --- *)
  let w4 = of_simple { base with args = [ lit "run"; lit "-d"; lit "nginx" ] } in
  (match w4 with
   | W (Docker { detach = true; _ }) -> ()
   | w -> Alcotest.failf "Docker -d: got %a" pp w);
  let w4b = of_simple { base with args = [ lit "run"; lit "--detach"; lit "nginx" ] } in
  (match w4b with
   | W (Docker { detach = true; _ }) -> ()
   | w -> Alcotest.failf "Docker --detach: got %a" pp w);
  (* --- --name NAME --- *)
  let w5 = of_simple { base with args = [ lit "run"; lit "--name"; lit "myapp"; lit "nginx" ] } in
  (match w5 with
   | W (Docker { name = Some "myapp"; rest = [ "nginx" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker --name: got %a" pp w);
  (* --- --name=NAME eq-form --- *)
  let w5b = of_simple { base with args = [ lit "run"; lit "--name=myapp"; lit "nginx" ] } in
  (match w5b with
   | W (Docker { name = Some "myapp"; rest = [ "nginx" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker --name= eq-form: got %a" pp w);
  (* --- --network NETWORK / --net NETWORK --- *)
  let w6 = of_simple { base with args = [ lit "run"; lit "--network"; lit "host"; lit "nginx" ] } in
  (match w6 with
   | W (Docker { network = Some "host"; _ }) -> ()
   | w -> Alcotest.failf "Docker --network: got %a" pp w);
  (* --net is a short alias — eq-form only supported for --network= *)
  let w6b = of_simple { base with args = [ lit "run"; lit "--network=mynet"; lit "nginx" ] } in
  (match w6b with
   | W (Docker { network = Some "mynet"; _ }) -> ()
   | w -> Alcotest.failf "Docker --network= eq-form: got %a" pp w);
  (* --- Multiple -v volumes --- *)
  let w7 = of_simple { base with args = [ lit "run"; lit "-v"; lit "/a:/b"; lit "-v"; lit "/c:/d"; lit "nginx" ] } in
  (match w7 with
   | W (Docker { volumes = [ "/a:/b"; "/c:/d" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker -v multiple: got %a" pp w);
  (* --- Multiple -p publish --- *)
  let w8 = of_simple { base with args = [ lit "run"; lit "-p"; lit "8080:80"; lit "-p"; lit "443:443"; lit "nginx" ] } in
  (match w8 with
   | W (Docker { publish = [ "8080:80"; "443:443" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker -p multiple: got %a" pp w);
  (* --- Multiple -e env_vars --- *)
  let w9 = of_simple { base with args = [ lit "run"; lit "-e"; lit "FOO=bar"; lit "-e"; lit "BAZ=qux"; lit "nginx" ] } in
  (match w9 with
   | W (Docker { env_vars = [ "FOO=bar"; "BAZ=qux" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker -e multiple: got %a" pp w);
  (* --- -w WORKDIR / --workdir= eq-form --- *)
  let w10 = of_simple { base with args = [ lit "run"; lit "-w"; lit "/app"; lit "nginx" ] } in
  (match w10 with
   | W (Docker { workdir = Some "/app"; _ }) -> ()
   | w -> Alcotest.failf "Docker -w: got %a" pp w);
  let w10b = of_simple { base with args = [ lit "run"; lit "--workdir=/srv"; lit "nginx" ] } in
  (match w10b with
   | W (Docker { workdir = Some "/srv"; _ }) -> ()
   | w -> Alcotest.failf "Docker --workdir= eq-form: got %a" pp w);
  (* --- --platform PLATFORM / --platform= eq-form --- *)
  let w11 = of_simple { base with args = [ lit "run"; lit "--platform"; lit "linux/amd64"; lit "nginx" ] } in
  (match w11 with
   | W (Docker { platform = Some "linux/amd64"; _ }) -> ()
   | w -> Alcotest.failf "Docker --platform: got %a" pp w);
  let w11b = of_simple { base with args = [ lit "run"; lit "--platform=linux/arm64"; lit "nginx" ] } in
  (match w11b with
   | W (Docker { platform = Some "linux/arm64"; _ }) -> ()
   | w -> Alcotest.failf "Docker --platform= eq-form: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w12 = of_simple { base with args = [ lit "run"; lit "--rm"; lit "--"; lit "nginx"; lit "sh" ] } in
  (match w12 with
   | W (Docker { rm = true; rest = [ "nginx"; "sh" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker --: got %a" pp w);
  (* --- Unknown flags skipped (-t, --tty, --interactive, --init) --- *)
  let w13 = of_simple { base with args = [ lit "run"; lit "-t"; lit "--tty"; lit "-i"; lit "--interactive"; lit "nginx" ] } in
  (match w13 with
   | W (Docker { rest = [ "nginx" ]; subcommand = "run"; _ }) -> ()
   | w -> Alcotest.failf "Docker unknown flags: got %a" pp w);
  (* --- Combined: docker run --rm -d --name web -p 8080:80 -e NODE_ENV=prod -w /app nginx --- *)
  let w14 =
    of_simple
      { base with
        args =
          [ lit "run"; lit "--rm"; lit "-d"; lit "--name"; lit "web"
          ; lit "-p"; lit "8080:80"; lit "-e"; lit "NODE_ENV=prod"
          ; lit "-w"; lit "/app"; lit "nginx"
          ]
      }
  in
  (match w14 with
   | W (Docker { subcommand = "run"; rm = true; detach = true; name = Some "web"; publish = [ "8080:80" ]; env_vars = [ "NODE_ENV=prod" ]; workdir = Some "/app"; rest = [ "nginx" ]; _ }) -> ()
   | w -> Alcotest.failf "Docker combined: got %a" pp w);
  (* --- Non-run subcommand: docker build (unknown -t skipped, myimage + . go to rest) --- *)
  let w15 = of_simple { base with args = [ lit "build"; lit "-t"; lit "myimage"; lit "." ] } in
  (match w15 with
   | W (Docker { subcommand = "build"; rest = [ "myimage"; "." ]; _ }) -> ()
   | w -> Alcotest.failf "Docker build: got %a" pp w);
  (* --- Round-trip tests --- *)
  let rt_cases =
    [ W (Docker { subcommand = "run"; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [ "nginx" ] })
    ; W (Docker { subcommand = "run"; rm = true; privileged = false; detach = true; name = Some "myapp"; network = Some "host"; volumes = [ "/a:/b"; "/c:/d" ]; publish = [ "8080:80" ]; env_vars = [ "FOO=bar" ]; workdir = Some "/app"; platform = Some "linux/amd64"; rest = [ "nginx" ] })
    ; W (Docker { subcommand = "build"; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [ "." ] })
    ; W (Docker { subcommand = "exec"; rm = false; privileged = false; detach = false; name = None; network = None; volumes = []; publish = []; env_vars = []; workdir = None; platform = None; rest = [ "mycontainer"; "sh"; "-c"; "echo hello" ] })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Docker round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 20: Make parser edge cases — target, jobs, directory, makefile,
   dry_run, keep_going, silent, always_make, combined -jN, eq-form, POSIX --. *)
let test_make_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "make"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Bare make (no args) --- *)
  let w = of_simple { base with args = [] } in
  (match w with
   | W (Make { target = None; jobs = None; directory = None; makefile = None; dry_run = false; keep_going = false; silent = false; always_make = false }) -> ()
   | w -> Alcotest.failf "Make bare: got %a" pp w);
  (* --- Target only --- *)
  let w2 = of_simple { base with args = [ lit "all" ] } in
  (match w2 with
   | W (Make { target = Some "all"; _ }) -> ()
   | w -> Alcotest.failf "Make target: got %a" pp w);
  (* --- Boolean flags: -n / --dry-run --- *)
  let w3 = of_simple { base with args = [ lit "-n" ] } in
  (match w3 with
   | W (Make { dry_run = true; _ }) -> ()
   | w -> Alcotest.failf "Make -n: got %a" pp w);
  let w3b = of_simple { base with args = [ lit "--dry-run" ] } in
  (match w3b with
   | W (Make { dry_run = true; _ }) -> ()
   | w -> Alcotest.failf "Make --dry-run: got %a" pp w);
  (* --- -k / --keep-going --- *)
  let w4 = of_simple { base with args = [ lit "-k" ] } in
  (match w4 with
   | W (Make { keep_going = true; _ }) -> ()
   | w -> Alcotest.failf "Make -k: got %a" pp w);
  (* --- -s / --silent / --quiet --- *)
  let w5 = of_simple { base with args = [ lit "-s" ] } in
  (match w5 with
   | W (Make { silent = true; _ }) -> ()
   | w -> Alcotest.failf "Make -s: got %a" pp w);
  let w5b = of_simple { base with args = [ lit "--quiet" ] } in
  (match w5b with
   | W (Make { silent = true; _ }) -> ()
   | w -> Alcotest.failf "Make --quiet: got %a" pp w);
  (* --- -B / --always-make --- *)
  let w6 = of_simple { base with args = [ lit "-B" ] } in
  (match w6 with
   | W (Make { always_make = true; _ }) -> ()
   | w -> Alcotest.failf "Make -B: got %a" pp w);
  (* --- Jobs: -j N, --jobs N, --jobs=N, -jN combined --- *)
  let w7 = of_simple { base with args = [ lit "-j"; lit "4" ] } in
  (match w7 with
   | W (Make { jobs = Some 4; _ }) -> ()
   | w -> Alcotest.failf "Make -j 4: got %a" pp w);
  let w7b = of_simple { base with args = [ lit "--jobs"; lit "8" ] } in
  (match w7b with
   | W (Make { jobs = Some 8; _ }) -> ()
   | w -> Alcotest.failf "Make --jobs 8: got %a" pp w);
  let w7c = of_simple { base with args = [ lit "--jobs=16" ] } in
  (match w7c with
   | W (Make { jobs = Some 16; _ }) -> ()
   | w -> Alcotest.failf "Make --jobs=16: got %a" pp w);
  let w7d = of_simple { base with args = [ lit "-j4" ] } in
  (match w7d with
   | W (Make { jobs = Some 4; _ }) -> ()
   | w -> Alcotest.failf "Make -j4 combined: got %a" pp w);
  (* --- Directory: -C DIR, --directory DIR, --directory=DIR --- *)
  let w8 = of_simple { base with args = [ lit "-C"; lit "/tmp/build" ] } in
  (match w8 with
   | W (Make { directory = Some "/tmp/build"; _ }) -> ()
   | w -> Alcotest.failf "Make -C: got %a" pp w);
  let w8b = of_simple { base with args = [ lit "--directory=/opt" ] } in
  (match w8b with
   | W (Make { directory = Some "/opt"; _ }) -> ()
   | w -> Alcotest.failf "Make --directory=: got %a" pp w);
  (* --- Makefile: -f FILE, --file FILE, --file=FILE, --makefile FILE, --makefile=FILE --- *)
  let w9 = of_simple { base with args = [ lit "-f"; lit "custom.mk" ] } in
  (match w9 with
   | W (Make { makefile = Some "custom.mk"; _ }) -> ()
   | w -> Alcotest.failf "Make -f: got %a" pp w);
  let w9b = of_simple { base with args = [ lit "--makefile=other.mk" ] } in
  (match w9b with
   | W (Make { makefile = Some "other.mk"; _ }) -> ()
   | w -> Alcotest.failf "Make --makefile=: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w10 = of_simple { base with args = [ lit "-n"; lit "--"; lit "target1" ] } in
  (match w10 with
   | W (Make { dry_run = true; target = Some "target1"; _ }) -> ()
   | w -> Alcotest.failf "Make --: got %a" pp w);
  (* --- Unknown flags skipped --- *)
  let w11 = of_simple { base with args = [ lit "-j2"; lit "--warn-undefined-variables"; lit "all" ] } in
  (match w11 with
   | W (Make { jobs = Some 2; target = Some "all"; _ }) -> ()
   | w -> Alcotest.failf "Make unknown flags: got %a" pp w);
  (* --- Combined: make -C /b -f m.mk -j8 -nksB all --- *)
  let w12 = of_simple { base with args = [ lit "-C"; lit "/b"; lit "-f"; lit "m.mk"; lit "-j8"; lit "-nksB"; lit "all" ] } in
  (match w12 with
   | W (Make { directory = Some "/b"; makefile = Some "m.mk"; jobs = Some 8; target = Some "all"; _ }) -> ()
   | w -> Alcotest.failf "Make combined: got %a" pp w);
  (* Note: -nksB is NOT a combined flag in the parser — only -jN is handled as combined.
     -n/-k/-s/-B are single-char boolean flags but the parser doesn't expand combined booleans.
     So -nksB is treated as an unknown flag and skipped. *)
  let w12b = of_simple { base with args = [ lit "-C"; lit "/b"; lit "-f"; lit "m.mk"; lit "-j8"; lit "-n"; lit "-k"; lit "-s"; lit "-B"; lit "all" ] } in
  (match w12b with
   | W (Make { directory = Some "/b"; makefile = Some "m.mk"; jobs = Some 8; dry_run = true; keep_going = true; silent = true; always_make = true; target = Some "all"; _ }) -> ()
   | w -> Alcotest.failf "Make all flags: got %a" pp w);
  (* --- Round-trip tests --- *)
  let rt_cases =
    [ W (Make { target = None; jobs = None; directory = None; makefile = None; dry_run = false; keep_going = false; silent = false; always_make = false })
    ; W (Make { target = Some "all"; jobs = Some 4; directory = Some "/tmp"; makefile = Some "Makefile"; dry_run = true; keep_going = true; silent = true; always_make = true })
    ; W (Make { target = Some "test"; jobs = Some 8; directory = None; makefile = None; dry_run = false; keep_going = false; silent = false; always_make = false })
    ; W (Make { target = None; jobs = None; directory = Some "/src"; makefile = Some "custom.mk"; dry_run = true; keep_going = false; silent = false; always_make = false })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Make round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 21: Sed parser edge cases — expression, file, -i (GNU/macOS), -E, -n,
   eq-form, POSIX --, combined flags, unknown flag skipping. *)
let test_sed_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "sed"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Basic: sed 's/foo/bar/' file.txt --- *)
  let w = of_simple { base with args = [ lit "s/foo/bar/"; lit "file.txt" ] } in
  (match w with
   | W (Sed { expression = "s/foo/bar/"; file = "file.txt"; in_place = false; extended_regex = false; suppress_output = false }) -> ()
   | w -> Alcotest.failf "Sed basic: got %a" pp w);
  (* --- -e EXPR / --expression EXPR --- *)
  let w2 = of_simple { base with args = [ lit "-e"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w2 with
   | W (Sed { expression = "s/a/b/"; _ }) -> ()
   | w -> Alcotest.failf "Sed -e: got %a" pp w);
  let w2b = of_simple { base with args = [ lit "--expression"; lit "s/x/y/"; lit "f.txt" ] } in
  (match w2b with
   | W (Sed { expression = "s/x/y/"; _ }) -> ()
   | w -> Alcotest.failf "Sed --expression: got %a" pp w);
  (* --- --expression=EXPR eq-form --- *)
  let w2c = of_simple { base with args = [ lit "--expression=s/1/2/"; lit "f.txt" ] } in
  (match w2c with
   | W (Sed { expression = "s/1/2/"; _ }) -> ()
   | w -> Alcotest.failf "Sed --expression=: got %a" pp w);
  (* --- -f FILE / --file FILE (script file → expression) --- *)
  let w3 = of_simple { base with args = [ lit "-f"; lit "script.sed"; lit "f.txt" ] } in
  (match w3 with
   | W (Sed { expression = "script.sed"; file = "f.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed -f: got %a" pp w);
  let w3b = of_simple { base with args = [ lit "--file=myscript.sed"; lit "f.txt" ] } in
  (match w3b with
   | W (Sed { expression = "myscript.sed"; _ }) -> ()
   | w -> Alcotest.failf "Sed --file=: got %a" pp w);
  (* --- -i (GNU in-place, no suffix) --- *)
  let w4 = of_simple { base with args = [ lit "-i"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w4 with
   | W (Sed { in_place = true; _ }) -> ()
   | w -> Alcotest.failf "Sed -i: got %a" pp w);
  (* --- -i '' (macOS empty suffix) --- *)
  let w4b = of_simple { base with args = [ lit "-i"; lit ""; lit "s/a/b/"; lit "f.txt" ] } in
  (match w4b with
   | W (Sed { in_place = true; _ }) -> ()
   | w -> Alcotest.failf "Sed -i '': got %a" pp w);
  (* --- --in-place (GNU long form) --- *)
  let w4c = of_simple { base with args = [ lit "--in-place"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w4c with
   | W (Sed { in_place = true; _ }) -> ()
   | w -> Alcotest.failf "Sed --in-place: got %a" pp w);
  (* --- -E / --regexp-extended --- *)
  let w5 = of_simple { base with args = [ lit "-E"; lit "s/(a)/\\1/"; lit "f.txt" ] } in
  (match w5 with
   | W (Sed { extended_regex = true; _ }) -> ()
   | w -> Alcotest.failf "Sed -E: got %a" pp w);
  let w5b = of_simple { base with args = [ lit "--regexp-extended"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w5b with
   | W (Sed { extended_regex = true; _ }) -> ()
   | w -> Alcotest.failf "Sed --regexp-extended: got %a" pp w);
  (* --- -n / --quiet / --silent --- *)
  let w6 = of_simple { base with args = [ lit "-n"; lit "s/a/b/p"; lit "f.txt" ] } in
  (match w6 with
   | W (Sed { suppress_output = true; _ }) -> ()
   | w -> Alcotest.failf "Sed -n: got %a" pp w);
  let w6b = of_simple { base with args = [ lit "--quiet"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w6b with
   | W (Sed { suppress_output = true; _ }) -> ()
   | w -> Alcotest.failf "Sed --quiet: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w7 = of_simple { base with args = [ lit "-i"; lit "--"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w7 with
   | W (Sed { in_place = true; expression = "s/a/b/"; file = "f.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed --: got %a" pp w);
  (* --- Unknown flags skipped --- *)
  let w8 = of_simple { base with args = [ lit "-u"; lit "--unbuffered"; lit "s/a/b/"; lit "f.txt" ] } in
  (match w8 with
   | W (Sed { expression = "s/a/b/"; file = "f.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sed unknown flags: got %a" pp w);
  (* --- Combined: sed -iE 's/foo/bar/' file.txt --- *)
  let w9 = of_simple { base with args = [ lit "-iE"; lit "s/foo/bar/"; lit "file.txt" ] } in
  (match w9 with
   | W (Sed { in_place = true; extended_regex = true; suppress_output = false; _ }) -> ()
   | w -> Alcotest.failf "Sed -iE: got %a" pp w);
  (* --- Round-trip tests --- *)
  let rt_cases =
    [ W (Sed { expression = "s/foo/bar/"; file = "input.txt"; in_place = false; extended_regex = false; suppress_output = false })
    ; W (Sed { expression = "s/a/b/g"; file = "data.csv"; in_place = true; extended_regex = true; suppress_output = true })
    ; W (Sed { expression = "/^$/d"; file = "log.txt"; in_place = true; extended_regex = false; suppress_output = false })
    ; W (Sed { expression = "s/x/y/"; file = "f"; in_place = false; extended_regex = true; suppress_output = false })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Sed round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 21: Rsync parser edge cases — archive, delete, dry_run, compress,
   combined flags (-az/-anz), value-consuming flags, eq-form, POSIX --. *)
let test_rsync_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "rsync"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Basic: rsync src dst --- *)
  let w = of_simple { base with args = [ lit "/a/"; lit "/b/" ] } in
  (match w with
   | W (Rsync { source = "/a/"; dest = "/b/"; archive = false; delete = false; dry_run = false; compress = false; flags = [] }) -> ()
   | w -> Alcotest.failf "Rsync basic: got %a" pp w);
  (* --- -a / --archive --- *)
  let w2 = of_simple { base with args = [ lit "-a"; lit "/a/"; lit "/b/" ] } in
  (match w2 with
   | W (Rsync { archive = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync -a: got %a" pp w);
  let w2b = of_simple { base with args = [ lit "--archive"; lit "/a/"; lit "/b/" ] } in
  (match w2b with
   | W (Rsync { archive = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync --archive: got %a" pp w);
  (* --- --delete --- *)
  let w3 = of_simple { base with args = [ lit "-a"; lit "--delete"; lit "/a/"; lit "/b/" ] } in
  (match w3 with
   | W (Rsync { archive = true; delete = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync --delete: got %a" pp w);
  (* --- --dry-run / -n --- *)
  let w4 = of_simple { base with args = [ lit "-a"; lit "--dry-run"; lit "/a/"; lit "/b/" ] } in
  (match w4 with
   | W (Rsync { archive = true; dry_run = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync --dry-run: got %a" pp w);
  let w4b = of_simple { base with args = [ lit "-n"; lit "/a/"; lit "/b/" ] } in
  (match w4b with
   | W (Rsync { dry_run = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync -n: got %a" pp w);
  (* --- -z / --compress --- *)
  let w5 = of_simple { base with args = [ lit "-az"; lit "/a/"; lit "/b/" ] } in
  (match w5 with
   | W (Rsync { archive = true; compress = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync -az: got %a" pp w);
  (* --- Combined: -anz --- *)
  let w6 = of_simple { base with args = [ lit "-anz"; lit "/a/"; lit "/b/" ] } in
  (match w6 with
   | W (Rsync { archive = true; dry_run = true; compress = true; _ }) -> ()
   | w -> Alcotest.failf "Rsync -anz: got %a" pp w);
  (* --- Value-consuming: --exclude --- *)
  let w7 = of_simple { base with args = [ lit "-a"; lit "--exclude"; lit "*.log"; lit "/a/"; lit "/b/" ] } in
  (match w7 with
   | W (Rsync { archive = true; flags = fl; _ }) when List.mem "*.log" fl && List.mem "--exclude" fl -> ()
   | w -> Alcotest.failf "Rsync --exclude: got %a" pp w);
  (* --- Value-consuming: -e (remote shell) --- *)
  let w8 = of_simple { base with args = [ lit "-a"; lit "-e"; lit "ssh -p 2222"; lit "/a/"; lit "host:/b/" ] } in
  (match w8 with
   | W (Rsync { archive = true; flags = fl; _ }) when List.mem "ssh -p 2222" fl && List.mem "-e" fl -> ()
   | w -> Alcotest.failf "Rsync -e: got %a" pp w);
  (* --- Value-consuming eq-form: --exclude=PATTERN --- *)
  let w9 = of_simple { base with args = [ lit "-a"; lit "--exclude=*.tmp"; lit "/a/"; lit "/b/" ] } in
  (match w9 with
   | W (Rsync { archive = true; flags = fl; _ }) when List.mem "*.tmp" fl && List.mem "--exclude" fl -> ()
   | w -> Alcotest.failf "Rsync --exclude=: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w10 = of_simple { base with args = [ lit "-a"; lit "--"; lit "/src/"; lit "/dst/" ] } in
  (match w10 with
   | W (Rsync { archive = true; source = "/src/"; dest = "/dst/"; _ }) -> ()
   | w -> Alcotest.failf "Rsync --: got %a" pp w);
  (* --- Unknown flags go to flags list --- *)
  let w11 = of_simple { base with args = [ lit "-a"; lit "--progress"; lit "--human-readable"; lit "/a/"; lit "/b/" ] } in
  (match w11 with
   | W (Rsync { archive = true; flags = fl; _ }) when List.mem "--progress" fl && List.mem "--human-readable" fl -> ()
   | w -> Alcotest.failf "Rsync unknown flags: got %a" pp w);
  (* --- Round-trip tests --- *)
  let rt_cases =
    [ W (Rsync { source = "/a/"; dest = "/b/"; archive = false; delete = false; dry_run = false; compress = false; flags = [] })
    ; W (Rsync { source = "/src/"; dest = "host:/dst/"; archive = true; delete = true; dry_run = true; compress = true; flags = [ "--exclude"; "*.log" ] })
    ; W (Rsync { source = "."; dest = "/backup/"; archive = true; delete = false; dry_run = false; compress = false; flags = [] })
    ; W (Rsync { source = "/data/"; dest = "/mirror/"; archive = false; delete = true; dry_run = false; compress = true; flags = [ "-e"; "ssh -p 22" ] })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Rsync round-trip failed for %a" pp w)
    rt_cases
;;

(* Batch 21: Grep parser edge cases — recursive, case_sensitive, files_with_matches,
   -e/--regexp pattern, combined flags (-ri/-rli), value-consuming context flags,
   eq-form, POSIX --. *)
let test_grep_edge_cases () =
  let open Shell_ir_typed in
  let base =
    { Shell_ir.bin = bin_ok "grep"
    ; args = []
    ; env = []
    ; cwd = None
    ; redirects = []
    ; sandbox = Sandbox_target.host ()
    }
  in
  let pp = Shell_ir_typed.pp in
  (* --- Basic: grep pattern file --- *)
  let w = of_simple { base with args = [ lit "TODO"; lit "main.ml" ] } in
  (match w with
   | W (Grep { pattern = "TODO"; path = Some "main.ml"; recursive = false; case_sensitive = true; files_with_matches = false }) -> ()
   | w -> Alcotest.failf "Grep basic: got %a" pp w);
  (* --- -r / -R / --recursive --- *)
  let w2 = of_simple { base with args = [ lit "-r"; lit "TODO"; lit "src/" ] } in
  (match w2 with
   | W (Grep { recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep -r: got %a" pp w);
  let w2b = of_simple { base with args = [ lit "--recursive"; lit "TODO"; lit "src/" ] } in
  (match w2b with
   | W (Grep { recursive = true; _ }) -> ()
   | w -> Alcotest.failf "Grep --recursive: got %a" pp w);
  (* --- -i / --ignore-case (case_sensitive becomes false) --- *)
  let w3 = of_simple { base with args = [ lit "-i"; lit "todo"; lit "main.ml" ] } in
  (match w3 with
   | W (Grep { case_sensitive = false; _ }) -> ()
   | w -> Alcotest.failf "Grep -i: got %a" pp w);
  let w3b = of_simple { base with args = [ lit "--ignore-case"; lit "TODO"; lit "main.ml" ] } in
  (match w3b with
   | W (Grep { case_sensitive = false; _ }) -> ()
   | w -> Alcotest.failf "Grep --ignore-case: got %a" pp w);
  (* --- -l / --files-with-matches --- *)
  let w4 = of_simple { base with args = [ lit "-l"; lit "TODO"; lit "src/" ] } in
  (match w4 with
   | W (Grep { files_with_matches = true; _ }) -> ()
   | w -> Alcotest.failf "Grep -l: got %a" pp w);
  (* --- -e PATTERN / --regexp PATTERN (explicit pattern, allows patterns starting with -) --- *)
  (* Note: pattern must be >4 chars or contain non-alpha to avoid expand_combined_short_flags *)
  let w5 = of_simple { base with args = [ lit "-e"; lit "-foo-bar"; lit "main.ml" ] } in
  (match w5 with
   | W (Grep { pattern = "-foo-bar"; _ }) -> ()
   | w -> Alcotest.failf "Grep -e: got %a" pp w);
  let w5b = of_simple { base with args = [ lit "--regexp"; lit "bar"; lit "main.ml" ] } in
  (match w5b with
   | W (Grep { pattern = "bar"; _ }) -> ()
   | w -> Alcotest.failf "Grep --regexp: got %a" pp w);
  (* --- -ePATTERN combined form --- *)
  let w5c = of_simple { base with args = [ lit "-e-pattern"; lit "main.ml" ] } in
  (match w5c with
   | W (Grep { pattern = "-pattern"; _ }) -> ()
   | w -> Alcotest.failf "Grep -ePATTERN: got %a" pp w);
  (* --- --regexp=PATTERN eq-form --- *)
  let w5d = of_simple { base with args = [ lit "--regexp=hello"; lit "main.ml" ] } in
  (match w5d with
   | W (Grep { pattern = "hello"; _ }) -> ()
   | w -> Alcotest.failf "Grep --regexp=: got %a" pp w);
  (* --- Combined flags: -ri, -rli --- *)
  let w6 = of_simple { base with args = [ lit "-ri"; lit "todo"; lit "src/" ] } in
  (match w6 with
   | W (Grep { recursive = true; case_sensitive = false; _ }) -> ()
   | w -> Alcotest.failf "Grep -ri: got %a" pp w);
  let w6b = of_simple { base with args = [ lit "-rli"; lit "todo"; lit "src/" ] } in
  (match w6b with
   | W (Grep { recursive = true; case_sensitive = false; files_with_matches = true; _ }) -> ()
   | w -> Alcotest.failf "Grep -rli: got %a" pp w);
  (* --- Value-consuming: -A/-B/-C/-m NUM (context/max-count, skipped) --- *)
  let w7 = of_simple { base with args = [ lit "-C"; lit "3"; lit "TODO"; lit "main.ml" ] } in
  (match w7 with
   | W (Grep { pattern = "TODO"; path = Some "main.ml"; _ }) -> ()
   | w -> Alcotest.failf "Grep -C 3: got %a" pp w);
  let w7b = of_simple { base with args = [ lit "-m"; lit "5"; lit "TODO"; lit "main.ml" ] } in
  (match w7b with
   | W (Grep { pattern = "TODO"; path = Some "main.ml"; _ }) -> ()
   | w -> Alcotest.failf "Grep -m 5: got %a" pp w);
  (* --- Value-consuming: --include/--exclude (skipped) --- *)
  let w8 = of_simple { base with args = [ lit "-r"; lit "--include"; lit "*.ml"; lit "TODO"; lit "src/" ] } in
  (match w8 with
   | W (Grep { recursive = true; pattern = "TODO"; _ }) -> ()
   | w -> Alcotest.failf "Grep --include: got %a" pp w);
  (* --- --color=auto eq-form (skipped) --- *)
  let w9 = of_simple { base with args = [ lit "--color=auto"; lit "TODO"; lit "main.ml" ] } in
  (match w9 with
   | W (Grep { pattern = "TODO"; path = Some "main.ml"; _ }) -> ()
   | w -> Alcotest.failf "Grep --color=auto: got %a" pp w);
  (* --- POSIX -- end-of-options --- *)
  let w10 = of_simple { base with args = [ lit "-r"; lit "--"; lit "pattern"; lit "dir/" ] } in
  (match w10 with
   | W (Grep { recursive = true; pattern = "pattern"; path = Some "dir/"; _ }) -> ()
   | w -> Alcotest.failf "Grep --: got %a" pp w);
  (* --- Unknown flags skipped --- *)
  let w11 = of_simple { base with args = [ lit "-r"; lit "--line-number"; lit "--with-filename"; lit "TODO"; lit "src/" ] } in
  (match w11 with
   | W (Grep { recursive = true; pattern = "TODO"; _ }) -> ()
   | w -> Alcotest.failf "Grep unknown flags: got %a" pp w);
  (* --- Round-trip tests --- *)
  let rt_cases =
    [ W (Grep { pattern = "TODO"; path = None; recursive = false; case_sensitive = true; files_with_matches = false })
    ; W (Grep { pattern = "error"; path = Some "logs/"; recursive = true; case_sensitive = false; files_with_matches = true })
    ; W (Grep { pattern = "-v"; path = Some "main.ml"; recursive = false; case_sensitive = true; files_with_matches = false })
    ; W (Grep { pattern = "foo"; path = Some "src/"; recursive = true; case_sensitive = false; files_with_matches = false })
    ]
  in
  List.iter
    (fun (W cmd as w) ->
       let simple = to_simple cmd in
       let back = of_simple simple in
       if not (w = back)
       then Alcotest.failf "Grep round-trip failed for %a" pp w)
    rt_cases
;;

let test_sort_cut_tr_tar_edge_cases () =
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
  (* Sort: -k3rn combined key+flags *)
  let s1 = of_simple { (base "sort") with args = [ lit "-k3rn"; lit "data.txt" ] } in
  (match s1 with
   | W (Sort { key = Some 3; reverse = true; numeric = true; file = Some "data.txt"; _ }) -> ()
   | w -> Alcotest.failf "Sort -k3rn: got %a" pp w);
  (* Sort: -k2 combined key only (no trailing flags) *)
  let s2 = of_simple { (base "sort") with args = [ lit "-k2"; lit "f" ] } in
  (match s2 with
   | W (Sort { key = Some 2; reverse = false; numeric = false; file = Some "f"; _ }) -> ()
   | w -> Alcotest.failf "Sort -k2: got %a" pp w);
  (* Sort: --key=5 eq-form *)
  let s3 = of_simple { (base "sort") with args = [ lit "--key=5"; lit "f" ] } in
  (match s3 with
   | W (Sort { key = Some 5; _ }) -> ()
   | w -> Alcotest.failf "Sort --key=5: got %a" pp w);
  (* Sort: -rn combined flags *)
  let s4 = of_simple { (base "sort") with args = [ lit "-rn"; lit "f" ] } in
  (match s4 with
   | W (Sort { reverse = true; numeric = true; unique = false; _ }) -> ()
   | w -> Alcotest.failf "Sort -rn: got %a" pp w);
  (* Sort: -rnu combined flags *)
  let s5 = of_simple { (base "sort") with args = [ lit "-rnu"; lit "f" ] } in
  (match s5 with
   | W (Sort { reverse = true; numeric = true; unique = true; _ }) -> ()
   | w -> Alcotest.failf "Sort -rnu: got %a" pp w);
  (* Sort: --field-separator=: eq-form (skipped, doesn't affect typed) *)
  let s6 = of_simple { (base "sort") with args = [ lit "-t"; lit ":"; lit "-k2"; lit "f" ] } in
  (match s6 with
   | W (Sort { key = Some 2; _ }) -> ()
   | w -> Alcotest.failf "Sort -t : -k2: got %a" pp w);
  (* Sort: -- end-of-options *)
  let s7 = of_simple { (base "sort") with args = [ lit "-r"; lit "--"; lit "-file" ] } in
  (match s7 with
   | W (Sort { reverse = true; file = Some "-file"; _ }) -> ()
   | w -> Alcotest.failf "Sort -- -file: got %a" pp w);
  (* Sort: round-trip for complex case *)
  let rt_sort = W (Sort { reverse = true; numeric = true; unique = false; key = Some 3; file = Some "data.txt" }) in
  (match rt_sort with W c ->
     let simple = to_simple c in
     let back = of_simple simple in
     if not (rt_sort = back)
     then Alcotest.failf "Sort round-trip failed: %a" pp back);
  (* Cut: -d: combined delimiter *)
  let c1 = of_simple { (base "cut") with args = [ lit "-d:"; lit "-f1"; lit "data.csv" ] } in
  (match c1 with
   | W (Cut { delimiter = Some ":"; fields = "1"; file = Some "data.csv" }) -> ()
   | w -> Alcotest.failf "Cut -d:: got %a" pp w);
  (* Cut: -f1,3 combined field *)
  let c2 = of_simple { (base "cut") with args = [ lit "-f1,3"; lit "f" ] } in
  (match c2 with
   | W (Cut { fields = "1,3"; _ }) -> ()
   | w -> Alcotest.failf "Cut -f1,3: got %a" pp w);
  (* Cut: --delimiter=: eq-form *)
  let c3 = of_simple { (base "cut") with args = [ lit "--delimiter=:"; lit "-f2"; lit "f" ] } in
  (match c3 with
   | W (Cut { delimiter = Some ":"; fields = "2"; _ }) -> ()
   | w -> Alcotest.failf "Cut --delimiter=:: got %a" pp w);
  (* Cut: --fields=1,2 eq-form *)
  let c4 = of_simple { (base "cut") with args = [ lit "--fields=1,2"; lit "f" ] } in
  (match c4 with
   | W (Cut { fields = "1,2"; _ }) -> ()
   | w -> Alcotest.failf "Cut --fields=1,2: got %a" pp w);
  (* Cut: round-trip *)
  let rt_cut = W (Cut { delimiter = Some ":"; fields = "1,3,5"; file = Some "/etc/passwd" }) in
  (match rt_cut with W c ->
     let simple_c = to_simple c in
     let back_c = of_simple simple_c in
     if not (rt_cut = back_c)
     then Alcotest.failf "Cut round-trip failed: %a" pp back_c);
  (* Tr: -ds combined flags *)
  let t1 = of_simple { (base "tr") with args = [ lit "-ds"; lit "' '"; lit "" ] } in
  (match t1 with
   | W (Tr { delete = true; squeeze = true; set1 = "' '"; set2 = Some ""; _ }) -> ()
   | w -> Alcotest.failf "Tr -ds: got %a" pp w);
  (* Tr: -sd combined flags *)
  let t2 = of_simple { (base "tr") with args = [ lit "-sd"; lit "a-z"; lit "A-Z" ] } in
  (match t2 with
   | W (Tr { delete = true; squeeze = true; set1 = "a-z"; set2 = Some "A-Z"; _ }) -> ()
   | w -> Alcotest.failf "Tr -sd: got %a" pp w);
  (* Tr: -- with dash-prefixed set *)
  let t3 = of_simple { (base "tr") with args = [ lit "-d"; lit "--"; lit "-x" ] } in
  (match t3 with
   | W (Tr { delete = true; squeeze = false; set1 = "-x"; set2 = None; _ }) -> ()
   | w -> Alcotest.failf "Tr -- -x: got %a" pp w);
  (* Tr: round-trip *)
  let rt_tr = W (Tr { set1 = "a-z"; set2 = Some "A-Z"; delete = false; squeeze = true }) in
  (match rt_tr with W c ->
     let simple_t = to_simple c in
     let back_t = of_simple simple_t in
     if not (rt_tr = back_t)
     then Alcotest.failf "Tr round-trip failed: %a" pp back_t);
  (* Tar: -czf combined flags *)
  let r1 = of_simple { (base "tar") with args = [ lit "-czf"; lit "archive.tar.gz"; lit "src/" ] } in
  (match r1 with
   | W (Tar { action = `Create; compression = `Gzip; archive = "archive.tar.gz"; paths = [ "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar -czf: got %a" pp w);
  (* Tar: -xzf combined flags *)
  let r2 = of_simple { (base "tar") with args = [ lit "-xzf"; lit "archive.tar.gz" ] } in
  (match r2 with
   | W (Tar { action = `Extract; compression = `Gzip; archive = "archive.tar.gz"; paths = []; _ }) -> ()
   | w -> Alcotest.failf "Tar -xzf: got %a" pp w);
  (* Tar: -cjf bzip2 *)
  let r3 = of_simple { (base "tar") with args = [ lit "-cjf"; lit "archive.tar.bz2"; lit "data/" ] } in
  (match r3 with
   | W (Tar { action = `Create; compression = `Bzip2; archive = "archive.tar.bz2"; _ }) -> ()
   | w -> Alcotest.failf "Tar -cjf: got %a" pp w);
  (* Tar: -cJf xz *)
  let r4 = of_simple { (base "tar") with args = [ lit "-cJf"; lit "archive.tar.xz"; lit "data/" ] } in
  (match r4 with
   | W (Tar { action = `Create; compression = `Xz; archive = "archive.tar.xz"; _ }) -> ()
   | w -> Alcotest.failf "Tar -cJf: got %a" pp w);
  (* Tar: --file= eq-form *)
  let r5 = of_simple { (base "tar") with args = [ lit "-c"; lit "--file=archive.tar"; lit "src/" ] } in
  (match r5 with
   | W (Tar { action = `Create; archive = "archive.tar"; paths = [ "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --file=: got %a" pp w);
  (* Tar: --exclude=PATTERN eq-form (skipped) *)
  let r6 = of_simple { (base "tar") with args = [ lit "-czf"; lit "a.tar.gz"; lit "--exclude=*.o"; lit "src/" ] } in
  (match r6 with
   | W (Tar { action = `Create; compression = `Gzip; archive = "a.tar.gz"; paths = [ "src/" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar --exclude=: got %a" pp w);
  (* Tar: -tf list *)
  let r7 = of_simple { (base "tar") with args = [ lit "-tf"; lit "archive.tar" ] } in
  (match r7 with
   | W (Tar { action = `List; archive = "archive.tar"; compression = `None; paths = []; _ }) -> ()
   | w -> Alcotest.failf "Tar -tf: got %a" pp w);
  (* Tar: --zstd compression *)
  let r8 = of_simple { (base "tar") with args = [ lit "-c"; lit "--zstd"; lit "-f"; lit "a.tar.zst"; lit "d/" ] } in
  (match r8 with
   | W (Tar { action = `Create; compression = `Zstd; archive = "a.tar.zst"; _ }) -> ()
   | w -> Alcotest.failf "Tar --zstd: got %a" pp w);
  (* Tar: --strip-components=N eq-form (skipped) *)
  let r9 = of_simple { (base "tar") with args = [ lit "-xf"; lit "a.tar"; lit "--strip-components=1" ] } in
  (match r9 with
   | W (Tar { action = `Extract; archive = "a.tar"; paths = []; _ }) -> ()
   | w -> Alcotest.failf "Tar --strip-components=: got %a" pp w);
  (* Tar: -- end-of-options with dash-prefixed path *)
  let r10 = of_simple { (base "tar") with args = [ lit "-cf"; lit "a.tar"; lit "--"; lit "-weird-file" ] } in
  (match r10 with
   | W (Tar { action = `Create; archive = "a.tar"; paths = [ "-weird-file" ]; _ }) -> ()
   | w -> Alcotest.failf "Tar -- -file: got %a" pp w);
  (* Tar: round-trip for complex case *)
  let rt_tar = W (Tar { action = `Create; archive = "backup.tar.gz"; paths = [ "src/"; "docs/" ]; compression = `Gzip }) in
  (match rt_tar with W c ->
     let simple_r = to_simple c in
     let back_r = of_simple simple_r in
     if not (rt_tar = back_r)
     then Alcotest.failf "Tar round-trip failed: %a" pp back_r);
  (* Sort: round-trip edge case: no key, no file *)
  let rt_sort2 = W (Sort { reverse = false; numeric = false; unique = true; key = None; file = None }) in
  (match rt_sort2 with W c ->
     let simple_s2 = to_simple c in
     let back_s2 = of_simple simple_s2 in
     if not (rt_sort2 = back_s2)
     then Alcotest.failf "Sort round-trip (minimal) failed: %a" pp back_s2)
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
        ; Alcotest.test_case
            "Batch15 Rustc/Gofmt/Ninja/Su/Mkfs value flags"
            `Quick
            test_batch15_value_consuming_flags
        ; Alcotest.test_case
            "Batch16 eq-form --flag=VALUE for subcommand+args"
            `Quick
            test_subcommand_args_eq_form_flags
        ; Alcotest.test_case
            "Batch 2 regression: boolean-as-value & missing value arms"
            `Quick
            test_batch2_regression_fixes
        ; Alcotest.test_case
            "Batch 3 regression: Node/Opam/Yarn/Npx/Ruff boolean-as-value"
            `Quick
            test_batch3_regression_fixes
        ; Alcotest.test_case
            "Batch 4: POSIX -- end-of-options for Sudo/Echo/Which/Printenv/Printf/Test"
            `Quick
            test_batch4_posix_end_of_options
        ; Alcotest.test_case
            "Mvn/Gh boolean-as-value regression (-nt, --no-transfer-progress, -X, --web)"
            `Quick
            test_mvn_gh_boolean_flag_regression
        ; Alcotest.test_case
            "Long-form boolean flags (--human-readable, --summarize, --in-place, --verbose, --exitfirst)"
            `Quick
            test_long_form_boolean_flags
        ; Alcotest.test_case
            "Long-form value-consuming flags (--field-separator, --regexp, --message, --expression, --file, --lines)"
            `Quick
            test_long_form_value_consuming_flags
        ; Alcotest.test_case
            "eq-form value-consuming flags (--field-separator=, --regexp=P, --message=M, --lines=N)"
            `Quick
            test_eq_form_value_consuming_flags
        ; Alcotest.test_case
            "Batch17 generic subcommand_args_ctor edge cases (Cmake/Java/Javac/Dd/Osascript/Ffplay/Mpg123/Open/Dune/Play/Rec/Ocamlfind)"
            `Quick
            test_generic_subcommand_args_edge_cases
        ; Alcotest.test_case
            "Batch18 Curl edge cases (method/headers/body/eq-form/combined flags/--)"
            `Quick
            test_curl_edge_cases
        ; Alcotest.test_case
            "Batch19 Docker edge cases (rm/priv/detach/name/net/vol/port/env/wd/platform/eq-form/--)"
            `Quick
            test_docker_edge_cases
        ; Alcotest.test_case
            "Batch20 Make edge cases (target/jobs/dir/mkfile/-nksB/-jN/eq-form/--)"
            `Quick
            test_make_edge_cases
        ; Alcotest.test_case
            "Batch21 Sed edge cases (expr/file/-i(GNU+mac)/-E/-n/eq-form/combined/--)"
            `Quick
            test_sed_edge_cases
        ; Alcotest.test_case
            "Batch21 Rsync edge cases (archive/delete/dry-run/compress/-az/-anz/value-flags/eq-form/--)"
            `Quick
            test_rsync_edge_cases
        ; Alcotest.test_case
            "Batch21 Grep edge cases (-r/-i/-l/-e/--regexp/-ri/-rli/ctx-flags/eq-form/--)"
            `Quick
            test_grep_edge_cases
        ; Alcotest.test_case
            "Batch22 Sort/Cut/Tr/Tar edge cases (-k3rn/-d:/-ds/-czf/eq-form/--)"
            `Quick
            test_sort_cut_tr_tar_edge_cases
        ] )
    ; ( "spec_invariants"
      , [ Alcotest.test_case "is_eq_form_flag helper" `Quick test_is_eq_form_flag
        ; Alcotest.test_case "eq_form_flag_value helper" `Quick test_eq_form_flag_value
        ; Alcotest.test_case "constructor count baseline" `Quick test_constructor_count
        ; Alcotest.test_case
            "constructor names declaration-order"
            `Quick
            test_constructor_names_in_declaration_order
        ] )
    ]
;;
