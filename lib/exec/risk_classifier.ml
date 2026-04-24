(* P20: Command Risk Classifier
   Pure-function command classification by risk level.
   Prefix matching + flag inspection for escalation. *)

type risk_class =
  | Read
  | Write
  | Network
  | Destructive

let risk_class_to_string = function
  | Read -> "read"
  | Write -> "write"
  | Network -> "network"
  | Destructive -> "destructive"

let risk_class_to_json rc =
  `String (risk_class_to_string rc)

let is_cacheable = function
  | Read -> true
  | _ -> false

let requires_approval = function
  | Destructive -> true
  | _ -> false

let default_timeout_ms = function
  | Read -> 30_000
  | Write -> 60_000
  | Network -> 120_000
  | Destructive -> 120_000

(* --- classification helpers --- *)

let is_shell_whitespace = function
  | ' ' | '\t' | '\n' | '\r' | '\011' | '\012' -> true
  | _ -> false

let normalize_shell_whitespace cmd =
  let len = String.length cmd in
  let buf = Buffer.create len in
  let in_ws = ref false in
  String.iter (fun ch ->
    if is_shell_whitespace ch then
      in_ws := true
    else begin
      if !in_ws && Buffer.length buf > 0 then Buffer.add_char buf ' ';
      in_ws := false;
      Buffer.add_char buf ch
    end
  ) cmd;
  Buffer.contents buf

let first_token cmd =
  let len = String.length cmd in
  let i = ref 0 in
  while !i < len && is_shell_whitespace cmd.[!i] do incr i done;
  let start = !i in
  while !i < len && not (is_shell_whitespace cmd.[!i]) do incr i done;
  if start >= !i then ""
  else String.sub cmd start (!i - start)

(* Pre-compiled regexes for flag detection *)
let destructive_flag_re =
  Re.compile (Re.Pcre.re {_|(^|\s)(-[rR]f|-f[rR]|-[rR]\s+-f|-f\s+-[rR])(\s|$)|_})

let no_preserve_root_re =
  Re.compile (Re.Pcre.re {_|(^|\s)--no-preserve-root(\s|$)|_})

let recursive_flag_re =
  Re.compile (Re.Pcre.re {_|(^|\s)-[rR](\s|$)|_})

let recursive_long_re =
  Re.compile (Re.Pcre.re {_|(^|\s)--recursive(\s|$)|_})

let force_flag_re =
  Re.compile (Re.Pcre.re {_|(^|\s)-f(\s|$)|_})

let force_long_re =
  Re.compile (Re.Pcre.re {_|(^|\s)--force(\s|$)|_})

let has_destructive_flag cmd =
  Re.exec_opt destructive_flag_re cmd <> None
  || Re.exec_opt no_preserve_root_re cmd <> None

let has_recursive_flag cmd =
  Re.exec_opt recursive_flag_re cmd <> None
  || Re.exec_opt recursive_long_re cmd <> None

let has_force_flag cmd =
  Re.exec_opt force_flag_re cmd <> None
  || Re.exec_opt force_long_re cmd <> None

(* Classification tables *)
let read_prefixes = [
  "ls"; "cat"; "less"; "more"; "head"; "tail"; "file"; "stat";
  "wc"; "du"; "df"; "free"; "uptime"; "whoami"; "id"; "uname";
  "echo"; "printf"; "pwd"; "env"; "printenv"; "which"; "type";
  "find"; "rg"; "grep"; "ag"; "ack"; "fd"; "locate";
  "ps"; "top"; "htop"; "lsof"; "ss"; "netstat"; "dig"; "nslookup";
  "git status"; "git log"; "git diff"; "git show"; "git branch";
  "git tag"; "git remote"; "git stash list"; "git config --get";
  "opam";
  "ocamlfind"; "ocamlopt"; "ocamlc";
]

let write_prefixes = [
  "git add"; "git commit"; "git push"; "git merge"; "git rebase";
  "git checkout"; "git switch"; "git reset"; "git stash push";
  "git tag -"; "git apply"; "git cherry-pick";
  "cp"; "mv"; "touch"; "mkdir"; "tee"; "install";
  "chmod"; "chown"; "chgrp";
  "sed -i"; "awk"; "patch";
  "dune"; "cargo build"; "cargo test"; "cargo publish";
  "npm install"; "npm publish"; "npm test"; "npm run"; "make";
  "docker build"; "docker push"; "docker compose";
]

let network_prefixes = [
  "curl"; "wget"; "ssh"; "scp"; "rsync"; "ftp"; "sftp";
  "git clone"; "git fetch"; "git pull";
  "npm install"; "opam install"; "opam update"; "pip install";
  "docker pull"; "docker run"; "helm"; "kubectl";
]

let destructive_prefixes = [
  "rm"; "rmdir"; "shred"; "truncate"; "dd";
  "sudo"; "su"; "doas";
  "mkfs"; "fdisk"; "parted"; "mkswap";
  "kill"; "killall"; "pkill";
  "reboot"; "shutdown"; "poweroff"; "halt";
  "iptables"; "ufw";
]

let matches_prefix cmd prefix =
  let plen = String.length prefix in
  String.length cmd >= plen
  && String.sub cmd 0 plen = prefix
  && (String.length cmd = plen
      || is_shell_whitespace cmd.[plen]
      || cmd.[plen] = '.')

let prefix_matches prefixes cmd =
  List.exists (matches_prefix cmd) prefixes

let classify cmd =
  let cmd = normalize_shell_whitespace (String.trim cmd) in
  let tok = first_token cmd in
  if prefix_matches destructive_prefixes cmd then
    Destructive
  else if prefix_matches network_prefixes cmd then begin
    if has_destructive_flag cmd then Destructive
    else Network
  end
  else if prefix_matches write_prefixes cmd then begin
    if has_destructive_flag cmd then Destructive
    else if has_force_flag cmd && has_recursive_flag cmd then Destructive
    else Write
  end
  else if prefix_matches read_prefixes cmd then begin
    if has_destructive_flag cmd then Destructive
    else Read
  end
  else if List.exists (fun p -> tok = p) destructive_prefixes then
    Destructive
  else
    Write
