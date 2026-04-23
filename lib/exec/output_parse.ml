(* P10: Structured Output Extraction
   Pure-function parsers that turn raw command output into machine-readable
   JSON.  No side effects, no I/O.  Each parser returns [Some json] on a
   confident match or [None] to decline (fail-open). *)

(* --- helpers --- *)

let split_lines s =
  let len = String.length s in
  if len = 0 then []
  else
    let buf = Buffer.create 64 in
    let lines = ref [] in
    String.iter
      (fun ch ->
        if ch = '\n' then (
          lines := Buffer.contents buf :: !lines;
          Buffer.clear buf)
        else Buffer.add_char buf ch)
      s;
    let last = Buffer.contents buf in
    if last <> "" then lines := last :: !lines;
    List.rev !lines

let trim s =
  let len = String.length s in
  let start = ref 0 in
  while !start < len && (s.[!start] = ' ' || s.[!start] = '\t') do
    incr start
  done;
  let stop = ref (len - 1) in
  while !stop >= !start && (s.[!stop] = ' ' || s.[!stop] = '\t') do
    decr stop
  done;
  String.sub s !start (!stop - !start + 1)

let starts_with s prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let contains_substring s sub =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len = 0 then true
  else if sub_len > s_len then false
  else
    let found = ref false in
    for i = 0 to s_len - sub_len do
      if not !found
         && String.sub s i sub_len = sub
      then found := true
    done;
    !found

(* --- git status --porcelain --- *)

let parse_git_status_porcelean output =
  let lines = split_lines (trim output) in
  if lines = [] then None
  else
    let staged = ref [] and unstaged = ref [] and untracked = ref [] in
    List.iter
      (fun line ->
        if String.length line < 2 then ()
        else
          let xy = String.sub line 0 2 in
          let path = trim (String.sub line 2 (String.length line - 2)) in
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
  let lines = split_lines (trim output) in
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
            let msg = trim (String.sub line (sp + 1) (len - sp - 1)) in
            commits := `Assoc [ ("hash", `String hash); ("message", `String msg) ]
                       :: !commits)
      lines;
    let n = List.length !commits in
    if n = 0 then None
    else Some (`Assoc [ ("commits", `List (List.rev !commits)); ("count", `Int n) ])

(* --- git diff --stat --- *)

let parse_git_diff_stat output =
  let lines = split_lines (trim output) in
  if lines = [] then None
  else
    (* last line: " N files changed, M insertions(+), D deletions(-)" *)
    let last = List.hd (List.rev lines) in
    let lower = String.lowercase_ascii last in
    if not (starts_with (trim lower) "file" || starts_with (trim lower) "files") then
      None
    else
      let files_changed = ref 0 and insertions = ref 0 and deletions = ref 0 in
      (* parse "N file(s) changed" *)
      (try
         let re = Str.regexp {|\([0-9]+\) file|} in
         if Str.string_match re (trim last) 0 then
           files_changed := int_of_string (Str.matched_group 1 (trim last))
       with _ -> ());
      (* parse "M insertion(s)(+)" *)
      (try
         let re = Str.regexp {|\([0-9]+\) insertion|} in
         if Str.string_match re (trim last) 0 then
           insertions := int_of_string (Str.matched_group 1 (trim last))
       with _ -> ());
      (* parse "D deletion(s)(-)" *)
      (try
         let re = Str.regexp {|\([0-9]+\) deletion|} in
         if Str.string_match re (trim last) 0 then
           deletions := int_of_string (Str.matched_group 1 (trim last))
       with _ -> ());
      Some
        (`Assoc
           [
             ("files_changed", `Int !files_changed);
             ("insertions", `Int !insertions);
             ("deletions", `Int !deletions);
           ])

(* --- wc -l --- *)

let parse_wc_lines output =
  let line = trim output in
  if line = "" then None
  else
    (* format: "    1234 filename" or just "1234" *)
    let tokens = split_lines line in
    match tokens with
    | [] -> None
    | first :: _ ->
        let words =
          let parts = ref [] in
          let buf = Buffer.create 16 in
          String.iter
            (fun ch ->
              if ch = ' ' || ch = '\t' then (
                if Buffer.length buf > 0 then (
                  parts := Buffer.contents buf :: !parts;
                  Buffer.clear buf))
              else Buffer.add_char buf ch)
            first;
          let last = Buffer.contents buf in
          if last <> "" then parts := last :: !parts;
          List.rev !parts
        in
        match words with
        | [] -> None
        | n_str :: _ ->
            (try Some (`Assoc [ ("lines", `Int (int_of_string n_str)) ])
             with _ -> None)

