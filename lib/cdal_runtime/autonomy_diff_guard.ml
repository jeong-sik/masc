(** Autonomy_diff_guard — pure unified-diff validation helper.

    @since 0.92.1 *)

type issue =
  | Empty_patch
  | Unsafe_path of string
  | Outside_allowed_paths of string
  | Banned_addition of
      { path : string option
      ; pattern : string
      ; line : string
      }

type report =
  { accepted : bool
  ; touched_paths : string list
  ; issues : issue list
  }

let default_banned_patterns =
  [ "ptrace"; "mount("; "umount("; "reboot("; "shutdown("; "mkfs"; "rm -rf /" ]
;;

(* Normalize a command-ish string for matching:
   - strip shell-style line comments (# to end of line) per line
   - drop quote / backslash characters that don't change semantics for the
     coarse substrings we care about
   - collapse runs of ASCII whitespace to single spaces
   - lowercase ASCII

   This is intentionally cheap; it is a bypass-resistance layer, not a full
   shell parser. The original line is still passed through to the issue
   record so reviewers can see the verbatim source. *)
let normalize_command s =
  let buf = Buffer.create (String.length s) in
  let in_comment = ref false in
  String.iter
    (fun c ->
       if !in_comment
       then (
         if c = '\n'
         then (
           in_comment := false;
           let len = Buffer.length buf in
           if len > 0 && Buffer.nth buf (len - 1) <> ' ' then Buffer.add_char buf ' '))
       else (
         match c with
         | '#' -> in_comment := true
         | '\'' | '"' | '`' | '\\' -> ()
         | ' ' | '\t' | '\n' | '\r' ->
           let len = Buffer.length buf in
           if len > 0 && Buffer.nth buf (len - 1) <> ' ' then Buffer.add_char buf ' '
         | _ -> Buffer.add_char buf (Char.lowercase_ascii c)))
    s;
  String.trim (Buffer.contents buf)
;;

let show_issue = function
  | Empty_patch -> "patch is empty or has no touched paths"
  | Unsafe_path path -> Printf.sprintf "unsafe patch path: %s" path
  | Outside_allowed_paths path ->
    Printf.sprintf "patch touches path outside allowlist: %s" path
  | Banned_addition { path; pattern; line } ->
    let where = Option.value ~default:"<unknown>" path in
    Printf.sprintf
      "banned addition in %s matched %S: %s"
      where
      pattern
      (Util.clip line 120)
;;

type allowed_spec =
  | Exact of string
  | Prefix of string

let normalize_path raw =
  let trimmed = String.trim raw in
  let stripped =
    if String.length trimmed >= 2
    then (
      let prefix = String.sub trimmed 0 2 in
      if prefix = "a/" || prefix = "b/"
      then String.sub trimmed 2 (String.length trimmed - 2)
      else trimmed)
    else trimmed
  in
  if stripped = "" || stripped = "/dev/null"
  then Error (Unsafe_path raw)
  else if String.get stripped 0 = '/'
  then Error (Unsafe_path raw)
  else (
    let segments = String.split_on_char '/' stripped in
    let rec loop acc = function
      | [] -> Ok (String.concat "/" (List.rev acc))
      | "" :: rest | "." :: rest -> loop acc rest
      | ".." :: _ -> Error (Unsafe_path raw)
      | seg :: rest -> loop (seg :: acc) rest
    in
    loop [] segments)
;;

let normalize_allowed_path raw =
  let trimmed = String.trim raw in
  let is_prefix =
    String.length trimmed > 0 && trimmed.[String.length trimmed - 1] = '/'
  in
  match normalize_path trimmed with
  | Ok path when is_prefix -> Ok (Prefix path)
  | Ok path -> Ok (Exact path)
  | Error issue -> Error issue
;;

let path_allowed specs path =
  List.exists
    (function
      | Exact allowed -> allowed = path
      | Prefix prefix ->
        let with_sep = prefix ^ "/" in
        path = prefix
        || (String.length path > String.length with_sep
            && String.sub path 0 (String.length with_sep) = with_sep))
    specs
;;

let parse_path_token line prefix_len =
  let remainder =
    String.sub line prefix_len (String.length line - prefix_len) |> String.trim
  in
  match String.split_on_char '\t' remainder with
  | token :: _ -> token
  | [] -> remainder
;;

let parse_diff_git_path line =
  let parts = String.split_on_char ' ' line in
  match parts with
  | "diff" :: "--git" :: old_path :: new_path :: _ ->
    let pick = if new_path <> "/dev/null" then new_path else old_path in
    normalize_path pick
  | _ -> Error (Unsafe_path line)
;;

let add_unique items value = if List.mem value items then items else items @ [ value ]

let validate_patch ~allowed_paths ?(banned_patterns = default_banned_patterns) patch =
  let allowed_specs, setup_issues =
    List.fold_left
      (fun (specs, issues) raw ->
         match normalize_allowed_path raw with
         | Ok spec -> spec :: specs, issues
         | Error issue -> specs, issue :: issues)
      ([], [])
      allowed_paths
  in
  let rec loop current_path touched issues = function
    | [] -> current_path, touched, issues
    | line :: rest when Util.contains_substring_ci ~haystack:line ~needle:"diff --git " ->
      let current_path, touched, issues =
        match parse_diff_git_path line with
        | Ok path -> Some path, add_unique touched path, issues
        | Error issue -> current_path, touched, issue :: issues
      in
      loop current_path touched issues rest
    | line :: rest when Util.string_contains ~needle:"+++ " line ->
      let token = parse_path_token line 4 in
      let current_path, touched, issues =
        if token = "/dev/null"
        then current_path, touched, issues
        else (
          match normalize_path token with
          | Ok path -> Some path, add_unique touched path, issues
          | Error issue -> current_path, touched, issue :: issues)
      in
      loop current_path touched issues rest
    | line :: rest when Util.string_contains ~needle:"--- " line ->
      let token = parse_path_token line 4 in
      let current_path, touched, issues =
        if token = "/dev/null"
        then current_path, touched, issues
        else (
          match normalize_path token with
          | Ok path when current_path = None -> Some path, add_unique touched path, issues
          | Ok _ -> current_path, touched, issues
          | Error issue -> current_path, touched, issue :: issues)
      in
      loop current_path touched issues rest
    | line :: rest
      when String.length line > 0
           && line.[0] = '+'
           && not (Util.string_contains ~needle:"+++ " line) ->
      (* Strip the leading '+' before normalization so comment-stripping
         and whitespace-collapsing operate on the actual added content. *)
      let added = String.sub line 1 (String.length line - 1) in
      let normalized_line = normalize_command added in
      let content_issues =
        List.filter_map
          (fun pattern ->
             let normalized_pattern = normalize_command pattern in
             if
               normalized_pattern <> ""
               && Util.contains_substring_ci
                    ~haystack:normalized_line
                    ~needle:normalized_pattern
             then Some (Banned_addition { path = current_path; pattern; line })
             else None)
          banned_patterns
      in
      loop current_path touched (List.rev_append content_issues issues) rest
    | _ :: rest -> loop current_path touched issues rest
  in
  let _, touched_paths, issues =
    loop None [] setup_issues (String.split_on_char '\n' patch)
  in
  let allowlist_issues =
    List.fold_left
      (fun acc path ->
         if path_allowed allowed_specs path
         then acc
         else Outside_allowed_paths path :: acc)
      []
      touched_paths
  in
  let issues = List.rev_append issues (List.rev allowlist_issues) in
  let issues =
    if String.trim patch = "" || touched_paths = [] then Empty_patch :: issues else issues
  in
  { accepted = issues = []; touched_paths; issues = List.rev issues }
;;

[@@@coverage off]
(* === Inline tests === *)

let sample_patch =
  String.concat
    "\n"
    [ "diff --git a/lib/foo.ml b/lib/foo.ml"
    ; "--- a/lib/foo.ml"
    ; "+++ b/lib/foo.ml"
    ; "@@"
    ; "+let answer = 42"
    ; ""
    ]
;;

let%test "validate_patch accepts allowlisted file" =
  let report = validate_patch ~allowed_paths:[ "lib/" ] sample_patch in
  report.accepted && report.touched_paths = [ "lib/foo.ml" ]
;;

let%test "validate_patch rejects outside allowlist" =
  let report = validate_patch ~allowed_paths:[ "test/" ] sample_patch in
  (not report.accepted)
  && List.exists
       (function
         | Outside_allowed_paths "lib/foo.ml" -> true
         | _ -> false)
       report.issues
;;

let%test "validate_patch rejects parent traversal" =
  let patch =
    String.concat
      "\n"
      [ "diff --git a/../secret.txt b/../secret.txt"
      ; "--- a/../secret.txt"
      ; "+++ b/../secret.txt"
      ; "@@"
      ; "+oops"
      ]
  in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  (not report.accepted)
  && List.exists
       (function
         | Unsafe_path _ -> true
         | _ -> false)
       report.issues
;;

let%test "validate_patch rejects banned addition" =
  let patch =
    String.concat
      "\n"
      [ "diff --git a/lib/foo.ml b/lib/foo.ml"
      ; "--- a/lib/foo.ml"
      ; "+++ b/lib/foo.ml"
      ; "@@"
      ; "+let _ = ptrace ()"
      ]
  in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  (not report.accepted)
  && List.exists
       (function
         | Banned_addition { pattern = "ptrace"; _ } -> true
         | _ -> false)
       report.issues
;;

let%test "validate_patch allows deletion when file is allowlisted" =
  let patch =
    String.concat
      "\n"
      [ "diff --git a/lib/foo.ml b/lib/foo.ml"
      ; "--- a/lib/foo.ml"
      ; "+++ /dev/null"
      ; "@@"
      ; "-let answer = 42"
      ]
  in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  report.accepted && report.touched_paths = [ "lib/foo.ml" ]
;;

let%test "validate_patch rejects empty patch" =
  let report = validate_patch ~allowed_paths:[ "lib/" ] "" in
  (not report.accepted)
  && List.exists
       (function
         | Empty_patch -> true
         | _ -> false)
       report.issues
;;

(* === Bypass-resistance tests (Tier C C-4) ===

   Each helper builds a minimal patch with [added_line] as the added
   content; we then assert whether the matcher catches a [rm -rf /]
   class addition. *)

let make_addition_patch added_line =
  String.concat
    "\n"
    [ "diff --git a/lib/foo.ml b/lib/foo.ml"
    ; "--- a/lib/foo.ml"
    ; "+++ b/lib/foo.ml"
    ; "@@"
    ; "+" ^ added_line
    ]
;;

let has_banned_rm_rf report =
  List.exists
    (function
      | Banned_addition { pattern = "rm -rf /"; _ } -> true
      | _ -> false)
    report.issues
;;

let%test "normalize catches double-whitespace bypass" =
  let patch = make_addition_patch "rm  -rf /" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize catches backslash-escape bypass" =
  let patch = make_addition_patch {|r\m -rf /|} in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize catches surrounding-whitespace bypass" =
  let patch = make_addition_patch "  rm   -rf  /  " in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize catches uppercase bypass" =
  let patch = make_addition_patch "RM -RF /" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize catches per-token quoting bypass" =
  let patch = make_addition_patch {|'rm' '-rf' '/'|} in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize catches pre-comment dangerous content" =
  (* semicolon-separated: dangerous part is BEFORE the comment, must match *)
  let patch = make_addition_patch "echo hello; rm -rf /" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  has_banned_rm_rf report
;;

let%test "normalize ignores content inside line comment" =
  (* the dangerous text is after [#] so it's a comment, not executed.
     Per audit, this must NOT trigger. *)
  let patch = make_addition_patch "echo hello # rm -rf /" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  not (has_banned_rm_rf report)
;;

let%test "normalize still flags mount(" =
  let patch = make_addition_patch "let _ = mount(something)" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  List.exists
    (function
      | Banned_addition { pattern = "mount("; _ } -> true
      | _ -> false)
    report.issues
;;

let%test "normalize keeps benign line accepted" =
  let patch = make_addition_patch "let answer = 42" in
  let report = validate_patch ~allowed_paths:[ "lib/" ] patch in
  report.accepted
;;
