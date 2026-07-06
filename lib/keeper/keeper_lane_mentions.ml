(** Boundary mention parser — see the interface.  Token extraction lives in
    {!Board_types.Mention_id} so board rows and keeper chat rows share the same
    exact-token protocol parser.  This module adds only keeper identity
    canonicalization on top. *)

let mention_ids_of_content (content : string) :
  Keeper_identity.Keeper_id.t list
  =
  Board_types.Mention_id.mention_ids_of_content content
  |> List.filter_map (fun id ->
    Keeper_identity.Keeper_id.of_string (Board_types.Mention_id.to_string id))
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let target_ids_of (targets : string list) :
  Keeper_identity.Keeper_id.t list
  =
  List.filter_map Keeper_identity.Keeper_id.of_string targets
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let ids_match ~(target_ids : Keeper_identity.Keeper_id.t list)
      (mentions : Keeper_identity.Keeper_id.t list)
  : bool
  =
  List.exists
    (fun mention ->
      List.exists (Keeper_identity.Keeper_id.equal mention) target_ids)
    mentions
;;
