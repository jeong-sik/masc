type scope =
  | Inside_worktree of string
  | Inside_sandbox of string
  | Outside_worktree of string
  | Absolute_unknown of string

type t = {
  raw : string;
  scope : scope;
}

(** Sandbox markers — absolute paths that should be classified as
    [Inside_sandbox] regardless of [cwd].  Bound to the keeper +
    macOS-temp conventions; widening this list weakens the gate so
    additions need explicit review. *)
let sandbox_prefixes =
  [
    "/tmp/masc-";
    "/tmp/masc_";
    "/private/tmp/masc-";
    "/private/tmp/masc_";
  ]

let contains_substring s sub =
  let sub_len = String.length sub in
  let s_len = String.length s in
  if sub_len > s_len then false
  else
    let rec scan i =
      if i + sub_len > s_len then false
      else if String.sub s i sub_len = sub then true
      else scan (i + 1)
    in
    scan 0

let starts_with_any prefixes s =
  List.exists (fun p -> String.starts_with ~prefix:p s) prefixes

let starts_with_sandbox abs =
  starts_with_any sandbox_prefixes abs
  || contains_substring abs "/.masc/"

(** Normalize [raw] against [cwd] using [Unix.realpath] on the parent
    directory, then re-attach the basename.  This resolves symlinks
    and [..]/[.] traversal in every component except the final one,
    which may not exist (e.g. write target).  An [_ -> None] catch-all
    keeps the classifier fail-closed: paths whose parent does not
    resolve land in [Absolute_unknown] and are denied by the policy
    gate. *)
let normalize_path ~cwd raw =
  let abs =
    if Filename.is_relative raw then Filename.concat cwd raw
    else raw
  in
  let parent = Filename.dirname abs in
  let basename = Filename.basename abs in
  try
    let parent_real = Unix.realpath parent in
    Some
      (if basename = "." || basename = "" then parent_real
       else Filename.concat parent_real basename)
  with _ -> None

let normalize_cwd cwd =
  try Unix.realpath cwd
  with _ -> cwd

let starts_with_dir ~prefix abs =
  abs = prefix || String.starts_with ~prefix:(prefix ^ "/") abs

let lexical_normalize_abs abs =
  let parts = String.split_on_char '/' abs in
  let stack = ref [] in
  List.iter
    (function
      | "" | "." -> ()
      | ".." ->
          (match !stack with
           | _ :: rest -> stack := rest
           | [] -> ())
      | part -> stack := part :: !stack)
    parts;
  "/" ^ String.concat "/" (List.rev !stack)

let lexical_abs ~cwd raw =
  let abs =
    if Filename.is_relative raw then Filename.concat cwd raw
    else raw
  in
  lexical_normalize_abs abs

let classify ~raw ~cwd =
  match normalize_path ~cwd raw with
  | None ->
      let abs = lexical_abs ~cwd raw in
      if starts_with_sandbox abs then
        { raw; scope = Inside_sandbox abs }
      else
        { raw; scope = Absolute_unknown raw }
  | Some abs ->
    if starts_with_sandbox abs then
      { raw; scope = Inside_sandbox abs }
    else
      let cwd_norm = normalize_cwd cwd in
      if starts_with_dir ~prefix:cwd_norm abs then
        { raw; scope = Inside_worktree abs }
      else
        { raw; scope = Outside_worktree abs }

let scope t = t.scope
let raw t = t.raw

let pp fmt t =
  let tag =
    match t.scope with
    | Inside_worktree _ -> "inside_worktree"
    | Inside_sandbox _ -> "inside_sandbox"
    | Outside_worktree _ -> "outside_worktree"
    | Absolute_unknown _ -> "absolute_unknown"
  in
  Format.fprintf fmt "%s:%s" tag t.raw
