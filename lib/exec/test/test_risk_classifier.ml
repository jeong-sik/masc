(* P20 tests: command risk classifier *)

module RC = Masc_exec.Risk_classifier

(* --- risk_class helpers --- *)

let test_risk_class_to_string () =
  Alcotest.(check string) "read" "read" (RC.risk_class_to_string RC.Read);
  Alcotest.(check string) "write" "write" (RC.risk_class_to_string RC.Write);
  Alcotest.(check string) "network" "network" (RC.risk_class_to_string RC.Network);
  Alcotest.(check string)
    "destructive"
    "destructive"
    (RC.risk_class_to_string RC.Destructive)
;;

let test_risk_class_to_json () =
  (match RC.risk_class_to_json RC.Read with
   | `String "read" -> ()
   | _ -> Alcotest.fail "Read JSON");
  (match RC.risk_class_to_json RC.Destructive with
   | `String "destructive" -> ()
   | _ -> Alcotest.fail "Destructive JSON");
  match RC.risk_class_to_json RC.Network with
  | `String "network" -> ()
  | _ -> Alcotest.fail "Network JSON"
;;

let test_is_cacheable () =
  Alcotest.(check bool) "read cacheable" true (RC.is_cacheable RC.Read);
  Alcotest.(check bool) "write not" false (RC.is_cacheable RC.Write);
  Alcotest.(check bool) "network not" false (RC.is_cacheable RC.Network);
  Alcotest.(check bool) "destructive not" false (RC.is_cacheable RC.Destructive)
;;

let test_requires_approval () =
  Alcotest.(check bool) "destructive" true (RC.requires_approval RC.Destructive);
  Alcotest.(check bool) "read" false (RC.requires_approval RC.Read);
  Alcotest.(check bool) "write" false (RC.requires_approval RC.Write);
  Alcotest.(check bool) "network" false (RC.requires_approval RC.Network)
;;

let test_default_timeout_ms () =
  Alcotest.(check int) "read" 30_000 (RC.default_timeout_ms RC.Read);
  Alcotest.(check int) "write" 60_000 (RC.default_timeout_ms RC.Write);
  Alcotest.(check int) "network" 120_000 (RC.default_timeout_ms RC.Network);
  Alcotest.(check int) "destructive" 120_000 (RC.default_timeout_ms RC.Destructive)
;;

(* --- classify: read commands --- *)

let test_classify_read () =
  let read_cmds =
    [ "ls"
    ; "ls -la"
    ; "cat file.txt"
    ; "less README.md"
    ; "more /tmp/log"
    ; "head -n 10 file"
    ; "tail -f log"
    ; "file /bin/ls"
    ; "stat /dev/null"
    ; "wc -l *.ml"
    ; "du -sh ."
    ; "df -h"
    ; "free"
    ; "uptime"
    ; "whoami"
    ; "id"
    ; "uname -a"
    ; "echo hello"
    ; "printf '%s' x"
    ; "pwd"
    ; "env"
    ; "printenv"
    ; "which ocaml"
    ; "type ls"
    ; "find . -name '*.ml'"
    ; "rg pattern"
    ; "grep -r pattern ."
    ; "ag TODO"
    ; "ack 'TODO'"
    ; "fd .ml"
    ; "ps aux"
    ; "top"
    ; "lsof -i"
    ; "ss -tln"
    ; "netstat -an"
    ; "dig example.com"
    ; "nslookup example.com"
    ; "git status"
    ; "git log --oneline"
    ; "git diff"
    ; "git show HEAD"
    ; "git branch"
    ; "git tag"
    ; "git remote -v"
    ; "git stash list"
    ; "opam list"
    ]
  in
  List.iter
    (fun cmd ->
       match RC.classify cmd with
       | RC.Read -> ()
       | other ->
         Alcotest.fail
           (Printf.sprintf
              "expected Read for '%s', got %s"
              cmd
              (RC.risk_class_to_string other)))
    read_cmds
;;

(* --- classify: write commands --- *)

let test_classify_write () =
  let write_cmds =
    [ "git add ."
    ; "git commit -m 'x'"
    ; "git push"
    ; "git merge main"
    ; "git rebase main"
    ; "git checkout -b feat"
    ; "git switch main"
    ; "git stash push"
    ; "git apply patch"
    ; "git cherry-pick abc"
    ; "cp a b"
    ; "mv a b"
    ; "touch newfile"
    ; "mkdir -p dir/sub"
    ; "tee output.txt"
    ; "install -m 755 bin /usr/local/bin"
    ; "chmod 644 file"
    ; "chown user file"
    ; "chgrp staff file"
    ; "dune build"
    ; "cargo build"
    ; "cargo test"
    ; "npm test"
    ; "npm run build"
    ; "make"
    ; "make test"
    ; "docker build ."
    ]
  in
  List.iter
    (fun cmd ->
       match RC.classify cmd with
       | RC.Write -> ()
       | other ->
         Alcotest.fail
           (Printf.sprintf
              "expected Write for '%s', got %s"
              cmd
              (RC.risk_class_to_string other)))
    write_cmds
;;

(* --- classify: network commands --- *)

let test_classify_network () =
  let net_cmds =
    [ "curl https://example.com"
    ; "wget http://example.com/file"
    ; "ssh user@host"
    ; "scp file user@host:/tmp"
    ; "rsync -av src/ dest/"
    ; "ftp host"
    ; "sftp host"
    ; "git clone https://github.com/org/repo"
    ; "git fetch origin"
    ; "git pull"
    ; "opam install pkg"
    ; "opam update"
    ; "pip install pkg"
    ; "docker pull image"
    ; "docker run image"
    ; "helm install chart"
    ; "kubectl get pods"
    ]
  in
  List.iter
    (fun cmd ->
       match RC.classify cmd with
       | RC.Network -> ()
       | other ->
         Alcotest.fail
           (Printf.sprintf
              "expected Network for '%s', got %s"
              cmd
              (RC.risk_class_to_string other)))
    net_cmds
;;

(* --- classify: destructive commands --- *)

let test_classify_destructive () =
  let destructive_cmds =
    [ "rm file"
    ; "rm -rf dir"
    ; "rmdir emptydir"
    ; "shred secret.txt"
    ; "truncate -s 0 file"
    ; "dd if=/dev/zero of=/dev/sda"
    ; "sudo apt install"
    ; "su - root"
    ; "doas cmd"
    ; "mkfs.ext4 /dev/sda1"
    ; "fdisk /dev/sda"
    ; "parted /dev/sda"
    ; "kill 1234"
    ; "killall process"
    ; "pkill -f pattern"
    ; "reboot"
    ; "shutdown -h now"
    ; "poweroff"
    ; "halt"
    ; "iptables -A INPUT -j DROP"
    ; "ufw deny 80"
    ]
  in
  List.iter
    (fun cmd ->
       match RC.classify cmd with
       | RC.Destructive -> ()
       | other ->
         Alcotest.fail
           (Printf.sprintf
              "expected Destructive for '%s', got %s"
              cmd
              (RC.risk_class_to_string other)))
    destructive_cmds
;;

(* --- flag escalation --- *)

let test_flag_escalation () =
  (* read cmd with -rf → Destructive *)
  (match RC.classify "ls -rf /tmp" with
   | RC.Destructive -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "ls -rf should be Destructive, got %s"
          (RC.risk_class_to_string other)));
  (* write cmd with -rf → Destructive *)
  (match RC.classify "chmod -Rf 777 /" with
   | RC.Destructive -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "chmod -Rf 777 / should be Destructive, got %s"
          (RC.risk_class_to_string other)));
  (* --no-preserve-root is destructive *)
  (match RC.classify "rm --no-preserve-root -rf /" with
   | RC.Destructive -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "rm --no-preserve-root should be Destructive, got %s"
          (RC.risk_class_to_string other)));
  (* tail -f should remain Read (follow, not force) *)
  match RC.classify "tail -f log" with
  | RC.Read -> ()
  | other ->
    Alcotest.fail
      (Printf.sprintf "tail -f should be Read, got %s" (RC.risk_class_to_string other))
;;

(* --- fallback: unknown → Write (conservative) --- *)

let test_classify_unknown () =
  (match RC.classify "my_custom_tool --flag" with
   | RC.Write -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf "unknown should be Write, got %s" (RC.risk_class_to_string other)));
  match RC.classify "unknown_binary" with
  | RC.Write -> ()
  | other ->
    Alcotest.fail
      (Printf.sprintf
         "unknown binary should be Write, got %s"
         (RC.risk_class_to_string other))
;;

(* --- whitespace handling --- *)

let test_whitespace_handling () =
  (match RC.classify "  ls" with
   | RC.Read -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "leading whitespace should still classify as read, got %s"
          (RC.risk_class_to_string other)));
  (match RC.classify "  cat file" with
   | RC.Read -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "leading whitespace cat should be read, got %s"
          (RC.risk_class_to_string other)));
  (match RC.classify "git\tstatus" with
   | RC.Read -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "tab-separated git status should be read, got %s"
          (RC.risk_class_to_string other)));
  (match RC.classify "rm\t-rf /" with
   | RC.Destructive -> ()
   | other ->
     Alcotest.fail
       (Printf.sprintf
          "tab-separated rm -rf should be destructive, got %s"
          (RC.risk_class_to_string other)));
  match RC.classify "rm\n-rf /" with
  | RC.Destructive -> ()
  | other ->
    Alcotest.fail
      (Printf.sprintf
         "newline-separated rm -rf should be destructive, got %s"
         (RC.risk_class_to_string other))
;;

(* --- empty string --- *)

let test_empty_string () =
  match RC.classify "" with
  | RC.Write -> ()
  | other ->
    Alcotest.fail
      (Printf.sprintf
         "empty string should be Write (conservative), got %s"
         (RC.risk_class_to_string other))
;;

let () =
  test_risk_class_to_string ();
  test_risk_class_to_json ();
  test_is_cacheable ();
  test_requires_approval ();
  test_default_timeout_ms ();
  test_classify_read ();
  test_classify_write ();
  test_classify_network ();
  test_classify_destructive ();
  test_flag_escalation ();
  test_classify_unknown ();
  test_whitespace_handling ();
  test_empty_string ();
  print_endline "test_risk_classifier: 13/13 passed"
;;
