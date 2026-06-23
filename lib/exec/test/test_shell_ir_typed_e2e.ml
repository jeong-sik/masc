(** test_shell_ir_typed_e2e — end-to-end integration tests.

    Parse real shell command strings through the Menhir bash parser,
    extract Shell_ir.simple stages, lift them through Shell_ir_typed.of_simple,
    and verify the resulting typed constructor.

    This catches regressions that unit tests miss: parser ↔ typed IR
    interoperability, real-world flag handling, and edge cases in
    argument tokenization. *)

open Alcotest
open Masc_exec
open Masc_exec_bash_parser

(** Parse a shell command string and extract the first Simple stage. *)
let parse_simple cmd =
  match Bash.parse_string cmd with
  | Parsed.Parsed (Shell_ir.Simple s) -> s
  | Parsed.Parsed (Shell_ir.Pipeline _) ->
    failf "expected Simple, got Pipeline for: %s" cmd
  | Parsed.Parse_error _ ->
    failf "parse error for: %s" cmd
  | Parsed.Too_complex _ ->
    failf "too complex for: %s" cmd
  | Parsed.Parse_aborted _ ->
    failf "parse aborted for: %s" cmd
;;

(** Get the constructor name from a typed IR result. *)
let ctor_name = function
  | Shell_ir_typed.W cmd ->
    (match cmd with
     | Shell_ir_typed.Ls _ -> "Ls"
     | Shell_ir_typed.Cat _ -> "Cat"
     | Shell_ir_typed.Rg _ -> "Rg"
     | Shell_ir_typed.Git_status _ -> "Git_status"
     | Shell_ir_typed.Git_clone _ -> "Git_clone"
     | Shell_ir_typed.Curl _ -> "Curl"
     | Shell_ir_typed.Rm _ -> "Rm"
     | Shell_ir_typed.Sudo _ -> "Sudo"
     | Shell_ir_typed.Find _ -> "Find"
     | Shell_ir_typed.Head _ -> "Head"
     | Shell_ir_typed.Tail _ -> "Tail"
     | Shell_ir_typed.Grep _ -> "Grep"
     | Shell_ir_typed.Mkdir _ -> "Mkdir"
     | Shell_ir_typed.Wc _ -> "Wc"
     | Shell_ir_typed.Git_diff _ -> "Git_diff"
     | Shell_ir_typed.Git_log _ -> "Git_log"
     | Shell_ir_typed.Git_commit _ -> "Git_commit"
     | Shell_ir_typed.Git_push _ -> "Git_push"
     | Shell_ir_typed.Git_pull _ -> "Git_pull"
     | Shell_ir_typed.Git_stash _ -> "Git_stash"
     | Shell_ir_typed.Git_rebase _ -> "Git_rebase"
     | Shell_ir_typed.Git_merge _ -> "Git_merge"
     | Shell_ir_typed.Git_branch _ -> "Git_branch"
     | Shell_ir_typed.Git_checkout _ -> "Git_checkout"
     | Shell_ir_typed.Git_fetch _ -> "Git_fetch"
     | Shell_ir_typed.Git_show _ -> "Git_show"
     | Shell_ir_typed.Git_reset _ -> "Git_reset"
     | Shell_ir_typed.Git_blame _ -> "Git_blame"
     | Shell_ir_typed.Git_add _ -> "Git_add"
     | Shell_ir_typed.Pwd _ -> "Pwd"
     | Shell_ir_typed.Echo _ -> "Echo"
     | Shell_ir_typed.Which _ -> "Which"
     | Shell_ir_typed.Sort _ -> "Sort"
     | Shell_ir_typed.Cut _ -> "Cut"
     | Shell_ir_typed.Tr _ -> "Tr"
     | Shell_ir_typed.Date _ -> "Date"
     | Shell_ir_typed.Env _ -> "Env"
     | Shell_ir_typed.Printenv _ -> "Printenv"
     | Shell_ir_typed.Uniq _ -> "Uniq"
     | Shell_ir_typed.Basename _ -> "Basename"
     | Shell_ir_typed.Dirname _ -> "Dirname"
     | Shell_ir_typed.Test _ -> "Test"
     | Shell_ir_typed.Stat _ -> "Stat"
     | Shell_ir_typed.Hostname _ -> "Hostname"
     | Shell_ir_typed.Whoami _ -> "Whoami"
     | Shell_ir_typed.Du _ -> "Du"
     | Shell_ir_typed.Df _ -> "Df"
     | Shell_ir_typed.File _ -> "File"
     | Shell_ir_typed.Printf _ -> "Printf"
     | Shell_ir_typed.Uname _ -> "Uname"
     | Shell_ir_typed.Ps _ -> "Ps"
     | Shell_ir_typed.Tty _ -> "Tty"
     | Shell_ir_typed.Wget _ -> "Wget"
     | Shell_ir_typed.Ssh _ -> "Ssh"
     | Shell_ir_typed.Scp _ -> "Scp"
     | Shell_ir_typed.Tar _ -> "Tar"
     | Shell_ir_typed.Make _ -> "Make"
     | Shell_ir_typed.Diff _ -> "Diff"
     | Shell_ir_typed.Sed _ -> "Sed"
     | Shell_ir_typed.Rsync _ -> "Rsync"
     | Shell_ir_typed.Node _ -> "Node"
     | Shell_ir_typed.Python _ -> "Python"
     | Shell_ir_typed.Python3 _ -> "Python3"
     | Shell_ir_typed.Pip _ -> "Pip"
     | Shell_ir_typed.Patch _ -> "Patch"
     | Shell_ir_typed.Npm _ -> "Npm"
     | Shell_ir_typed.Cargo _ -> "Cargo"
     | Shell_ir_typed.Go _ -> "Go"
     | Shell_ir_typed.Gh _ -> "Gh"
     | Shell_ir_typed.Chmod _ -> "Chmod"
     | Shell_ir_typed.Chown _ -> "Chown"
     | Shell_ir_typed.Docker _ -> "Docker"
     | Shell_ir_typed.Opam _ -> "Opam"
     | Shell_ir_typed.Npx _ -> "Npx"
     | Shell_ir_typed.Yarn _ -> "Yarn"
     | Shell_ir_typed.Pnpm _ -> "Pnpm"
     | Shell_ir_typed.Uv _ -> "Uv"
     | Shell_ir_typed.Glab _ -> "Glab"
     | Shell_ir_typed.Pytest _ -> "Pytest"
     | Shell_ir_typed.Terminal_notifier _ -> "Terminal_notifier"
     | Shell_ir_typed.Ruff _ -> "Ruff"
     | Shell_ir_typed.Pyright _ -> "Pyright"
     | Shell_ir_typed.Tsc _ -> "Tsc"
     | Shell_ir_typed.Ocamlfind _ -> "Ocamlfind"
     | Shell_ir_typed.Rustc _ -> "Rustc"
     | Shell_ir_typed.Gofmt _ -> "Gofmt"
     | Shell_ir_typed.Gradle _ -> "Gradle"
     | Shell_ir_typed.Ninja _ -> "Ninja"
     | Shell_ir_typed.Java _ -> "Java"
     | Shell_ir_typed.Javac _ -> "Javac"
     | Shell_ir_typed.Mvn _ -> "Mvn"
     | Shell_ir_typed.Cmake _ -> "Cmake"
     | Shell_ir_typed.Dune_local_sh _ -> "Dune_local_sh"
     | Shell_ir_typed.Osascript _ -> "Osascript"
     | Shell_ir_typed.Play _ -> "Play"
     | Shell_ir_typed.Rec _ -> "Rec"
     | Shell_ir_typed.Ffplay _ -> "Ffplay"
     | Shell_ir_typed.Mpg123 _ -> "Mpg123"
     | Shell_ir_typed.Open _ -> "Open"
     | Shell_ir_typed.Su _ -> "Su"
     | Shell_ir_typed.Dd _ -> "Dd"
     | Shell_ir_typed.Mkfs _ -> "Mkfs"
     | Shell_ir_typed.Cp _ -> "Cp"
     | Shell_ir_typed.Mv _ -> "Mv"
     | Shell_ir_typed.Ln _ -> "Ln"
     | Shell_ir_typed.Touch _ -> "Touch"
     | Shell_ir_typed.Tee _ -> "Tee"
     | Shell_ir_typed.Awk _ -> "Awk"
     | Shell_ir_typed.Xargs _ -> "Xargs"
     | Shell_ir_typed.Generic _ -> "Generic")
