module Archive = Librarian_archive
module Change = Librarian_memory_change
module Types = Keeper_memory_os_types
module Ids = Set.Make (String)
module Seq_set = Set.Make (Int)
module Sequences = Map.Make (Int)

type range = Time of float * float | Revisions of int * int

let includes range ~at ~revision = match range with
  | Time (lo, hi) -> lo <= at && at <= hi
  | Revisions (lo, hi) -> Option.fold ~none:false ~some:(fun r -> lo <= r && r <= hi) revision

let intersects range (f : Archive.folded) = match range with
  | Time (lo, hi) -> lo <= f.max_at && f.min_at <= hi
  | Revisions (lo, hi) -> lo <= f.max_revision && f.min_revision <= hi

type cut = { by_rows : bool; by_bytes : bool }
let no_cut = { by_rows = false; by_bytes = false }
let is_cut c = c.by_rows || c.by_bytes

type t =
  { unsequenced : Archive.left list
  ; changes : Change.t list
  ; folded : Archive.folded option
  ; unreadable : int
  ; conflicting : int
  ; unsequenced_count : int
  ; live_cut : cut
  ; archive_cut : cut
  ; details_limited : bool
  ; input_limited : bool
  }

type tail = { rows : string; start : int; offset : int; cut : cut; fragment : bool }

(* Keep whole lines from the newest end. The private reader also bounds bytes
   before looking for a newline, including a file made of one oversized row. *)
let read_tail path ~max_bytes ~max_rows =
  match Fs_compat.read_private_jsonl_tail_locked_result path ~max_bytes with
  | Fs_compat.Private_file_failed e | Private_file_failed_with_cleanup_failure { error = e; _ } ->
    Error (Private_jsonl_scan.Read_failed { path; detail = Fs_compat.Private_jsonl_tail.error_to_string e })
  | Private_file_succeeded tail | Private_file_succeeded_with_cleanup_failure { value = tail; _ } ->
    (match tail with
     | Fs_compat.Private_jsonl_tail.Tail_missing ->
       Ok { rows = ""; start = 0; offset = 0; cut = no_cut; fragment = false }
     | Tail_present { rows; prefix_omitted; incomplete_tail; end_offset } ->
       let rec take n stop =
         if stop <= 0 then 0 else if n = 0 then stop else
           match String.rindex_from_opt rows (stop - 2) '\n' with
           | None -> 0 | Some newline -> take (n - 1) (newline + 1) in
       let start = take max_rows (String.length rows) in
       (* Diff positions use sequence/revision/time. A fragment has no byte
          position the bounded tail can certify. Use a local offset only for dedup. *)
       let offset = if incomplete_tail then 0 else end_offset - String.length rows in
       Ok { rows; start; offset; cut = { by_rows = start > 0; by_bytes = prefix_omitted }; fragment = incomplete_tail })

let iter tail f =
  let rec loop index start =
    match String.index_from_opt tail.rows start '\n' with
    | None -> ()
    | Some stop ->
      f index (tail.offset + start) (String.sub tail.rows start (stop - start));
      loop (index + 1) (stop + 1) in
  loop 0 tail.start

let live_row at raw = match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error _ -> Some Archive.Invalid
  | json -> (match Librarian_log_codec.of_json json with
    | Ok (Librarian_log.Started _) -> None
    | Ok (Committed c) -> Some (Archive.Detail (Change.of_commit ~line_at:at c))
    | Error _ -> Some Archive.Invalid)

