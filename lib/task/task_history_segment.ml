open Result.Syntax
open Task_history_types
open Task_history_inventory
open Task_history_reader
open Task_history_scan

type task_bucket = {
  hash : int;
  key : string;
  mutable rev_offsets : int list;
  mutable next : task_bucket option;
}

type task_table = {
  mutable buckets : task_bucket option array;
  mutable mask : int;
  mutable size : int;
}

let create_task_table () =
  { buckets = Array.make 1024 None; mask = 1023; size = 0 }

let full_slice_hash s off len =
  let stop = off + len in
  let rec loop h i =
    if i >= stop then h land max_int
    else
      let c = Char.code (String.unsafe_get s i) in
      loop (((h lxor c) * 16777619) + (h lsr 16)) (i + 1)
  in
  loop 2166136261 off

let grow_task_table (t : task_table) =
  let old_buckets = t.buckets in
  let old_cap = Array.length old_buckets in
  let new_cap = old_cap lsl 1 in
  let new_mask = new_cap - 1 in
  let new_buckets = Array.make new_cap None in
  let rec reinsert = function
    | None -> ()
    | Some b ->
      let next = b.next in
      let idx = b.hash land new_mask in
      b.next <- Array.unsafe_get new_buckets idx;
      Array.unsafe_set new_buckets idx (Some b);
      reinsert next
  in
  for i = 0 to old_cap - 1 do
    reinsert (Array.unsafe_get old_buckets i)
  done;
  t.buckets <- new_buckets;
  t.mask <- new_mask

let rec add_slice_to_chain (t : task_table) idx h s off len offset = function
  | Some b when b.hash = h && slice_eq_lit s off len b.key ->
    b.rev_offsets <- offset :: b.rev_offsets
  | Some b -> add_slice_to_chain t idx h s off len offset b.next
  | None ->
    let key = String.sub s off len in
    let b = { hash = h; key; rev_offsets = [ offset ]; next = Array.unsafe_get t.buckets idx } in
    Array.unsafe_set t.buckets idx (Some b);
    t.size <- t.size + 1;
    if t.size > t.mask then grow_task_table t

let add_slice_to_table (t : task_table) s off len offset =
  let h = full_slice_hash s off len in
  let idx = h land t.mask in
  add_slice_to_chain t idx h s off len offset (Array.unsafe_get t.buckets idx)

let rec add_string_to_chain (t : task_table) idx h key offset = function
  | Some b when b.hash = h && String.equal key b.key ->
    b.rev_offsets <- offset :: b.rev_offsets
  | Some b -> add_string_to_chain t idx h key offset b.next
  | None ->
    let b = { hash = h; key; rev_offsets = [ offset ]; next = Array.unsafe_get t.buckets idx } in
    Array.unsafe_set t.buckets idx (Some b);
    t.size <- t.size + 1;
    if t.size > t.mask then grow_task_table t

let add_string_to_table (t : task_table) key offset =
  let h = full_slice_hash key 0 (String.length key) in
  let idx = h land t.mask in
  add_string_to_chain t idx h key offset (Array.unsafe_get t.buckets idx)

let rec fold_bucket_chain map = function
  | None -> map
  | Some b ->
    let map = String_map.add b.key (List.rev b.rev_offsets) map in
    fold_bucket_chain map b.next

let rec buckets_to_map_loop (buckets : task_bucket option array) i map =
  if i >= Array.length buckets then map
  else buckets_to_map_loop buckets (i + 1) (fold_bucket_chain map (Array.unsafe_get buckets i))

let task_table_to_map (t : task_table) =
  buckets_to_map_loop t.buckets 0 String_map.empty

type cached_segment = {
  device : int;
  inode : int;
  snapshot : Fs_compat.owned_regular_file_snapshot;
  scanned_from : int;
  scanned_to : int;
  row_count : int;
  first_row_offset : int;
  block_digests : (int * int * string) list;
  by_task : int list String_map.t;
  conflicting : int list String_map.t;
  verified_settled : bool;
  mutable last_used : int;
}