;;

(* ── E2E: parse → typed IR ─────────────────────────────────────── *)

let check_ctor cmd expected =
  let simple = parse_simple cmd in
  let typed = Shell_ir_typed.of_simple simple in
  check string
    (Printf.sprintf "\"%s\" → %s" cmd expected)
    expected
    (ctor_name typed)
;;

(** Round-trip: parse → of_simple → to_simple → re-parse → of_simple
    must yield the same constructor. *)
let check_round_trip cmd_str =
  let simple = parse_simple cmd_str in
  let typed = Shell_ir_typed.of_simple simple in
  match typed with
  | Shell_ir_typed.W (Shell_ir_typed.Generic _) -> () (* Generic round-trip is identity *)
  | Shell_ir_typed.W c ->
    let reconstructed = Shell_ir_typed.to_simple c in
    let retyped = Shell_ir_typed.of_simple reconstructed in
    if not (typed = retyped)
    then
      failf
        "round-trip failed for \"%s\"@\n  \
         first:  %a@\n  \
         second: %a"
        cmd_str
        Shell_ir_typed.pp
        typed
        Shell_ir_typed.pp
        retyped
;;

let test_basic_commands () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "ls", "Ls"
    ; "ls -l -a", "Ls"
    ; "ls -l -a /tmp", "Ls"
    ; "cat /etc/hosts", "Cat"
    ; "grep TODO", "Grep"
    ; "grep -r TODO lib/", "Grep"
    ; "grep -r -i fixme src/", "Grep"
    ; "wc -l README.md", "Wc"
    ; "wc -w file.txt", "Wc"
    ; "wc file.txt", "Wc"
    ; "head -n 5 file.txt", "Head"
    ; "tail -n 20 log.txt", "Tail"
    ; "mkdir -p /tmp/a/b", "Mkdir"
    ; "rm -r -f /tmp/x", "Rm"
    ; "find . -name '*.ml'", "Find"
    ; "sort -n file.txt", "Sort"
    ; "cut -d : -f 1 /etc/passwd", "Cut"
    ; "tr a-z A-Z", "Tr"
    ; "date +%Y-%m-%d", "Date"
    ; "uname -a", "Uname"
    ; "ps -e", "Ps"
    ; "du -s -h /tmp", "Du"
    ; "df -h", "Df"
    ; "file /bin/ls", "File"
    ; "stat /tmp", "Stat"
    ; "hostname", "Hostname"
    ; "whoami", "Whoami"
    ; "pwd", "Pwd"
    ; "echo hello", "Echo"
    ; "which ocaml", "Which"
    ; "tty", "Tty"
    ; "env", "Env"
    ; "printenv PATH", "Printenv"
    ; "basename /tmp/foo.bar .bar", "Basename"
    ; "dirname /tmp/foo.bar", "Dirname"
    ; "test -f file.txt", "Test"
    ; "printf '%s\\n' hello", "Printf"
    ; "uniq -c file.txt", "Uniq"
    (* Combined short flags — expanded by [expand_combined_short_flags] *)
    ; "ls -la", "Ls"
    ; "ls -lah", "Ls"
    ; "ls -lah /tmp", "Ls"
    ; "rm -rf /tmp/x", "Rm"
    ; "grep -ri pattern src/", "Grep"
    ; "sort -nr file.txt", "Sort"
    ; "du -sh /tmp", "Du"
    ; "tar czf archive.tar.gz dir/", "Tar"
    ; "tar xzf archive.tar.gz", "Tar"
    ; "tar tf archive.tar", "Tar"
    (* Tar with different compression algorithms *)
    ; "tar cjf archive.tar.bz2 dir/", "Tar"
    ; "tar cJf archive.tar.xz dir/", "Tar"
    ; "tar xf archive.tar.xz", "Tar"
    (* Find with unknown flags (tolerant parsing) *)
    ; "find . -maxdepth 1 -name '*.ml'", "Find"
    ; "find /tmp -type f -mtime -7", "Find"
    ; "find -name '*.ml'", "Find"
    (* Tolerant parsers: unknown flags skipped *)
    ; "ps aux", "Ps"
    ; "ps -ef", "Ps"
    ; "ps ax", "Ps"
    ; "uname -a", "Uname"
    ; "uname -sr", "Uname"
    ; "df -h", "Df"
    ; "df -hT", "Df"
    ; "file -i /bin/ls", "File"
    ; "stat -f /tmp", "Stat"
    ; "stat -c %U /tmp", "Stat"
    (* Tolerant parsers: unknown flags skipped — batch 2 *)
    ; "ls -la -x /tmp", "Ls"
    ; "ls --color=auto /tmp", "Ls"
    ; "grep --color=auto pattern src/", "Grep"
    ; "grep -E --only-matching pattern file", "Grep"
    ; "git clone --bare --depth 1 https://x/y.git", "Git_clone"
    ; "curl --compressed https://example.com", "Curl"
    ; "curl -s -S --retry 3 https://example.com", "Curl"
    ; "rm -rf --interactive /tmp/x", "Rm"
    ; "head -z file.txt", "Head"
    ; "tail -z file.txt", "Tail"
    (* Combined value flags — NOT expanded by [expand_combined_short_flags] (digits) *)
    ; "head -n5 file.txt", "Head"
    ; "tail -n20 log.txt", "Tail"
    ; "mkdir -v -p /tmp/a/b", "Mkdir"
    ; "wc -z file.txt", "Wc"
    ; "du -z /tmp", "Du"
    ; "wget --no-check-certificate https://example.com/file.txt", "Wget"
    ; "scp -p file.txt user@host:/tmp/", "Scp"
    ]
;;

let test_git_commands () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "git status", "Git_status"
    ; "git status -s", "Git_status"
    ; "git status --branch", "Git_status"
    ; "git status --porcelain", "Git_status"
    ; "git diff", "Git_diff"
    ; "git diff --stat", "Git_diff"
    ; "git diff --cached", "Git_diff"
    ; "git log --oneline", "Git_log"
    ; "git log --oneline -n 10", "Git_log"
    ; "git log -n5", "Git_log"
    ; "git log --oneline -n5", "Git_log"
    ; "git commit -m test", "Git_commit"
    ; "git commit --amend -m fix", "Git_commit"
    ; "git push origin main", "Git_push"
    ; "git push --force-with-lease", "Git_push"
    ; "git pull --rebase", "Git_pull"
    ; "git pull origin develop", "Git_pull"
    ; "git clone https://github.com/x/y.git", "Git_clone"
    ; "git clone --depth 1 https://github.com/x/y.git", "Git_clone"
    ; "git clone -b main https://github.com/x/y.git", "Git_clone"
    ; "git clone https://github.com/x/y.git repos/z", "Git_clone"
    ]
;;

let test_network_tools () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "curl https://example.com", "Curl"
    ; "curl -X POST https://example.com", "Curl"
    ; "curl -H 'Accept: application/json' https://example.com", "Curl"
    ; "wget https://example.com/file.txt", "Wget"
    ; "ssh user@host", "Ssh"
    ; "ssh user@host ls -la", "Ssh"
    ; "ssh -p 2222 user@host", "Ssh"
    ; "scp file.txt user@host:/tmp/", "Scp"
    ; "scp -r dir/ user@host:/tmp/", "Scp"
    ; "scp -P 2222 file.txt user@host:/tmp/", "Scp"
    ]
;;

let test_build_tools () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "make", "Make"
    ; "make -j4", "Make"
    ; "make install", "Make"
    ; "npm test", "Npm"
    ; "npm install", "Npm"
    ; "npm run build", "Npm"
    ; "cargo build", "Cargo"
    ; "cargo test", "Cargo"
    ; "go build ./...", "Go"
    ; "go test ./...", "Go"
    ; "gh pr list", "Gh"
    ; "gh issue create -t title -b body", "Gh"
    ; "docker ps", "Docker"
    ; "docker build -t myapp .", "Docker"
    ; "docker run -it ubuntu bash", "Docker"
    ; "opam install alcotest", "Opam"
    ; "npx prettier --check .", "Npx"
    ; "yarn install", "Yarn"
    ; "pnpm install", "Pnpm"
    ; "uv pip install requests", "Uv"
    ; "glab mr list", "Glab"
    ; "pytest tests/", "Pytest"
    ; "ruff check .", "Ruff"
    ; "pyright --check .", "Pyright"
    ; "tsc --noEmit src/index.ts", "Tsc"
    ; "ocamlfind list", "Ocamlfind"
    ; "rustc --version", "Rustc"
    ; "gofmt -l .", "Gofmt"
    ; "gradle build", "Gradle"
    ; "ninja all", "Ninja"
    ; "java -jar app.jar", "Java"
    ; "javac Main.java", "Javac"
    ; "mvn test", "Mvn"
    ; "cmake --build .", "Cmake"
    ]
