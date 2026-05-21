(** Option → JSON small builders + git_upstream_status record + 3
    small utility helpers for the dashboard runtime-info surface.

    Four 3-line option-to-Yojson coercers + the
    [git_upstream_status] record that captures git branch / upstream
    / ahead-behind state for a worktree, plus its empty default,
    plus 3 utility helpers shared by the rest of [Server_dashboard_
    http_runtime_info]:
    - [contains_substring ~needle haystack] — String_util wrapper
      with swapped argument order.
    - [take n xs] — first n elements of a list (tolerant of short
      input).
    - [trim_to_option raw] — empty-after-trim string -> None.

    Pure builders + value records. Verbatim extract from
    [Server_dashboard_http_runtime_info]; the parent retains
    transparent record alias + 8 value aliases. *)

let contains_substring ~needle haystack = String_util.contains_substring haystack needle

let take n xs =
  let rec loop acc remaining xs =
    if remaining <= 0
    then List.rev acc
    else (
      match xs with
      | [] -> List.rev acc
      | x :: tl -> loop (x :: acc) (remaining - 1) tl)
  in
  loop [] n xs
;;

let trim_to_option raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None else Some trimmed
;;

let opt_string_json = function
  | None -> `Null
  | Some value -> `String value
;;

let opt_bool_json = function
  | None -> `Null
  | Some value -> `Bool value
;;

let opt_commit_equal left right =
  match left, right with
  | Some left, Some right -> Some (String.equal left right)
  | _ -> None
;;

let opt_int_json = function
  | None -> `Null
  | Some value -> `Int value
;;

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
