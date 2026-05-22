(* P20: Command Risk Classifier
   Pure-function command classification by risk level.
   Prefix matching + flag/redirection inspection for escalation. *)

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

(* Both helpers below replace [_ -> false] wildcards with explicit
   arms.  Behaviour is identical for the four current variants
   (locked by test_risk_classifier; Read/Write/Network/Destructive
   each asserted directly), but adding a future variant — e.g.
   Privileged, External_call — now triggers a non-exhaustive-match
   compile error instead of silently inheriting the false branch.
   Defends against the inverse of the
   "Variant addition partial-match cascade" pattern. *)
let is_cacheable = function
  | Read -> true
  | Write | Network | Destructive -> false

let requires_approval = function
  | Destructive -> true
  | Read | Write | Network -> false

let default_timeout_ms = function
  | Read -> 30_000
  | Write -> 60_000
  | Network -> 120_000
  | Destructive -> 120_000

module Words = Masc_exec_shell_words.Shell_words

(* --- classification helpers --- *)

let unquoted_values words =
  words
  |> List.filter (fun (word : Words.word) -> not word.quoted)
  |> List.map (fun (word : Words.word) -> word.value)

let first_token words =
  match words with
  | [] -> ""
  | word :: _ -> word.Words.value

let has_shell_write_redirection words =
  List.exists
    (fun (word : Words.word) ->
       (not word.quoted) && String.contains word.value '>')
    words

let short_flag_has chars value =
  String.length value > 1
  && value.[0] = '-'
  && not (String.starts_with ~prefix:"--" value)
  && List.exists (fun ch -> String.contains value ch) chars

let is_recursive_flag = function
  | "-r" | "-R" | "--recursive" -> true
  | value -> short_flag_has [ 'r'; 'R' ] value

let is_force_flag = function
  | "-f" | "--force" -> true
  | value -> short_flag_has [ 'f' ] value

let has_recursive_flag values = List.exists is_recursive_flag values

let has_force_flag values = List.exists is_force_flag values

let has_destructive_flag values =
  List.exists (String.equal "--no-preserve-root") values
  || (has_recursive_flag values && has_force_flag values)

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

let prefix_tokens prefix =
  prefix
  |> String.split_on_char ' '
  |> List.filter (fun token -> not (String.equal token ""))

let command_token_matches ~is_last word prefix_word =
  String.equal word prefix_word
  || (is_last && String.starts_with ~prefix:(prefix_word ^ ".") word)

let rec starts_with_tokens words prefix =
  match words, prefix with
  | _words, [] -> true
  | word :: words_tail, prefix_word :: prefix_tail
    when command_token_matches ~is_last:(prefix_tail = []) word prefix_word ->
    starts_with_tokens words_tail prefix_tail
  | [], _ :: _ | _ :: _, _ :: _ -> false

let matches_prefix words prefix =
  starts_with_tokens (List.map (fun (word : Words.word) -> word.value) words) (prefix_tokens prefix)

let prefix_matches prefixes words =
  List.exists (matches_prefix words) prefixes

let max_risk left right =
  match left, right with
  | Destructive, _ | _, Destructive -> Destructive
  | Network, _ | _, Network -> Network
  | Write, _ | _, Write -> Write
  | Read, Read -> Read

let classify_stage words =
  let unquoted = unquoted_values words in
  let tok = first_token words in
  if prefix_matches destructive_prefixes words then
    Destructive
  else if prefix_matches network_prefixes words then begin
    if has_destructive_flag unquoted then Destructive
    else Network
  end
  else if has_shell_write_redirection words then
    Write
  else if prefix_matches write_prefixes words then begin
    if has_destructive_flag unquoted then Destructive
    else Write
  end
  else if prefix_matches read_prefixes words then begin
    if has_destructive_flag unquoted then Destructive
    else Read
  end
  else if List.exists (fun p -> tok = p) destructive_prefixes then
    Destructive
  else
    Write

let classify cmd =
  match Words.stages (String.trim cmd) with
  | Ok [] -> Write
  | Ok stages -> List.fold_left (fun acc words -> max_risk acc (classify_stage words)) Read stages
  | Error _ -> if String.trim cmd = "" then Write else Destructive