;;

let test_privileged_commands () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "sudo ls /root", "Sudo"
    ; "sudo sh -c \"echo hi\"", "Sudo"
    ; "chmod 755 script.sh", "Chmod"
    ; "chmod -R 755 dir/", "Chmod"
    ; "chown user:group file.txt", "Chown"
    ; "chown -R user:group dir/", "Chown"
    ; "su root", "Su"
    ; "dd if=/dev/zero of=/tmp/zeros bs=1M count=10", "Dd"
    ; "mkfs -t ext4 /dev/sdb1", "Mkfs"
    ]
;;

let test_file_operations () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "cp file1 file2", "Cp"
    ; "cp -r dir1 dir2", "Cp"
    ; "cp -rf src dst", "Cp"
    ; "cp -p file1 file2", "Cp"
    ; "mv old new", "Mv"
    ; "mv -f old new", "Mv"
    ; "mv -n old new", "Mv"
    ; "ln -s target link", "Ln"
    ; "ln -sf target link", "Ln"
    ; "touch file.txt", "Touch"
    ; "touch -c file.txt", "Touch"
    ; "touch -a file.txt", "Touch"
    ; "tee output.log", "Tee"
    ; "tee -a output.log", "Tee"
    ; "awk '{print $1}' file.txt", "Awk"
    ; "xargs rm", "Xargs"
    ; "xargs -n 1 echo", "Xargs"
    ]
;;

let test_cp_field_values () =
  let check_cp cmd ~expected_recursive ~expected_force ~expected_preserve =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Cp { recursive; force; preserve; _ }) ->
      check bool (Printf.sprintf "\"%s\" → recursive" cmd) expected_recursive recursive;
      check bool (Printf.sprintf "\"%s\" → force" cmd) expected_force force;
      check bool (Printf.sprintf "\"%s\" → preserve" cmd) expected_preserve preserve
    | _ -> failf "expected Cp for: %s" cmd
  in
  check_cp "cp a b" ~expected_recursive:false ~expected_force:false ~expected_preserve:false;
  check_cp "cp -r a b" ~expected_recursive:true ~expected_force:false ~expected_preserve:false;
  check_cp "cp -rf a b" ~expected_recursive:true ~expected_force:true ~expected_preserve:false;
  check_cp "cp -rfp a b" ~expected_recursive:true ~expected_force:true ~expected_preserve:true;
  check_cp "cp -R a b" ~expected_recursive:true ~expected_force:false ~expected_preserve:false
;;

let test_mv_field_values () =
  let check_mv cmd ~expected_force ~expected_no_clobber =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Mv { force; no_clobber; _ }) ->
      check bool (Printf.sprintf "\"%s\" → force" cmd) expected_force force;
      check bool (Printf.sprintf "\"%s\" → no_clobber" cmd) expected_no_clobber no_clobber
    | _ -> failf "expected Mv for: %s" cmd
  in
  check_mv "mv a b" ~expected_force:false ~expected_no_clobber:false;
  check_mv "mv -f a b" ~expected_force:true ~expected_no_clobber:false;
  check_mv "mv -n a b" ~expected_force:false ~expected_no_clobber:true;
  check_mv "mv -fn a b" ~expected_force:true ~expected_no_clobber:true
;;

let test_ln_field_values () =
  let check_ln cmd ~expected_symbolic ~expected_force =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Ln { symbolic; force; _ }) ->
      check bool (Printf.sprintf "\"%s\" → symbolic" cmd) expected_symbolic symbolic;
      check bool (Printf.sprintf "\"%s\" → force" cmd) expected_force force
    | _ -> failf "expected Ln for: %s" cmd
  in
  check_ln "ln target link" ~expected_symbolic:false ~expected_force:false;
  check_ln "ln -s target link" ~expected_symbolic:true ~expected_force:false;
  check_ln "ln -sf target link" ~expected_symbolic:true ~expected_force:true;
  check_ln "ln --symbolic target link" ~expected_symbolic:true ~expected_force:false;
  check_ln "ln --force target link" ~expected_symbolic:false ~expected_force:true
;;

let test_system_tools () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "tar -c -f archive.tar file1 file2", "Tar"
    ; "tar -x -z -f archive.tar.gz", "Tar"
    ; "tar -c -z -f archive.tar.gz dir/", "Tar"
    ; "tar -c -j -f archive.tar.bz2 dir/", "Tar"
    ; "tar -c -J -f archive.tar.xz dir/", "Tar"
    ; "diff file1 file2", "Diff"
    ; "diff -u file1 file2", "Diff"
    ; "diff --brief a b", "Diff"
    ; "sed s/foo/bar/g file.txt", "Sed"
    ; "rsync -a -v -z dir/ user@host:/backup/", "Rsync"
    ; "rsync -a --delete --dry-run -z src/ dest/", "Rsync"
    ; "patch -p1", "Patch"
    ; "node script.js", "Node"
    ; "node -e process.exit", "Node"
    ; "python script.py", "Python"
    ; "python -c pass", "Python"
    ; "python3 script.py", "Python3"
    ; "python3 -c pass", "Python3"
    ; "pip install requests", "Pip"
    ]
;;

let test_generic_fallback () =
  (* Commands not in Exec_program.known should fall through to Generic *)
  List.iter
    (fun cmd -> check_ctor cmd "Generic")
    [ "less file.txt"
    ; "vim file.txt"
    ]
;;

