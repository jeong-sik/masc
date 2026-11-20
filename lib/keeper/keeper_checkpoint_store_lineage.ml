module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_summary

(* ── Written value (RFC main-domain-scheduler-latency §8 P4b step 2) ──
   A turn used to start by reading and decoding the whole canonical file, and
   its first save encoded the whole history again because the decoded records
   were new. The live canonicals on 2026-10-17 were 60-214 MB; the 118 MB one
   took 0.9 s and 439 MB of allocation to decode.

   Per canonical file this process keeps a lineage: the encoding memo of its
   saves and the value the head and its objects hold, which is what a load
   gives for them -- the decode of the files, not a second truth, so the disk
   stays the only watermark. A save keeps what it wrote, under
   the identity of the head it wrote, taken from that file's descriptor
   ([Keeper_fs.save_encoded_durable_atomic_from]).
   [load_agent_core_for_save] keeps what it read, with the memo the load
   filled ([Agent_core.Checkpoint_objects.load]), so the first save after a
   restart or after another writer encodes only the new messages. A
   load answers from the value while the file still has its identity; another
   writer, a removal or a restart leaves a mismatch, and the load reads the
   file.

   A lineage holds the decoded history and its encodings as strings the major
   GC does not scan: 2.28x of the files in the 2026-10-17 harness, four 113 MB
   canonicals holding 1,031 MB after their turns. Only a Keeper's own saves
   and save-bound loads keep one, and they name the Keeper: a checkpoint's
   [agent_name] is the runtime the turn ran on ("agent_core-<runtime>"), which
   Keepers share. Each Keeper has at most one: a save under a new trace drops
   the Keeper's older one, unregistering the Keeper drops it
   ([forget_written_lineages]). [written_lineages] evicts the least recently
   used unpinned lineage when the combined canonical-head and memo-entry
   encoded byte weight exceeds [default_max_retained_lineage_bytes]. There is
   no production entry-count cap: many small active histories should not
   displace each other while their combined weight fits. This logical byte
   weight excludes decoded OCaml records and is not a process heap limit. *)
let default_max_retained_lineage_bytes = 128 * 1024 * 1024

type written_value =
  { written_identity : canonical_identity
  ; written_checkpoint : Agent_core.Checkpoint.t
  }

(* The Keeper a lineage belongs to: the session root its traces live under, as
   resolved, and its registry name. *)
type lineage_owner =
  { owner_session_root : string
  ; owner_keeper : string
  }

type written_lineage =
  { lineage_owner : lineage_owner
  ; lineage_memo : Objects.memo
  ; lineage_written : written_value option
  ; lineage_retained_bytes : int
  ; lineage_access_seq : int
  }

module String_map = Map.Make (String)

type lineage_state =
  { entries : written_lineage String_map.t
  ; in_flight : int String_map.t
  ; max_entries : int option
  ; max_bytes : int
  ; next_seq : int
  }