let max_cached_files = 256
(* Bound total retained row offsets across all cached segments in addition to
   the file-count bound so a small number of dense files cannot retain an
   unbounded offset map. *)
let max_cached_segment_rows = 2_000_000
let full_digest_max_bytes = 8 * io_block_bytes
let cache_mutex = Stdlib.Mutex.create ()
let cache_clock = ref 0
let segment_cache_retained_rows = ref 0
let segment_cache : (string * string, cached_segment) Hashtbl.t = Hashtbl.create 64

let segment_weight (seg : cached_segment) = max 1 seg.row_count

let find_cached_segment ~root ~relative =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt segment_cache (root, relative) with
    | None -> None
    | Some seg ->
      incr cache_clock;
      seg.last_used <- !cache_clock;
      Some seg)

let invalidate_cached_segment_if_same ~root ~relative (stale : cached_segment) =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt segment_cache (root, relative) with
    | Some existing when existing == stale ->
      segment_cache_retained_rows :=
        max 0 (!segment_cache_retained_rows - segment_weight existing);
      Hashtbl.remove segment_cache (root, relative)
    | Some _ | None -> ())

let evict_lru_locked () =
  let oldest_key = ref None in
  let oldest_tick = ref max_int in
  Hashtbl.iter
    (fun key (seg : cached_segment) ->
      if seg.last_used < !oldest_tick then (
        oldest_tick := seg.last_used;
        oldest_key := Some key))
    segment_cache;
  match !oldest_key with
  | Some key ->
    (match Hashtbl.find_opt segment_cache key with
     | Some existing ->
       segment_cache_retained_rows :=
         max 0 (!segment_cache_retained_rows - segment_weight existing)
     | None -> ());
    Hashtbl.remove segment_cache key
  | None -> ()

let evict_segment_cache_if_needed_locked () =
  while Hashtbl.length segment_cache > 0
        && (Hashtbl.length segment_cache > max_cached_files
            || !segment_cache_retained_rows > max_cached_segment_rows)
  do
    evict_lru_locked ()
  done

let store_cached_segment ~root ~relative (seg : cached_segment) =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    let replace =
      match Hashtbl.find_opt segment_cache (root, relative) with
      | None -> true
      | Some existing ->
        let range_contains_existing =
          seg.scanned_from <= existing.scanned_from
          && seg.scanned_to >= existing.scanned_to
        in
        let snapshot_supersedes_or_matches =
          seg.snapshot.owner_uid = existing.snapshot.owner_uid
          && seg.snapshot.permissions = existing.snapshot.permissions
          && (seg.snapshot.file_size > existing.snapshot.file_size
              || (seg.snapshot.file_size = existing.snapshot.file_size
                  && Fs_compat.equal_owned_regular_file_snapshot
                       existing.snapshot
                       seg.snapshot))
        in
        existing.device <> seg.device
        || existing.inode <> seg.inode
        || (snapshot_supersedes_or_matches && range_contains_existing)
    in
    if replace then (
      (match Hashtbl.find_opt segment_cache (root, relative) with
       | Some existing ->
         segment_cache_retained_rows :=
           max 0 (!segment_cache_retained_rows - segment_weight existing)
       | None -> ());
      incr cache_clock;
      seg.last_used <- !cache_clock;
      Hashtbl.replace segment_cache (root, relative) seg;
      segment_cache_retained_rows :=
        !segment_cache_retained_rows + segment_weight seg;
      evict_segment_cache_if_needed_locked ()))

let block_digest_at reader ~limit offset =
  let from = offset - (offset mod io_block_bytes) in
  let len = min io_block_bytes (limit - from) in
  let* () = load_block reader from in
  if reader.block_len < len then Error Source_changed
  else
    let d =
      Agent_core_sha256.digest_string ~off:0 ~len reader.block
      |> Agent_core_sha256.to_hex
    in
    Ok (from, len, d)