let test_round_trip_e2e () =
  List.iter
    check_round_trip
    [ "ls -l -a /tmp"
    ; "cat /etc/hosts"
    ; "grep -r TODO lib/"
    ; "wc -l README.md"
    ; "head -n 5 file.txt"
    ; "tail -n 20 log.txt"
    ; "mkdir -p /tmp/a/b"
    ; "rm -r -f /tmp/x"
    ; "find . -name *.ml"
    ; "find . -maxdepth 1 -name *.ml"
    ; "find /tmp -type f -mtime -7"
    ; "find -name *.ml"
    ; "tar cjf archive.tar.bz2 dir/"
    ; "tar cJf archive.tar.xz dir/"
    ; "git status -s"
    ; "git diff --stat"
    ; "git log --oneline -n 10"
    ; "git commit -m test"
    ; "git push origin main"
    ; "git pull --rebase"
    ; "git clone https://github.com/x/y.git"
    ; "git clone --depth 1 https://github.com/x/y.git"
    ; "curl -X POST https://example.com"
    ; "curl -H 'Content-Type: application/json' -d '{\"key\":\"val\"}' https://api.example.com"
    ; "curl -u user:pass https://example.com"
    ; "wget https://example.com/file.txt"
    ; "ssh user@host ls -l -a"
    ; "ssh -p 2222 user@host ls -la"
    ; "scp file.txt user@host:/tmp/"
    ; "scp -r -P 2222 dir/ user@host:/tmp/"
    ; "make -j4"
    ; "npm test"
    ; "cargo build"
    ; "go test ./..."
    ; "gh pr list"
    ; "docker ps"
    ; "opam install alcotest"
    ; "npx prettier --check ."
    ; "yarn install"
    ; "pnpm install"
    ; "uv pip install requests"
    ; "glab mr list"
    ; "pytest tests/"
    ; "ruff check ."
    ; "tsc --noEmit"
    ; "ocamlfind list"
    ; "rustc --version"
    ; "gofmt -l ."
    ; "gradle build"
    ; "ninja"
    ; "java -jar app.jar"
    ; "javac Main.java"
    ; "mvn test"
    ; "cmake --build ."
    ; "sudo ls /root"
    ; "chmod 755 script.sh"
    ; "chmod -R 755 dir/"
    ; "chown user:group file.txt"
    ; "chown -R user:group dir/"
    ; "su root"
    ; "tar -c -f archive.tar file1"
    ; "tar -x -z -f archive.tar.gz"
    ; "diff -u file1 file2"
    ; "diff --brief a b"
    ; "wget -c --no-check-certificate https://example.com/file"
    ; "sed s/foo/bar/g file.txt"
    ; "sed -i s/foo/bar/g file.txt"
    ; "sed -e s/foo/bar/g file.txt"
    ; "rsync -a -v -z dir/ user@host:/backup/"
    ; "rsync --exclude '*.log' -a src/ dest/"
    ; "rsync -a --delete --dry-run -z src/ dest/"
    ; "node script.js"
    ; "node -e process.exit"
    ; "node -e process.exit --max-old-space-size=4096"
    ; "python script.py"
    ; "python -c pass"
    ; "python3 script.py"
    ; "python3 -c pass"
    ; "pip install requests"
    ; "sort -n file.txt"
    ; "cut -d: -f1 /etc/passwd"
    ; "tr a-z A-Z"
    ; "date +%Y-%m-%d"
    ; "uname -a"
    ; "ps -e"
    ; "du -s -h /tmp"
    ; "df -h"
    ; "file /bin/ls"
    ; "stat /tmp"
    ; "ps aux"
    ; "ps -ef"
    ; "ps ax"
    ; "uname -sr"
    ; "df -hT"
    ; "file -i /bin/ls"
    ; "stat -f /tmp"
    ; "stat -c %U /tmp"
    (* Tolerant parsers: round-trip — batch 2 *)
    ; "ls -la -x /tmp"
    ; "ls --color=auto /tmp"
    ; "grep --color=auto pattern src/"
    ; "git clone --bare --depth 1 https://x/y.git"
    ; "curl --compressed https://example.com"
    ; "rm -rf --interactive /tmp/x"
    ; "head -z file.txt"
    ; "tail -z file.txt"
    ; "mkdir -v -p /tmp/a/b"
    ; "wc -z file.txt"
    ; "du -z /tmp"
    ; "wget --no-check-certificate https://example.com/file.txt"
    ; "scp -p file.txt user@host:/tmp/"
    ; "echo hello"
    ; "which ocaml"
    ; "printenv PATH"
    ; "basename /tmp/foo.bar .bar"
    ; "dirname /tmp/foo.bar"
    ; "test -f file.txt"
    ; "printf '%s\\n' hello"
    ; "uniq -c file.txt"
    (* Coverage: constructors missing from earlier rounds *)
    ; "dd if=/dev/zero of=/dev/null count=1"
    ; "dune_local_sh build"
    ; "env"
    ; "hostname"
    ; "hostname -s"
    ; "mkfs -t ext4 /dev/sda1"
    ; "ffplay -autoexit sound.mp3"
    ; "mpg123 song.mp3"
    ; "ninja"
    ; "open https://example.com"
    ; "osascript -e 'tell app \"Finder\" to activate'"
    ; "play song.mp3"
    ; "pwd"
    ; "pyright --version"
    ; "rec recording.wav"
    ; "terminal_notifier -title Hello -message World"
    ; "tty"
    ; "whoami"
    ; "python3 script.py"
    ; "python3 -c pass"
    ; "patch -p1 < fix.patch"
    ; "rg pattern src/"
    ; "git clone https://github.com/x/y.git"
    ; "git clone --depth 1 https://github.com/x/y.git"
    ; "git diff --stat"
    ; "git diff --cached"
    ; "git log --oneline -n 10"
    ; "git commit -m test"
    ; "git push origin main"
    ; "git push --force-with-lease"
    ; "git pull --rebase"
    ; "git status -s"
    ; "git status --porcelain"
    (* File operations round-trip *)
    ; "cp file1 file2"
    ; "cp -r dir1 dir2"
    ; "cp -rf src dst"
    ; "cp -rfp a b"
    ; "cp -R a b"
    ; "mv old new"
    ; "mv -f old new"
    ; "mv -n old new"
    ; "mv -fn a b"
    ; "ln target link"
    ; "ln -s target link"
    ; "ln -sf target link"
    ; "touch file.txt"
    ; "touch -c file.txt"
    ; "touch -a file.txt"
    ; "tee output.log"
    ; "tee -a output.log"
    ; "awk '{print $1}' file.txt"
    ; "xargs rm"
    ; "xargs -n 1 echo"
    ]
;;

(* ── Field-value verification ─────────────────────────────────── *)

(** Verify that [make -jN] correctly parses the jobs field. *)
let test_make_combined_jobs () =
  let check_jobs cmd expected_jobs =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Make { jobs; _ }) ->
      check (option int)
        (Printf.sprintf "\"%s\" → jobs" cmd)
        expected_jobs jobs
    | _ -> failf "expected Make for: %s" cmd
  in
  check_jobs "make" None;
  check_jobs "make -j4" (Some 4);
  check_jobs "make -j8" (Some 8);
  check_jobs "make -j1" (Some 1);
  check_jobs "make -j4 install" (Some 4);
  check_jobs "make install" None
;;

(** Verify that [make -jN] round-trips correctly. *)
let test_make_round_trip () =
  List.iter
    check_round_trip
    [ "make"
    ; "make -j4"
    ; "make -j8"
    ; "make install"
    ; "make -j4 install"
    ; "make -j8 test"
    ]
;;

(** Verify that [head -nN] correctly parses the lines field. *)
let test_head_combined_lines () =
  let check_lines cmd expected_lines =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Head { lines; _ }) ->
      check int
        (Printf.sprintf "\"%s\" → lines" cmd)
        expected_lines lines
    | _ -> failf "expected Head for: %s" cmd
  in
  check_lines "head -n 5 file.txt" 5;
  check_lines "head -n5 file.txt" 5;
  check_lines "head -n 1 file.txt" 1;
  check_lines "head -n1 file.txt" 1;
  check_lines "head file.txt" 10
;;

(** Verify that [tail -nN] correctly parses the lines field. *)
let test_tail_combined_lines () =
  let check_lines cmd expected_lines =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Tail { lines; _ }) ->
      check int
        (Printf.sprintf "\"%s\" → lines" cmd)
        expected_lines lines
    | _ -> failf "expected Tail for: %s" cmd
  in
  check_lines "tail -n 20 log.txt" 20;
  check_lines "tail -n20 log.txt" 20;
  check_lines "tail -n 1 log.txt" 1;
  check_lines "tail -n1 log.txt" 1;
  check_lines "tail log.txt" 10
;;

(** Verify that [git log -nN] correctly parses the max_count field. *)
let test_git_log_combined_count () =
  let check_count cmd expected =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Git_log { max_count; _ }) ->
      check (option int)
        (Printf.sprintf "\"%s\" → max_count" cmd)
        expected max_count
    | _ -> failf "expected Git_log for: %s" cmd
  in
  check_count "git log --oneline -n 10" (Some 10);
  check_count "git log -n5" (Some 5);
  check_count "git log --oneline -n5" (Some 5);
  check_count "git log --oneline" None;
  check_count "git log" None
;;

(** Round-trip: combined value flags for Head, Tail, Git_log. *)
let test_combined_value_flag_round_trip () =
  List.iter
    check_round_trip
    [ "head -n5 file.txt"
    ; "tail -n20 log.txt"
    ; "git log -n5"
    ; "git log --oneline -n5"
    ]
;;

(** Verify that [sed -i / -e / -n] correctly parses fields. *)
let test_sed_flags () =
  let check_sed cmd ~expected_expr ~expected_file ~expected_in_place ~expected_ext_re ~expected_suppress =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Sed { expression; file; in_place; extended_regex; suppress_output }) ->
      check bool (Printf.sprintf "\"%s\" → in_place" cmd) expected_in_place in_place;
      check bool (Printf.sprintf "\"%s\" → extended_regex" cmd) expected_ext_re extended_regex;
      check bool (Printf.sprintf "\"%s\" → suppress_output" cmd) expected_suppress suppress_output;
      check string (Printf.sprintf "\"%s\" → expression" cmd) expected_expr expression;
      check string (Printf.sprintf "\"%s\" → file" cmd) expected_file file
    | _ -> failf "expected Sed for: %s" cmd
  in
  (* basic *)
  check_sed "sed s/foo/bar/g file.txt"
    ~expected_expr:"s/foo/bar/g" ~expected_file:"file.txt" ~expected_in_place:false
    ~expected_ext_re:false ~expected_suppress:false;
  (* -i without suffix *)
  check_sed "sed -i s/foo/bar/g file.txt"
    ~expected_expr:"s/foo/bar/g" ~expected_file:"file.txt" ~expected_in_place:true
    ~expected_ext_re:false ~expected_suppress:false;
  (* -e explicit expression *)
  check_sed "sed -e s/foo/bar/g file.txt"
    ~expected_expr:"s/foo/bar/g" ~expected_file:"file.txt" ~expected_in_place:false
    ~expected_ext_re:false ~expected_suppress:false;
  (* -n suppress output *)
  check_sed "sed -n '1,5p' file.txt"
    ~expected_expr:"1,5p" ~expected_file:"file.txt" ~expected_in_place:false
    ~expected_ext_re:false ~expected_suppress:true
