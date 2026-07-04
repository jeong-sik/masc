(* P10: Structured Output Extraction
   Pure-function parsers that turn raw command output into machine-readable
   JSON.  No side effects, no I/O.  Each parser returns [Some json] on a
   confident match or [None] to decline (fail-open). *)

(* --- module-level regexes for git diff --stat --- *)

let files_changed_re = Re.Pcre.re {|\b(\d+) file|} |> Re.compile
let insertions_re = Re.Pcre.re {|\b(\d+) insertion|} |> Re.compile
let deletions_re = Re.Pcre.re {|\b(\d+) deletion|} |> Re.compile

(* --- pytest summary counters: prefix set is closed (passed/failed/error/
   skipped), so build the four DFAs once at module init instead of per line.
   Using exec_opt means the prior execp+exec double-compile is also gone. *)
let pytest_passed_re = Re.Pcre.re {|(\d+) passed|} |> Re.compile
let pytest_failed_re = Re.Pcre.re {|(\d+) failed|} |> Re.compile
let pytest_error_re = Re.Pcre.re {|(\d+) error|} |> Re.compile
let pytest_skipped_re = Re.Pcre.re {|(\d+) skipped|} |> Re.compile

(* --- cargo test result line counters --- *)
let cargo_passed_re = Re.Pcre.re {|(\d+) passed|} |> Re.compile
let cargo_failed_re = Re.Pcre.re {|(\d+) failed|} |> Re.compile

(* --- git status --porcelain --- *)

type git_status_porcelain_summary = {
  changed_files : int;
  staged_files : int;
  unstaged_files : int;
  untracked_files : int;
  conflicted_files : int;
  staged_paths : string list;
  unstaged_paths : string list;
  untracked_paths : string list;
  conflicted_paths : string list;
}

let empty_git_status_porcelain_summary =
  {
    changed_files = 0;
    staged_files = 0;
    unstaged_files = 0;
    untracked_files = 0;
    conflicted_files = 0;
    staged_paths = [];
    unstaged_paths = [];
    untracked_paths = [];
    conflicted_paths = [];
  }

let git_porcelain_conflict x y =
  match (x, y) with
  | 'D', 'D'
  | 'A', 'U'
  | 'U', 'D'
  | 'U', 'A'
  | 'D', 'U'
  | 'A', 'A'
  | 'U', 'U' -> true
  | _ -> false

let git_porcelain_status_char = function
  | ' ' | 'M' | 'A' | 'D' | 'R' | 'C' | 'T' | 'U' | '?' | '!' -> true
  | _ -> false

let update_git_status_summary summary line =
  if String.length line < 3 then
    Error "git status --porcelain=v1 returned a malformed status row"
  else
    let x = String.get line 0 in
    let y = String.get line 1 in
    if
      (not (git_porcelain_status_char x)) || not (git_porcelain_status_char y)
    then
      Error
        (Printf.sprintf
           "git status --porcelain=v1 returned unknown status row %S" line)
    else
      let path = String.trim (String.sub line 2 (String.length line - 2)) in
      if path = "" then
        Error "git status --porcelain=v1 returned a status row without a path"
      else
        let is_untracked = Char.equal x '?' && Char.equal y '?' in
        let is_ignored = Char.equal x '!' && Char.equal y '!' in
        if is_ignored then Ok summary
        else
          let conflicted = git_porcelain_conflict x y in
          if
            ((Char.equal x '?' || Char.equal y '?') && not is_untracked)
            || ((Char.equal x '!' || Char.equal y '!') && not is_ignored)
            || ((Char.equal x 'U' || Char.equal y 'U') && not conflicted)
          then
            Error
              (Printf.sprintf
                 "git status --porcelain=v1 returned unknown status row %S" line)
          else
            let staged =
              (not conflicted) && (not is_untracked) && not (Char.equal x ' ')
            in
            let unstaged =
              (not conflicted) && (not is_untracked) && not (Char.equal y ' ')
            in
            Ok
              {
                changed_files = summary.changed_files + 1;
                staged_files =
                  summary.staged_files + if staged then 1 else 0;
                unstaged_files =
                  summary.unstaged_files + if unstaged then 1 else 0;
                untracked_files =
                  summary.untracked_files + if is_untracked then 1 else 0;
                conflicted_files =
                  summary.conflicted_files + if conflicted then 1 else 0;
                staged_paths =
                  if staged then path :: summary.staged_paths
                  else summary.staged_paths;
                unstaged_paths =
                  if unstaged then path :: summary.unstaged_paths
                  else summary.unstaged_paths;
                untracked_paths =
                  if is_untracked then path :: summary.untracked_paths
                  else summary.untracked_paths;
                conflicted_paths =
                  if conflicted then path :: summary.conflicted_paths
                  else summary.conflicted_paths;
              }

