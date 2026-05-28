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
    ]
;;

let test_git_commands () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "git status", "Git_status"
    ; "git status -s", "Git_status"
    ; "git diff", "Git_diff"
    ; "git diff --stat", "Git_diff"
    ; "git diff --cached", "Git_diff"
    ; "git log --oneline", "Git_log"
    ; "git log --oneline -n 10", "Git_log"
    ; "git commit -m test", "Git_commit"
    ; "git commit --amend -m fix", "Git_commit"
    ; "git push origin main", "Git_push"
    ; "git push --force-with-lease", "Git_push"
    ; "git pull --rebase", "Git_pull"
    ; "git pull origin develop", "Git_pull"
    ; "git clone https://github.com/x/y.git", "Git_clone"
    ; "git clone --depth 1 https://github.com/x/y.git", "Git_clone"
    ; "git clone -b main https://github.com/x/y.git", "Git_clone"
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
    ; "scp file.txt user@host:/tmp/", "Scp"
    ; "scp -r dir/ user@host:/tmp/", "Scp"
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
    ; "tsc --noEmit", "Tsc"
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
    ; "chown user:group file.txt", "Chown"
    ; "su root", "Su"
    ; "dd if=/dev/zero of=/tmp/zeros bs=1M count=10", "Dd"
    ; "mkfs -t ext4 /dev/sdb1", "Mkfs"
    ]
;;

let test_system_tools () =
  List.iter
    (fun (cmd, expected) -> check_ctor cmd expected)
    [ "tar -c -f archive.tar file1 file2", "Tar"
    ; "tar -x -z -f archive.tar.gz", "Tar"
    ; "tar -c -z -f archive.tar.gz dir/", "Tar"
    ; "diff file1 file2", "Diff"
    ; "diff -u file1 file2", "Diff"
    ; "sed s/foo/bar/g file.txt", "Sed"
    ; "rsync -a -v -z dir/ user@host:/backup/", "Rsync"
    ; "patch -p1", "Patch"
    ; "node script.js", "Node"
    ; "python script.py", "Python"
    ; "python3 script.py", "Python3"
    ; "pip install requests", "Pip"
    ]
;;

let test_generic_fallback () =
  (* Commands not in Exec_program.known should fall through to Generic *)
  List.iter
    (fun cmd -> check_ctor cmd "Generic")
    [ "awk '{print $1}'"
    ; "xargs echo"
    ; "tee /tmp/output.txt"
    ; "less file.txt"
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
    ; "git status -s"
    ; "git diff --stat"
    ; "git log --oneline -n 10"
    ; "git commit -m test"
    ; "git push origin main"
    ; "git pull --rebase"
    ; "git clone https://github.com/x/y.git"
    ; "git clone --depth 1 https://github.com/x/y.git"
    ; "curl -X POST https://example.com"
    ; "wget https://example.com/file.txt"
    ; "ssh user@host ls -l -a"
    ; "scp file.txt user@host:/tmp/"
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
    ; "chown user:group file.txt"
    ; "su root"
    ; "tar -c -f archive.tar file1"
    ; "tar -x -z -f archive.tar.gz"
    ; "diff -u file1 file2"
    ; "sed s/foo/bar/g file.txt"
    ; "rsync -a -v -z dir/ user@host:/backup/"
    ; "node script.js"
    ; "python script.py"
    ; "python3 script.py"
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
    ; "echo hello"
    ; "which ocaml"
    ; "printenv PATH"
    ; "basename /tmp/foo.bar .bar"
    ; "dirname /tmp/foo.bar"
    ; "test -f file.txt"
    ; "printf '%s\\n' hello"
    ; "uniq -c file.txt"
    ]
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
  ]

let () = run "shell_ir_typed_e2e" suite