;;

(** Verify that [sed -E / --regexp-extended / -n / --quiet / --silent / -En] parse correctly. *)
let test_sed_extended () =
  let check_sed cmd ~expected_expr ~expected_file ~expected_in_place ~expected_ext_re ~expected_suppress =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Sed { expression; file; in_place; extended_regex; suppress_output }) ->
      check bool (Printf.sprintf "\"%s\" → in_place" cmd) expected_in_place in_place;
      check bool (Printf.sprintf "\"%s\" → extended_regex" cmd) expected_ext_re extended_regex;
      check bool (Printf.sprintf "\"%s\" → suppress_output" cmd) expected_suppress suppress_output;
      check string (Printf.sprintf "\"%s\" → expression" cmd) expected_expr expression;
      check string (Printf.sprintf "\"%s\" → file" cmd) expected_file file
    | _ -> failf "expected Sed for: %s" cmd
  in
  (* -E extended regex *)
  check_sed "sed -E 's/(foo)/bar/' file.txt"
    ~expected_expr:"s/(foo)/bar/" ~expected_file:"file.txt"
    ~expected_in_place:false ~expected_ext_re:true ~expected_suppress:false;
  (* --regexp-extended long form *)
  check_sed "sed --regexp-extended 's/(foo)/bar/' file.txt"
    ~expected_expr:"s/(foo)/bar/" ~expected_file:"file.txt"
    ~expected_in_place:false ~expected_ext_re:true ~expected_suppress:false;
  (* --quiet alias for -n *)
  check_sed "sed --quiet '1,5p' file.txt"
    ~expected_expr:"1,5p" ~expected_file:"file.txt"
    ~expected_in_place:false ~expected_ext_re:false ~expected_suppress:true;
  (* --silent alias for -n *)
  check_sed "sed --silent '1,5p' file.txt"
    ~expected_expr:"1,5p" ~expected_file:"file.txt"
    ~expected_in_place:false ~expected_ext_re:false ~expected_suppress:true;
  (* -En combined *)
  check_sed "sed -En 's/(foo)/bar/p' file.txt"
    ~expected_expr:"s/(foo)/bar/p" ~expected_file:"file.txt"
    ~expected_in_place:false ~expected_ext_re:true ~expected_suppress:true;
  (* -iE combined with -n *)
  check_sed "sed -iE -n 's/(foo)/bar/p' file.txt"
    ~expected_expr:"s/(foo)/bar/p" ~expected_file:"file.txt"
    ~expected_in_place:true ~expected_ext_re:true ~expected_suppress:true
;;

(** Verify that [sort] handles combined -kN and -t value flag. *)
let test_sort_flags () =
  let check_sort cmd ~expected_key ~expected_reverse ~expected_numeric ~expected_file =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Sort { key; reverse; numeric; unique = _; file }) ->
      check (option int) (Printf.sprintf "\"%s\" → key" cmd) expected_key key;
      check bool (Printf.sprintf "\"%s\" → reverse" cmd) expected_reverse reverse;
      check bool (Printf.sprintf "\"%s\" → numeric" cmd) expected_numeric numeric;
      check (option string) (Printf.sprintf "\"%s\" → file" cmd) expected_file file
    | _ -> failf "expected Sort for: %s" cmd
  in
  (* basic *)
  check_sort "sort file.txt"
    ~expected_key:None ~expected_reverse:false ~expected_numeric:false ~expected_file:(Some "file.txt");
  (* -k with space *)
  check_sort "sort -k 2 file.txt"
    ~expected_key:(Some 2) ~expected_reverse:false ~expected_numeric:false ~expected_file:(Some "file.txt");
  (* combined -k2 *)
  check_sort "sort -k2 file.txt"
    ~expected_key:(Some 2) ~expected_reverse:false ~expected_numeric:false ~expected_file:(Some "file.txt");
  (* combined -k3rn *)
  check_sort "sort -k3rn file.txt"
    ~expected_key:(Some 3) ~expected_reverse:true ~expected_numeric:true ~expected_file:(Some "file.txt");
  (* -t value flag consumed *)
  check_sort "sort -t, -k2 file.csv"
    ~expected_key:(Some 2) ~expected_reverse:false ~expected_numeric:false ~expected_file:(Some "file.csv")
;;

(** Verify that [cut] handles long-form --delimiter and --fields. *)
let test_cut_long_forms () =
  let check_cut cmd ~expected_delimiter ~expected_fields ~expected_file =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Cut { delimiter; fields; file }) ->
      check (option string) (Printf.sprintf "\"%s\" → delimiter" cmd) expected_delimiter delimiter;
      check string (Printf.sprintf "\"%s\" → fields" cmd) expected_fields fields;
      check (option string) (Printf.sprintf "\"%s\" → file" cmd) expected_file file
    | Shell_ir_typed.W other ->
      failf "expected Cut for: %s, got %s" cmd (ctor_name (Shell_ir_typed.W other))
  in
  (* short forms *)
  check_cut "cut -d: -f1 /etc/passwd"
    ~expected_delimiter:(Some ":") ~expected_fields:"1" ~expected_file:(Some "/etc/passwd");
  (* long forms *)
  check_cut "cut --delimiter=: --fields=1,3 /etc/passwd"
    ~expected_delimiter:(Some ":") ~expected_fields:"1,3" ~expected_file:(Some "/etc/passwd");
  (* mixed long/short *)
  check_cut "cut --delimiter , -f2 file.txt"
    ~expected_delimiter:(Some ",") ~expected_fields:"2" ~expected_file:(Some "file.txt")
;;

(** Verify that [du] handles space-separated --max-depth N. *)
let test_du_max_depth () =
  let check_du cmd ~expected_depth ~expected_human ~expected_summary ~expected_path =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Du { max_depth; human_readable; summary; path }) ->
      check (option int) (Printf.sprintf "\"%s\" → max_depth" cmd) expected_depth max_depth;
      check bool (Printf.sprintf "\"%s\" → human_readable" cmd) expected_human human_readable;
      check bool (Printf.sprintf "\"%s\" → summary" cmd) expected_summary summary;
      check (option string) (Printf.sprintf "\"%s\" → path" cmd) expected_path path
    | _ -> failf "expected Du for: %s" cmd
  in
  (* equals form *)
  check_du "du --max-depth=2 /tmp"
    ~expected_depth:(Some 2) ~expected_human:false ~expected_summary:false ~expected_path:(Some "/tmp");
  (* space-separated form *)
  check_du "du --max-depth 2 /tmp"
    ~expected_depth:(Some 2) ~expected_human:false ~expected_summary:false ~expected_path:(Some "/tmp");
  (* -h combined *)
  check_du "du -hs /tmp"
    ~expected_depth:None ~expected_human:true ~expected_summary:true ~expected_path:(Some "/tmp")
;;

(** Verify that [find] captures -maxdepth as a typed field. *)
let test_find_maxdepth () =
  let check_find cmd ~expected_name ~expected_type ~expected_maxdepth ~expected_path =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Find { path; name; type_; maxdepth }) ->
      check (option string) (Printf.sprintf "\"%s\" → name" cmd) expected_name name;
      (match expected_type, type_ with
       | None, None -> ()
       | Some `File, Some `File -> ()
       | Some `Dir, Some `Dir -> ()
       | _ -> failf "\"%s\" → type_ mismatch" cmd);
      check (option int) (Printf.sprintf "\"%s\" → maxdepth" cmd) expected_maxdepth maxdepth;
      check string (Printf.sprintf "\"%s\" → path" cmd) expected_path path
    | _ -> failf "expected Find for: %s" cmd
  in
  (* with -maxdepth *)
  check_find "find . -maxdepth 2 -name '*.ml'"
    ~expected_name:(Some "*.ml") ~expected_type:None ~expected_maxdepth:(Some 2) ~expected_path:".";
  (* without -maxdepth *)
  check_find "find /tmp -name 'foo' -type f"
    ~expected_name:(Some "foo") ~expected_type:(Some `File) ~expected_maxdepth:None ~expected_path:"/tmp";
  (* -maxdepth 1 with -type d *)
  check_find "find . -maxdepth 1 -type d"
    ~expected_name:None ~expected_type:(Some `Dir) ~expected_maxdepth:(Some 1) ~expected_path:".";
  (* -maxdepth 0 edge case *)
  check_find "find / -maxdepth 0 -name 'etc'"
    ~expected_name:(Some "etc") ~expected_type:None ~expected_maxdepth:(Some 0) ~expected_path:"/"