(* Lock-free immutable state swapped via CAS, safe across Eio fibers and pool
   domains without holding a lock across encoding or disk I/O. In-flight save
   paths pin their canonical key until the write settles so concurrent saves
   cannot evict an actively saving Keeper's memo mid-turn. *)
let written_lineages_state : lineage_state Atomic.t =
  Atomic.make
    { entries = String_map.empty
    ; in_flight = String_map.empty
    ; max_entries = None
    ; max_bytes = default_max_retained_lineage_bytes
    ; next_seq = 0
    }

let rec update_lineage_state f =
  let current = Atomic.get written_lineages_state in
  let next, output = f current in
  if Atomic.compare_and_set written_lineages_state current next
  then output
  else update_lineage_state f

let saturating_add left right =
  let left = max 0 left in
  let right = max 0 right in
  if right > max_int - left then max_int else left + right

let is_pinned state key =
  match String_map.find_opt key state.in_flight with
  | Some count -> count > 0
  | None -> false

let total_retained_bytes entries =
  String_map.fold
    (fun _key lineage total -> saturating_add total lineage.lineage_retained_bytes)
    entries
    0

let oldest_evictable_lineage_key state =
  String_map.fold
    (fun key lineage oldest ->
       if is_pinned state key
       then oldest
       else (
         match oldest with
         | None -> Some (key, lineage.lineage_access_seq)
         | Some (_oldest_key, oldest_seq) ->
           if lineage.lineage_access_seq < oldest_seq
           then Some (key, lineage.lineage_access_seq)
           else oldest))
    state.entries
    None
  |> Option.map fst

let rec evict_excess_lineages state =
  let count = String_map.cardinal state.entries in
  let over_count = Option.fold ~none:false ~some:(fun limit -> count > limit) state.max_entries in
  let over_bytes = count > 1 && total_retained_bytes state.entries > state.max_bytes in
  if over_count || over_bytes
  then (
    match oldest_evictable_lineage_key state with
    | None -> state
    | Some oldest_key ->
      evict_excess_lineages
        { state with entries = String_map.remove oldest_key state.entries })
  else state

let same_lineage_owner left right =
  String.equal left.owner_session_root right.owner_session_root
  && String.equal left.owner_keeper right.owner_keeper

(* The key is the resolved [<session root>/<trace>/<trace>.json]. *)
let lineage_owner_of_key ~key ~keeper_name =
  { owner_session_root = Filename.dirname (Filename.dirname key); owner_keeper = keeper_name }

let with_active_lineage ~canonical_path f =
  match summary_key canonical_path with
  | None -> f ()
  | Some key ->
    update_lineage_state (fun state ->
      let count = Option.value ~default:0 (String_map.find_opt key state.in_flight) in
      { state with in_flight = String_map.add key (count + 1) state.in_flight }, ());
    Fun.protect
      ~finally:(fun () ->
        update_lineage_state (fun state ->
          let in_flight =
            match String_map.find_opt key state.in_flight with
            | None | Some 1 -> String_map.remove key state.in_flight
            | Some count -> String_map.add key (max 1 (count - 1)) state.in_flight
          in
          evict_excess_lineages { state with in_flight }, ()))
      f

(* The memo of the file's lineage, or a fresh one for a file this process has
   not written. *)
let lineage_memo ~canonical_path =
  match summary_key canonical_path with
  | None -> Objects.create_memo ()
  | Some key ->
    update_lineage_state (fun state ->
      match String_map.find_opt key state.entries with
      | Some lineage ->
        let seq = state.next_seq + 1 in
        let entries =
          String_map.add key { lineage with lineage_access_seq = seq } state.entries
        in
        { state with entries; next_seq = seq }, Some lineage.lineage_memo
      | None -> state, None)
    |> function
    | Some memo -> memo
    | None -> Objects.create_memo ()

(* [written] is the value the files now hold, [None] when no value here
   describes them. *)
let keep_lineage ~canonical_path ~identity ~memo ~keeper_name written =
  match summary_key canonical_path with
  | None -> ()
  | Some key ->
    let owner = lineage_owner_of_key ~key ~keeper_name in
    let lineage_written =
      Option.map
        (fun written_checkpoint -> { written_identity = identity; written_checkpoint })
        written
    in
    let lineage_retained_bytes =
      saturating_add identity.size (Objects.memo_encoded_bytes memo)
    in
    update_lineage_state (fun state ->
      let entries =
        String_map.filter
          (fun other lineage ->
             String.equal other key
             || not (same_lineage_owner lineage.lineage_owner owner))
          state.entries
      in
      let lineage_access_seq = state.next_seq + 1 in
      let entries =
        String_map.add
          key
          { lineage_owner = owner
            ; lineage_memo = memo
            ; lineage_written
            ; lineage_retained_bytes
            ; lineage_access_seq
          }
          entries
      in
      evict_excess_lineages { state with entries; next_seq = lineage_access_seq }, ())

let forget_written_lineages ~session_root ~keeper_name =
  let forgets =
    match resolve_session_root session_root with
    | Ok resolved -> same_lineage_owner { owner_session_root = resolved; owner_keeper = keeper_name }
    | Error error ->
      (* A root this process never resolved and that no longer resolves --
         its directory was moved or removed before the unregistration --
         cannot name its lineages, so every lineage of this Keeper name goes.
         A root a save or a load resolved is named by that resolution, as its
         lineages' keys are. A lineage only spares a read: one
         dropped here for the same name in another workspace costs that
         workspace one read of its file. *)
      Log.Keeper.warn
        "checkpoint lineage: cannot resolve %s; forgetting every lineage of keeper=%s: %s"
        session_root
        keeper_name
        (Unix.error_message error);
      fun owner -> String.equal owner.owner_keeper keeper_name
  in
  update_lineage_state (fun state ->
    let entries =
      String_map.filter
        (fun _key lineage -> not (forgets lineage.lineage_owner))
        state.entries
    in
    { state with entries }, ())

(* The context is a mutable table, so each caller gets its own copy. *)
let handed_out (checkpoint : Agent_core.Checkpoint.t) =
  { checkpoint with context = Agent_core.Context.copy checkpoint.context }

(* [Some] only while the file has the identity it had when this process wrote
   or read it. A mismatch changes nothing here: a load that sampled the
   identity before a concurrent save's rename would otherwise drop the value
   that save just kept. The next save or save-bound load replaces a value
   whose file changed. *)
let find_reusable_written_value ~canonical_path ~identity =
  match summary_key canonical_path with
  | None -> None
  | Some key ->
    update_lineage_state (fun state ->
      match String_map.find_opt key state.entries with
      | None | Some { lineage_written = None; _ } -> state, None
      | Some ({ lineage_written = Some written; _ } as lineage) ->
        if canonical_identity_equal written.written_identity identity
        then (
          let seq = state.next_seq + 1 in
          let entries =
            String_map.add key { lineage with lineage_access_seq = seq } state.entries
          in
          { state with entries; next_seq = seq }, Some written.written_checkpoint)
        else state, None)

let reusable_written_value ~canonical_path ~identity =
  find_reusable_written_value ~canonical_path ~identity |> Option.map handed_out

let written_lineage_is_reusable ~canonical_path ~identity =
  find_reusable_written_value ~canonical_path ~identity |> Option.is_some

(* After a save-bound read: the lineage describes the bytes read only if the
   file identity is the same before and after the read, as for the summary. *)
let keep_read_lineage ~canonical_path ~identity_before ~memo ~keeper_name checkpoint =
  match identity_before, canonical_identity_opt canonical_path with
  | Some before, Some after when canonical_identity_equal before after ->
    keep_lineage
      ~canonical_path
      ~identity:before
      ~memo
      ~keeper_name
      (Some checkpoint)
  | Some _, (Some _ | None) | None, (Some _ | None) -> ()

let with_written_lineage_limits ~max_entries ~max_bytes f =
  let max_entries = Some (max 1 max_entries) in
  let max_bytes = max 0 max_bytes in
  let previous =
    update_lineage_state (fun state ->
      let prev = state.max_entries, state.max_bytes in
      evict_excess_lineages { state with max_entries; max_bytes }, prev)
  in
  Fun.protect
    ~finally:(fun () ->
      let prev_entries, prev_bytes = previous in
      update_lineage_state (fun state ->
        evict_excess_lineages
          { state with max_entries = prev_entries; max_bytes = prev_bytes }
        , ()))
    f
