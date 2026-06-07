(** Path-argument descriptors used by [Exec_policy.validate_shell_ir_paths].

    Extracted from [Exec_policy] under the Shell IR Adjacent Surfaces
    Plan §P11. The descriptors here encode *typed* knowledge of which
    argv tokens of a recognized command shape are paths — the
    descriptor is consulted *before* the [looks_like_path_token]
    heuristic, so path validation routes through structural metadata
    first and only falls back to look-alike inference when no
    descriptor matches.

    Three descriptor surfaces:

    1. [is_path_flag] / [path_flag_requires_existing_dir] — separated
       flag/value form (e.g. [-C /tmp], [--git-dir /repo/.git]).
    2. [path_value_of_flagged_token] / [inline_path_flag_requires_existing_dir]
       — inline flag=value form (e.g. [--git-dir=/repo/.git]).
    3. [command_materializes_path_arg] — closed set of commands whose
       positional argv entries are paths (e.g. [ls], [cat], [rg]).

    [git] and [gh] are *intentionally* absent from
    [command_materializes_path_arg]: their positional args are
    revisions/refs/issue-numbers, not paths. They stay in Shell IR and are
    classified by typed executable/risk surfaces instead of path heuristics. *)

let is_path_flag token =
  match token with
  | "-C" | "--git-dir" | "--work-tree" | "--exec-path" -> true
  | _ -> false
;;

let path_flag_requires_existing_dir token =
  match token with
  | "-C" | "--work-tree" -> true
  | _ -> false
;;

let path_value_of_flagged_token token =
  let prefixes = [ "--git-dir="; "--work-tree="; "--exec-path=" ] in
  List.find_map
    (fun prefix ->
       if String.starts_with ~prefix token
       then
         Some
           (String.sub
              token
              (String.length prefix)
              (String.length token - String.length prefix))
       else None)
    prefixes
;;

let inline_path_flag_requires_existing_dir token =
  String.starts_with ~prefix:"--work-tree=" token
;;

let command_materializes_path_arg = function
  | "cat" | "find" | "grep" | "head" | "ls" | "nl" | "rg" | "sed" | "stat"
  | "tail" | "tree" | "wc" -> true
  | _ -> false
;;

(** [path_arg_command_corpus] is the documented set of commands whose
    positional argv tokens are recognized as paths by
    [command_materializes_path_arg]. Exposed for tests that assert the
    descriptor stays the SSOT — adding a command to the corpus without
    also adding it to [command_materializes_path_arg] (or vice versa)
    fails the assertion. *)
let path_arg_command_corpus =
  [ "cat"; "find"; "grep"; "head"; "ls"; "nl"; "rg"; "sed"; "stat"; "tail"
  ; "tree"; "wc" ]
;;
