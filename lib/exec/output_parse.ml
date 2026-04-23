(* P10: Structured Output Extraction
   Pure-function parsers that turn raw command output into machine-readable
   JSON.  No side effects, no I/O.  Each parser returns [Some json] on a
   confident match or [None] to decline (fail-open). *)

(* --- module-level regexes for git diff --stat --- *)

let files_changed_re = Re.Pcre.re {|\b(\d+) file|} |> Re.compile
let insertions_re = Re.Pcre.re {|\b(\d+) insertion|} |> Re.compile
let deletions_re = Re.Pcre.re {|\b(\d+) deletion|} |> Re.compile

(* --- git status --porcelain --- *)

let parse_git_status_porcelain output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> String.trim line <> "")
  in
  if lines = [] then None
  else
    let staged = ref [] and unstaged = ref [] and untracked = ref [] in
    List.iter
      (fun line ->
        if String.length line < 2 then ()
        else
          let xy = String.sub line 0 2 in
          let path = String.trim (String.sub line 2 (String.length line - 2)) in
          (* XY format: X=index, Y=worktree *)
          match xy.[0], xy.[1] with
          | '?', '?' -> untracked := path :: !untracked
          | ' ', ('M' | 'D' | 'A') -> unstaged := path :: !unstaged
          | ('M' | 'A' | 'D' | 'R' | 'C'), _ ->
              staged := path :: !staged;
              if xy.[1] <> ' ' then unstaged := path :: !unstaged
          | ' ', _ -> () (* clean in index, clean in worktree *)
          | _ -> unstaged := path :: !unstaged)
      lines;
    let n_staged = List.length !staged in
    let n_unstaged = List.length !unstaged in
    let n_untracked = List.length !untracked in
    if n_staged + n_unstaged + n_untracked = 0 then None
    else
      Some
        (`Assoc
           [
             ("staged", `List (List.map (fun p -> `String p) (List.rev !staged)));
             ("unstaged", `List (List.map (fun p -> `String p) (List.rev !unstaged)));
             ( "untracked",
               `List (List.map (fun p -> `String p) (List.rev !untracked)) );
           ])

(* --- git log --oneline --- *)

let parse_git_log_oneline output =
  let lines = String.split_on_char '\n' (String.trim output) in
  if lines = [] then None
  else
    let commits = ref [] in
    List.iter
      (fun line ->
        (* format: "abc1234 commit message" *)
        let len = String.length line in
        if len < 8 then ()
        else
          (* find first space after hash *)
          let rec find_space i =
            if i >= len then len
            else if line.[i] = ' ' then i
            else find_space (i + 1)
          in
          let sp = find_space 0 in
          if sp = 0 || sp >= len then ()
          else
            let hash = String.sub line 0 sp in
            let msg = String.trim (String.sub line (sp + 1) (len - sp - 1)) in
            commits := `Assoc [ ("hash", `String hash); ("message", `String msg) ]
                       :: !commits)
      lines;
    let n = List.length !commits in
    if n = 0 then None
    else Some (`Assoc [ ("commits", `List (List.rev !commits)); ("count", `Int n) ])

(* --- git diff --stat --- *)

let parse_git_diff_stat output =
  let lines = String.split_on_char '\n' (String.trim output) in
  if lines = [] then None
  else
    match List.rev lines with
    | [] -> None
    | last :: _ ->
        (* last line: " N files changed, M insertions(+), D deletions(-)" *)
        let lower = String.lowercase_ascii last in
        if not
             (String_util.contains_substring lower " file changed"
              || String_util.contains_substring lower " files changed")
        then None
        else
          let extract re =
            match Re.exec_opt re lower with
            | Some g -> (try int_of_string (Re.Group.get g 1) with _ -> 0)
            | None -> 0
          in
          let files_changed = extract files_changed_re in
          let insertions = extract insertions_re in
          let deletions = extract deletions_re in
          if files_changed = 0 && insertions = 0 && deletions = 0 then None
          else
            Some
              (`Assoc
                 [
                   ("files_changed", `Int files_changed);
                   ("insertions", `Int insertions);
                   ("deletions", `Int deletions);
                 ])

(* --- wc -l --- *)

let parse_wc_lines output =
  let line = String.trim output in
  if line = "" then None
  else
    (* format: "    1234 filename" or just "1234" *)
    let tokens = String.split_on_char '\n' line in
    match tokens with
    | [] -> None
    | first :: _ ->
        let words =
          String.split_on_char ' ' first
          |> List.map String.trim
          |> List.filter (fun s -> s <> "")
        in
        match words with
        | [] -> None
        | n_str :: _ ->
            (try Some (`Assoc [ ("lines", `Int (int_of_string n_str)) ])
             with _ -> None)

(* --- ls -la --- *)

let parse_ls_long output =
  let lines = String.split_on_char '\n' (String.trim output) in
  if lines = [] then None
  else
    let entries = ref [] in
    List.iter
      (fun line ->
        let line = String.trim line in
        (* skip "total N" line *)
        if String.starts_with ~prefix:"total" line then ()
        else
          (* format: "drwxr-xr-x  2 user group  4096 Jan 1 12:00 dirname" *)
          let len = String.length line in
          if len < 10 then ()
          else
            let perms = String.sub line 0 10 in
            (* skip if perms doesn't look like drwx... or -rw... *)
            if perms.[0] <> 'd' && perms.[0] <> '-' && perms.[0] <> 'l' then ()
            else
              let rest = String.trim (String.sub line 10 (len - 10)) in
              let parts =
                String.split_on_char ' ' rest
                |> List.map String.trim
                |> List.filter (fun s -> s <> "")
              in
              (* parts: [nlink, user, group, size, month, day, time/year, name...] *)
              (match parts with
              | _nlink :: _user :: _group :: size_str :: _m :: _d :: _t :: name_parts ->
                  let name = String.concat " " name_parts in
                  (try
                     entries :=
                       `Assoc
                         [ ("perms", `String perms); ("size", `Int (int_of_string size_str))
                         ; ("name", `String name) ]
                       :: !entries
                   with _ -> ())
              | _ -> ()))
      lines;
    let n = List.length !entries in
    if n = 0 then None
    else Some (`Assoc [ ("entries", `List (List.rev !entries)); ("count", `Int n) ])

(* --- dune test output --- *)

let parse_dune_test output =
  (* dune runtest outputs like:
     "Test src/...: ok" or "...FAILED..."
     Summary line may not exist, so count individual results. *)
  let lines = String.split_on_char '\n' (String.trim output) in
  let passed = ref 0 and failed = ref 0 and skipped = ref 0 in
  List.iter
    (fun line ->
      let trimmed = String.trim line in
      let l = String.lowercase_ascii trimmed in
      if String.starts_with ~prefix:"test " l then
        let rest = String.trim (String.sub l 5 (String.length l - 5)) in
        if String.starts_with ~prefix:"src/" rest
           || String.starts_with ~prefix:"test/" rest
        then
          let len = String.length l in
          if len >= 3 && String.sub l (len - 2) 2 = "ok" then incr passed
          else if String.length trimmed > 5 then begin
            (* look for FAILED or ERROR in the line *)
            if String_util.contains_substring l "failed" then incr failed
            else if String_util.contains_substring l "error" then incr failed
          end
      else if String.starts_with ~prefix:"  " l then ()
      else if String.starts_with ~prefix:"error:" l then incr failed
      else ())
    lines;
  let total = !passed + !failed + !skipped in
  if total = 0 then None
  else
    Some
      (`Assoc
         [
           ("passed", `Int !passed);
           ("failed", `Int !failed);
           ("skipped", `Int !skipped);
         ])

(* --- dispatcher --- *)

type parser_kind =
  | Git_status
  | Git_log_oneline
  | Git_diff_stat
  | Wc_lines
  | Ls_long
  | Dune_test

let git_option_requires_arg = function
  | "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--exec-path"
  | "--super-prefix" | "--config-env" ->
      true
  | _ -> false

let git_option_has_inline_arg opt =
  starts_with opt "--git-dir=" || starts_with opt "--work-tree="
  || starts_with opt "--namespace=" || starts_with opt "--exec-path="
  || starts_with opt "--super-prefix=" || starts_with opt "--config-env="
  || (String.length opt > 2 && (starts_with opt "-C" || starts_with opt "-c"))

let git_subcommand tokens =
  let rec loop = function
    | [] -> None
    | "--" :: _ -> None
    | opt :: _value :: rest when git_option_requires_arg opt -> loop rest
    | opt :: rest when git_option_has_inline_arg opt -> loop rest
    | opt :: rest when starts_with opt "-" -> loop rest
    | sub :: _ -> Some sub
  in
  loop tokens

let classify_for_parsing ~cmd ~_output =
  let tokens =
    String.trim cmd
    |> String.split_on_char ' '
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")
  in
  match tokens with
  | [] -> None
  | bin :: rest ->
      let base = Filename.basename bin |> String.lowercase_ascii in
      match base with
      | "git" ->
          let sub = git_subcommand rest in
          (match sub with
          | Some "status" -> Some Git_status
          | Some "log" -> Some Git_log_oneline
          | Some "diff" -> Some Git_diff_stat
          | _ -> None)
      | "wc" ->
          if List.exists (fun t -> t = "-l" || t = "--lines") rest then
            Some Wc_lines
          else None
      | "ls" ->
          if List.exists (fun t ->
            t = "-l" || t = "-la" || t = "-al" || t = "-lah" || t = "-lha"
          ) rest then
            Some Ls_long
          else None
      | "dune" ->
          if List.exists (fun t -> t = "runtest" || t = "test") rest then
            Some Dune_test
          else None
      | _ -> None

let parser_allows_nonzero = function
  | Dune_test -> true
  | Git_status | Git_log_oneline | Git_diff_stat | Wc_lines | Ls_long -> false

let try_parse ~cmd ~status ~output =
  match classify_for_parsing ~cmd ~_output:output with
  | None -> None
  | Some kind ->
      let may_parse =
        match status with
        | Unix.WEXITED 0 -> true
        | _ -> parser_allows_nonzero kind
      in
      if not may_parse then None
      else
        match kind with
        | Git_status -> parse_git_status_porcelain output
        | Git_log_oneline -> parse_git_log_oneline output
        | Git_diff_stat -> parse_git_diff_stat output
        | Wc_lines -> parse_wc_lines output
        | Ls_long -> parse_ls_long output
        | Dune_test -> parse_dune_test output