;;

(** Verify that [uniq] handles -f and -s value flags. *)
let test_uniq_value_flags () =
  let check_uniq cmd ~expected_count ~expected_duplicates ~expected_unique ~expected_skip_fields ~expected_skip_chars ~expected_file =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Uniq { count; duplicates; unique; skip_fields; skip_chars; file }) ->
      check bool (Printf.sprintf "\"%s\" → count" cmd) expected_count count;
      check bool (Printf.sprintf "\"%s\" → duplicates" cmd) expected_duplicates duplicates;
      check bool (Printf.sprintf "\"%s\" → unique" cmd) expected_unique unique;
      check (option int) (Printf.sprintf "\"%s\" → skip_fields" cmd) expected_skip_fields skip_fields;
      check (option int) (Printf.sprintf "\"%s\" → skip_chars" cmd) expected_skip_chars skip_chars;
      check (option string) (Printf.sprintf "\"%s\" → file" cmd) expected_file file
    | _ -> failf "expected Uniq for: %s" cmd
  in
  (* basic *)
  check_uniq "uniq file.txt"
    ~expected_count:false ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:None ~expected_skip_chars:None ~expected_file:(Some "file.txt");
  (* -c *)
  check_uniq "uniq -c file.txt"
    ~expected_count:true ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:None ~expected_skip_chars:None ~expected_file:(Some "file.txt");
  (* -f skips fields *)
  check_uniq "uniq -f 2 file.txt"
    ~expected_count:false ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:(Some 2) ~expected_skip_chars:None ~expected_file:(Some "file.txt");
  (* -s skips chars *)
  check_uniq "uniq -s 5 file.txt"
    ~expected_count:false ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:None ~expected_skip_chars:(Some 5) ~expected_file:(Some "file.txt");
  (* combined -f and -c *)
  check_uniq "uniq -f 1 -c file.txt"
    ~expected_count:true ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:(Some 1) ~expected_skip_chars:None ~expected_file:(Some "file.txt");
  (* combined -f and -s *)
  check_uniq "uniq -f 3 -s 7 file.txt"
    ~expected_count:false ~expected_duplicates:false ~expected_unique:false ~expected_skip_fields:(Some 3) ~expected_skip_chars:(Some 7) ~expected_file:(Some "file.txt")
;;

let test_grep_combined_flags () =
  let check_grep cmd ~expected_recursive ~expected_case_sensitive ~expected_pattern ~expected_path =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Grep { pattern; path; recursive; case_sensitive }) ->
      check bool (Printf.sprintf "\"%s\" → recursive" cmd) expected_recursive recursive;
      check bool (Printf.sprintf "\"%s\" → case_sensitive" cmd) expected_case_sensitive case_sensitive;
      check string (Printf.sprintf "\"%s\" → pattern" cmd) expected_pattern pattern;
      check (option string) (Printf.sprintf "\"%s\" → path" cmd) expected_path path
    | _ -> failf "expected Grep for: %s" cmd
  in
  (* separate flags *)
  check_grep "grep -r -i pattern path"
    ~expected_recursive:true ~expected_case_sensitive:false ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* combined -ri *)
  check_grep "grep -ri pattern path"
    ~expected_recursive:true ~expected_case_sensitive:false ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* combined -ir *)
  check_grep "grep -ir pattern path"
    ~expected_recursive:true ~expected_case_sensitive:false ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* combined -ri with other unknown flags *)
  check_grep "grep -riv pattern path"
    ~expected_recursive:true ~expected_case_sensitive:false ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* -r only *)
  check_grep "grep -r pattern path"
    ~expected_recursive:true ~expected_case_sensitive:true ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* -i only *)
  check_grep "grep -i pattern path"
    ~expected_recursive:false ~expected_case_sensitive:false ~expected_pattern:"pattern" ~expected_path:(Some "path")
;;

(** Verify that [grep] captures -l/--files-with-matches as a typed field. *)
let test_grep_files_with_matches () =
  let check_grep cmd ~expected_recursive ~expected_case_sensitive ~expected_fwm ~expected_pattern ~expected_path =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Grep { pattern; path; recursive; case_sensitive; files_with_matches }) ->
      check bool (Printf.sprintf "\"%s\" → recursive" cmd) expected_recursive recursive;
      check bool (Printf.sprintf "\"%s\" → case_sensitive" cmd) expected_case_sensitive case_sensitive;
      check bool (Printf.sprintf "\"%s\" → files_with_matches" cmd) expected_fwm files_with_matches;
      check string (Printf.sprintf "\"%s\" → pattern" cmd) expected_pattern pattern;
      check (option string) (Printf.sprintf "\"%s\" → path" cmd) expected_path path
    | _ -> failf "expected Grep for: %s" cmd
  in
  (* -l standalone *)
  check_grep "grep -l pattern path"
    ~expected_recursive:false ~expected_case_sensitive:true ~expected_fwm:true ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* --files-with-matches long form *)
  check_grep "grep --files-with-matches pattern path"
    ~expected_recursive:false ~expected_case_sensitive:true ~expected_fwm:true ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* combined -rl *)
  check_grep "grep -rl pattern path"
    ~expected_recursive:true ~expected_case_sensitive:true ~expected_fwm:true ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* combined -rli *)
  check_grep "grep -rli pattern path"
    ~expected_recursive:true ~expected_case_sensitive:false ~expected_fwm:true ~expected_pattern:"pattern" ~expected_path:(Some "path");
  (* -r only (no -l) *)
  check_grep "grep -r pattern path"
    ~expected_recursive:true ~expected_case_sensitive:true ~expected_fwm:false ~expected_pattern:"pattern" ~expected_path:(Some "path")
;;

let test_wget_long_form () =
  let check_wget cmd ~expected_url ~expected_output ~expected_continue ~expected_ncc =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Wget { url; output; continue_; no_check_certificate }) ->
      check string (Printf.sprintf "\"%s\" → url" cmd) expected_url url;
      check (option string) (Printf.sprintf "\"%s\" → output" cmd) expected_output output;
      check bool (Printf.sprintf "\"%s\" → continue" cmd) expected_continue continue_;
      check bool (Printf.sprintf "\"%s\" → no_check_certificate" cmd) expected_ncc no_check_certificate
    | _ -> failf "expected Wget for: %s" cmd
  in
  (* space-separated *)
  check_wget "wget -O file.html https://example.com"
    ~expected_url:"https://example.com" ~expected_output:(Some "file.html")
    ~expected_continue:false ~expected_ncc:false;
  (* long form with = *)
  check_wget "wget --output-document=file.html https://example.com"
    ~expected_url:"https://example.com" ~expected_output:(Some "file.html")
    ~expected_continue:false ~expected_ncc:false;
  (* no output flag *)
  check_wget "wget https://example.com"
    ~expected_url:"https://example.com" ~expected_output:None
    ~expected_continue:false ~expected_ncc:false;
  (* --continue resume *)
  check_wget "wget --continue https://example.com/big.iso"
    ~expected_url:"https://example.com/big.iso" ~expected_output:None
    ~expected_continue:true ~expected_ncc:false;
  (* -c short form *)
  check_wget "wget -c https://example.com/big.iso"
    ~expected_url:"https://example.com/big.iso" ~expected_output:None
    ~expected_continue:true ~expected_ncc:false;
  (* --no-check-certificate *)
  check_wget "wget --no-check-certificate https://self-signed.example.com"
    ~expected_url:"https://self-signed.example.com" ~expected_output:None
    ~expected_continue:false ~expected_ncc:true;
  (* both flags combined *)
  check_wget "wget -c --no-check-certificate -O out.bin https://example.com"
    ~expected_url:"https://example.com" ~expected_output:(Some "out.bin")
    ~expected_continue:true ~expected_ncc:true
