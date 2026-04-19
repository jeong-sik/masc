(** Keeper_tool_alias — see .mli for contract.

    The mapping below is the single source of truth for LLM-facing tool
    surface naming. Reviewers: any change here must keep [to_public]
    total (every internal name has a defined behavior) and
    [to_internal] partial (only Anthropic-Code cognates resolve). *)

(* (public_name, internal_name).
   Keep alphabetical by public name to make diffs reviewable. *)
let aliases : (string * string) list =
  [
    "Bash", "keeper_bash";
    "Edit", "keeper_fs_edit";
    "Grep", "keeper_shell";   (* op=rg routed at dispatch layer, Phase A.2 *)
    "Read", "keeper_fs_read";
    "Write", "keeper_fs_edit"; (* create-vs-update collapsed at dispatch layer *)
  ]

(* Anthropic Code surface names without a keeper cognate. The disclosure
   check should not nuke a turn solely because these appeared — instead a
   teaching tool_result tells the LLM what surface to use. RFC-0006 §3.1. *)
let hallucinated_builtins =
  [ "Agent"; "Skill"; "WebSearch"; "WebFetch"; "TodoWrite"; "NotebookEdit" ]

let public_to_internal_tbl =
  let t = Hashtbl.create (List.length aliases) in
  List.iter (fun (pub, internal) -> Hashtbl.replace t pub internal) aliases;
  t

let internal_to_public_tbl =
  (* When two public names share an internal target (Edit/Write -> keeper_fs_edit)
     the first occurrence wins so [to_public] is stable. *)
  let t = Hashtbl.create (List.length aliases) in
  List.iter
    (fun (pub, internal) ->
      if not (Hashtbl.mem t internal) then Hashtbl.replace t internal pub)
    aliases;
  t

let to_internal name = Hashtbl.find_opt public_to_internal_tbl name

let to_public internal =
  match Hashtbl.find_opt internal_to_public_tbl internal with
  | Some public -> public
  | None -> internal

let canonicalize_observed names =
  List.map (fun n -> match to_internal n with Some i -> i | None -> n) names

let hallucinated_set =
  let t = Hashtbl.create (List.length hallucinated_builtins) in
  List.iter (fun n -> Hashtbl.replace t n ()) hallucinated_builtins;
  t

let is_hallucinated_builtin name = Hashtbl.mem hallucinated_set name

let all_aliases () = aliases
