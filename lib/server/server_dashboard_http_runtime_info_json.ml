(** Option → JSON small builders + git_upstream_status record + 2
    small utility helpers for the dashboard runtime-info surface.

    Four 3-line option-to-Yojson coercers + the
    [git_upstream_status] record that captures git branch / upstream
    / ahead-behind state for a worktree, plus its empty default,
    plus 2 utility helpers shared by the rest of [Server_dashboard_
    http_runtime_info]:
      with swapped argument order.
    - [take n xs] — first n elements of a list (tolerant of short
      input).
    - [String_util.trim_nonempty raw] — empty-after-trim string -> None.

    Pure builders + value records. Verbatim extract from
    [Server_dashboard_http_runtime_info]; the parent retains
    transparent record alias + 8 value aliases. *)


let take = List.take

;;

let opt_string_json = Json_util.string_opt_to_json


let is_hex_commit value =
  let length = String.length value in
  length >= 7
  && length <= 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
         | _ -> false)
       value
;;

let is_full_hex_commit value =
  let length = String.length value in
  (length = 40 || length = 64) && is_hex_commit value
;;

let commit_equal left right =
  if String.equal left right
  then true
  else if not (is_hex_commit left && is_hex_commit right)
  then false
  else (
    let left = String.lowercase_ascii left in
    let right = String.lowercase_ascii right in
    let short, long =
      if String.length left <= String.length right then left, right else right, left
    in
    is_full_hex_commit long && String.starts_with ~prefix:short long)
;;

let opt_commit_equal left right =
  match left, right with
  | Some left, Some right -> Some (commit_equal left right)
  | _ -> None

let opt_int_json = Json_util.int_opt_to_json

type git_upstream_status =
  { branch : string option
  ; upstream_ref : string option
  ; upstream_head_commit : string option
  ; ahead_count : int option
  ; behind_count : int option
  }

let empty_git_upstream_status =
  { branch = None
  ; upstream_ref = None
  ; upstream_head_commit = None
  ; ahead_count = None
  ; behind_count = None
  }
;;