let finalize_git_status_summary summary =
  {
    summary with
    staged_paths = List.rev summary.staged_paths;
    unstaged_paths = List.rev summary.unstaged_paths;
    untracked_paths = List.rev summary.untracked_paths;
    conflicted_paths = List.rev summary.conflicted_paths;
  }

let summarize_git_status_porcelain output =
  let lines =
    String.split_on_char '\n' output
    |> List.filter (fun line -> String.trim line <> "")
  in
  let ( let* ) = Result.bind in
  let* summary =
    List.fold_left
      (fun acc line ->
        let* summary = acc in
        update_git_status_summary summary line)
      (Ok empty_git_status_porcelain_summary) lines
  in
  Ok (finalize_git_status_summary summary)

let git_status_paths_json paths =
  `List (List.map (fun p -> `String p) paths)

let parse_git_status_porcelain output =
  match summarize_git_status_porcelain output with
  | Error _ -> None
  | Ok
      {
        staged_files;
        unstaged_files;
        untracked_files;
        conflicted_files;
        staged_paths;
        unstaged_paths;
        untracked_paths;
        conflicted_paths;
        _;
      } ->
      if staged_files + unstaged_files + untracked_files + conflicted_files = 0
      then None
      else
        Some
          (`Assoc
             [
               ("staged", git_status_paths_json staged_paths);
               ("unstaged", git_status_paths_json unstaged_paths);
               ("untracked", git_status_paths_json untracked_paths);
               ("conflicted", git_status_paths_json conflicted_paths);
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
            | Some g ->
                (match int_of_string_opt (Re.Group.get g 1) with
                 | Some n -> n
                 | None -> 0)
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
            (match int_of_string_opt n_str with
             | Some n -> Some (`Assoc [ ("lines", `Int n) ])
             | None -> None)

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
                  (match int_of_string_opt size_str with
                   | Some size ->
                       entries :=
                         `Assoc
                           [ ("perms", `String perms); ("size", `Int size)
                           ; ("name", `String name) ]
                         :: !entries
                   | None -> ())
              | _ -> ()))
      lines;
    let n = List.length !entries in
    if n = 0 then None
    else Some (`Assoc [ ("entries", `List (List.rev !entries)); ("count", `Int n) ])

(* --- dune test output --- *)

(** Classification of dune runtest output lines.
    Replaces ad-hoc [String.starts_with] prefix matching with a typed
    variant so the compiler enforces exhaustive handling. *)
type dune_line =
  | Dune_test_line
      (** A "test ..." line with a recognized path prefix (src/ or test/). *)
  | Dune_error_line  (** An "error:..." line indicating test failure. *)
  | Dune_indent_line  (** An indented line (ignored in counting). *)
  | Dune_other  (** Any other line (ignored in counting). *)

let classify_dune_line (l : string) : dune_line =
  let len = String.length l in
  if len >= 5 && String.sub l 0 5 = "test " then
    let rest = String.trim (String.sub l 5 (len - 5)) in
    let rest_len = String.length rest in
    if rest_len >= 4 && String.sub rest 0 4 = "src/"
    then Dune_test_line
    else if rest_len >= 5 && String.sub rest 0 5 = "test/"
    then Dune_test_line
    else Dune_other
  else if len >= 2 && l.[0] = ' ' && l.[1] = ' '
  then Dune_indent_line
  else if len >= 6 && String.sub l 0 6 = "error:"
  then Dune_error_line
  else Dune_other
;;

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
      match classify_dune_line l with
      | Dune_test_line ->
        let len = String.length l in
        if len >= 3 && String.sub l (len - 2) 2 = "ok" then incr passed
        else if String.length trimmed > 5 then begin
          (* look for FAILED or ERROR in the line *)
          if String_util.contains_substring l "failed" then incr failed
          else if String_util.contains_substring l "error" then incr failed
        end
      | Dune_error_line -> incr failed
      | Dune_indent_line | Dune_other -> ())
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

(* --- Repo-hosting PR list (tabular) --- *)

let parse_repo_hosting_pr_list output =
  let lines = String.split_on_char '\n' (String.trim output) in
  match lines with
  | [] -> None
  | header :: body ->
      let cols =
        let h = String.trim header in
        if String.length h = 0 then [||]
        else Array.of_list (String.split_on_char '\t' h)
      in
      if Array.length cols < 2 then None
      else
        let prs = ref [] in
        List.iter
          (fun line ->
            let fields = String.split_on_char '\t' (String.trim line) in
            match fields with
            | [] -> ()
            | number :: rest ->
                let n = String.trim number in
                if n <> "" && String.for_all (fun c -> c >= '0' && c <= '9') n then
                  let title =
                    match rest with [] -> "" | t :: _ -> String.trim t
                  in
                  let state =
                    let state_idx = Array.length cols - 1 in
                    match List.nth_opt rest (state_idx - 1) with
                    | Some s -> String.trim s
                    | None -> ""
                  in
                  prs := `Assoc [
                    ("number", `String n);
                    ("title", `String title);
                    ("state", `String state);
                  ] :: !prs)
          body;
        let n = List.length !prs in
        if n = 0 then None
        else Some (`Assoc [("prs", `List (List.rev !prs)); ("count", `Int n)])

(* --- pytest output --- *)

let parse_pytest output =
  let lines = String.split_on_char '\n' (String.trim output) in
  let passed = ref 0 and failed = ref 0
  and errors = ref 0 and skipped = ref 0 in
  List.iter
    (fun line ->
      let l = String.trim line in
      if String.length l < 5 then ()
      else
        (* Summary line: "X passed, Y failed, Z errors, W skipped" *)
        let extract_count re slot =
          match Re.exec_opt re l with
          | None -> ()
          | Some m ->
              (match int_of_string_opt (Re.Group.get m 1) with
               | Some n -> slot := n
               | None -> ())
        in
        if String_util.contains_substring l "passed"
           || String_util.contains_substring l "failed"
           || String_util.contains_substring l "error"
        then begin
          extract_count pytest_passed_re passed;
          extract_count pytest_failed_re failed;
          extract_count pytest_error_re errors;
          extract_count pytest_skipped_re skipped
        end)
    lines;
  let total = !passed + !failed + !errors + !skipped in
  if total = 0 then None
  else Some (`Assoc [
    ("passed", `Int !passed);
    ("failed", `Int !failed);
    ("errors", `Int !errors);
    ("skipped", `Int !skipped);
  ])

(* --- cargo test output --- *)

let parse_cargo_test output =
  let lines = String.split_on_char '\n' (String.trim output) in
  let passed = ref 0 and failed = ref 0 in
  List.iter
    (fun line ->
      let l = String.trim line in
      if String_util.contains_substring l "test result:" then begin
        (* "test result: ok. X passed; 0 failed; ..." *)
        let extract re =
          match Re.exec_opt re l with
          | None -> 0
          | Some m ->
              match int_of_string_opt (Re.Group.get m 1) with
              | Some n -> n
              | None -> 0
        in
        passed := !passed + extract cargo_passed_re;
        failed := !failed + extract cargo_failed_re
      end)
    lines;
  let total = !passed + !failed in
  if total = 0 then None
  else Some (`Assoc [
    ("passed", `Int !passed);
    ("failed", `Int !failed);
  ])

(* --- UTF-8 boundary helper --- *)

(** Length of the UTF-8 character whose leading byte is at position [i]. *)
let utf8_char_len s i =
  let b = Char.code s.[i] in
  if b land 0x80 = 0 then 1
  else if b land 0xE0 = 0xC0 then 2
  else if b land 0xF0 = 0xE0 then 3
  else 4

(** Find the start offset of the last complete UTF-8 character
    that begins at or before byte position [pos] in [s].
    UTF-8 continuation bytes have the pattern 10xxxxxx (0x80..0xBF).
    A leading byte never matches that pattern, so we walk backwards
    until we find one.  Returns [pos] if [pos] is already at a
    character boundary. *)
let utf8_find_char_start s pos =
  let rec loop i =
    if i <= 0 then 0
    else if Char.code s.[i] land 0xC0 <> 0x80 then i
    else loop (i - 1)
  in
  loop (min pos (String.length s - 1))

(** Truncate string [s] to at most [max_bytes], breaking only at
    UTF-8 character boundaries.  Returns the safe prefix. *)
let utf8_truncate s max_bytes =
  let len = String.length s in
  if len <= max_bytes then s
  else
    let boundary = utf8_find_char_start s (max_bytes - 1) in
    let char_end = boundary + utf8_char_len s boundary in
    if char_end <= max_bytes then String.sub s 0 char_end
    else String.sub s 0 boundary

(* --- dispatcher --- *)

type parser_kind =
  | Git_status
  | Git_log_oneline
  | Git_diff_stat
  | Wc_lines
  | Ls_long
  | Dune_test
  | Repo_hosting_pr_list
  | Pytest
  | Cargo_test

let git_option_requires_arg = function
  | "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--exec-path"
  | "--super-prefix" | "--config-env" ->
      true
  | _ -> false

(** Git global options that take an inline value (e.g. [--git-dir=PATH]).
    Replaces ad-hoc [String.starts_with] prefix matching with a list-driven
    check over the known option set. *)
let git_option_inline_prefixes =
  [ "--git-dir="
  ; "--work-tree="
  ; "--namespace="
  ; "--exec-path="
  ; "--super-prefix="
  ; "--config-env="
  ]
;;

let git_option_has_inline_arg opt =
  List.exists (fun prefix -> String.starts_with ~prefix opt) git_option_inline_prefixes
  || (String.length opt > 2
      && (let c = opt.[1] in
          c = 'C' || c = 'c')
      && opt.[0] = '-')

let git_subcommand tokens =
  let rec loop = function
    | [] -> None
    | "--" :: _ -> None
    | opt :: _value :: rest when git_option_requires_arg opt -> loop rest
    | opt :: rest when git_option_has_inline_arg opt -> loop rest
    | opt :: rest when String.starts_with ~prefix:"-" opt -> loop rest
    | sub :: _ -> Some sub
  in
  loop tokens

let command_words_for_parsing cmd =
  match Masc_exec_shell_words.Shell_words.stages cmd with
  | Ok [ words ] ->
      words
      |> List.map (fun (word : Masc_exec_shell_words.Shell_words.word) -> word.value)
      |> List.filter (fun s -> s <> "")
  | Ok [] | Ok (_ :: _ :: _) | Error _ -> []

let classify_for_parsing ~cmd ~_output =
  let tokens = command_words_for_parsing cmd in
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
      | "gh" ->
          (match rest with
           | "pr" :: rest' ->
               if List.exists (fun t -> t = "list") rest' then
                 Some Repo_hosting_pr_list
               else None
           | _ -> None)
      | "pytest" | "py.test" ->
          Some Pytest
      | "python" | "python3" ->
          if List.exists (fun t -> t = "pytest") rest then
            Some Pytest
          else None
      | "cargo" ->
          if List.exists (fun t -> t = "test") rest then
            Some Cargo_test
          else None
      | _ -> None

let parser_allows_nonzero = function
  | Dune_test | Pytest | Cargo_test -> true
  | Git_status | Git_log_oneline | Git_diff_stat | Wc_lines
  | Ls_long | Repo_hosting_pr_list -> false

let try_parse ~cmd ~status ~output =
  match classify_for_parsing ~cmd ~_output:output with
  | None -> None
  | Some kind ->
      let may_parse =
        match status with
        | Unix.WEXITED 0 -> true
        | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
            parser_allows_nonzero kind
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
        | Repo_hosting_pr_list -> parse_repo_hosting_pr_list output
        | Pytest -> parse_pytest output
        | Cargo_test -> parse_cargo_test output
