(** Boundary mention parser — see the interface.  The tokenization grammar
    is shared with the Board write boundary through [Board_addressing]
    (issue #25601); this module only mints the grammar's raw, case-preserved
    target candidates through [Keeper_identity.Keeper_id.of_string], whose
    documented contract case-folds and canonicalizes.  Equivalence against
    the legacy (pre-folded) decision procedure is pinned by
    test_keeper_lane_mentions. *)

type explicit_address =
  | No_explicit_address
  | Targets of Keeper_identity.Keeper_id.t list
  | Broadcast_all
  | Unsupported_broadcast of string list

let explicit_address_of_content content =
  match Board_addressing.parse content with
  | Board_addressing.Broadcast_all -> Broadcast_all
  | Board_addressing.Unsupported_broadcast selectors ->
    Unsupported_broadcast selectors
  | Board_addressing.No_explicit_address -> No_explicit_address
  | Board_addressing.Raw_targets candidates ->
    (match
       List.filter_map Keeper_identity.Keeper_id.of_string candidates
       |> List.sort_uniq Keeper_identity.Keeper_id.compare
     with
     | [] -> No_explicit_address
     | _ :: _ as targets -> Targets targets)
;;

let mention_ids_of_content content =
  match explicit_address_of_content content with
  | Targets targets -> targets
  | No_explicit_address | Broadcast_all | Unsupported_broadcast _ -> []
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
