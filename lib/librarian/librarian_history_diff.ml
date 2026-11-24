type range = Time of float * float | Revisions of int * int
type position =
  { seq : int option
  ; revision : int option
  ; at : float
  ; source : Keeper_memory_os_current_types.source option
  }

type relation = Revision | Program_revision | Program_absorption
type body_source = Same_commit | Held_before | Current_snapshot | Archived_fact
type event =
  | Added of Keeper_memory_os_types.fact
  | Updated of { before : Keeper_memory_os_types.fact; after : Keeper_memory_os_types.fact;
                 relation : relation; body_source : body_source }
  | Successor_unavailable of { before : Keeper_memory_os_types.fact; successor_id : string; relation : relation }
  | Removed of { fact : Keeper_memory_os_types.fact; reason : string option; missing : string list option }

type gap = { first_seq : int; last_seq : int }
type t =
  { events : (position * event) list
  ; ticks : Librarian_memory_change.t list
  ; gaps : gap list
  ; unsequenced_in_range : int
  ; snapshot_ahead : bool
  ; snapshot_behind : bool
  }

module Types = Keeper_memory_os_types
module Change = Librarian_memory_change
module Archive = Librarian_archive

let includes range ~at ~revision =
  match range with
  | Time (lo, hi) -> lo <= at && at <= hi
  | Revisions (lo, hi) -> Option.fold ~none:false ~some:(fun r -> lo <= r && r <= hi) revision
;;

let project ~range ~current ~revision (history : Archive.history) =
  let id = Types.memory_id in
  let known = Hashtbl.create 64 and held = Hashtbl.create 64 in
  let remember body_source fact = Hashtbl.replace known (id fact) (fact, body_source) in
  List.iter (fun (e : Archive.left) -> remember Archived_fact e.fact) history.unsequenced;
  List.iter (fun (c : Change.t) ->
    List.iter (fun (fact, _) -> remember Archived_fact fact) c.removed;
    List.iter (remember Archived_fact) c.added) history.changes;
  List.iter (remember Current_snapshot) current;
  let events = ref [] in
  let emit position event = events := (position, event) :: !events in
  let changes_at position ~added ~removed =
    let replacements = Hashtbl.create 8 and revisions = Hashtbl.create 8 in
    List.iter (fun fact -> Hashtbl.replace replacements (id fact) fact) added;
    List.iter (fun (_, removal) -> match removal with
      | Librarian_effects.Revised_into target | Superseded_by target ->
        Hashtbl.replace revisions target (1 + Option.value ~default:0 (Hashtbl.find_opt revisions target))
      | Dropped _ | Merged_into _ | Retracted _ | Support_lost _ | Molted _ -> ()) removed;
    let paired = Hashtbl.create 8 in
    List.iter (fun (fact, removal) ->
      let replace target relation =
        let after = match Hashtbl.find_opt replacements target with
          | Some after -> Some (after, Same_commit)
          | None -> match Hashtbl.find_opt held target with
            | Some after -> Some (after, Held_before)
            | None -> Hashtbl.find_opt known target
        in
        match after with
        | None -> emit position (Successor_unavailable { before = fact; successor_id = target; relation })
        | Some (after, body_source) ->
          Hashtbl.replace paired target ();
          emit position (Updated { before = fact; after; relation; body_source })
      in
      match removal with
      | Librarian_effects.Merged_into target -> replace target Program_absorption
      | Revised_into target | Superseded_by target ->
        let relation = match Hashtbl.find_opt revisions target with
          | Some n when n > 1 -> Program_revision
          | Some _ | None -> Revision in
        replace target relation
      | Dropped { reason } | Molted { reason } | Retracted { reason; _ } ->
        emit position (Removed { fact; reason = Some reason; missing = None })
      | Support_lost { missing } -> emit position (Removed { fact; reason = None; missing = Some missing })
    ) removed;
    List.iter (fun fact -> if not (Hashtbl.mem paired (id fact)) then emit position (Added fact)) added
  in
  let unsequenced_in_range =
    List.fold_left (fun n (e : Archive.left) ->
      if includes range ~at:e.at ~revision:None then (
        changes_at { seq = None; revision = None; at = e.at; source = None } ~added:[] ~removed:[e.fact, e.removal];
        n + 1)
      else n) 0 history.unsequenced
  in
  let last_seq = ref 0 and last_rev = ref 0 and gaps = ref [] and ticks = ref [] in
  List.iter (fun (c : Change.t) ->
    if c.seq > !last_seq + 1 then (
      (* A lost sequence has no recorded time. Adjacent timestamps cannot prove
         that a missing commit fell outside a wall-clock window. *)
      let relevant = match range with
        | Time _ -> true
        | Revisions (lo, hi) -> lo <= c.revision && !last_rev <= hi in
      if relevant then gaps := { first_seq = !last_seq + 1; last_seq = c.seq - 1 } :: !gaps;
      Hashtbl.clear held);
    last_seq := c.seq;
    last_rev := c.revision;
    if includes range ~at:c.at ~revision:(Some c.revision) then (
      ticks := c :: !ticks;
      changes_at { seq = Some c.seq; revision = Some c.revision; at = c.at; source = Some c.source }
        ~added:c.added ~removed:c.removed);
    List.iter (fun (fact, _) -> Hashtbl.remove held (id fact)) c.removed;
    List.iter (fun fact -> Hashtbl.replace held (id fact) fact) c.added) history.changes;
  let snapshot_ahead = revision > max 1 !last_rev in
  let snapshot_behind = !last_seq > 0 && revision < !last_rev in
  { events = List.rev !events; ticks = List.rev !ticks; gaps = List.rev !gaps; unsequenced_in_range; snapshot_ahead; snapshot_behind }
;;
