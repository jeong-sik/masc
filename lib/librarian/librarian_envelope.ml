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
  | Rewritten of
      { snapshot : Current.t
      ; bytes : string
      }

type refusal =
  | Revision_not_next of
      { snapshot : int
      ; line : int
      }
  | Facts_inconsistent of string
  | Not_encodable of string

let source_of_direct ~trace (write : Librarian_direct.write) : Current.source =
  match write with
  | Remember _ | Supersede _ -> { kind = Explicit_write; trace_id = trace }
  | Retract _ -> { kind = Explicit_retract; trace_id = trace }
;;

let rewritten ~(previous : Current.t) ~at ~(effects : Effects.t) ~source =
  let facts = Effects.apply ~at previous.facts effects in
  let invalidated =
    List.filter_map
      (fun (fact, (removal : Effects.removal)) ->
         match removal with
         | Support_lost { missing } -> Some { Current.fact; missing_premise_ids = missing }
         | Dropped _ | Merged_into _ | Revised_into _ | Superseded_by _ | Retracted _ -> None)
      effects.removed
  in
  match
    Keeper_memory_os_support_core.compute_change ~previous:previous.facts ~next:facts ~invalidated
  with
  | Error detail -> Error (Facts_inconsistent detail)
  | Ok change ->
    let snapshot : Current.t =
      { revision = previous.revision + 1; updated_at = at; source; facts; change }
    in
    (* The codec raises on what it does not write. A line read back from disk
       can ask for that, and the boot that reads it has to get an answer. *)
    (match Keeper_memory_os_snapshot_codec.snapshot_bytes snapshot with
     | exception Invalid_argument detail -> Error (Not_encodable detail)
     | bytes -> Ok (Rewritten { snapshot; bytes }))
;;

(* The snapshot holds the facts; the rest of an answer's effects is the
   line's. An answer that adds, sees and removes nothing changes no byte. *)
let changes_facts (effects : Effects.t) =
  not
    (List.is_empty effects.added
     && List.is_empty effects.touched
     && List.is_empty effects.removed)
;;

let next ~previous ~at (cause : Log.cause) effects =
  match cause with
  | Adopt { by = (_ : string); observed = (_ : Digest.digest) } -> Ok Unchanged
  | Skip { hole = (_ : Log.hole) } -> Ok Unchanged
  | Direct { by = (_ : Effects.actor); trace; write } ->
    rewritten ~previous ~at ~effects ~source:(source_of_direct ~trace write)
  | Read
      { trace
      ; question = (_ : Librarian_question_id.t)
      ; shown = (_ : Log.shown)
      ; slot = (_ : string)
      ; missing = (_ : Librarian_unit.missing_at list)
      }
  | Make_room { trace; question = (_ : Librarian_question_id.t); slot = (_ : string) } ->
    if changes_facts effects
    then
      rewritten ~previous ~at ~effects
        ~source:({ kind = Librarian; trace_id = trace } : Current.source)
    else Ok Unchanged
;;

let after ~(previous : Current.t) (commit : Log.commit) =
  match next ~previous ~at:commit.at commit.cause commit.effects with
  | Ok (Rewritten { snapshot; bytes = (_ : string) })
    when not (Int.equal snapshot.revision commit.revision) ->
    Error (Revision_not_next { snapshot = previous.revision; line = commit.revision })
  | (Ok (Rewritten _ | Unchanged) | Error (_ : refusal)) as result -> result
;;
