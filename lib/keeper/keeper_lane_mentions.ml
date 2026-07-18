(** Boundary mention parser — see the interface.  Syntax parsing is owned by
    {!Direct_mention}; this module only mints the parsed tokens into canonical
    Keeper identities. *)

let mention_ids_of_content (content : string) :
  Keeper_identity.Keeper_id.t list
  =
  Direct_mention.targets_of_content content
  |> List.filter_map Keeper_identity.Keeper_id.of_string
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