(* --- ls -la --- *)

let parse_ls_long output =
  let lines = split_lines (trim output) in
  if lines = [] then None
  else
    let entries = ref [] in
    List.iter
      (fun line ->
        let line = trim line in
        (* skip "total N" line *)
        if starts_with line "total" then ()
        else
          (* format: "drwxr-xr-x  2 user group  4096 Jan 1 12:00 dirname" *)
          let len = String.length line in
          if len < 10 then ()
          else
            let perms = String.sub line 0 10 in
            (* skip if perms doesn't look like drwx... or -rw... *)
            if perms.[0] <> 'd' && perms.[0] <> '-' && perms.[0] <> 'l' then ()
            else
              let rest = trim (String.sub line 10 (len - 10)) in
              let parts = ref [] in
              let buf = Buffer.create 32 in
              String.iter
                (fun ch ->
                  if ch = ' ' || ch = '\t' then (
                    if Buffer.length buf > 0 then (
                      parts := Buffer.contents buf :: !parts;
                      Buffer.clear buf))
                  else Buffer.add_char buf ch)
                rest;
              let last = Buffer.contents buf in
              if last <> "" then parts := last :: !parts;
              let parts = List.rev !parts in
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
  let lower = String.lowercase_ascii output in
  (* dune runtest outputs like:
     "Test src/...: ok" or "...FAILED..."
     Summary line may not exist, so count individual results. *)
  let lines = split_lines (trim output) in
  let passed = ref 0 and failed = ref 0 and skipped = ref 0 in
  List.iter
    (fun line ->
      let trimmed = trim line in
      let l = String.lowercase_ascii trimmed in
      if starts_with l "test " && (starts_with (trim (String.sub l 5 (String.length l - 5))) "src/"
                                   || starts_with (trim (String.sub l 5 (String.length l - 5))) "test/") then
        if starts_with l "test " then
          (* check for ok/failed at end *)
          let len = String.length l in
          if len >= 3 && String.sub l (len - 2) 2 = "ok" then incr passed
          else if starts_with l "test " && String.length trimmed > 5 then begin
            (* look for FAILED or ERROR in the line *)
            if contains_substring l "failed" then incr failed
            else if contains_substring l "error" then incr failed
          end
      else if starts_with l "  " then ()
      else if starts_with l "error:" then incr failed
      else ()
    )
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

let classify_for_parsing ~cmd ~output =
  let tokens =
    let parts = ref [] in
    let buf = Buffer.create 32 in
    String.iter
      (fun ch ->
        if ch = ' ' || ch = '\t' then (
          if Buffer.length buf > 0 then (
            parts := Buffer.contents buf :: !parts;
            Buffer.clear buf))
        else Buffer.add_char buf ch)
      (trim cmd);
    let last = Buffer.contents buf in
    if last <> "" then parts := last :: !parts;
    List.rev !parts
  in
  match tokens with
  | [] -> None
  | bin :: rest ->
      let base = Filename.basename bin |> String.lowercase_ascii in
      match base with
      | "git" ->
          let sub = match rest with _first :: s :: _ -> Some s | _ -> None in
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
          if List.exists (fun t -> t = "-l" || t = "-la" || t = "-al" || t = "-lah" || t = "-lha") rest then
            Some Ls_long
          else None
      | "dune" ->
          if List.exists (fun t -> t = "runtest" || t = "test") rest then
            Some Dune_test
          else None
      | _ -> None

let try_parse ~cmd ~output =
  match classify_for_parsing ~cmd ~output with
  | None -> None
  | Some Git_status -> parse_git_status_porcelean output
  | Some Git_log_oneline -> parse_git_log_oneline output
  | Some Git_diff_stat -> parse_git_diff_stat output
  | Some Wc_lines -> parse_wc_lines output
  | Some Ls_long -> parse_ls_long output
  | Some Dune_test -> parse_dune_test output
