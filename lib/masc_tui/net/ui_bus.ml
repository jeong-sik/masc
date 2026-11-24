let default_stream_capacity = 512

type ('snap_key, 'snap, 'ev) item =
  | Snapshot of 'snap_key * 'snap
  | Stream_event of 'ev
  | Stream_gap of int

type stats = {
  queued_snapshots : int;
  queued_stream_events : int;
  pending_gap : int;
  total_coalesced_snapshots : int;
  total_dropped_stream_events : int;
}

type ('snap_key, 'snap) snap_slot = {
  key : 'snap_key;
  mutable value : 'snap;
}

type ('snap_key, 'snap, 'ev) t = {
  mu : Stdlib.Mutex.t;
  key_equal : 'snap_key -> 'snap_key -> bool;
  key_hash : 'snap_key -> int;
  (* Buckets keyed by hash; collisions scanned linearly with key_equal.
     Keeps polymorphic interface clean with zero functor boilerplate. *)
  snap_buckets : (int, ('snap_key, 'snap) snap_slot list) Hashtbl.t;
  snap_order : ('snap_key, 'snap) snap_slot Queue.t;
  mutable snap_count : int;
  ring : 'ev option array;
  ring_cap : int;
  mutable ring_head : int;
  mutable ring_len : int;
  mutable pending_gap : int;
  mutable total_coalesced_snapshots : int;
  mutable total_dropped_stream_events : int;
  mutable wake_pending : bool;
  on_wake : (unit -> unit) option;
}

let create ?(stream_capacity = default_stream_capacity) ~key_equal ~key_hash
    ?on_wake () =
  let ring_cap = max 1 stream_capacity in
  {
    mu = Stdlib.Mutex.create ();
    key_equal;
    key_hash;
    snap_buckets = Hashtbl.create 16;
    snap_order = Queue.create ();
    snap_count = 0;
    ring = Array.make ring_cap None;
    ring_cap;
    ring_head = 0;
    ring_len = 0;
    pending_gap = 0;
    total_coalesced_snapshots = 0;
    total_dropped_stream_events = 0;
    wake_pending = false;
    on_wake;
  }

(* Must be called while holding [t.mu] so latching and clearing [wake_pending]
   are strictly serialized against [drain_up_to]/[drain]. *)
let latch_wake_locked t =
  match t.on_wake with
  | None -> false
  | Some _ ->
      if t.wake_pending then false
      else begin
        t.wake_pending <- true;
        true
      end

let fire_wake t should_wake =
  if should_wake then
    match t.on_wake with
    | Some wake -> wake ()
    | None -> ()

let publish_snapshot t ~key value =
  (* Microsecond in-memory mutation only — zero I/O or fiber suspension. *)
  let should_wake =
    Stdlib.Mutex.protect t.mu (fun () ->
        let h = t.key_hash key in
        let bucket =
          match Hashtbl.find_opt t.snap_buckets h with
          | Some b -> b
          | None -> []
        in
        (match List.find_opt (fun slot -> t.key_equal slot.key key) bucket with
        | Some existing ->
            existing.value <- value;
            t.total_coalesced_snapshots <- t.total_coalesced_snapshots + 1
        | None ->
            let slot = { key; value } in
            Hashtbl.replace t.snap_buckets h (slot :: bucket);
            Queue.push slot t.snap_order;
            t.snap_count <- t.snap_count + 1);
        latch_wake_locked t)
  in
  fire_wake t should_wake

let publish_stream t ev =
  let should_wake =
    Stdlib.Mutex.protect t.mu (fun () ->
        if t.ring_len < t.ring_cap then begin
          let tail = (t.ring_head + t.ring_len) mod t.ring_cap in
          t.ring.(tail) <- Some ev;
          t.ring_len <- t.ring_len + 1
        end
        else begin
          (* Ring full: evict oldest entry, record exact gap, write newest at tail. *)
          t.ring.(t.ring_head) <- Some ev;
          t.ring_head <- (t.ring_head + 1) mod t.ring_cap;
          t.pending_gap <- t.pending_gap + 1;
          t.total_dropped_stream_events <- t.total_dropped_stream_events + 1
        end;
        latch_wake_locked t)
  in
  fire_wake t should_wake

let pop_one_snapshot_locked t =
  match Queue.take_opt t.snap_order with
  | None -> None
  | Some slot ->
      let h = t.key_hash slot.key in
      (match Hashtbl.find_opt t.snap_buckets h with
      | None -> ()
      | Some bucket -> (
          let rest =
            List.filter (fun s -> not (t.key_equal s.key slot.key)) bucket
          in
          match rest with
          | [] -> Hashtbl.remove t.snap_buckets h
          | _ -> Hashtbl.replace t.snap_buckets h rest));
      t.snap_count <- max 0 (t.snap_count - 1);
      Some (Snapshot (slot.key, slot.value))

let pop_one_stream_locked t =
  if t.pending_gap > 0 then begin
    let gap = t.pending_gap in
    t.pending_gap <- 0;
    Some (Stream_gap gap)
  end
  else if t.ring_len > 0 then begin
    let entry = t.ring.(t.ring_head) in
    t.ring.(t.ring_head) <- None;
    t.ring_head <- (t.ring_head + 1) mod t.ring_cap;
    t.ring_len <- t.ring_len - 1;
    match entry with Some ev -> Some (Stream_event ev) | None -> None
  end
  else None

let drain_up_to ~max_items t =
  if max_items <= 0 then []
  else
    let items, should_wake =
      Stdlib.Mutex.protect t.mu (fun () ->
          let rec loop remaining acc =
            if remaining = 0 then List.rev acc
            else
              match pop_one_snapshot_locked t with
              | Some item -> loop (remaining - 1) (item :: acc)
              | None -> (
                  match pop_one_stream_locked t with
                  | Some item -> loop (remaining - 1) (item :: acc)
                  | None -> List.rev acc)
          in
          let drained = loop max_items [] in
          let more =
            t.snap_count > 0 || t.pending_gap > 0 || t.ring_len > 0
          in
          t.wake_pending <- false;
          let should_wake = if more then latch_wake_locked t else false in
          (drained, should_wake))
    in
    fire_wake t should_wake;
    items

let drain t =
  Stdlib.Mutex.protect t.mu (fun () ->
      let acc = ref [] in
      let rec drain_snaps () =
        match pop_one_snapshot_locked t with
        | Some item ->
            acc := item :: !acc;
            drain_snaps ()
        | None -> ()
      in
      drain_snaps ();
      let rec drain_stream () =
        match pop_one_stream_locked t with
        | Some item ->
            acc := item :: !acc;
            drain_stream ()
        | None -> ()
      in
      drain_stream ();
      t.wake_pending <- false;
      List.rev !acc)

let is_empty t =
  Stdlib.Mutex.protect t.mu (fun () ->
      t.snap_count = 0 && t.pending_gap = 0 && t.ring_len = 0)

let stats t =
  Stdlib.Mutex.protect t.mu (fun () ->
      {
        queued_snapshots = t.snap_count;
        queued_stream_events = t.ring_len;
        pending_gap = t.pending_gap;
        total_coalesced_snapshots = t.total_coalesced_snapshots;
        total_dropped_stream_events = t.total_dropped_stream_events;
      })