;;

let test_ssh_identity_file () =
  let check_ssh cmd ~expected_host ~expected_user ~expected_port ~expected_id =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Ssh { host; user; command = _; port; identity_file }) ->
      check string (Printf.sprintf "\"%s\" → host" cmd) expected_host host;
      check (option string) (Printf.sprintf "\"%s\" → user" cmd) expected_user user;
      check (option int) (Printf.sprintf "\"%s\" → port" cmd) expected_port port;
      check (option string) (Printf.sprintf "\"%s\" → identity_file" cmd) expected_id identity_file
    | _ -> failf "expected Ssh for: %s" cmd
  in
  (* basic - no identity file *)
  check_ssh "ssh user@host"
    ~expected_host:"host" ~expected_user:(Some "user") ~expected_port:None ~expected_id:None;
  (* -i flag *)
  check_ssh "ssh -i ~/.ssh/id_rsa user@host"
    ~expected_host:"host" ~expected_user:(Some "user") ~expected_port:None
    ~expected_id:(Some "~/.ssh/id_rsa");
  (* -i with port *)
  check_ssh "ssh -p 2222 -i /path/key user@host"
    ~expected_host:"host" ~expected_user:(Some "user") ~expected_port:(Some 2222)
    ~expected_id:(Some "/path/key");
  (* -i before user@host, no user *)
  check_ssh "ssh -i key.pem host"
    ~expected_host:"host" ~expected_user:None ~expected_port:None
    ~expected_id:(Some "key.pem")
;;

let test_diff_brief () =
  let check_diff cmd ~expected_unified ~expected_brief =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Diff { file1; file2; unified; brief }) ->
      ignore (file1, file2);
      check bool (Printf.sprintf "\"%s\" → unified" cmd) expected_unified unified;
      check bool (Printf.sprintf "\"%s\" → brief" cmd) expected_brief brief
    | _ -> failf "expected Diff for: %s" cmd
  in
  check_diff "diff a b" ~expected_unified:false ~expected_brief:false;
  check_diff "diff -u a b" ~expected_unified:true ~expected_brief:false;
  check_diff "diff --brief a b" ~expected_unified:false ~expected_brief:true;
  check_diff "diff -q -u a b" ~expected_unified:true ~expected_brief:true
;;

let test_uname_combined_flags () =
  let check_uname cmd ~expected_all ~expected_kn ~expected_rel ~expected_mach =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Uname { all; kernel_name; release; machine }) ->
      check bool (Printf.sprintf "\"%s\" → all" cmd) expected_all all;
      check bool (Printf.sprintf "\"%s\" → kernel_name" cmd) expected_kn kernel_name;
      check bool (Printf.sprintf "\"%s\" → release" cmd) expected_rel release;
      check bool (Printf.sprintf "\"%s\" → machine" cmd) expected_mach machine
    | _ -> failf "expected Uname for: %s" cmd
  in
  (* separate flags *)
  check_uname "uname -s -r -m"
    ~expected_all:false ~expected_kn:true ~expected_rel:true ~expected_mach:true;
  (* combined -srm *)
  check_uname "uname -srm"
    ~expected_all:false ~expected_kn:true ~expected_rel:true ~expected_mach:true;
  (* combined -arsm *)
  check_uname "uname -arsm"
    ~expected_all:true ~expected_kn:true ~expected_rel:true ~expected_mach:true;
  (* -a only *)
  check_uname "uname -a"
    ~expected_all:true ~expected_kn:false ~expected_rel:false ~expected_mach:false
;;

let test_file_combined_flags () =
  let check_file cmd ~expected_mime ~expected_brief ~expected_path =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.File { path; mime; brief }) ->
      check bool (Printf.sprintf "\"%s\" → mime" cmd) expected_mime mime;
      check bool (Printf.sprintf "\"%s\" → brief" cmd) expected_brief brief;
      check string (Printf.sprintf "\"%s\" → path" cmd) expected_path path
    | _ -> failf "expected File for: %s" cmd
  in
  (* separate flags *)
  check_file "file -b -i /etc/passwd"
    ~expected_mime:true ~expected_brief:true ~expected_path:"/etc/passwd";
  (* combined -bi *)
  check_file "file -bi /etc/passwd"
    ~expected_mime:true ~expected_brief:true ~expected_path:"/etc/passwd";
  (* combined -ib *)
  check_file "file -ib /etc/passwd"
    ~expected_mime:true ~expected_brief:true ~expected_path:"/etc/passwd";
  (* -b only *)
  check_file "file -b /etc/passwd"
    ~expected_mime:false ~expected_brief:true ~expected_path:"/etc/passwd"
;;

let test_rsync_long_form () =
  let check_rsync cmd ~expected_src ~expected_dst ~expected_archive ~expected_delete ~expected_dry_run ~expected_compress ~expected_flags =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Rsync { source; dest; archive; delete; dry_run; compress; flags }) ->
      check string (Printf.sprintf "\"%s\" → source" cmd) expected_src source;
      check string (Printf.sprintf "\"%s\" → dest" cmd) expected_dst dest;
      check bool (Printf.sprintf "\"%s\" → archive" cmd) expected_archive archive;
      check bool (Printf.sprintf "\"%s\" → delete" cmd) expected_delete delete;
      check bool (Printf.sprintf "\"%s\" → dry_run" cmd) expected_dry_run dry_run;
      check bool (Printf.sprintf "\"%s\" → compress" cmd) expected_compress compress;
      check (list string) (Printf.sprintf "\"%s\" → flags" cmd) expected_flags flags
    | _ -> failf "expected Rsync for: %s" cmd
  in
  (* two-token form *)
  check_rsync "rsync --exclude .git src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:false ~expected_delete:false ~expected_dry_run:false ~expected_compress:false
    ~expected_flags:["--exclude"; ".git"];
  (* long form with = *)
  check_rsync "rsync --exclude=.git src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:false ~expected_delete:false ~expected_dry_run:false ~expected_compress:false
    ~expected_flags:["--exclude"; ".git"];
  (* multiple long forms with = *)
  check_rsync "rsync --exclude=.git --exclude=node_modules --progress src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:false ~expected_delete:false ~expected_dry_run:false ~expected_compress:false
    ~expected_flags:["--exclude"; ".git"; "--exclude"; "node_modules"; "--progress"];
  (* typed boolean flags *)
  check_rsync "rsync -a --delete --dry-run -z src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:true ~expected_delete:true ~expected_dry_run:true ~expected_compress:true
    ~expected_flags:[];
  check_rsync "rsync -avz src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:false ~expected_delete:false ~expected_dry_run:false ~expected_compress:false
    ~expected_flags:["-avz"];
  check_rsync "rsync --archive --compress --exclude='*.log' src/ dest/"
    ~expected_src:"src/" ~expected_dst:"dest/"
    ~expected_archive:true ~expected_delete:false ~expected_dry_run:false ~expected_compress:true
    ~expected_flags:["--exclude"; "*.log"]
;;

let test_df_combined_and_long_form () =
  let check_df cmd ~expected_hr ~expected_fs =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Df { human_readable; filesystem_type; _ }) ->
      check bool (Printf.sprintf "\"%s\" → human_readable" cmd) expected_hr human_readable;
      check (option string) (Printf.sprintf "\"%s\" → filesystem_type" cmd) expected_fs filesystem_type
    | _ -> failf "expected Df for: %s" cmd
  in
  (* separate *)
  check_df "df -h -t ext4" ~expected_hr:true ~expected_fs:(Some "ext4");
  (* combined -ht ext4 *)
  check_df "df -ht ext4" ~expected_hr:true ~expected_fs:(Some "ext4");
  (* long form *)
  check_df "df --type=ext4" ~expected_hr:false ~expected_fs:(Some "ext4");
  (* combined -text4 *)
  check_df "df -text4" ~expected_hr:false ~expected_fs:(Some "ext4")
;;

