(** See masc_tui_pr_ref.mli. *)

type t =
  | Pull_url of
      { slug : string
      ; number : int
      }
  | Pr_token of int

let number = function
  | Pull_url { number; _ } -> number
  | Pr_token number -> number

let github_host = "github.com/"

let is_digit c = c >= '0' && c <= '9'

let is_word_char c =
  is_digit c || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

(* Owner and repository names on GitHub: letters, digits, [-], [_], [.]. *)
let is_slug_char c = is_word_char c || c = '-' || c = '.'

(* The run of [ok] characters starting at [i]; [i] itself when there is
   none. *)
let run_end s ok i =
  let n = String.length s in
  let rec go j = if j < n && ok s.[j] then go (j + 1) else j in
  go i

(* A digit run that is a whole number: bounded on the right by a non-digit
   or the end, and small enough to be an [int]. *)
let number_at s i =
  let stop = run_end s is_digit i in
  if stop = i then None
  else int_of_string_opt (String.sub s i (stop - i))

let starts_at s i prefix =
  let n = String.length prefix in
  i + n <= String.length s && String.equal (String.sub s i n) prefix

(* [<owner>/<repo>/pull/<n>] starting right after [github.com/]. *)
let pull_url_at s i =
  let owner_end = run_end s is_slug_char i in
  if owner_end = i || not (starts_at s owner_end "/") then None
  else
    let repo_start = owner_end + 1 in
    let repo_end = run_end s is_slug_char repo_start in
    if repo_end = repo_start || not (starts_at s repo_end "/pull/") then None
    else
      let slug = String.sub s i (repo_end - i) in
      Option.map
        (fun number -> Pull_url { slug; number })
        (number_at s (repo_end + String.length "/pull/"))

(* [PR-<n>] as its own word: a token glued to letters before it is part of
   another identifier. *)
let pr_token_at s i =
  let bounded = i = 0 || not (is_word_char s.[i - 1]) in
  if bounded && (starts_at s i "PR-" || starts_at s i "pr-") then
    Option.map (fun number -> Pr_token number) (number_at s (i + 3))
  else None

let find s =
  let n = String.length s in
  let rec scan i =
    if i >= n then None
    else
      let found =
        if starts_at s i github_host then
          pull_url_at s (i + String.length github_host)
        else pr_token_at s i
      in
      match found with
      | Some _ as reference -> reference
      | None -> scan (i + 1)
  in
  scan 0

let strip_suffix ~suffix s =
  if String.ends_with ~suffix s then
    String.sub s 0 (String.length s - String.length suffix)
  else s

let github_slug_of_remote remote =
  let remote = String.trim remote in
  let path =
    let ssh = "git@github.com:" and https = "https://github.com/" in
    if String.starts_with ~prefix:ssh remote then
      Some (String.sub remote (String.length ssh) (String.length remote - String.length ssh))
    else if String.starts_with ~prefix:https remote then
      Some
        (String.sub remote (String.length https)
           (String.length remote - String.length https))
    else None
  in
  Option.bind path (fun path ->
      let slug = path |> strip_suffix ~suffix:"/" |> strip_suffix ~suffix:".git" in
      match String.split_on_char '/' slug with
      | [ owner; repo ] when owner <> "" && repo <> "" -> Some slug
      | _ :: _ | [] -> None)

let pull_url ~slug ~number = Printf.sprintf "https://%s%s/pull/%d" github_host slug number

let github_pr_url ~remote ~number =
  Option.map (fun slug -> pull_url ~slug ~number) (github_slug_of_remote remote)
