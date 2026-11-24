module Archive = Librarian_archive
module Change = Librarian_memory_change
module Types = Keeper_memory_os_types
module Ids = Set.Make (String)
module Sequences = Map.Make (Int)

type range = Time of float * float | Revisions of int * int

let includes range ~at ~revision = match range with
  | Time (lo, hi) -> lo <= at && at <= hi
  | Revisions (lo, hi) -> Option.fold ~none:false ~some:(fun r -> lo <= r && r <= hi) revision

let intersects range (f : Archive.folded) = match range with
  | Time (lo, hi) -> lo <= f.max_at && f.min_at <= hi
  | Revisions (lo, hi) -> lo <= f.max_revision && f.min_revision <= hi

type cut = { by_rows : bool; by_bytes : bool }

type t =
  { unsequenced : Archive.left list
  ; changes : Change.t list
  ; folded : Archive.folded option
  ; unreadable : int
  ; conflicting : int
  ; unsequenced_count : int
  ; live_cut : cut
  ; archive_cut : cut
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
       Ok { rows = ""; start = 0; offset = 0; cut = { by_rows = false; by_bytes = false }; fragment = false }
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
  let rec loop start =
    match String.index_from_opt tail.rows start '\n' with
    | None -> ()
    | Some stop ->
      f (tail.offset + start) (String.sub tail.rows start (stop - start)); loop (stop + 1) in
  loop tail.start

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
    iter cold (fun at raw -> f `Cold at raw (Archive.cold_row raw));
    iter live (fun at raw -> Option.iter (f `Live at raw) (live_row at raw)) in
  (* Materialize out-of-range bodies only for direct successors named in this
     request. Both passes operate on the same two bounded byte snapshots. *)
  let needed = ref Ids.empty in
  let need = function
    | Librarian_effects.Revised_into target | Superseded_by target | Merged_into target ->
      needed := Ids.add target !needed
    | Dropped _ | Retracted _ | Support_lost _ | Molted _ -> () in
  each (fun _ _ _ -> function
    | Archive.Left e when includes range ~at:e.at ~revision:None -> need e.removal
    | Detail c when includes range ~at:c.at ~revision:(Some c.revision) ->
      List.iter (fun (_, removal) -> need removal) c.removed
    | Left _ | Detail _ | Invalid | Opaque _ | Folded _ -> ());
  let wanted f = Ids.mem (Types.memory_id f) !needed in
  let versions = ref Sequences.empty and old = ref [] and folded = ref None in
  let damage = Hashtbl.create 4 and cold_events = Hashtbl.create 16 in
  let old_count = ref 0 and cold_head = ref 0 and live_head = ref 0 in
  let remember_damage marker = Hashtbl.replace damage marker () in
  each (fun origin at raw row ->
    let head = match origin with `Live -> live_head | `Cold -> cold_head in
    match row with
    | Archive.Folded boundary -> folded := Some boundary
    | Opaque marker -> remember_damage marker
    | Invalid -> remember_damage (Archive.damaged_row
        ~origin:(match origin with `Live -> "live" | `Cold -> "archive") ~at ~after_seq:!head raw)
    | Left e -> incr old_count;
      if includes range ~at:e.at ~revision:None || wanted e.fact then old := e :: !old
    | Detail c ->
      head := max !head c.seq;
      let selected = includes range ~at:c.at ~revision:(Some c.revision) in
      let change = if selected then c else
        { c with added = List.filter wanted c.added; removed = List.filter (fun (f, _) -> wanted f) c.removed } in
      let fingerprint = Change.fingerprint c in
      versions := Sequences.update c.seq (function
        | None -> Some (Some (fingerprint, change))
        | Some (Some (prior, _)) as found when String.equal prior fingerprint -> found
        | Some _ -> Some None) !versions);
  let changes, conflicting = Sequences.fold (fun seq version (changes, conflicts) ->
    match version with
    | None -> changes, conflicts + 1
    | Some _ when Option.fold ~none:false ~some:(fun (f : Archive.folded) -> seq <= f.through_seq) !folded ->
      changes, conflicts
    | Some (_, c) ->
      List.iter (fun (fact, removal) -> Hashtbl.replace cold_events (Types.memory_id fact, removal, c.Change.at) ()) c.removed;
      c :: changes, conflicts) !versions ([], 0) in
  let unsequenced = List.rev !old |> List.filter (fun (e : Archive.left) ->
    not (Hashtbl.mem cold_events (Types.memory_id e.fact, e.removal, e.at))) in
  Ok { changes = List.rev changes; unsequenced; folded = !folded; conflicting;
       unreadable = Hashtbl.length damage + (if cold.fragment then 1 else 0);
       unsequenced_count = !old_count; live_cut = live.cut; archive_cut = cold.cut;
       input_limited = live.cut.by_rows || live.cut.by_bytes || cold.cut.by_rows || cold.cut.by_bytes }
