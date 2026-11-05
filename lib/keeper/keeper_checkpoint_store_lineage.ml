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
   stays the only watermark (RFC-0225 §3.2). A save keeps what it wrote, under
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
   Keepers share. Each Keeper has one: a save under a new trace drops the
   Keeper's older one, and unregistering the Keeper drops it
   ([forget_written_lineages]). *)
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
  }

let written_lineages : (string, written_lineage) Hashtbl.t = Hashtbl.create 16

(* Same discipline as [canonical_summaries_mutex]. *)
let written_lineages_mutex = Stdlib.Mutex.create ()

let same_lineage_owner left right =
  String.equal left.owner_session_root right.owner_session_root
  && String.equal left.owner_keeper right.owner_keeper

(* The key is the resolved [<session root>/<trace>/<trace>.json]. *)
let lineage_owner_of_key ~key ~keeper_name =
  { owner_session_root = Filename.dirname (Filename.dirname key); owner_keeper = keeper_name }

(* The memo of the file's lineage, or a fresh one for a file this process has
   not written. *)
let lineage_memo ~canonical_path =
  match summary_key canonical_path with
  | None -> Objects.create_memo ()
  | Some key ->
    Stdlib.Mutex.protect written_lineages_mutex (fun () ->
      match Hashtbl.find_opt written_lineages key with
      | Some lineage -> lineage.lineage_memo
      | None -> Objects.create_memo ())

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
    Stdlib.Mutex.protect written_lineages_mutex (fun () ->
      Hashtbl.filter_map_inplace
        (fun other lineage ->
           if (not (String.equal other key)) && same_lineage_owner lineage.lineage_owner owner
           then None
           else Some lineage)
        written_lineages;
      Hashtbl.replace written_lineages key
        { lineage_owner = owner; lineage_memo = memo; lineage_written })

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
  Stdlib.Mutex.protect written_lineages_mutex (fun () ->
    Hashtbl.filter_map_inplace
      (fun _key lineage -> if forgets lineage.lineage_owner then None else Some lineage)
      written_lineages)

(* The context is a mutable table, so each caller gets its own copy. *)
let handed_out (checkpoint : Agent_core.Checkpoint.t) =
  { checkpoint with context = Agent_core.Context.copy checkpoint.context }

(* [Some] only while the file has the identity it had when this process wrote
   or read it. A mismatch changes nothing here: a load that sampled the
   identity before a concurrent save's rename would otherwise drop the value
   that save just kept. The next save or save-bound load replaces a value
   whose file changed. *)
let reusable_written_value ~canonical_path ~identity =
  match summary_key canonical_path with
  | None -> None
  | Some key ->
    Stdlib.Mutex.protect written_lineages_mutex (fun () ->
      match Hashtbl.find_opt written_lineages key with
      | None | Some { lineage_written = None; _ } -> None
      | Some { lineage_written = Some written; _ } ->
        if canonical_identity_equal written.written_identity identity
        then Some written.written_checkpoint
        else None)
    |> Option.map handed_out

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