let test_ps_combined_flags () =
  let check_ps cmd ~expected_all ~expected_full ~expected_user =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Ps { all; full; user }) ->
      check bool (Printf.sprintf "\"%s\" → all" cmd) expected_all all;
      check bool (Printf.sprintf "\"%s\" → full" cmd) expected_full full;
      check (option string) (Printf.sprintf "\"%s\" → user" cmd) expected_user user
    | _ -> failf "expected Ps for: %s" cmd
  in
  (* separate *)
  check_ps "ps -e -f" ~expected_all:true ~expected_full:true ~expected_user:None;
  (* combined -ef *)
  check_ps "ps -ef" ~expected_all:true ~expected_full:true ~expected_user:None;
  (* combined -aux *)
  check_ps "ps -aux" ~expected_all:true ~expected_full:false ~expected_user:None;
  (* -uroot combined *)
  check_ps "ps -uroot" ~expected_all:false ~expected_full:false ~expected_user:(Some "root");
  (* -u root separate *)
  check_ps "ps -u root" ~expected_all:false ~expected_full:false ~expected_user:(Some "root")
;;

let test_tar_farchive_combined () =
  let check_tar cmd ~expected_action ~expected_archive ~expected_compression =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Tar { action; archive; compression; _ }) ->
      let action_str = match action with `Create -> "create" | `Extract -> "extract" | `List -> "list" in
      let expected_action_str = match expected_action with `Create -> "create" | `Extract -> "extract" | `List -> "list" in
      check string (Printf.sprintf "\"%s\" → action" cmd) expected_action_str action_str;
      check string (Printf.sprintf "\"%s\" → archive" cmd) expected_archive archive;
      let comp_str = match compression with `None -> "none" | `Gzip -> "gzip" | `Bzip2 -> "bzip2" | `Xz -> "xz" | `Zstd -> "zstd" in
      let expected_comp_str = match expected_compression with `None -> "none" | `Gzip -> "gzip" | `Bzip2 -> "bzip2" | `Xz -> "xz" | `Zstd -> "zstd" in
      check string (Printf.sprintf "\"%s\" → compression" cmd) expected_comp_str comp_str
    | _ -> failf "expected Tar for: %s" cmd
  in
  (* separate -f *)
  check_tar "tar -czf archive.tar.gz dir/"
    ~expected_action:`Create ~expected_archive:"archive.tar.gz" ~expected_compression:`Gzip;
  (* bare xzf expanded *)
  check_tar "tar xzf archive.tar.gz"
    ~expected_action:`Extract ~expected_archive:"archive.tar.gz" ~expected_compression:`Gzip;
  (* combined -fARCHIVE: -czfarchive.tar.gz *)
  check_tar "tar -czfarchive.tar.gz dir/"
    ~expected_action:`Create ~expected_archive:"archive.tar.gz" ~expected_compression:`Gzip;
  (* combined -xfarchive.tar *)
  check_tar "tar -xfarchive.tar"
    ~expected_action:`Extract ~expected_archive:"archive.tar" ~expected_compression:`None
;;

(* ── Curl -o/-L/-k ────────────────────────────────────────────── *)

let test_curl_flags () =
  let check_curl cmd ~expected_output ~expected_follow ~expected_insecure =
    let simple = parse_simple cmd in
    let typed = Shell_ir_typed.of_simple simple in
    match typed with
    | Shell_ir_typed.W (Shell_ir_typed.Curl { output_file; follow_redirects; insecure; _ }) ->
      check (option string) (Printf.sprintf "\"%s\" → output" cmd) expected_output output_file;
      check bool (Printf.sprintf "\"%s\" → follow_redirects" cmd) expected_follow follow_redirects;
      check bool (Printf.sprintf "\"%s\" → insecure" cmd) expected_insecure insecure
    | _ -> failf "expected Curl for: %s" cmd
  in
  check_curl "curl https://example.com"
    ~expected_output:None ~expected_follow:false ~expected_insecure:false;
  check_curl "curl -o /tmp/out https://example.com"
    ~expected_output:(Some "/tmp/out") ~expected_follow:false ~expected_insecure:false;
  check_curl "curl -L https://example.com"
    ~expected_output:None ~expected_follow:true ~expected_insecure:false;
  check_curl "curl -k https://example.com"
    ~expected_output:None ~expected_follow:false ~expected_insecure:true;
  check_curl "curl -o /tmp/page.html -L -k https://example.com"
    ~expected_output:(Some "/tmp/page.html") ~expected_follow:true ~expected_insecure:true;
  check_curl "curl --output /tmp/data.json --location --insecure https://api.example.com"
    ~expected_output:(Some "/tmp/data.json") ~expected_follow:true ~expected_insecure:true
;;

(* ── Test runner ───────────────────────────────────────────────── *)

let suite =
  [ ( "E2E: basic commands"
    , [ test_case "basic commands" `Quick test_basic_commands ] )
  ; ( "E2E: git commands"
    , [ test_case "git commands" `Quick test_git_commands ] )
  ; ( "E2E: network tools"
    , [ test_case "network tools" `Quick test_network_tools ] )
  ; ( "E2E: build tools"
    , [ test_case "build tools" `Quick test_build_tools ] )
  ; ( "E2E: privileged commands"
    , [ test_case "privileged commands" `Quick test_privileged_commands ] )
  ; ( "E2E: system tools"
    , [ test_case "system tools" `Quick test_system_tools ] )
  ; ( "E2E: generic fallback"
    , [ test_case "generic fallback" `Quick test_generic_fallback ] )
  ; ( "E2E: round-trip"
    , [ test_case "round-trip" `Quick test_round_trip_e2e ] )
  ; ( "E2E: Make combined -jN"
    , [ test_case "field values" `Quick test_make_combined_jobs
      ; test_case "round-trip" `Quick test_make_round_trip
      ] )
  ; ( "E2E: Head combined -nN"
    , [ test_case "field values" `Quick test_head_combined_lines ] )
  ; ( "E2E: Tail combined -nN"
    , [ test_case "field values" `Quick test_tail_combined_lines ] )
  ; ( "E2E: Git_log combined -nN"
    , [ test_case "field values" `Quick test_git_log_combined_count
      ; test_case "round-trip" `Quick test_combined_value_flag_round_trip
      ] )
  ; ( "E2E: Sed flags"
    , [ test_case "field values" `Quick test_sed_flags ] )
  ; ( "E2E: Sed -E/-n"
    , [ test_case "extended flags" `Quick test_sed_extended ] )
  ; ( "E2E: Sort combined -kN + -t"
    , [ test_case "field values" `Quick test_sort_flags ] )
  ; ( "E2E: Cut long forms"
    , [ test_case "field values" `Quick test_cut_long_forms ] )
  ; ( "E2E: Du --max-depth"
    , [ test_case "field values" `Quick test_du_max_depth ] )
  ; ( "E2E: Find -maxdepth"
    , [ test_case "field values" `Quick test_find_maxdepth ] )
  ; ( "E2E: Uniq -f/-s"
    , [ test_case "field values" `Quick test_uniq_value_flags ] )
  ; ( "E2E: Grep combined flags"
    , [ test_case "field values" `Quick test_grep_combined_flags ] )
  ; ( "E2E: Grep -l/--files-with-matches"
    , [ test_case "field values" `Quick test_grep_files_with_matches ] )
  ; ( "E2E: Wget --output-document=X"
    , [ test_case "field values" `Quick test_wget_long_form ] )
  ; ( "E2E: Diff --brief"
    , [ test_case "field values" `Quick test_diff_brief ] )
  ; ( "E2E: Uname combined -srm"
    , [ test_case "field values" `Quick test_uname_combined_flags ] )
  ; ( "E2E: File combined -bi"
    , [ test_case "field values" `Quick test_file_combined_flags ] )
  ; ( "E2E: Rsync --exclude=PATTERN"
    , [ test_case "field values" `Quick test_rsync_long_form ] )
  ; ( "E2E: Df combined + long form"
    , [ test_case "field values" `Quick test_df_combined_and_long_form ] )
  ; ( "E2E: Ps combined flags"
    , [ test_case "field values" `Quick test_ps_combined_flags ] )
  ; ( "E2E: Tar -fARCHIVE combined"
    , [ test_case "field values" `Quick test_tar_farchive_combined ] )
  ; ( "E2E: Ssh -i identity file"
    , [ test_case "field values" `Quick test_ssh_identity_file ] )
  ; ( "E2E: Curl -o/-L/-k"
    , [ test_case "field values" `Quick test_curl_flags ] )
  ; ( "E2E: File operations"
    , [ test_case "constructor" `Quick test_file_operations
      ; test_case "Cp fields" `Quick test_cp_field_values
      ; test_case "Mv fields" `Quick test_mv_field_values
      ; test_case "Ln fields" `Quick test_ln_field_values
      ] )
  ]

let () = run "shell_ir_typed_e2e" suite
