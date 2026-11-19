module Current = Keeper_memory_os_current_types
module Digest = Agent_core.Checkpoint_objects
module Effects = Librarian_effects
module Log = Librarian_log

let digest snapshot =
  Digest.digest_of_bytes (Keeper_memory_os_snapshot_codec.snapshot_bytes snapshot)
;;

let first_revision = 1

let empty ~at ~turn_log : Current.t =
  { revision = first_revision
  ; updated_at = at
  ; source = { kind = Librarian; trace_id = Keeper_turn_log.Log_id.to_string turn_log }
  ; facts = []
  ; change = { added = []; removed = []; retained = 0; invalidated = [] }
  }
;;

type next =
  | Unchanged
  | Rewritten of Current.t

type refusal =
  | Revision_not_next of
      { snapshot : int
      ; line : int
      }
  | Facts_inconsistent of string

let source_of_direct ~trace (write : Librarian_direct.write) : Current.source =
  match write with
  | Remember _ | Supersede _ -> { kind = Explicit_write; trace_id = trace }
  | Retract _ -> { kind = Explicit_retract; trace_id = trace }
;;

let rewritten ~(previous : Current.t) ~(commit : Log.commit) ~source =
  if not (Int.equal commit.revision (previous.revision + 1))
  then Error (Revision_not_next { snapshot = previous.revision; line = commit.revision })
  else (
    let facts = Effects.apply ~at:commit.at previous.facts commit.effects in
    let invalidated =
      List.filter_map
        (fun (fact, (removal : Effects.removal)) ->
           match removal with
           | Support_lost { missing } ->
             Some { Current.fact; missing_premise_ids = missing }
           | Dropped _ | Merged_into _ | Revised_into _ | Superseded_by _ | Retracted _ -> None)
        commit.effects.removed
    in
    match
      Keeper_memory_os_support_core.compute_change ~previous:previous.facts ~next:facts
        ~invalidated
    with
    | Error detail -> Error (Facts_inconsistent detail)
    | Ok change ->
      Ok
        (Rewritten
           { revision = commit.revision; updated_at = commit.at; source; facts; change }))
;;

let after ~previous (commit : Log.commit) =
  match commit.cause with
  | Adopt { by = (_ : string); observed = (_ : Digest.digest) } -> Ok Unchanged
  | Direct { by = (_ : Effects.actor); trace; write } ->
    rewritten ~previous ~commit ~source:(source_of_direct ~trace write)
;;