let read ~range ~max_bytes path =
  let open Result.Syntax in
  Archive.with_path_lock ~log_path:path @@ fun () ->
  let* live = read_tail path ~max_bytes ~max_rows:Archive.max_detailed_rows in
  (* One extra line allows for the archive's retention footer. *)
  let* cold = read_tail (Librarian_log_store.archive_path_of_log_path path)
      ~max_bytes ~max_rows:(Archive.max_detailed_rows + 1) in
  let each f =
    iter cold (fun index at raw -> f `Cold index at raw (Archive.cold_row raw));
    iter live (fun index at raw -> Option.iter (f `Live index at raw) (live_row at raw)) in
  (* Materialize out-of-range bodies only for direct successors named in this
     request. Both passes operate on the same two bounded byte snapshots. *)
  let needed = ref Ids.empty and coverage = ref None and folded = ref None in
  let need = function
    | Librarian_effects.Revised_into target | Superseded_by target | Merged_into target ->
      needed := Ids.add target !needed
    | Dropped _ | Retracted _ | Support_lost _ | Molted _ -> () in
  each (fun _ index _ _ -> function
    | Archive.Left e when includes range ~at:e.at ~revision:None -> need e.removal
    | Detail c when includes range ~at:c.at ~revision:(Some c.revision) ->
      List.iter (fun (_, removal) -> need removal) c.removed
    | Folded boundary -> folded := Some boundary
    | Coverage c -> coverage := Some (index, c); folded := c.folded_detail
    | Left _ | Detail _ | Invalid | Opaque _ -> ());
  let wanted f = Ids.mem (Types.memory_id f) !needed in
  let versions = ref Sequences.empty and old = ref [] in
  let archive_details = ref Seq_set.empty and archive_conflicts = ref Seq_set.empty in
  let first_cold_detail = ref None in
  let damage = Hashtbl.create 4 and cold_events = Hashtbl.create 16 in
  let old_count = ref 0 and cold_head = ref 0 and live_head = ref 0 in
  let remember_damage marker = Hashtbl.replace damage marker () in
  let after_fold seq = Option.fold ~none:true
      ~some:(fun (f : Archive.folded) -> seq > f.through_seq) !folded in
  each (fun origin index at raw row ->
    let head = match origin with `Live -> live_head | `Cold -> cold_head in
    match row with
    | Archive.Folded _ | Coverage _ -> ()
    | Opaque marker -> remember_damage marker
    | Invalid -> remember_damage (Archive.damaged_row
        ~origin:(match origin with `Live -> "live" | `Cold -> "archive") ~at ~after_seq:!head raw)
    | Left e -> incr old_count;
      if includes range ~at:e.at ~revision:None || wanted e.fact then old := e :: !old
    | Detail c ->
      head := max !head c.seq;
      let earlier_conflict = match origin, !coverage with
        | `Cold, Some (footer, coverage) when index < footer ->
          if index < footer - coverage.detail_rows then (
            archive_conflicts := Seq_set.add c.seq !archive_conflicts;
            true)
          else (archive_details := Seq_set.add c.seq !archive_details; false)
        | (`Cold | `Live), _ -> false in
      if earlier_conflict then versions := Sequences.add c.seq None !versions
      else (
        (match origin, !first_cold_detail with
         | `Cold, None when after_fold c.seq -> first_cold_detail := Some c
         | (`Cold | `Live), _ -> ());
        let selected = includes range ~at:c.at ~revision:(Some c.revision) in
        let change = if selected then c else
          { c with added = List.filter wanted c.added; removed = List.filter (fun (f, _) -> wanted f) c.removed } in
        let fingerprint = Change.fingerprint c in
        versions := Sequences.update c.seq (function
          | None -> Some (Some (fingerprint, change))
          | Some (Some (prior, _)) as found when String.equal prior fingerprint -> found
          | Some _ -> Some None) !versions));
  let published = Option.map snd !coverage in
  let may_hide_conflict seq = match published with
    | Some c -> c.conflicting_sequences > Seq_set.cardinal !archive_conflicts
                && seq <= c.last_seq && not (Seq_set.mem seq !archive_details)
    | None -> false in
  let changes, conflicting, new_conflicting = Sequences.fold
    (fun seq version (changes, conflicting, new_conflicting) ->
    match version with
    | None ->
      let new_conflicting = if Seq_set.mem seq !archive_conflicts || may_hide_conflict seq
        then new_conflicting else new_conflicting + 1 in
      changes, conflicting + 1, new_conflicting
    | Some _ when not (after_fold seq) || may_hide_conflict seq ->
      changes, conflicting, new_conflicting
    | Some (_, c) ->
      List.iter (fun (fact, removal) -> Hashtbl.replace cold_events (Types.memory_id fact, removal, c.Change.at) ()) c.removed;
      c :: changes, conflicting, new_conflicting) !versions ([], 0, 0) in
  let unsequenced = List.rev !old |> List.filter (fun (e : Archive.left) ->
    not (Hashtbl.mem cold_events (Types.memory_id e.fact, e.removal, e.at))) in
  let cold_limited = is_cut cold.cut in
  let cold_detail_limited, relevant_legacy_cut = match !coverage with
    | Some (footer, c) ->
      let legacy_in_range = match range with
        | Time (lo, hi) -> Option.fold ~none:false
            ~some:(fun (first, last) -> lo <= last && first <= hi) c.unsequenced_time
        | Revisions (lo, _) -> (match c.folded_detail, !first_cold_detail with
          | Some f, _ -> lo <= f.max_revision
          | None, Some first -> lo <= first.revision
          | None, None -> true) in
      cold_limited && footer < c.detail_rows,
      cold_limited && !old_count < c.unsequenced_rows && legacy_in_range
    | None ->
      (* A pre-summary archive cannot certify its omitted legacy or damage
         rows. Its sequenced tail can still begin exactly at the fold boundary. *)
      let detail_known = match !folded, !first_cold_detail with
        | Some boundary, Some first -> first.seq - 1 = boundary.through_seq
        | _ -> false in
      cold_limited && not detail_known, cold_limited in
  let archive_cut = if cold_detail_limited || relevant_legacy_cut then cold.cut else no_cut in
  let details_limited = is_cut live.cut || cold_detail_limited in
  let conflicting = max conflicting (Option.fold ~none:0
      ~some:(fun (c : Archive.coverage) -> c.conflicting_sequences + new_conflicting) published) in
  (* On publication overlap an omitted retained marker may also be present in
     the live log. Take the larger observed count without counting it twice. *)
  let unreadable = max (Hashtbl.length damage) (Option.fold ~none:0
      ~some:(fun (c : Archive.coverage) -> c.unreadable_rows) published) in
  let unsequenced_count = max !old_count (Option.fold ~none:0
      ~some:(fun (c : Archive.coverage) -> c.unsequenced_rows) published) in
  Ok { changes = List.rev changes; unsequenced; folded = !folded; conflicting;
       unreadable = unreadable + (if cold.fragment then 1 else 0);
       unsequenced_count; live_cut = live.cut; archive_cut; details_limited;
       input_limited = details_limited || relevant_legacy_cut }
