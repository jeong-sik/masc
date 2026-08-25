(** Keeper_name_codec — the keeper<->agent name spellings, in one place.

    This lives in [masc_core] so both the keeper layer and the workspace
    layer reach the same codec: before it existed, [Keeper_identity]
    (lib/keeper) held the canonical four-affix parse and
    [Workspace_task_receipts] (lib/workspace, which cannot depend on
    lib/keeper) carried a one-affix degraded copy that silently missed the
    underscore spellings (RFC-0371 B12).

    Keep this module dependency-light: [Safe_identifier] only. A heavier
    dependency added here is inherited by every caller, and the copies
    come back. *)

let parse_affixed ~prefix ~suffix agent_name =
  let plen = String.length prefix and slen = String.length suffix in
  let alen = String.length agent_name in
  if alen > plen + slen
     && String.sub agent_name 0 plen = prefix
     && String.sub agent_name (alen - slen) slen = suffix
  then (
    let keeper_name = String.sub agent_name plen (alen - plen - slen) in
    if Safe_identifier.is_portable_name keeper_name then Some keeper_name else None)
  else None
;;

(* The four accepted spellings of a runtime keeper-agent identity.
   Enumerated once, so adding a spelling reaches every consumer. *)
let keeper_agent_affixes =
  [ "keeper-", "-agent"; "keeper_", "_agent"; "keeper-", "_agent"; "keeper_", "-agent" ]
;;

let keeper_name_of_agent_alias agent_name =
  List.find_map
    (fun (prefix, suffix) -> parse_affixed ~prefix ~suffix agent_name)
    keeper_agent_affixes
;;

let strip_keeper_prefix (s : string) : string option =
  let prefix = "keeper-" in
  let plen = String.length prefix in
  let slen = String.length s in
  if slen > plen && String.starts_with s ~prefix
  then Some (String.sub s plen (slen - plen))
  else None
;;

let keeper_agent_name name =
  let stable =
    match strip_keeper_prefix name with
    | Some stripped -> stripped
    | None -> name
  in
  Printf.sprintf "keeper-%s-agent" stable
;;
