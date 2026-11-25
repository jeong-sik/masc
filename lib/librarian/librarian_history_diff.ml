type range = Librarian_history_window.range = Time of float * float | Revisions of int * int
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
  ; events_limited : bool
  }

module Types = Keeper_memory_os_types
module Change = Librarian_memory_change
module Archive = Librarian_archive

let includes = Librarian_history_window.includes

let project_rows ~range ~current ~revision ~unsequenced ~changes ~sequence_suffix ~(folded : Archive.folded option) =
  let current = List.filter Types.is_ordinary current in
  let unsequenced = List.filter (fun (row : Archive.left) -> Types.is_ordinary row.fact) unsequenced in
  let changes = List.map (fun (c : Change.t) ->
    { c with
      added = List.filter Types.is_ordinary c.added
    ; removed = List.filter (fun (fact, _) -> Types.is_ordinary fact) c.removed
    }) changes in
  let id = Types.memory_id in
  let targets = Hashtbl.create 32 in
  let add_target = function
    | Librarian_effects.Revised_into target | Superseded_by target | Merged_into target ->
      Hashtbl.replace targets target ()
    | Dropped _ | Molted _ | Retracted _ | Support_lost _ -> () in
  List.iter (fun (old : Archive.left) -> if includes range ~at:old.at ~revision:None then add_target old.removal) unsequenced;
  List.iter (fun (c : Change.t) -> if includes range ~at:c.at ~revision:(Some c.revision) then
    List.iter (fun (_, r) -> add_target r) c.removed) changes;
  let known = Hashtbl.create 64 and held = Hashtbl.create 64 in
  let wanted fact = Hashtbl.mem targets (id fact) in
  let remember body_source fact = if wanted fact then Hashtbl.replace known (id fact) (fact, body_source) in
  List.iter (fun (e : Archive.left) -> remember Archived_fact e.fact) unsequenced;
  List.iter (fun (c : Change.t) ->
    List.iter (fun (fact, _) -> remember Archived_fact fact) c.removed;
    List.iter (remember Archived_fact) c.added) changes;
  List.iter (remember Current_snapshot) current;
  let events = Queue.create () and events_limited = ref false in
  let emit position event =
    Queue.add (position, event) events;
    if Queue.length events > Archive.max_detailed_rows then (
      ignore (Queue.take events : position * event); events_limited := true) in
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
      else n) 0 unsequenced
  in
  let last_seq = ref (Option.fold ~none:0 ~some:(fun f -> f.Archive.through_seq) folded)
  and last_rev = ref (Option.fold ~none:0 ~some:(fun f -> f.Archive.max_revision) folded) and gaps = ref [] and ticks = ref [] in
  List.iter (fun (c : Change.t) ->
    if !last_seq < c.seq - 1 then (
      (* A lost sequence has no recorded time. Adjacent timestamps cannot prove
         that a missing commit fell outside a wall-clock window. *)
      let relevant = match range with
        | Time _ -> true
        | Revisions (lo, hi) -> lo <= c.revision && !last_rev <= hi in
      (match sequence_suffix with
       | Librarian_history_window.From_sequence start when relevant && start < c.seq ->
         gaps := { first_seq = max start (!last_seq + 1); last_seq = c.seq - 1 } :: !gaps
       | From_sequence _ | Unknown_suffix -> ());
      Hashtbl.clear held);
    last_seq := c.seq;
    last_rev := c.revision;
    if includes range ~at:c.at ~revision:(Some c.revision) then (
      ticks := c :: !ticks;
      changes_at { seq = Some c.seq; revision = Some c.revision; at = c.at; source = Some c.source }
        ~added:c.added ~removed:c.removed);
    List.iter (fun (fact, _) -> Hashtbl.remove held (id fact)) c.removed;
    List.iter (fun fact -> if wanted fact then Hashtbl.replace held (id fact) fact) c.added) changes;
  let snapshot_ahead = match sequence_suffix with
    | Librarian_history_window.From_sequence _ -> revision > max 1 !last_rev
    | Unknown_suffix -> false in
  let snapshot_behind = !last_seq > 0 && revision < !last_rev in
  { events = List.of_seq (Queue.to_seq events); events_limited = !events_limited; ticks = List.rev !ticks; gaps = List.rev !gaps; unsequenced_in_range; snapshot_ahead; snapshot_behind }
;;

let project ~range ~current ~revision (history : Archive.history) =
  project_rows ~range ~current ~revision ~unsequenced:history.unsequenced ~changes:history.changes ~folded:history.folded ~sequence_suffix:(Librarian_history_window.From_sequence 1)
;;
let project_window ~range ~current ~revision (history : Librarian_history_window.t) =
  project_rows ~range ~current ~revision ~unsequenced:history.unsequenced ~changes:history.changes ~folded:history.folded ~sequence_suffix:history.sequence_suffix
;;