let blocks_to_hash ~scanned_from ~scanned_to =
  let first_block = scanned_from - (scanned_from mod io_block_bytes) in
  let last_block = (scanned_to - 1) - ((scanned_to - 1) mod io_block_bytes) in
  if scanned_to - scanned_from <= full_digest_max_bytes then (
    let rec all_blocks acc pos =
      if pos > last_block then List.rev acc
      else all_blocks (pos :: acc) (pos + io_block_bytes)
    in
    all_blocks [] first_block
  ) else if first_block = last_block then
    [ first_block ]
  else
    [ first_block; last_block ]

let compute_block_digests reader ~scanned_from ~scanned_to =
  let offsets = blocks_to_hash ~scanned_from ~scanned_to in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | off :: rest ->
      let* d = block_digest_at reader ~limit:scanned_to off in
      loop (d :: acc) rest
  in
  loop [] offsets

let snapshot_is_settled (s : Fs_compat.owned_regular_file_snapshot) =
  let now = Unix.gettimeofday () in
  now -. s.modified_at > 2.0 && now -. s.changed_at > 2.0

let make_cached_segment reader ~scanned_from ~scanned_to ~row_count ~first_row_offset ~by_task ~conflicting =
  let* block_digests = compute_block_digests reader ~scanned_from ~scanned_to in
  let snap = reader.file.snapshot in
  Ok {
    device = snap.device;
    inode = snap.inode;
    snapshot = snap;
    scanned_from;
    scanned_to;
    row_count;
    first_row_offset;
    block_digests;
    by_task;
    conflicting;
    verified_settled =
      snapshot_is_settled snap
      && (first_row_offset <= 0 || first_row_offset < scanned_to);
    last_used = 0;
  }

let verify_cached_segment ~is_ceiling reader (cached : cached_segment) =
  let cur = reader.file.snapshot in
  if cached.device <> cur.device
     || cached.inode <> cur.inode
     || cached.snapshot.owner_uid <> cur.owner_uid
     || cached.snapshot.permissions <> cur.permissions
     || cur.file_size < cached.snapshot.file_size
     || cached.snapshot.file_size < cached.scanned_to
     || cached.scanned_from < 0
     || cached.scanned_from >= cached.scanned_to
     || cached.row_count < 0
     || (cur.file_size = cached.snapshot.file_size
         && not (Fs_compat.equal_owned_regular_file_snapshot cached.snapshot cur))
  then Ok false
  else if not is_ceiling
          && cached.verified_settled
          && cur.file_size = cached.snapshot.file_size
          && Fs_compat.equal_owned_regular_file_snapshot cached.snapshot cur
  then Ok true
  else
    let rec verify_blocks = function
      | [] ->
        if cached.first_row_offset <= 0 then Ok true
        else if cached.first_row_offset >= cached.scanned_to then Ok false
        else (
          let* prev = byte reader (cached.first_row_offset - 1) in
          Ok (prev = '\n'))
      | (expected_from, expected_len, expected_sha256) :: rest ->
        let* actual_from, actual_len, actual_sha256 =
          block_digest_at reader ~limit:cached.scanned_to expected_from
        in
        if actual_from = expected_from
           && actual_len = expected_len
           && String.equal actual_sha256 expected_sha256
        then verify_blocks rest
        else Ok false
    in
    verify_blocks cached.block_digests

let add_offset_to_map key offset map =
  let existing = Option.value ~default:[] (String_map.find_opt key map) in
  String_map.add key (offset :: existing) map

let merge_desc_maps upper_map lower_map =
  String_map.merge
    (fun _key upper_opt lower_opt ->
      match upper_opt, lower_opt with
      | Some u, Some l -> Some (u @ l)
      | Some u, None -> Some u
      | None, Some l -> Some l
      | None, None -> None)
    upper_map lower_map
