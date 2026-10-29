(** Keeper_checkpoint_store — checkpoint file I/O.

    Handles saving, loading, listing, and pruning AGENT_CORE checkpoint JSON files
    within a session directory. Separated from [Keeper_working_context]
    so that file I/O concerns do not mix with context types and
    pure operations.

    @since keeper-ctx-split *)

open Printf

(* ================================================================ *)
(* AGENT_CORE Checkpoints                                                    *)
(* ================================================================ *)

let agent_core_checkpoint_path ~(session_dir : string) ~(session_id : string) =
  Filename.concat session_dir (session_id ^ ".json")

let agent_core_history_prefix = "agent-core-snapshot-"
let agent_core_history_suffix = ".json"

let before_history_link_hook : (unit -> unit) option Atomic.t = Atomic.make None

let archive_created_ms_of_filename (filename : string) : int option =
  let len = String.length filename in
  let prefix_len = String.length agent_core_history_prefix in
  let suffix_len = String.length agent_core_history_suffix in
  let created_ms_digits = 13 in
  if len <> prefix_len + created_ms_digits + suffix_len
     || not (String.starts_with ~prefix:agent_core_history_prefix filename)
     || not (String.ends_with ~suffix:agent_core_history_suffix filename)
  then None
  else
    let raw = String.sub filename prefix_len created_ms_digits in
    if String.for_all (fun char -> Char.compare char '0' >= 0 && Char.compare char '9' <= 0) raw
    then int_of_string_opt raw
    else None
;;

let is_agent_core_history_file ~(session_dir : string) (filename : string) : bool =
  let canonical_filename = Filename.basename session_dir ^ ".json" in
  (not (String.equal filename canonical_filename))
  && Option.is_some (archive_created_ms_of_filename filename)
;;

let list_agent_core_history_files ~(session_dir : string) : string list =
  if not (Fs_compat.file_exists session_dir) then []
  else
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Sys.readdir session_dir
      |> Array.to_list
      |> List.filter (is_agent_core_history_file ~session_dir)
      |> List.sort (fun a b -> compare b a))

(* Each entry is a copy of the head the canonical held (RFC-0476 §3.2), so it
   costs the head's bytes; the objects are shared. The only reader is the
   dashboard checkpoint list, which decodes every retained entry to describe
   it, so the count is also what that request costs.

   Disk and how far back an operator can look pull against each other, and
   which way to lean is theirs to say, so the window is the runtime setting
   [keeper.checkpoint_history_retained] rather than a number a deploy fixed.

   This store does not read it. A setting read can raise (its default is read
   from the environment), and in here it would raise inside the best-effort
   archive wrapper that swallows it, so the prune would stop without ever
   saying so. The caller reads the setting and passes the answer in; the
   stale-guard "raw Domain saves through Unix context" test saves from a raw
   Domain that way. *)

let agent_core_history_path ~(session_dir : string) ~(snapshot_id : string) =
  Filename.concat session_dir snapshot_id

(* A name below the session root ([leaf] of a session_dir, or a
   [snapshot_id] appended by [agent_core_history_path]) must denote exactly one
   directory entry. An empty, ".", ".." or separator-bearing name makes
   [Filename.concat parent name] (and the [^ ".checkpoint.lock"] sibling
   derived from a session location) resolve outside the session root, so
   every downstream consumer would inherit the escape. A NUL byte would
   truncate the path at the syscall boundary, so it is rejected here before
   any filesystem side effect. *)
let leaf_is_real_segment leaf =
  (not (String.equal leaf ""))
  && (not (String.equal leaf Filename.current_dir_name))
  && (not (String.equal leaf Filename.parent_dir_name))
  && not
       (String.exists
          (fun c -> String.contains Filename.dir_sep c || Char.equal c '\000')
          leaf)

(* Checkpoint payloads serialize to 0.7-1.4MB (see the [~pretty:false] note on
   [Keeper_fs.save_json_durable_atomic]). Encoding or decoding one on the
   calling fiber stalls every other fiber on the single-domain scheduler for
   the whole conversion (issue #25077; same class as the board_attention
   ledger re-parse hangs). Route the pure conversions through
   [Domain_pool_ref.submit_cpu_or_inline] — the typed CPU-weight policy layer
   keeper call sites are documented to prefer over the raw
   [Executor_pool_ref]; it re-raises job exceptions instead of rerunning the
   closure inline on failure, and falls back to inline execution for
   non-Eio callers itself (#25158) — the store is also reachable from raw
   Domains (see the stale-guard "raw Domain saves through Unix context"
   test). *)
let offload_checkpoint_cpu (f : unit -> 'a) : 'a =
  Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ f

module Objects = Agent_core.Checkpoint_objects

let head_of_bytes_off_scheduler (content : string) =
  offload_checkpoint_cpu (fun () -> Objects.head_of_string content)

(* The objects a head names are read and decoded in the same pool job as the
   head (RFC-0476 §3.5). [memo] then holds the loaded messages. *)
let decode_head_off_scheduler ~session_dir ~memo (content : string) :
    (Objects.head * Agent_core.Checkpoint.t, Objects.load_error) result =
  offload_checkpoint_cpu (fun () ->
    match Objects.head_of_string content with
    | Error _ as error -> error
    | Ok head ->
      Objects.load memo ~read_object:(Keeper_checkpoint_object_store.read ~session_dir) head
      |> Result.map (fun checkpoint -> head, checkpoint))

let agent_core_history_snapshot_id_of_checkpoint (ckpt : Agent_core.Checkpoint.t) : string =
  let created_ms = max 0 (int_of_float (ckpt.created_at *. 1000.0)) in
  Printf.sprintf "%s%013d%s"
    agent_core_history_prefix created_ms agent_core_history_suffix

let prune_agent_core_history ~(session_dir : string) ~(retained : int) : unit =
  let files = list_agent_core_history_files ~session_dir in
  if List.length files > retained then
    files
    |> List.filteri (fun index _ -> index >= retained)
    |> List.iter (fun filename ->
         let path = agent_core_history_path ~session_dir ~snapshot_id:filename in
         try
           Eio_guard.run_in_systhread ~label:"keeper.checkpoint.history.unlink"
             (fun () -> Sys.remove path)
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Log.Keeper.warn "AGENT_CORE snapshot cleanup failed for %s: %s"
               path (Printexc.to_string exn);
             Otel_metric_store.inc_counter
               Keeper_metrics.(to_string CheckpointFailures)
               ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_cleanup))]
               ())

let hardlink_agent_core_history_from_canonical
    ~(session_dir : string)
    ~(session_id : string)
    ~(snapshot_id : string) : (unit, string) result =
  let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
  let snapshot_path = agent_core_history_path ~session_dir ~snapshot_id in
  if not (Fs_compat.file_exists canonical_path) then
    Error "canonical AGENT_CORE checkpoint is missing"
  else
    try
      let snapshot_exists = Fs_compat.file_exists snapshot_path in
      Eio_guard.run_in_systhread ~label:"keeper.checkpoint.history.link" (fun () ->
        Option.iter (fun hook -> hook ()) (Atomic.get before_history_link_hook);
        if snapshot_exists then Sys.remove snapshot_path;
        Unix.link canonical_path snapshot_path);
      Ok ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Printexc.to_string exn)

(* A save-scoped capability is carried to each checkpoint payload writer. It
   observes the pieces actually submitted to a successful canonical write and
   the bytes submitted to a successful archive fallback. A failed archive can
   have a partial effect, so its observation is unknown. *)
module Checkpoint_payload_writer = struct
  type t = Unmeasured | Measured of (int option -> unit)

  let note capability observation =
    match capability with
    | Unmeasured -> ()
    | Measured observe -> observe observation

  let count_pieces pieces =
    List.fold_left (fun total piece ->
      match total with
      | Some bytes when String.length piece <= max_int - bytes -> Some (bytes + String.length piece)
      | Some _ | None -> None) (Some 0) pieces

  let canonical capability ~write ~ownership_root path encode =
    match capability with
    | Unmeasured -> write ~ownership_root path encode
    | Measured observe ->
      let submitted = ref None in
      let result = write ~ownership_root path (fun () ->
        let pieces = encode () in
        submitted := count_pieces pieces;
        pieces) in
      (match result with
       | Ok _ -> observe !submitted
       | Error _ -> ());
      result

  let archive capability path bytes =
    let result = Keeper_fs.save_atomic path bytes in
    (match result with
     | Ok () -> note capability (Some (String.length bytes))
     | Error _ -> note capability None);
    result
end

(* A window of zero keeps nothing, so this writes nothing: the prune would
   delete the entry again on the way out. When the hardlink fails, the head
   bytes are written as the entry instead. *)
let save_agent_core_history
    ~payload_writer ~(session_dir : string) ~(retained : int) ~head_bytes
    (ckpt : Agent_core.Checkpoint.t) : unit =
  if retained <= 0 then prune_agent_core_history ~session_dir ~retained
  else begin
  let snapshot_id = agent_core_history_snapshot_id_of_checkpoint ckpt in
  let save_snapshot_file () =
    Checkpoint_payload_writer.archive payload_writer
      (agent_core_history_path ~session_dir ~snapshot_id) head_bytes
  in
  let save_result =
    match
      hardlink_agent_core_history_from_canonical
        ~session_dir ~session_id:ckpt.session_id ~snapshot_id
    with
    | Ok () -> Ok ()
    | Error _ -> save_snapshot_file ()
  in
  match save_result with
  | Ok () ->
    prune_agent_core_history ~session_dir ~retained
  | Error msg ->
    Log.Keeper.warn "save_agent_core_history failed for %s: %s" snapshot_id msg;
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_save))]
      ()
  end

type history_delete_result =
  | History_deleted of string
  | History_missing of string
  | History_refused of string
  | History_removal_failed of string

let delete_agent_core_history_files ~(session_dir : string) ~(snapshot_ids : string list)
    : history_delete_result list =
  List.map
    (fun snapshot_id ->
      (* The dashboard supplies filenames. Both containment and the same
         archive identity used by listing/pruning must hold before unlink;
         other files in this session are not checkpoint history entries. *)
      if not
           (leaf_is_real_segment snapshot_id
            && is_agent_core_history_file ~session_dir snapshot_id)
      then History_refused snapshot_id
      else
      let path = agent_core_history_path ~session_dir ~snapshot_id in
      if Fs_compat.file_exists path then (
        try
          Sys.remove path;
          History_deleted snapshot_id
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Log.Keeper.warn "AGENT_CORE snapshot delete failed for %s: %s"
              path (Printexc.to_string exn);
            Otel_metric_store.inc_counter
              Keeper_metrics.(to_string CheckpointFailures)
              ~labels:[("site", Keeper_checkpoint_store_failure_site.(to_label Agent_core_delete))]
              ();
            History_removal_failed snapshot_id)
      else
        History_missing snapshot_id)
    snapshot_ids
;;

type checkpoint_read_failure =
  | Os_error of Unix.error
  | Changed_while_read
  | Read_raised

type checkpoint_load_error =
  | Not_found
  | Store_error of string
  | Parse_error of string
  (** A canonical this binary recognises as an earlier [checkpoint_version].
      Apart from [Parse_error] because the two need opposite answers: a
      superseded canonical is replaceable, a corrupt one is not. *)
  | Superseded_version of { expected : int; got : int }
  (** A canonical a *later* [checkpoint_version] wrote: an older binary is
      reading a newer workspace. Nothing here replaces or deletes it, because
      the newer binary can still read it. Only a writer that bumped the
      version is told apart this way (#38680). *)
  | Newer_version of { expected : int; got : int }
  | Io_error of string
  | Read_failed of { cause : checkpoint_read_failure; detail : string }
  (** Catch-all for agent-core errors outside the Io / Serialization families
      (Api / Agent / Mcp / Config / Orchestration / Internal).
      Distinct from Io_error so observers can tell a local
      checkpoint-store I/O failure apart from an agent-core failure that
      surfaced during a load. (#8605 family) *)
  | Agent_core_error of string
  | Objects_invalid of Objects.load_error
  (** The head names a message object or bundle that is missing, unreadable
      or not what the head says it is. *)

(* A missing checkpoint never reaches here: [read_checkpoint_bytes]'s typed
   owned-file read decides absence before agent core runs. Every
   [Agent_core.Error.t] seen here is a real I/O, serialization or agent-core
   fault, routed by its variant without reading detail strings, so there is
   no [Not_found] arm. The match names every variant, so a new one is a build
   error that forces a routing decision. *)
let classify_core_error (e : Agent_core.Error.t) : checkpoint_load_error =
  match e with
  | Io (FileOpFailed r) ->
      Io_error (sprintf "file %s failed on %s: %s" r.op r.path r.detail)
  | Io (ValidationFailed r) -> Store_error r.detail
  | Serialization (JsonParseError r) -> Parse_error r.detail
  | Serialization (StructuredOutputParseError _) ->
      Parse_error (Agent_core.Error.to_string e)
  | Serialization (StructuredOutputStateError _) ->
      Agent_core_error (Agent_core.Error.to_string e)
  | Serialization (VersionMismatch r) when r.got < r.expected ->
      Superseded_version { expected = r.expected; got = r.got }
  (* Only a writer that bumped [checkpoint_version] reaches this arm; a codec
     change shipped without a bump fails later in the decode, as a
     [JsonParseError] or [UnknownVariant] (#38680). *)
  | Serialization (VersionMismatch r) when r.got > r.expected ->
      Newer_version { expected = r.expected; got = r.got }
  | Serialization (VersionMismatch r) ->
      Parse_error (sprintf "version mismatch: expected %d, got %d" r.expected r.got)
  | Serialization (UnknownVariant r) ->
      Parse_error (sprintf "unknown variant %s: %s" r.type_name r.value)
  | Api _ | Provider _ | Agent _ | Mcp _ | Config _
  | Orchestration _ | Media _ | Internal _ | Internal_carried { message = _; _ } ->
      Agent_core_error (Agent_core.Error.to_string e)

let classify_objects_error : Objects.load_error -> checkpoint_load_error = function
  | Objects.Head_invalid detail -> Parse_error detail
  | Objects.Checkpoint_invalid error -> classify_core_error error
  | ( Objects.Object_missing _
    | Objects.Object_unreadable _
    | Objects.Object_digest_mismatch _
    | Objects.Bundle_invalid _
    | Objects.Turn_mismatch _
    | Objects.Message_invalid _
    | Objects.Segment_invalid _
    | Objects.Header_object_invalid _ ) as error -> Objects_invalid error

(* Both checkpoint reads take their bytes through
   [Fs_compat.load_owned_regular_file]: the read runs on a system thread when
   the Eio filesystem is active, and the file must sit inside the owned chain
   the writers publish into ([~ownership_root], the parent of the session
   directory), so a symbolic link or a changed parent is refused. Until
   2026-09-05 the bytes came through [Fs_compat.load_file], whose Eio branch
   ([Eio.Path.load]) copied the 13-35 MB file on the calling fiber and held
   the main domain 45-180 ms per turn — the [openat -> switch] class of RFC
   main-domain-scheduler-latency §8.8. *)
let read_checkpoint_bytes ~(session_dir : string) path : (string, checkpoint_load_error) result =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Filename.dirname session_dir)
      path
  with
  | Ok (Some bytes) -> Ok bytes
  | Ok None -> Error Not_found
  | Error error ->
    let detail = Fs_compat.owned_regular_file_read_error_to_string error in
    (match error.failure with
     | Fs_compat.Ownership_boundary_rejected _ | Fs_compat.Path_is_not_regular_file _
     | Fs_compat.Owned_path_owner_mismatch _
     | Fs_compat.Owned_path_writable_by_others _ ->
       Error (Io_error detail)
     | Fs_compat.Filesystem_identity_changed _ ->
       Error (Read_failed { cause = Changed_while_read; detail })
     | Fs_compat.Owned_file_operation_failed { cause = Unix.Unix_error (errno, _, _); _ } ->
       Error (Read_failed { cause = Os_error errno; detail })
     | Fs_compat.Owned_file_operation_failed _ ->
       Error (Read_failed { cause = Read_raised; detail }))

let load_agent_core_history_file ~(session_dir : string) ~(snapshot_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* [snapshot_id] reaches this entry point from the dashboard HTTP
     surface; a non-segment id ("../..") would read outside the session
     directory, so it is refused as absent before any filesystem access. *)
  if not (leaf_is_real_segment snapshot_id) then Error Not_found
  else (
    let path = agent_core_history_path ~session_dir ~snapshot_id in
    if Fs_compat.file_exists path then
      try
        match read_checkpoint_bytes ~session_dir path with
        | Error e -> Error e
        | Ok bytes ->
          (match decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) bytes with
           | Ok (_head, ckpt) -> Ok ckpt
           | Error e -> Error (classify_objects_error e))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Error (Io_error (Printexc.to_string exn))
    else Error Not_found)

(* ── Canonical summary (RFC main-domain-scheduler-latency §8 P4b) ────
   The scalars other paths need from the canonical checkpoint — session_id
   and turn_count for the save watermark, the message count for the
   heartbeat — are kept per canonical path together with the identity of the
   file they describe. Every writer publishes the canonical file by atomic
   rename, so a changed file is a new inode; equal (device, inode, size,
   mtime) therefore means the file the summary describes is still the one on
   disk. A summary is filled from a parse of the bytes on disk, or from the
   value a writer installed. Measured 2026-09-05: the save watermark alone
   re-read and re-parsed the canonical file on every turn, 5.2 GB allocated
   per 4 minutes across the fleet, and every heartbeat did the same for one
   integer. The whole value of a file this process wrote is kept under the
   same identity rule as [written_lineages] below, so a false match hands out
   a stale history, not one integer. A save therefore takes the identity from
   the file it wrote, never from the path afterwards. A writer that rewrites
   the file in place and keeps its size and mtime (touch -r, rsync -t) would
   still fool the rule (#43575). *)
type canonical_identity =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

(* Whether this process has seen every object a head names: it wrote them,
   or a load read them back against their digests. A head that was only
   parsed names objects nobody here has looked for, so a save checks that
   they are there before it names them again (RFC-0476 §3.3). Objects are
   never removed while a head names them, so a head seen once stays seen. *)
type head_objects =
  | Objects_seen
  | Objects_unchecked

type canonical_summary =
  { identity : canonical_identity
  ; summary_session_id : string
  ; summary_turn_count : int
  ; summary_message_count : int
  ; summary_head : Objects.head
  ; summary_objects : head_objects
  }

let canonical_summaries : (string, canonical_summary) Hashtbl.t = Hashtbl.create 16

(* Stdlib mutex on purpose: touched from systhread and main-domain paths; the
   critical section is a Hashtbl lookup with no yield. *)
let canonical_summaries_mutex = Stdlib.Mutex.create ()

let canonical_identity_equal left right =
  Int.equal left.device right.device
  && Int.equal left.inode right.inode
  && Int.equal left.size right.size
  && Float.equal left.mtime right.mtime

let canonical_identity_of_stats (stats : Unix.stats) =
  { device = stats.st_dev
  ; inode = stats.st_ino
  ; size = stats.st_size
  ; mtime = stats.st_mtime
  }

let canonical_identity_opt path =
  match Unix.stat path with
  | stats when stats.Unix.st_kind = Unix.S_REG -> Some (canonical_identity_of_stats stats)
  | _ -> None
  | exception Unix.Unix_error _ -> None

(* Summaries are keyed by the file's path under the resolved session root. A
   save reaches the canonical through [canonical_session_location], which
   resolves a symlinked session root, while a reader is handed the configured
   spelling of the same file; both spellings name one key. Only the root is
   resolved. [canonical_session_location] refuses a symbolic link at the
   session directory and the canonical readers refuse one at the file, so a
   path with a link below the root has a key no save publishes, and its
   reader goes to the file. An answer found under a key is used only while it
   carries the identity of the file at the caller's path.

   A lookup resolves a root once per spelling and remembers the answer.
   [Unix.realpath] on every lookup walked the whole path on the scheduler
   thread and took 399 of 2,112 samples of it on 2026-10-20. Every locked
   transaction resolves its root afresh ([canonical_session_location]) and
   records that answer for the spelling it was given, so a root re-pointed
   while the server runs moves the lookups and [forget_written_lineages]
   with the saves. A root that does not resolve is not remembered, so a
   lookup resolves it again once it exists, and until then a path under it
   has no key. *)
let resolved_session_roots : (string, string) Hashtbl.t = Hashtbl.create 4

(* Same discipline as [canonical_summaries_mutex]. *)
let resolved_session_roots_mutex = Stdlib.Mutex.create ()

(* The resolved spelling names itself, so a key built from a path a save
   resolved finds the same root. *)
let remember_session_root ~spelling resolved =
  Stdlib.Mutex.protect resolved_session_roots_mutex (fun () ->
    Hashtbl.replace resolved_session_roots spelling resolved;
    Hashtbl.replace resolved_session_roots resolved resolved)

let resolve_session_root root =
  match
    Stdlib.Mutex.protect resolved_session_roots_mutex (fun () ->
      Hashtbl.find_opt resolved_session_roots root)
  with
  | Some resolved -> Ok resolved
  | None ->
    (match Unix.realpath root with
     | resolved ->
       remember_session_root ~spelling:root resolved;
       Ok resolved
     | exception Unix.Unix_error (error, _, _) -> Error error)

let summary_key canonical_path =
  let session_dir = Filename.dirname canonical_path in
  match resolve_session_root (Filename.dirname session_dir) with
  | Ok root ->
    Some
      (Filename.concat
         (Filename.concat root (Filename.basename session_dir))
         (Filename.basename canonical_path))
  | Error (_ : Unix.error) -> None

(* [Some summary] only while the file at [canonical_path] is the one the
   summary was taken from. *)
let cached_summary ~canonical_path =
  match canonical_identity_opt canonical_path with
  | None -> None
  | Some identity ->
    (match summary_key canonical_path with
     | None -> None
     | Some key ->
       Stdlib.Mutex.protect canonical_summaries_mutex (fun () ->
         match Hashtbl.find_opt canonical_summaries key with
         | Some summary when canonical_identity_equal summary.identity identity ->
           Some summary
         | Some _ | None -> None))

let summary_of_head ~identity ~objects (head : Objects.head) =
  { identity
  ; summary_session_id = head.header.session_id
  ; summary_turn_count = head.header.turn_count
  ; summary_message_count = Objects.message_count head.history
  ; summary_head = head
  ; summary_objects = objects
  }

let publish_summary ~canonical_path summary =
  match summary_key canonical_path with
  | None -> ()
  | Some key ->
    Stdlib.Mutex.protect canonical_summaries_mutex (fun () ->
      Hashtbl.replace canonical_summaries key summary)

(* After a parse: the summary describes the bytes parsed only if the file
   identity is the same before and after the read. Otherwise a rename landed
   during the read and nothing is published; the next access reads again. *)
let publish_summary_after_parse ~canonical_path ~identity_before ~objects head =
  match identity_before, canonical_identity_opt canonical_path with
  | Some before, Some after when canonical_identity_equal before after ->
    publish_summary ~canonical_path (summary_of_head ~identity:before ~objects head)
  | Some _, (Some _ | None) | None, (Some _ | None) -> ()

(* After a durable atomic write under the session lock: the file at the path
   is the one just installed. *)
let publish_summary_after_write ~canonical_path head =
  match canonical_identity_opt canonical_path with
  | Some identity ->
    publish_summary ~canonical_path (summary_of_head ~identity ~objects:Objects_seen head);
    Some identity
  | None -> None

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

type read_use =
  | Read_only
  | Read_for_save of string  (** the Keeper that saves this lineage next *)

let load_agent_core_as ~read_use ~(session_dir : string) ~(session_id : string) :
    (Agent_core.Checkpoint.t, checkpoint_load_error) result =
  (* Absence comes from [read_checkpoint_bytes]'s typed owned-file read, not
     [file_exists], whose boolean also covers stat failures. An unreadable
     existing checkpoint must not become a fresh Keeper history.
     One read path for Eio and non-Eio contexts: [read_checkpoint_bytes]
     reads on a system thread when the fs capability is installed, and the
     decode is routed off the calling fiber (#25077). A [session_id] that is
     not one real path segment (empty, a separator, NUL) is a
     [Store_error]. *)
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
  let path = agent_core_checkpoint_path ~session_dir ~session_id in
  let identity_before = canonical_identity_opt path in
  match
    Option.bind identity_before (fun identity ->
      reusable_written_value ~canonical_path:path ~identity)
  with
  | Some checkpoint -> Ok checkpoint
  | None ->
    try
      match read_checkpoint_bytes ~session_dir path with
      | Error e -> Error e
      | Ok bytes ->
        let memo = Objects.create_memo () in
        (match decode_head_off_scheduler ~session_dir ~memo bytes with
         | Error e -> Error (classify_objects_error e)
         | Ok (head, ckpt) ->
           publish_summary_after_parse ~canonical_path:path ~identity_before ~objects:Objects_seen head;
           (match read_use with
            | Read_only -> Ok ckpt
            | Read_for_save keeper_name ->
              keep_read_lineage ~canonical_path:path ~identity_before ~memo ~keeper_name ckpt;
              Ok (handed_out ckpt)))
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Unix.Unix_error (errno, _, _) as exn ->
      Error (Read_failed { cause = Os_error errno; detail = Printexc.to_string exn })
    | exn -> Error (Read_failed { cause = Read_raised; detail = Printexc.to_string exn })

type turn_history =
  | Saved_history of Agent_core.Checkpoint.t
  | No_saved_history
  | Saved_history_superseded of { expected : int; got : int }

let turn_history_of_load = function
  | Ok checkpoint -> Ok (Saved_history checkpoint)
  | Error Not_found -> Ok No_saved_history
  | Error (Superseded_version { expected; got }) ->
    Ok (Saved_history_superseded { expected; got })
  | Error
      ( ( Store_error _
        | Parse_error _
        | Newer_version _
        | Io_error _
        | Read_failed _
        | Agent_core_error _
        | Objects_invalid _ ) as error ) -> Error error
;;

let load_agent_core ~session_dir ~session_id =
  load_agent_core_as ~read_use:Read_only ~session_dir ~session_id

let load_agent_core_for_save ~keeper_name ~session_dir ~session_id =
  load_agent_core_as ~read_use:(Read_for_save keeper_name) ~session_dir ~session_id

(** Message count of the canonical checkpoint. Answered from the canonical
    summary while the file on disk is the one the summary was taken from;
    otherwise the checkpoint is loaded and parsed once, which fills the
    summary. [Ok None] when there is no checkpoint. *)
let canonical_message_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.summary_message_count)
    | None ->
      (match load_agent_core ~session_dir ~session_id with
       | Ok checkpoint -> Ok (Some (List.length checkpoint.messages))
       | Error Not_found -> Ok None
       | Error
           (( Store_error _
            | Parse_error _
            | Superseded_version _
            | Newer_version _
            | Io_error _
            | Read_failed _
            | Agent_core_error _
            | Objects_invalid _ ) as error) -> Error error)

let canonical_byte_count ~(session_dir : string) ~(session_id : string)
  : (int option, checkpoint_load_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
    match cached_summary ~canonical_path with
    | Some summary -> Ok (Some summary.identity.size)
    | None ->
      (match Unix.stat canonical_path with
       | stats when stats.Unix.st_kind = Unix.S_REG -> Ok (Some stats.Unix.st_size)
       | _ -> Error (Store_error "canonical checkpoint is not a regular file")
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
       | exception Unix.Unix_error (code, _, _) ->
         Error
           (Store_error
              ("canonical checkpoint stat failed: " ^ Unix.error_message code)))

(* ── RFC-0225 §3.2: disk-SSOT monotonic checkpoint transaction ──────
   One stable per-session lock covers canonical disk load, comparison,
   durable publication, and history capture. The canonical file is the only
   admission watermark; no process-local checkpoint truth is retained. *)

type save_agent_core_relation = [ `Cold | `Forward | `Equal ]

type save_agent_core_outcome =
  | Saved of
      { relation : save_agent_core_relation
      ; turn_count : int
      ; canonical_bytes : int
      ; checkpoint : Agent_core.Checkpoint.t
      }
  | Stale_noop of { incoming_turn_count : int; known_turn_count : int }

let save_relation ~known ~incoming =
  match known with
  | None -> `Cold
  | Some previous when incoming > previous -> `Forward
  | Some _ -> `Equal

type unix_failure =
  { error : Unix.error
  ; operation : string
  ; argument : string
  }

type directory_failure =
  | Directory_unix_failure of unix_failure
  | Directory_other_failure of string
  | Directory_leaf_invalid of
      { session_dir : string
      ; leaf : string
      }

type save_agent_core_error =
  | Invalid_session_id of string
  | Session_directory_unavailable of directory_failure
  | Existing_checkpoint_unreadable of checkpoint_load_error
  | Checkpoint_unencodable of Agent_core.Error.t
      (** The checkpoint codec refused the messages or the fields around them,
          and dropping unencodable json did not give a copy it accepts. *)
  | Objects_write_failed of Keeper_checkpoint_object_store.write_error
  | Canonical_write_failed of Keeper_fs.durable_write_error
  | Transaction_lock_failed of File_lock_eio.durable_lock_error
  | Structurally_invalid of Keeper_transcript_unit.structural_error
      (** The messages do not satisfy the tool-protocol contract a reload has
          to replay. One of the three writers ran this check before calling
          here; the mid-run sink and finalize assembled their checkpoint
          directly and did not, so a broken history was admitted by the two
          hottest paths (#25561). The check belongs at the write boundary
          every writer passes through. *)

let checkpoint_load_error_to_string = function
  | Not_found -> "checkpoint not found"
  | Superseded_version { expected; got } ->
    Printf.sprintf
      "checkpoint version %d is superseded by %d" got expected
  | Newer_version { expected; got } ->
    Printf.sprintf
      "checkpoint version %d was written by a later binary; this one reads %d"
      got expected
  | Store_error detail
  | Parse_error detail
  | Io_error detail
  | Read_failed { detail; _ }
  | Agent_core_error detail -> detail
  | Objects_invalid error -> Objects.load_error_to_string error

let save_agent_core_error_to_string = function
  | Invalid_session_id reason -> reason
  | Session_directory_unavailable (Directory_unix_failure failure) ->
    Printf.sprintf "checkpoint session directory unavailable: %s(%s): %s"
      failure.operation failure.argument (Unix.error_message failure.error)
  | Session_directory_unavailable (Directory_other_failure detail) ->
    "checkpoint session directory unavailable: " ^ detail
  | Session_directory_unavailable (Directory_leaf_invalid { session_dir; leaf }) ->
    Printf.sprintf
      "checkpoint session directory rejected: leaf %S of %S is not a real \
       path segment"
      leaf session_dir
  | Existing_checkpoint_unreadable error ->
    "existing checkpoint unreadable: " ^ checkpoint_load_error_to_string error
  | Checkpoint_unencodable error ->
    "checkpoint cannot be encoded: " ^ Agent_core.Error.to_string error
  | Objects_write_failed error -> Keeper_checkpoint_object_store.write_error_to_string error
  | Canonical_write_failed error ->
    "canonical checkpoint write failed: "
    ^ Keeper_fs.durable_write_error_to_string error
  | Transaction_lock_failed error ->
    "checkpoint transaction lock failed: "
    ^ File_lock_eio.durable_lock_error_to_string error
  | Structurally_invalid error ->
    "checkpoint messages are structurally invalid: "
    ^ Keeper_transcript_unit.show_structural_error error

let canonical_session_location session_dir =
  (* Containment boundary for every checkpoint path (issue #25077).
     [Keeper_fs.save_json_durable_atomic ~ownership_root] already rejects
     escapes on the durable-write directory chain, but the lock file, history
     archive, and read paths consume this location without that guard, so the
     leaf is validated here once, before any filesystem side effect. The
     canonical parent is [Unix.realpath] of the *configured* session root:
     resolving a symlinked deployment root to its physical location is the
     purpose of this function, so the parent resolution itself is trusted.
     The leaf, however, must not be a symlink: a link there would redirect
     every checkpoint and lock write through whatever target it names
     ([Keeper_fs] applies the same symlink rejection to its own write
     chains). The lstat check shares the TOCTOU
     caveat documented on [Keeper_fs]: OCaml 5.4 has no portable
     dirfd-relative API, so the caller keeps the subtree process-owned. *)
  let leaf = Filename.basename session_dir in
  if not (leaf_is_real_segment leaf)
  then
    Error
      (Session_directory_unavailable
         (Directory_leaf_invalid { session_dir; leaf }))
  else (
    let parent = Filename.dirname session_dir in
    try
      Fs_compat.mkdir_p parent;
      let location =
        Eio_guard.run_in_systhread ~label:"checkpoint-parent-stat" (fun () ->
          let spelling = parent in
          let parent = Unix.realpath parent in
          if (Unix.stat parent).Unix.st_kind <> Unix.S_DIR
          then
            raise
              (Unix.Unix_error
                 (Unix.ENOTDIR, "checkpoint_session_parent", parent));
          remember_session_root ~spelling parent;
          let location = Filename.concat parent leaf in
          (match Unix.lstat location with
           | { Unix.st_kind = Unix.S_LNK; _ } ->
             raise
               (Unix.Unix_error
                  (Unix.ELOOP, "checkpoint_session_leaf", location))
           | { Unix.st_kind =
                 ( Unix.S_REG
                 | Unix.S_DIR
                 | Unix.S_CHR
                 | Unix.S_BLK
                 | Unix.S_FIFO
                 | Unix.S_SOCK )
             ; _
             } -> ()
           | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
          location)
      in
      Ok location
    with
    | Unix.Unix_error (error, operation, argument) ->
      Error
        (Session_directory_unavailable
           (Directory_unix_failure { error; operation; argument }))
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Session_directory_unavailable
           (Directory_other_failure (Printexc.to_string exn))))

let with_session_lock_typed ~session_dir f =
  match canonical_session_location session_dir with
  | Error _ as error -> error
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    (match File_lock_eio.with_durable_lock ~lock_path (fun () -> f session_dir) with
     | Ok result -> result
     | Error error -> Error (Transaction_lock_failed error))

let with_session_lock ~session_dir f =
  with_session_lock_typed ~session_dir (fun session_dir -> Ok (f session_dir))
  |> Result.map_error save_agent_core_error_to_string

let archive_agent_core_history_best_effort ~payload_writer ~session_dir ~retained ~head_bytes ckpt =
  try save_agent_core_history ~payload_writer ~session_dir ~retained ~head_bytes ckpt with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Checkpoint_payload_writer.note payload_writer None;
    Log.Keeper.warn "AGENT_CORE snapshot archive write failed for %s: %s"
      ckpt.session_id (Printexc.to_string exn);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CheckpointFailures)
      ~labels:
        [ ( "site"
          , Keeper_checkpoint_store_failure_site.(to_label Agent_core_archive) )
        ]
      ()

(* The bytes go into one allocation of the size the descriptor reports, and
   the identity returned is the descriptor's, so it names the file the bytes
   came from: the lineage reuse in [load_ref_locked] relies on that. The bytes
   are refused as changed while read when the descriptor is not the regular
   file [lstat] saw at the path, or when the file ends early, or when its
   identity moved during the read: the file was replaced or rewritten in
   place under the read, and the bytes are not one version of it. *)
let load_canonical_bytes_strict path =
  let unix_error error operation argument =
    Read_failed
      { cause = Os_error error
      ; detail = Printf.sprintf "%s(%s): %s"
          operation argument (Unix.error_message error)
      }
  in
  let changed_while_read () =
    Read_failed
      { cause = Changed_while_read
      ; detail = "canonical checkpoint changed while it was read: " ^ path
      }
  in
  let read_exact fd size =
    let bytes = Bytes.create size in
    let rec fill offset =
      if offset = size
      then Some (Bytes.unsafe_to_string bytes)
      else
        match Unix.read fd bytes offset (size - offset) with
        | 0 -> None
        | count -> fill (offset + count)
        | exception Unix.Unix_error (Unix.EINTR, _, _) -> fill offset
    in
    fill 0
  in
  let read () =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (error, operation, argument) ->
      Error (unix_error error operation argument)
    | stat when stat.Unix.st_kind <> Unix.S_REG ->
      Error (Io_error ("canonical checkpoint is not a regular file: " ^ path))
    | path_stats ->
      (try
         let fd = Unix.openfile path [ Unix.O_CLOEXEC; Unix.O_RDONLY ] 0 in
         Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
           let opened = Unix.fstat fd in
           if opened.Unix.st_kind <> Unix.S_REG
              || opened.Unix.st_dev <> path_stats.Unix.st_dev
              || opened.Unix.st_ino <> path_stats.Unix.st_ino
           then Error (changed_while_read ())
           else (
             let identity = canonical_identity_of_stats opened in
             match read_exact fd identity.size with
             | None -> Error (changed_while_read ())
             | Some content ->
               if canonical_identity_equal identity (canonical_identity_of_stats (Unix.fstat fd))
               then Ok (Some (identity, content))
               else Error (changed_while_read ())))
       with
       | Unix.Unix_error (error, operation, argument) ->
         Error (unix_error error operation argument))
  in
  match Eio_guard.run_in_systhread ~label:"checkpoint-read" read with
  | Ok content -> Ok content
  | Error _ as error -> error
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Io_error (Printexc.to_string exn))

(* What a save needs from the canonical: the head alone, no message object.
   From the summary while it describes the file, otherwise from a parse of
   the head, which publishes the summary. *)
type known_canonical =
  { known_session_id : string
  ; known_turn_count : int
  ; known_head : Objects.head
  ; known_objects : head_objects
  }

let known_of_summary summary =
  { known_session_id = summary.summary_session_id
  ; known_turn_count = summary.summary_turn_count
  ; known_head = summary.summary_head
  ; known_objects = summary.summary_objects
  }

(* The head on disk now, parsed, with the identity of the file read. *)
let parsed_canonical ~canonical_path
  : ((canonical_identity * Objects.head) option, checkpoint_load_error) result =
  match load_canonical_bytes_strict canonical_path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some (identity, content)) ->
    (match head_of_bytes_off_scheduler content with
     | Error error -> Error (classify_objects_error error)
     | Ok head -> Ok (Some (identity, head)))

let known_canonical ~canonical_path
  : (known_canonical option, checkpoint_load_error) result =
  match cached_summary ~canonical_path with
  | Some summary -> Ok (Some (known_of_summary summary))
  | None ->
    (match parsed_canonical ~canonical_path with
     | Error _ as error -> error
     | Ok None -> Ok None
     | Ok (Some (identity, head)) ->
       let summary = summary_of_head ~identity ~objects:Objects_unchecked head in
       publish_summary_after_parse
         ~canonical_path ~identity_before:(Some identity) ~objects:Objects_unchecked head;
       Ok (Some (known_of_summary summary)))

(* The segments before [head]'s last one and every segment's bundles, read
   from the last segment back, or the first segment that could not be read
   whole. *)
type segment_walk =
  | Segments_reached of Objects.digest list
  | Segment_unreachable of
      { digest : Objects.digest
      ; detail : string
      }

let walk_segments ~session_dir (head : Objects.head) =
  let rec walk reached = function
    | None -> Segments_reached (List.rev reached)
    | Some digest ->
      let unreachable detail = Segment_unreachable { digest; detail } in
      (match Keeper_checkpoint_object_store.read ~session_dir digest with
       | Error detail -> unreachable detail
       | Ok None -> unreachable "missing"
       | Ok (Some bytes)
         when not (String.equal (Objects.digest_of_bytes bytes :> string) (digest :> string)) ->
         unreachable "its bytes have another digest"
       | Ok (Some bytes) ->
         (match Objects.segment_of_string ~digest bytes with
          | Error error -> unreachable (Objects.load_error_to_string error)
          | Ok segment ->
            walk (List.rev_append (Objects.segment_objects segment) reached) segment.previous))
  in
  walk [] (Option.map (fun (segment : Objects.segment_ref) -> segment.segment) head.history.segment)

(* The objects the canonical names that the session does not hold. A head
   this process has seen whole names none; one only parsed is checked file
   by file, so the save that follows writes the missing ones again instead
   of naming them once more. An object missing behind the last segment
   cannot be written again in its place, so that segment is reported absent
   and the save does not keep it. *)
let absent_objects ~session_dir (known : known_canonical) =
  match known.known_objects with
  | Objects_seen -> []
  | Objects_unchecked ->
    let head = known.known_head in
    let missing digests =
      List.filter
        (fun digest -> not (Keeper_checkpoint_object_store.present ~session_dir digest))
        digests
    in
    let named = missing (Objects.head_objects head) in
    (match head.history.segment, walk_segments ~session_dir head with
     | None, (Segments_reached _ | Segment_unreachable _) -> named
     | Some last, Segment_unreachable _ -> last.segment :: named
     | Some last, Segments_reached reached ->
       (match missing reached with
        | [] -> named
        | _ :: _ -> last.segment :: named))

(* ── Judging and removing an undecodable canonical ([masc_keeper_clear]) ─
   A canonical no turn can decode fails every turn (#37089), and nothing the
   store writes may replace it. The operator's clear deletes it, so the next
   turn starts from no checkpoint.

   Only bytes that were read and then rejected by the decoder for their
   content are removed. A read that returned no bytes (an OS failure, a file
   that changed during the read, a path that is not a regular file inside the
   owned chain, a session id that is not a path segment) says nothing about
   the content. A canonical a build that bumped [checkpoint_version] wrote is
   readable by that build. Both stay. A later build that changed the codec
   without a bump is not told apart from damage and is removed (#38680). The step that stopped decides this, not the
   [checkpoint_load_error] label: other readers in this module report OS
   failures as [Io_error]. *)

type canonical_judgement =
  | Judged_absent
  | Judged_decoded of Agent_core.Checkpoint.t
  | Judged_superseded of { expected : int; got : int }
  | Judged_newer of { expected : int; got : int }
  | Judged_undecodable of checkpoint_load_error
  | Judged_inconclusive of checkpoint_load_error

(* The read and the decode [load_agent_core] takes, one step at a time so the
   step that stopped is known. *)
let judge_canonical ~(session_dir : string) ~(session_id : string) : canonical_judgement =
  let raised cause exn =
    Judged_inconclusive (Read_failed { cause; detail = Printexc.to_string exn })
  in
  if not (leaf_is_real_segment session_id) then
    Judged_inconclusive (Store_error "session_id is not a real path segment")
  else
    let path = agent_core_checkpoint_path ~session_dir ~session_id in
    match read_checkpoint_bytes ~session_dir path with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception (Unix.Unix_error (errno, _, _) as exn) -> raised (Os_error errno) exn
    | exception exn -> raised Read_raised exn
    | Error Not_found -> Judged_absent
    | Error
        (( Store_error _
         | Parse_error _
         | Superseded_version _
         | Newer_version _
         | Io_error _
         | Read_failed _
         | Agent_core_error _
         | Objects_invalid _ ) as error) -> Judged_inconclusive error
    | Ok bytes ->
      (match decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) bytes with
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn -> raised Read_raised exn
       | Ok (_head, checkpoint) -> Judged_decoded checkpoint
       (* An object the OS could not read says nothing about what it holds. *)
       | Error (Objects.Object_unreadable _ as error) -> Judged_inconclusive (Objects_invalid error)
       | Error
           (( Objects.Head_invalid _
            | Objects.Checkpoint_invalid _
            | Objects.Object_missing _
            | Objects.Object_digest_mismatch _
            | Objects.Bundle_invalid _
            | Objects.Turn_mismatch _
            | Objects.Message_invalid _
            | Objects.Segment_invalid _
            | Objects.Header_object_invalid _ ) as error) ->
         (match classify_objects_error error with
          | Superseded_version { expected; got } -> Judged_superseded { expected; got }
          | Newer_version { expected; got } -> Judged_newer { expected; got }
          | (Parse_error _ | Store_error _ | Objects_invalid _) as undecodable ->
            Judged_undecodable undecodable
          (* The decoder failed for a reason that is not the content. *)
          | (Not_found | Io_error _ | Read_failed _ | Agent_core_error _) as error ->
            Judged_inconclusive error))

type undecodable_removal_outcome =
  | Removed of { undecodable : checkpoint_load_error }
  | Canonical_absent
  | Canonical_loadable

type undecodable_removal_error =
  | Removal_refused of checkpoint_load_error
  | Removal_failed of string
  | Removal_durability_unknown of string

let undecodable_removal_error_to_string = function
  | Removal_refused error ->
    "the checkpoint was not removed, because reading it again did not show bytes whose content fails to decode: "
    ^ checkpoint_load_error_to_string error
  | Removal_failed detail -> "the undecodable checkpoint was not removed: " ^ detail
  | Removal_durability_unknown detail ->
    "the undecodable checkpoint was removed, but the directory sync failed: " ^ detail

let remove_undecodable_canonical ~(session_dir : string) ~(session_id : string)
  : (undecodable_removal_outcome, undecodable_removal_error) result =
  if not (leaf_is_real_segment session_id) then
    Error (Removal_failed "session_id is not a real path segment")
  else
    let locked =
      with_session_lock ~session_dir (fun session_dir ->
        let remove undecodable =
          let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
          let unlink_and_sync () =
            Unix.unlink canonical_path;
            match Keeper_fs_durable_directory.fsync_directory session_dir with
            | () -> Ok (Removed { undecodable })
            | exception ((Unix.Unix_error _ | Fun.Finally_raised _) as exn) ->
              Error (Removal_durability_unknown (Printexc.to_string exn))
          in
          match
            Eio_guard.run_in_systhread ~label:"keeper.checkpoint.remove-undecodable"
              unlink_and_sync
          with
          | result -> result
          | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
          | exception (Unix.Unix_error _ as exn) ->
            Error (Removal_failed (Printexc.to_string exn))
        in
        match judge_canonical ~session_dir ~session_id with
        | Judged_absent -> Ok Canonical_absent
        (* A turn starts from the first, and replaces the second on its first
           save. *)
        | Judged_decoded _ | Judged_superseded _ -> Ok Canonical_loadable
        | Judged_newer { expected; got } ->
          Error (Removal_refused (Newer_version { expected; got }))
        | Judged_inconclusive error -> Error (Removal_refused error)
        | Judged_undecodable undecodable -> remove undecodable)
    in
    match locked with
    | Ok result -> result
    | Error detail -> Error (Removal_failed detail)

type checkpoint_identity_error =
  | Session_id_invalid of string
  | Ref_create_failed of Keeper_checkpoint_ref.create_error

type checkpoint_ref_load_error =
  | Ref_not_found
  | Ref_read_failed of checkpoint_load_error
  | Ref_identity_invalid of checkpoint_identity_error
  | Ref_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; actual : Keeper_id.Trace_id.t
      }
  | Ref_lock_failed of string

let checkpoint_ref_create_error_to_string = function
  | Keeper_checkpoint_ref.Negative_turn_count value ->
    Printf.sprintf "negative turn count %d" value
  | Keeper_checkpoint_ref.Invalid_sha256 value ->
    Printf.sprintf "invalid checkpoint sha256 %S" value

let checkpoint_identity_error_to_string = function
  | Session_id_invalid detail -> "invalid session id: " ^ detail
  | Ref_create_failed error -> checkpoint_ref_create_error_to_string error

let checkpoint_ref_load_error_to_string = function
  | Ref_not_found -> "checkpoint not found"
  | Ref_read_failed error -> checkpoint_load_error_to_string error
  | Ref_identity_invalid error -> checkpoint_identity_error_to_string error
  | Ref_session_mismatch { expected; actual } ->
    Printf.sprintf
      "session mismatch expected=%s actual=%s"
      (Keeper_id.Trace_id.to_string expected)
      (Keeper_id.Trace_id.to_string actual)
  | Ref_lock_failed detail -> "checkpoint lock failed: " ^ detail

(* A canonical an earlier [checkpoint_version] wrote is the deliberate hard
   cut, not a failed read: the turn path starts fresh on it and the next save
   replaces it. A reader of the saved history takes the same answer, that
   there is no history this build reads, and settles on it. A keeper whose
   turns save no checkpoint (an official client) never replaces the file, so
   a reader that reported it as unreadable stopped on it at every pass for as
   long as the trace lasted (#44446). *)
module Saved_history = struct
  type 'a t =
    | Read of 'a
    | Superseded of { expected : int; got : int }

  (* The load failures without the cut, so a reader cannot be handed it as
     a failure. *)
  type error =
    | Not_found
    | Store_error of string
    | Parse_error of string
    | Newer_version of { expected : int; got : int }
    | Io_error of string
    | Read_failed of { cause : checkpoint_read_failure; detail : string }
    | Agent_core_error of string
    | Objects_invalid of Objects.load_error

  type ref_error =
    | Ref_not_found
    | Ref_read_failed of error
    | Ref_identity_invalid of checkpoint_identity_error
    | Ref_session_mismatch of
        { expected : Keeper_id.Trace_id.t
        ; actual : Keeper_id.Trace_id.t
        }
    | Ref_lock_failed of string
end

let saved_history = function
  | Ok value -> Ok (Saved_history.Read value)
  | Error (Superseded_version { expected; got }) ->
    Ok (Saved_history.Superseded { expected; got })
  | Error Not_found -> Error Saved_history.Not_found
  | Error (Store_error detail) -> Error (Saved_history.Store_error detail)
  | Error (Parse_error detail) -> Error (Saved_history.Parse_error detail)
  | Error (Newer_version { expected; got }) ->
    Error (Saved_history.Newer_version { expected; got })
  | Error (Io_error detail) -> Error (Saved_history.Io_error detail)
  | Error (Read_failed { cause; detail }) -> Error (Saved_history.Read_failed { cause; detail })
  | Error (Agent_core_error detail) -> Error (Saved_history.Agent_core_error detail)
  | Error (Objects_invalid error) -> Error (Saved_history.Objects_invalid error)

let saved_history_of_ref = function
  | Ok value -> Ok (Saved_history.Read value)
  | Error Ref_not_found -> Error Saved_history.Ref_not_found
  | Error (Ref_read_failed error) ->
    (match saved_history (Error error) with
     | Ok history -> Ok history
     | Error error -> Error (Saved_history.Ref_read_failed error))
  | Error (Ref_identity_invalid error) -> Error (Saved_history.Ref_identity_invalid error)
  | Error (Ref_session_mismatch { expected; actual }) ->
    Error (Saved_history.Ref_session_mismatch { expected; actual })
  | Error (Ref_lock_failed detail) -> Error (Saved_history.Ref_lock_failed detail)

let load_error_of_saved_history_error : Saved_history.error -> checkpoint_load_error = function
  | Saved_history.Not_found -> Not_found
  | Saved_history.Store_error detail -> Store_error detail
  | Saved_history.Parse_error detail -> Parse_error detail
  | Saved_history.Newer_version { expected; got } -> Newer_version { expected; got }
  | Saved_history.Io_error detail -> Io_error detail
  | Saved_history.Read_failed { cause; detail } -> Read_failed { cause; detail }
  | Saved_history.Agent_core_error detail -> Agent_core_error detail
  | Saved_history.Objects_invalid error -> Objects_invalid error

let saved_history_error_to_string error =
  checkpoint_load_error_to_string (load_error_of_saved_history_error error)

let saved_history_ref_error_to_string = function
  | Saved_history.Ref_not_found -> checkpoint_ref_load_error_to_string Ref_not_found
  | Saved_history.Ref_read_failed error -> saved_history_error_to_string error
  | Saved_history.Ref_identity_invalid error ->
    checkpoint_ref_load_error_to_string (Ref_identity_invalid error)
  | Saved_history.Ref_session_mismatch { expected; actual } ->
    checkpoint_ref_load_error_to_string (Ref_session_mismatch { expected; actual })
  | Saved_history.Ref_lock_failed detail ->
    checkpoint_ref_load_error_to_string (Ref_lock_failed detail)

type exact_checkpoint_snapshot =
  { checkpoint : Agent_core.Checkpoint.t
  ; reference : Keeper_checkpoint_ref.t
  }

let exact_snapshot_checkpoint snapshot = snapshot.checkpoint
let exact_snapshot_reference snapshot = snapshot.reference
let exact_snapshot_messages snapshot = snapshot.checkpoint.messages

type checkpoint_cas_error =
  | Source_unavailable of checkpoint_ref_load_error
  | Source_changed of Keeper_checkpoint_ref.t
  | Candidate_identity_invalid of checkpoint_identity_error
  | Candidate_session_mismatch of
      { expected : Keeper_id.Trace_id.t
      ; candidate : Keeper_id.Trace_id.t
      }
   | Candidate_turn_regressed of
       { source_turn : int
       ; candidate_turn : int
       }
   | Candidate_unencodable of Agent_core.Error.t
   | Candidate_content_mismatch of
       { reference : Keeper_checkpoint_ref.t
       ; content : string
       }
   | Objects_not_installed of Keeper_checkpoint_object_store.write_error
   | Commit_not_installed of Keeper_fs.durable_write_error

type checkpoint_installation_auxiliary =
  | Commit_durability_unknown of Keeper_fs.durable_write_error
  | Commit_observer_failed of Eio.Exn.with_bt
  | Release_process_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_unwind_interrupted of Eio.Exn.with_bt

type not_installed_checkpoint =
  { cause : checkpoint_cas_error
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type installed_checkpoint =
  { installed_ref : Keeper_checkpoint_ref.t
  ; auxiliary : checkpoint_installation_auxiliary list
  }

type checkpoint_installation =
  | Not_installed of not_installed_checkpoint
  | Installed of installed_checkpoint

let require_confirmed_installation installation =
  let auxiliary = match installation with
    | Installed installed -> installed.auxiliary
    | Not_installed refused -> refused.auxiliary in
  List.iter (function
    | Commit_observer_failed ((Eio.Cancel.Cancelled _ as cause), backtrace)
    | Post_commit_unwind_interrupted ((Eio.Cancel.Cancelled _ as cause), backtrace) ->
      Printexc.raise_with_backtrace cause backtrace
    | Commit_observer_failed _ | Post_commit_unwind_interrupted _
    | Commit_durability_unknown _ | Release_process_lock_failed _ -> ()) auxiliary;
  match installation with
  | Installed {installed_ref; auxiliary=[]} -> Ok installed_ref
  | (Installed {auxiliary=_::_; _} | Not_installed _) as unconfirmed -> Error unconfirmed

let not_installed cause = Not_installed { cause; auxiliary = [] }

let append_installation_auxiliary installation auxiliary =
  match installation with
  | Not_installed outcome ->
    Not_installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
  | Installed outcome ->
    Installed
      { outcome with
        auxiliary = outcome.auxiliary @ [ auxiliary ]
      }
;;

(* RFC-0476 §3.2: a reference names the checkpoint's content digest, which a
   value and every head written for it share. *)
let checkpoint_ref_of_content (content : Objects.digest) (checkpoint : Agent_core.Checkpoint.t) =
  match Keeper_id.Trace_id.of_string checkpoint.Agent_core.Checkpoint.session_id with
  | Error reason -> Error (Session_id_invalid reason)
  | Ok trace_id ->
    Keeper_checkpoint_ref.of_persisted
      ~trace_id
      ~turn_count:checkpoint.turn_count
      ~sha256:(content :> string)
    |> Result.map_error (fun error -> Ref_create_failed error)

let exact_snapshot_of_checkpoint ~expected_session_id ~content checkpoint =
  match checkpoint_ref_of_content content checkpoint with
  | Error error -> Error (Ref_identity_invalid error)
  | Ok reference
    when not
           (Keeper_id.Trace_id.equal
              expected_session_id reference.trace_id) ->
    Error
      (Ref_session_mismatch
         { expected = expected_session_id; actual = reference.trace_id })
  | Ok reference -> Ok { checkpoint; reference }
;;

let exact_snapshot_of_value ~expected_session_id checkpoint =
  offload_checkpoint_cpu (fun () ->
    match Objects.content_digest (Objects.create_memo ()) checkpoint with
    | Error error -> Error (Ref_read_failed (classify_core_error error))
    | Ok content -> exact_snapshot_of_checkpoint ~expected_session_id ~content checkpoint)
;;

let exact_snapshot_of_head_bytes ~session_dir ~expected_session_id head_bytes =
  match decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) head_bytes with
  | Error error -> Error (Ref_read_failed (classify_objects_error error))
  | Ok (head, checkpoint) ->
    exact_snapshot_of_checkpoint
      ~expected_session_id ~content:(Objects.head_content_digest head) checkpoint
;;

let load_ref_locked ~session_dir ~expected_session_id =
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match load_canonical_bytes_strict canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Error Ref_not_found
  | Ok (Some (identity_before, head_bytes)) ->
    (* A Keeper's lineage holds what a load gives for the head it wrote or
       read, under that file's identity, so the objects of a head of that
       identity are not read again. The head is read: the reference is its
       content digest. A Librarian pass reads the snapshot of its Keeper's
       current trace when it prepares and again when it commits. *)
    let decoded =
      match reusable_written_value ~canonical_path ~identity:identity_before with
      | Some checkpoint ->
        Result.map (fun head -> head, checkpoint) (head_of_bytes_off_scheduler head_bytes)
      | None -> decode_head_off_scheduler ~session_dir ~memo:(Objects.create_memo ()) head_bytes
    in
    (match decoded with
     | Error error -> Error (Ref_read_failed (classify_objects_error error))
     | Ok (head, checkpoint) ->
       (* Published from the lineage's value too. The save or load that kept
          it published this identity's summary, but an unlocked reader that
          parsed the file before it can have replaced that summary since, and
          the next save's watermark reads it. *)
       publish_summary_after_parse
         ~canonical_path
         ~identity_before:(Some identity_before)
         ~objects:Objects_seen
         head;
       exact_snapshot_of_checkpoint
         ~expected_session_id ~content:(Objects.head_content_digest head) checkpoint)

(* What the canonical file holds, against the reference a candidate claims to
   advance. *)
type canonical_source =
  | Source_absent
  | Source_is_expected
  | Source_is_other of Keeper_checkpoint_ref.t

(* RFC-0225 §3.2 admission: the reference is the content digest, which the
   head gives without a message object read (RFC-0476 §3.2), and its session
   and turn are the head's. The head is read and parsed under the lock every
   time, so a file rewritten in place under the summary's identity (#43575)
   cannot pass for the expected source. A head that does not parse refuses
   the write. *)
let canonical_source_locked
      ~session_dir
      ~(expected_source_ref : Keeper_checkpoint_ref.t)
  =
  let expected_session_id = expected_source_ref.trace_id in
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
  in
  match parsed_canonical ~canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Ok Source_absent
  | Ok (Some ((_ : canonical_identity), head)) ->
    (match Keeper_id.Trace_id.of_string head.header.session_id with
     | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
     | Ok trace_id when not (Keeper_id.Trace_id.equal trace_id expected_session_id) ->
       Error (Ref_session_mismatch { expected = expected_session_id; actual = trace_id })
     | Ok trace_id ->
       (match
          Keeper_checkpoint_ref.of_persisted
            ~trace_id
            ~turn_count:head.header.turn_count
            ~sha256:(Objects.head_content_digest head :> string)
        with
        | Error error -> Error (Ref_identity_invalid (Ref_create_failed error))
        | Ok reference ->
          Ok
            (if Keeper_checkpoint_ref.equal reference expected_source_ref
             then Source_is_expected
             else Source_is_other reference)))
;;

let with_agent_core_exact_snapshot ~session_dir ~session_id f =
  match Keeper_id.Trace_id.of_string session_id with
  | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
  | Ok expected_session_id ->
    (match
       with_session_lock ~session_dir (fun session_dir ->
         match load_ref_locked ~session_dir ~expected_session_id with
         | Error _ as error -> error
         | Ok snapshot -> Ok (f snapshot))
     with
     | Ok result -> result
     | Error detail -> Error (Ref_lock_failed detail))

let load_agent_core_exact_snapshot ~session_dir ~session_id =
  with_agent_core_exact_snapshot ~session_dir ~session_id Fun.id

(* Only an exact snapshot names its source. Its digest is the content digest
   of the head it read; its value, trace and turn are the load of that head,
   or a Keeper lineage's value for it under the identity rule [load_ref_locked]
   uses. Equal digests mean the canonical still holds that content, so the
   value the caller already holds is still the one a snapshot of the file
   would hand out. The comparison is the digest alone. *)
type exact_source = Keeper_checkpoint_ref.t

let exact_snapshot_source snapshot = snapshot.reference

type exact_snapshot_since =
  | Unchanged_source
  | Changed_source of exact_checkpoint_snapshot

(* A head read under the session lock whose content digest differs from a
   known source, kept with that digest so its load does not compute it
   again. *)
type changed_bytes =
  { changed_path : string
  ; changed_session_dir : string
  ; changed_identity_before : canonical_identity
  ; changed_session_id : Keeper_id.Trace_id.t
  ; changed_head : Objects.head
  ; changed_content : Objects.digest
  }

type exact_bytes_since =
  | Unchanged_bytes
  | Changed_bytes of changed_bytes

let read_since_locked ~session_dir ~(known : exact_source) =
  let canonical_path =
    agent_core_checkpoint_path
      ~session_dir
      ~session_id:(Keeper_id.Trace_id.to_string known.trace_id)
  in
  match load_canonical_bytes_strict canonical_path with
  | Error error -> Error (Ref_read_failed error)
  | Ok None -> Error Ref_not_found
  | Ok (Some (identity_before, head_bytes)) ->
    (match head_of_bytes_off_scheduler head_bytes with
     | Error error -> Error (Ref_read_failed (classify_objects_error error))
     | Ok head ->
       let content = Objects.head_content_digest head in
       if String.equal (content :> string) known.sha256
       then Ok Unchanged_bytes
       else
         Ok
           (Changed_bytes
              { changed_path = canonical_path
              ; changed_session_dir = session_dir
              ; changed_identity_before = identity_before
              ; changed_session_id = known.trace_id
              ; changed_head = head
              ; changed_content = content
              }))

(* As in [load_ref_locked]: the objects of a head whose identity a Keeper's
   lineage holds are not read again, and the lineage's value is handed out.
   The identity is the one the head was read under, so the answer does not
   depend on what the file holds when this runs, after the lock was released.
   The objects a head names do not change, so reading them now gives what
   they held then. That holds only while nothing removes them between the
   head's read under the lock and this decode after it; the object sweep
   (RFC-0476 §3.6) has to keep that true. *)
let decode_changed_bytes changed =
  let decoded =
    match
      reusable_written_value
        ~canonical_path:changed.changed_path
        ~identity:changed.changed_identity_before
    with
    | Some checkpoint -> Ok checkpoint
    | None ->
      offload_checkpoint_cpu (fun () ->
        Objects.load
          (Objects.create_memo ())
          ~read_object:(Keeper_checkpoint_object_store.read ~session_dir:changed.changed_session_dir)
          changed.changed_head)
  in
  match decoded with
  | Error error -> Error (Ref_read_failed (classify_objects_error error))
  | Ok (checkpoint : Agent_core.Checkpoint.t) ->
    publish_summary_after_parse
      ~canonical_path:changed.changed_path
      ~identity_before:(Some changed.changed_identity_before)
      ~objects:Objects_seen
      changed.changed_head;
    (match Keeper_id.Trace_id.of_string checkpoint.session_id with
     | Error reason -> Error (Ref_identity_invalid (Session_id_invalid reason))
     | Ok trace_id when not (Keeper_id.Trace_id.equal trace_id changed.changed_session_id) ->
       Error (Ref_session_mismatch { expected = changed.changed_session_id; actual = trace_id })
     | Ok trace_id ->
       (match
          Keeper_checkpoint_ref.of_persisted
            ~trace_id ~turn_count:checkpoint.turn_count
            ~sha256:(changed.changed_content :> string)
        with
        | Error error -> Error (Ref_identity_invalid (Ref_create_failed error))
        | Ok reference -> Ok { checkpoint; reference }))

let read_agent_core_exact_bytes_since ~session_dir ~known =
  match with_session_lock ~session_dir (fun session_dir -> read_since_locked ~session_dir ~known) with
  | Ok result -> result
  | Error detail -> Error (Ref_lock_failed detail)

let with_agent_core_exact_snapshot_since ~session_dir ~known f =
  match
    with_session_lock ~session_dir (fun session_dir ->
      match read_since_locked ~session_dir ~known with
      | Error _ as error -> error
      | Ok Unchanged_bytes -> Ok (f Unchanged_source)
      | Ok (Changed_bytes changed) ->
        Result.map (fun snapshot -> f (Changed_source snapshot)) (decode_changed_bytes changed))
  with
  | Ok result -> result
  | Error detail -> Error (Ref_lock_failed detail)

let load_agent_core_with_ref ~session_dir ~session_id =
  load_agent_core_exact_snapshot ~session_dir ~session_id
  |> Result.map (fun snapshot ->
    exact_snapshot_checkpoint snapshot, exact_snapshot_reference snapshot)
;;

let lock_failure_not_installed error =
  not_installed
    (Source_unavailable
       (Ref_lock_failed (File_lock_eio.durable_lock_error_to_string error)))
;;

let installation_of_lock_observation = function
  | File_lock_eio.Lock_not_acquired error -> lock_failure_not_installed error
  | File_lock_eio.Body_completed { value; release_error = None } -> value
  | File_lock_eio.Body_completed { value; release_error = Some error } ->
    append_installation_auxiliary value (Release_process_lock_failed error)
;;

let with_checkpoint_cas_lock ~session_dir f =
  match canonical_session_location session_dir with
  | Error error ->
    not_installed
      (Source_unavailable
         (Ref_lock_failed (save_agent_core_error_to_string error)))
  | Ok session_dir ->
    let lock_path = session_dir ^ ".checkpoint.lock" in
    File_lock_eio.with_durable_lock_observed
      ~lock_path
      (fun () -> f session_dir)
    |> installation_of_lock_observation

(* A plan's layout follows the canonical as it is when the plan is made
   (RFC-0476 §3.3), and writes again what that head names but the session
   does not hold. Objects are not removed while a head names them, so the
   plan stays valid when the canonical moves before a lock is taken; the
   source check under the lock decides whether it is installed. A canonical
   that cannot be read gives no layout to follow, and the source check then
   refuses the install. *)
let plan_for_session ~session_dir ~boundary (checkpoint : Agent_core.Checkpoint.t) =
  let known =
    if not (leaf_is_real_segment checkpoint.session_id)
    then None
    else (
      match
        known_canonical
          ~canonical_path:
            (agent_core_checkpoint_path ~session_dir ~session_id:checkpoint.session_id)
      with
      | Ok known -> known
      | Error (_ : checkpoint_load_error) -> None)
  in
  let previous = Option.map (fun known -> known.known_head) known in
  let absent = Option.fold ~none:[] ~some:(absent_objects ~session_dir) known in
  offload_checkpoint_cpu (fun () ->
    Objects.plan_save (Objects.create_memo ()) ?previous ~absent boundary checkpoint)

let install_plan_if_source
    ~require_absent
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~(on_checkpoint_commit_observer : Keeper_checkpoint_ref.t -> unit)
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    ~(candidate_ref : Keeper_checkpoint_ref.t)
    (plan : Objects.plan) =
    let expected_session_id = expected_source_ref.trace_id in
    let observed_ref = ref None in
    let committed_installation = ref None in
    (* Every path through here has installed the plan's head, so the file is
       the candidate: its summary is the plan's head, without reading the
       file back. *)
    let publish ~canonical_path auxiliary =
      ignore (publish_summary_after_write ~canonical_path plan.head : canonical_identity option);
      let installed = { installed_ref = candidate_ref; auxiliary } in
      committed_installation := Some installed;
      Installed installed
    in
    let observe_commit () =
      observed_ref := Some candidate_ref;
      on_checkpoint_commit_observer candidate_ref
    in
    let outcome =
      try
        `Returned
          (with_checkpoint_cas_lock ~session_dir (fun session_dir ->
         let source =
           match canonical_source_locked ~session_dir ~expected_source_ref with
           | Error error -> Error (Source_unavailable error)
           | Ok Source_absent ->
             if require_absent then Ok () else Error (Source_unavailable Ref_not_found)
           | Ok Source_is_expected ->
             if require_absent
             then Error (Source_changed expected_source_ref)
             else Ok ()
           | Ok (Source_is_other reference) -> Error (Source_changed reference)
         in
         match source with
         | Error error -> not_installed error
         | Ok () ->
           let canonical_path =
             agent_core_checkpoint_path
               ~session_dir
               ~session_id:(Keeper_id.Trace_id.to_string expected_session_id)
           in
           let ownership_root = Filename.dirname session_dir in
           (match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
            | Error error -> not_installed (Objects_not_installed error)
            | Ok (_ : int) ->
              (match
                 write_checkpoint_bytes
                   ~on_durable_commit:observe_commit
                   ~ownership_root
                   ~path:canonical_path
                   ~bytes:plan.head_bytes
               with
               | Error error when error.Keeper_fs.renamed ->
                 publish ~canonical_path [ Commit_durability_unknown error ]
               | Error error -> not_installed (Commit_not_installed error)
               | Ok Keeper_fs.Committed ->
                 (* The durable writer installs the plan's head verbatim, and
                    [candidate_ref] is that plan's content digest, so the
                    published file and the returned ref agree by
                    construction. The hint is auxiliary and cannot downgrade
                    that fact. *)
                 publish ~canonical_path []
               | Ok (Keeper_fs.Committed_but_observer_failed failure) ->
                 publish ~canonical_path [ Commit_observer_failed failure ]))))
      with
      | Eio.Cancel.Cancelled _ as cancelled ->
        Printexc.raise_with_backtrace cancelled (Printexc.get_raw_backtrace ())
      | exn -> `Raised (exn, Printexc.get_raw_backtrace ())
    in
    let observed_installation installed_ref =
      match !committed_installation with
      | Some installed -> installed
      | None -> { installed_ref; auxiliary = [] }
    in
    let known_installed_ref () =
      match !committed_installation with
      | Some installed -> Some installed.installed_ref
      | None -> !observed_ref
    in
    (match outcome with
     | `Returned installation -> installation
     | `Raised (exn, backtrace) ->
       (match known_installed_ref () with
        | Some installed_ref ->
          append_installation_auxiliary
            (Installed (observed_installation installed_ref))
            (Post_commit_unwind_interrupted (exn, backtrace))
        | None -> Printexc.raise_with_backtrace exn backtrace))

let save_agent_core_if_source_with
    ?(require_absent = false)
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~(on_checkpoint_commit_observer : Keeper_checkpoint_ref.t -> unit)
    ~session_dir
    ~(expected_source_ref : Keeper_checkpoint_ref.t)
    ~boundary
    (candidate : Agent_core.Checkpoint.t) =
  match plan_for_session ~session_dir ~boundary candidate with
  | Error error -> not_installed (Candidate_unencodable error)
  | Ok plan ->
    (match checkpoint_ref_of_content plan.content candidate with
     | Error error -> not_installed (Candidate_identity_invalid error)
     | Ok candidate_ref
       when not
              (Keeper_id.Trace_id.equal
                 expected_source_ref.trace_id candidate_ref.trace_id) ->
       not_installed
         (Candidate_session_mismatch
            { expected = expected_source_ref.trace_id
            ; candidate = candidate_ref.trace_id
            })
     | Ok candidate_ref
       when candidate_ref.turn_count < expected_source_ref.turn_count ->
       not_installed
         (Candidate_turn_regressed
            { source_turn = expected_source_ref.turn_count
            ; candidate_turn = candidate_ref.turn_count
            })
     | Ok candidate_ref ->
       install_plan_if_source
         ~require_absent ~with_checkpoint_cas_lock ~write_checkpoint_bytes
         ~on_checkpoint_commit_observer ~session_dir ~expected_source_ref ~candidate_ref plan)

let write_checkpoint_bytes
    ~on_durable_commit
    ~ownership_root
    ~path
    ~bytes =
  Keeper_fs.save_bytes_durable_atomic_observed
    ~on_durable_commit
    ~ownership_root
    path
    bytes
;;

let save_agent_core_if_source ~session_dir ~expected_source_ref ~boundary candidate =
  save_agent_core_if_source_with
    ~with_checkpoint_cas_lock
    ~write_checkpoint_bytes
    ~on_checkpoint_commit_observer:(fun _ -> ())
    ~session_dir
    ~expected_source_ref
    ~boundary
    candidate
;;

let save_agent_core_if_absent ~session_dir ~boundary candidate =
  match plan_for_session ~session_dir ~boundary candidate with
  | Error error -> not_installed (Candidate_unencodable error)
  | Ok plan ->
    (match checkpoint_ref_of_content plan.content candidate with
     | Error error -> not_installed (Candidate_identity_invalid error)
     | Ok candidate_ref ->
       install_plan_if_source
         ~require_absent:true ~with_checkpoint_cas_lock ~write_checkpoint_bytes
         ~on_checkpoint_commit_observer:(fun _ -> ())
         ~session_dir ~expected_source_ref:candidate_ref ~candidate_ref plan)
;;

(* Accepted continuations are not observational rolling history: nothing
   expires them while a semantic execution names them. Once a journal commit
   stops naming one, the Owner removes it through [release_retained];
   [Keeper_retained_checkpoint_sweep] removes, at server startup, what a crash
   or a failed removal left. *)
let retained_dirname = "accepted-checkpoints"

let retained_checkpoint_path ~session_dir (reference : Keeper_checkpoint_ref.t) =
  Filename.concat (Filename.concat session_dir retained_dirname)
    (reference.sha256 ^ ".json")

let read_retained_locked ~session_dir ~reference =
  match Fs_compat.load_owned_regular_file
          ~ownership_root:(Filename.dirname session_dir)
          (retained_checkpoint_path ~session_dir reference) with
  | Error error ->
      Error (Source_unavailable (Ref_read_failed
        (Store_error (Fs_compat.owned_regular_file_read_error_to_string error))))
  | Ok None -> Ok None
  | Ok (Some bytes) ->
      (match exact_snapshot_of_head_bytes ~session_dir
               ~expected_session_id:reference.Keeper_checkpoint_ref.trace_id bytes with
       | Error error -> Error (Source_unavailable error)
       | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference ->
           Ok (Some snapshot)
       | Ok snapshot -> Error (Source_changed snapshot.reference))

let load_retained_exact_snapshot ~session_dir ~reference =
  match with_session_lock ~session_dir (fun session_dir ->
    match read_retained_locked ~session_dir ~reference with
    | Error _ as error -> error
    | Ok None -> Error (Source_unavailable Ref_not_found)
    | Ok (Some snapshot) -> Ok snapshot) with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

type retained_snapshot =
  | Retained_current of exact_checkpoint_snapshot
  | Retained_superseded of
      { reference : Keeper_checkpoint_ref.t
      ; expected_version : int
      ; got_version : int
      ; pending_input : Agent_core.Agent_input_request.pending option
      }

let decode_superseded_retained_bytes
    ~(reference : Keeper_checkpoint_ref.t)
    ~expected
    ~got
    bytes =
  let parse_error detail =
    Error (Source_unavailable (Ref_read_failed (Parse_error detail)))
  in
  let actual_sha256 =
    offload_checkpoint_cpu (fun () ->
      Keeper_checkpoint_ref.sha256_of_canonical_bytes bytes)
  in
  if not (String.equal actual_sha256 reference.sha256)
  then parse_error "superseded retained checkpoint digest mismatch"
  else (
    match offload_checkpoint_cpu (fun () -> Yojson.Safe.from_string bytes) with
    | exception Yojson.Json_error detail -> parse_error detail
    | `Assoc fields ->
      let unique_field name =
        match
          List.filter_map
            (fun (key, value) -> if String.equal key name then Some value else None)
            fields
        with
        | [ value ] -> Some value
        | [] | _ :: _ :: _ -> None
      in
      let session_id_opt =
        match unique_field "session_id" with
        | Some (`String session_id) -> Some session_id
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _)
        | None -> None
      in
      let turn_count_opt =
        match unique_field "turn_count" with
        | Some (`Int turn_count) -> Some turn_count
        | Some (`Null | `Bool _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> None
      in
      (match session_id_opt, turn_count_opt with
       | Some session_id, Some turn_count ->
         (match Keeper_id.Trace_id.of_string session_id with
          | Error reason ->
            Error
              (Source_unavailable
                 (Ref_identity_invalid (Session_id_invalid reason)))
          | Ok actual_trace_id
            when not (Keeper_id.Trace_id.equal actual_trace_id reference.trace_id) ->
            Error
              (Source_unavailable
                 (Ref_session_mismatch
                    { expected = reference.trace_id; actual = actual_trace_id }))
          | Ok _ ->
            if turn_count <> reference.turn_count
            then
              match
                Keeper_checkpoint_ref.of_persisted
                  ~trace_id:reference.trace_id
                  ~turn_count
                  ~sha256:actual_sha256
              with
              | Ok actual_ref -> Error (Source_changed actual_ref)
              | Error error ->
                Error
                  (Source_unavailable
                     (Ref_identity_invalid (Ref_create_failed error)))
            else (
              let pending_result =
                match
                  List.filter_map
                    (fun (key, value) ->
                       if String.equal key "pending_input" then Some value else None)
                    fields
                with
                | [] | [ `Null ] -> Ok None
                | [ value ] ->
                  Agent_core.Agent_input_request.pending_of_json value
                  |> Result.map Option.some
                | _ :: _ :: _ ->
                  Error "duplicate pending_input field in superseded checkpoint"
              in
              match pending_result with
              | Error detail -> parse_error detail
              | Ok pending_input ->
                Ok
                  (Retained_superseded
                     { reference
                     ; expected_version = expected
                     ; got_version = got
                     ; pending_input
                     })))
       | None, (Some _ | None) | Some _, None ->
         parse_error
           "superseded retained checkpoint is missing canonical session_id or turn_count")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      parse_error "superseded retained checkpoint must be a JSON object")

let read_retained_snapshot_locked ~session_dir ~reference =
  match
    Fs_compat.load_owned_regular_file
      ~ownership_root:(Filename.dirname session_dir)
      (retained_checkpoint_path ~session_dir reference)
  with
  | Error error ->
    Error
      (Source_unavailable
         (Ref_read_failed
            (Store_error (Fs_compat.owned_regular_file_read_error_to_string error))))
  | Ok None -> Error (Source_unavailable Ref_not_found)
  | Ok (Some bytes) ->
    (match
       exact_snapshot_of_head_bytes
         ~session_dir
         ~expected_session_id:reference.Keeper_checkpoint_ref.trace_id
         bytes
     with
     | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference ->
       Ok (Retained_current snapshot)
     | Ok snapshot -> Error (Source_changed snapshot.reference)
     | Error (Ref_read_failed (Superseded_version { expected; got })) ->
       decode_superseded_retained_bytes ~reference ~expected ~got bytes
     | Error
         ( Ref_read_failed
             ( Not_found
             | Newer_version _
             | Parse_error _
             | Store_error _
             | Io_error _
             | Read_failed _
             | Agent_core_error _
             | Objects_invalid _ )
         | Ref_not_found
         | Ref_identity_invalid _
         | Ref_session_mismatch _
         | Ref_lock_failed _ as error ) -> Error (Source_unavailable error))

let load_retained_snapshot ~session_dir ~reference =
  match
    with_session_lock ~session_dir (fun session_dir ->
      read_retained_snapshot_locked ~session_dir ~reference)
  with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

let find_exact_snapshot_for_retention ~session_dir ~reference =
  let unavailable detail = Source_unavailable (Ref_read_failed (Io_error detail)) in
  match with_session_lock ~session_dir (fun session_dir ->
    match read_retained_locked ~session_dir ~reference with
    | Ok (Some snapshot) -> Ok snapshot
    | Error _ as error -> error
    | Ok None ->
      Cancel_safe.protect ~on_exn:(fun exn -> Error (unavailable (Printexc.to_string exn))) (fun () ->
        let paths = agent_core_checkpoint_path ~session_dir
          ~session_id:(Keeper_id.Trace_id.to_string reference.Keeper_checkpoint_ref.trace_id)
          :: (list_agent_core_history_files ~session_dir |> List.map (Filename.concat session_dir)) in
        let rec find = function
          | [] -> Error (Source_unavailable Ref_not_found)
          | path :: rest ->
            (match Fs_compat.load_owned_regular_file ~ownership_root:(Filename.dirname session_dir) path with
             | Error error -> Error (unavailable (Fs_compat.owned_regular_file_read_error_to_string error))
             | Ok None -> find rest
             | Ok (Some bytes) ->
               (* A head names its content digest without an object read, so
                  only the head that names this reference is loaded. *)
               (match head_of_bytes_off_scheduler bytes with
                | Error (_ : Objects.load_error) -> find rest
                | Ok head
                  when not (String.equal (Objects.head_content_digest head :> string) reference.sha256) ->
                  find rest
                | Ok _ ->
                  (match exact_snapshot_of_head_bytes ~session_dir ~expected_session_id:reference.trace_id bytes with
                   | Error error -> Error (Source_unavailable error)
                   | Ok snapshot when Keeper_checkpoint_ref.equal reference snapshot.reference -> Ok snapshot
                   | Ok snapshot -> Error (Source_changed snapshot.reference)))) in
        find paths)) with
  | Ok result -> result
  | Error detail -> Error (Source_unavailable (Ref_lock_failed detail))

let retain_exact_snapshot_with ~write_checkpoint_bytes ~session_dir snapshot =
  let installed = ref None in
  let publish auxiliary =
    let value = { installed_ref = snapshot.reference; auxiliary } in
    installed := Some value;
    Installed value
  in
  (* This observer runs after all fsyncs but before pending cancellation. It
     preserves the committed fact if cancellation interrupts the lock unwind. *)
  let observe_commit () =
    installed := Some { installed_ref = snapshot.reference; auxiliary = [] }
  in
  let recover_unwind exn backtrace =
    match !installed with
    | None -> Printexc.raise_with_backtrace exn backtrace
    | Some value -> Installed
        { value with auxiliary = value.auxiliary @
            [Post_commit_unwind_interrupted (exn, backtrace)] }
  in
  try
    with_checkpoint_cas_lock ~session_dir (fun session_dir ->
      match read_retained_locked ~session_dir ~reference:snapshot.reference with
      | Error cause -> not_installed cause
      | Ok (None | Some _) ->
          (* The retained head shares the canonical's objects; its open
             messages are written as objects of their own. *)
          match plan_for_session ~session_dir ~boundary:Objects.Turn_continues snapshot.checkpoint with
          | Error error -> not_installed (Candidate_unencodable error)
          | Ok plan when not (String.equal (plan.content :> string) snapshot.reference.sha256) ->
              not_installed
                (Candidate_content_mismatch
                   { reference = snapshot.reference; content = (plan.content :> string) })
          | Ok plan ->
          match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
          | Error error -> not_installed (Objects_not_installed error)
          | Ok (_ : int) ->
          match write_checkpoint_bytes
                  ~on_durable_commit:observe_commit
                  ~ownership_root:(Filename.dirname session_dir)
                  ~path:(retained_checkpoint_path ~session_dir snapshot.reference)
                  ~bytes:plan.head_bytes with
          | Error error when error.Keeper_fs.renamed ->
              publish [Commit_durability_unknown error]
          | Error error -> not_installed (Commit_not_installed error)
          | Ok Keeper_fs.Committed -> publish []
          | Ok (Keeper_fs.Committed_but_observer_failed failure) ->
              publish [Commit_observer_failed failure])
  with
  | Eio.Cancel.Cancelled _ as exn ->
      recover_unwind exn (Printexc.get_raw_backtrace ())
  | exn -> recover_unwind exn (Printexc.get_raw_backtrace ())

let retain_exact_snapshot ~session_dir snapshot =
  retain_exact_snapshot_with ~write_checkpoint_bytes ~session_dir snapshot

(* A snapshot written as a head another store keeps (a Gate preparation),
   with the objects it names durable in the session first. *)
type persist_error =
  | Persist_session_unavailable of string
  | Persist_unencodable of Agent_core.Error.t
  | Persist_content_mismatch of
      { reference : Keeper_checkpoint_ref.t
      ; content : string
      }
  | Persist_objects_failed of Keeper_checkpoint_object_store.write_error

let persist_error_to_string = function
  | Persist_session_unavailable detail -> "checkpoint session unavailable: " ^ detail
  | Persist_unencodable error -> "checkpoint cannot be encoded: " ^ Agent_core.Error.to_string error
  | Persist_content_mismatch { reference; content } ->
    Printf.sprintf "checkpoint content %s does not match its reference %s" content reference.sha256
  | Persist_objects_failed error -> Keeper_checkpoint_object_store.write_error_to_string error

let persist_exact_snapshot ~session_dir snapshot =
  match
    with_session_lock ~session_dir (fun session_dir ->
      match plan_for_session ~session_dir ~boundary:Objects.Turn_continues snapshot.checkpoint with
      | Error error -> Error (Persist_unencodable error)
      | Ok plan when not (String.equal (plan.content :> string) snapshot.reference.sha256) ->
        Error
          (Persist_content_mismatch
             { reference = snapshot.reference; content = (plan.content :> string) })
      | Ok plan ->
        (match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
         | Error error -> Error (Persist_objects_failed error)
         | Ok (_ : int) -> Ok plan.head_bytes))
  with
  | Ok result -> result
  | Error detail -> Error (Persist_session_unavailable detail)

(* A copy of the canonical head and every object it names, laid out as the
   session holds them, so copying the backup over the session directory puts
   the checkpoint back (docs/CHECKPOINT-PURGE-RUNBOOK.md). *)
type canonical_backup =
  { backup_head : string
  ; backup_bytes : int
  }

type backup_error =
  | Backup_canonical_unreadable of checkpoint_load_error
  | Backup_canonical_absent
  | Backup_content_changed of
      { expected : string
      ; actual : string
      }
  | Backup_object_unreadable of
      { digest : string
      ; detail : string
      }
  | Backup_file_conflict of string
  | Backup_write_failed of
      { path : string
      ; error : Keeper_fs.durable_write_error
      }
  | Backup_read_back_mismatch of string

let backup_error_to_string = function
  | Backup_canonical_unreadable error -> checkpoint_load_error_to_string error
  | Backup_canonical_absent -> "no canonical checkpoint to back up"
  | Backup_content_changed { expected; actual } ->
    Printf.sprintf "the canonical checkpoint is %s, not the source %s" actual expected
  | Backup_object_unreadable { digest; detail } ->
    Printf.sprintf "checkpoint object %s cannot be backed up: %s" digest detail
  | Backup_file_conflict path -> path ^ " already holds other bytes"
  | Backup_write_failed { path; error } ->
    Printf.sprintf "%s: %s" path (Keeper_fs.durable_write_error_to_string error)
  | Backup_read_back_mismatch path -> path ^ " does not read back as written"

let back_up_canonical ~session_dir ~session_id ~ownership_root ~backup_dir ~content =
  (* A file already in the backup is kept when it holds these bytes, so a
     retried backup of one checkpoint succeeds. *)
  let copy ~path bytes =
    match Fs_compat.load_file_opt path with
    | Some existing when String.equal existing bytes -> Ok ()
    | Some _ -> Error (Backup_file_conflict path)
    | None ->
      (match Keeper_fs.save_bytes_durable_atomic ~ownership_root path bytes with
       | Error error -> Error (Backup_write_failed { path; error })
       | Ok () ->
         (match Fs_compat.load_file_opt path with
          | Some written when String.equal written bytes -> Ok ()
          | Some _ | None -> Error (Backup_read_back_mismatch path)))
  in
  let rec copy_objects total = function
    | [] -> Ok total
    | (digest : Objects.digest) :: rest ->
      let unreadable detail =
        Error (Backup_object_unreadable { digest = (digest :> string); detail })
      in
      (match Keeper_checkpoint_object_store.read ~session_dir digest with
       | Error detail -> unreadable detail
       | Ok None -> unreadable "missing"
       | Ok (Some bytes)
         when not (String.equal (Objects.digest_of_bytes bytes :> string) (digest :> string)) ->
         unreadable "its bytes have another digest"
       | Ok (Some bytes) ->
         (match
            copy ~path:(Keeper_checkpoint_object_store.path ~session_dir:backup_dir digest) bytes
          with
          | Error _ as error -> error
          | Ok () -> copy_objects (total + String.length bytes) rest))
  in
  if not (leaf_is_real_segment session_id)
  then Error (Backup_canonical_unreadable (Store_error "session_id is not a real path segment"))
  else (
    match load_canonical_bytes_strict (agent_core_checkpoint_path ~session_dir ~session_id) with
    | Error error -> Error (Backup_canonical_unreadable error)
    | Ok None -> Error Backup_canonical_absent
    | Ok (Some ((_ : canonical_identity), head_bytes)) ->
      (match head_of_bytes_off_scheduler head_bytes with
       | Error error -> Error (Backup_canonical_unreadable (classify_objects_error error))
       | Ok head ->
         let actual = (Objects.head_content_digest head :> string) in
         if not (String.equal actual content)
         then Error (Backup_content_changed { expected = content; actual })
         else (
           (* The objects first, then the head that names them. *)
           match walk_segments ~session_dir head with
           | Segment_unreachable { digest; detail } ->
             Error (Backup_object_unreadable { digest = (digest :> string); detail })
           | Segments_reached reached ->
           match copy_objects 0 (Objects.head_objects head @ reached) with
           | Error _ as error -> error
           | Ok object_bytes ->
             let backup_head = agent_core_checkpoint_path ~session_dir:backup_dir ~session_id in
             (match copy ~path:backup_head head_bytes with
              | Error _ as error -> error
              | Ok () -> Ok { backup_head; backup_bytes = object_bytes + String.length head_bytes }))))

type release_failure =
  | Lock_held_elsewhere
  | Release_failed of string

let release_retained ~session_root released =
  let reference = Keeper_chat_operation_store.released_reference released in
  let unlink session_dir =
    let retained_dir = Filename.concat session_dir retained_dirname in
    let path = retained_checkpoint_path ~session_dir reference in
    let unlink () =
      match Fs_compat.inspect_owned_directory_chain
              ~ownership_root:(Filename.dirname session_dir) retained_dir with
      | Error rejection -> Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
      | Ok Fs_compat.Owned_directory_missing -> Ok ()
      | Ok (Fs_compat.Owned_directory _) ->
        (match Unix.lstat path with
         | { Unix.st_kind = Unix.S_REG; _ } -> Unix.unlink path; Ok ()
         | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
                            | Unix.S_FIFO | Unix.S_SOCK) as kind; _ } ->
           Error (Printf.sprintf "%s is a %s, not a retained checkpoint"
                    path (Fs_compat.file_kind_to_string kind))
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ())
    in
    match Eio_guard.run_in_systhread ~label:"keeper.checkpoint.retained.release" unlink with
    | result -> result
    | exception (Unix.Unix_error _ as exn) -> Error (Printexc.to_string exn)
  in
  let session_dir = Keeper_chat_operation_store.released_session_dir ~session_root released in
  match canonical_session_location session_dir with
  | Error error -> Error (Release_failed (save_agent_core_error_to_string error))
  | Ok session_dir ->
    (* The same lock file retention and exact reads take, tried once. *)
    match File_lock_eio.try_with_durable_lock_observed
            ~lock_path:(session_dir ^ ".checkpoint.lock") (fun () -> unlink session_dir) with
    | File_lock_eio.Lock_held_elsewhere -> Error Lock_held_elsewhere
    | File_lock_eio.Lock_attempted (File_lock_eio.Lock_not_acquired error) ->
      Error (Release_failed (File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Lock_attempted (File_lock_eio.Body_completed { value = Error detail; _ }) ->
      Error (Release_failed detail)
    | File_lock_eio.Lock_attempted
        (File_lock_eio.Body_completed { value = Ok (); release_error = Some error }) ->
      Error (Release_failed ("removed, but the checkpoint lock was not released: "
                             ^ File_lock_eio.durable_lock_error_to_string error))
    | File_lock_eio.Lock_attempted
        (File_lock_eio.Body_completed { value = Ok (); release_error = None }) -> Ok ()

(* Who a save keeps a lineage for. Only a Keeper's own saves do; a save by a
   tool or a test writes the file and keeps nothing. *)
type save_lineage =
  | Save_for_keeper of string
  | Save_without_lineage

(* The summary and the lineage are kept under the identity of the head this
   save wrote, from its own descriptor ([written_file]). A stat of the path
   after the rename would name whatever file is there by then. *)
let save_outcome_after_write
    ~session_dir ~canonical_path ~save_lineage ~memo ~written_file ~known
    ~history_retained ~payload_writer ~(plan : Objects.plan) ckpt
  =
  let identity = canonical_identity_of_stats written_file in
  publish_summary ~canonical_path (summary_of_head ~identity ~objects:Objects_seen plan.head);
  (match save_lineage with
   | Save_for_keeper keeper_name ->
     keep_lineage ~canonical_path ~identity ~memo ~keeper_name (Some plan.decoded)
   | Save_without_lineage -> ());
  archive_agent_core_history_best_effort
    ~payload_writer ~session_dir ~retained:history_retained ~head_bytes:plan.head_bytes ckpt;
  Ok
    (Saved
       { relation = save_relation ~known ~incoming:ckpt.turn_count
       ; turn_count = ckpt.turn_count
       ; canonical_bytes = identity.size
       ; checkpoint = ckpt
       })

let write_canonical_durably ~ownership_root path encoded_source =
  Keeper_fs.save_encoded_durable_atomic_from ~ownership_root path encoded_source

let save_agent_core_classified_typed
    ~(write_canonical :
       ownership_root:string ->
       string ->
       (unit -> string list) ->
       (Unix.stats, Keeper_fs.durable_write_error) result)
    ~save_lineage ~payload_writer
    ~(session_dir : string)
    ~(history_retained : int)
    ~boundary
    (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, save_agent_core_error) result =
  match Keeper_transcript_unit.validate ckpt.messages with
  | Error structural -> Error (Structurally_invalid structural)
  | Ok () ->
  match Keeper_id.Trace_id.of_string ckpt.session_id with
  | Error reason -> Error (Invalid_session_id reason)
  | Ok trace_id ->
    with_session_lock_typed ~session_dir (fun session_dir ->
      let session_id = Keeper_id.Trace_id.to_string trace_id in
      let canonical_path = agent_core_checkpoint_path ~session_dir ~session_id in
      match
        (* A canonical this binary supersedes carries no watermark to respect.
           The load already refused it and started the keeper fresh, so nothing
           in memory descends from it, and the write below replaces it -- under
           the same durable session lock as every other write here. Reporting
           it as unreadable instead made every save fail the same way forever,
           because nothing ever replaced the file: a keeper whose workspace
           predates the version bump could not checkpoint again until someone
           deleted it by hand. *)
        match known_canonical ~canonical_path with
        | Error (Superseded_version { expected; got }) ->
          Log.Keeper.warn
            "AGENT_CORE checkpoint %s is version %d, superseded by %d; this \
             turn's checkpoint replaces it"
            canonical_path got expected;
          Ok None
        | ( Error
              ( Not_found | Store_error _ | Parse_error _ | Newer_version _ | Io_error _
              | Read_failed _ | Agent_core_error _ | Objects_invalid _ )
          | Ok _ ) as answer -> answer
      with
      | Error error -> Error (Existing_checkpoint_unreadable error)
      | Ok (Some existing) when not (String.equal existing.known_session_id session_id) ->
        Error
          (Existing_checkpoint_unreadable
             (Store_error
                (Printf.sprintf
                   "canonical checkpoint identity mismatch: expected=%s actual=%s"
                   session_id existing.known_session_id)))
      | Ok (Some existing) when ckpt.turn_count < existing.known_turn_count ->
        Log.Keeper.warn
          "stale AGENT_CORE checkpoint write skipped for %s: incoming turn_count=%d, last saved=%d"
          ckpt.session_id ckpt.turn_count existing.known_turn_count;
        Otel_metric_store.inc_counter
          "masc_keeper_checkpoint_stale_noop_total"
          ~labels:[("site", "store_watermark")]
          ();
        Ok
          (Stale_noop
             { incoming_turn_count = ckpt.turn_count
             ; known_turn_count = existing.known_turn_count
             })
      | Ok existing ->
        let known = Option.map (fun known -> known.known_turn_count) existing in
        let previous = Option.map (fun known -> known.known_head) existing in
        let absent = Option.fold ~none:[] ~some:(absent_objects ~session_dir) existing in
        let ownership_root = Filename.dirname session_dir in
        let memo =
          match save_lineage with
          | Save_for_keeper _ -> lineage_memo ~canonical_path
          | Save_without_lineage -> Objects.create_memo ()
        in
        let plan payload =
          offload_checkpoint_cpu (fun () -> Objects.plan_save memo ?previous ~absent boundary payload)
        in
        (* The objects first, then the head that names them (RFC-0476 §3.3). *)
        let install payload (plan : Objects.plan) =
          match Keeper_checkpoint_object_store.write ~session_dir plan.objects with
          | Error error -> Error (Objects_write_failed error)
          | Ok object_bytes ->
            Checkpoint_payload_writer.note payload_writer (Some object_bytes);
            (match
               Checkpoint_payload_writer.canonical payload_writer ~write:write_canonical
                 ~ownership_root canonical_path
                 (fun () -> [ plan.head_bytes ])
             with
             | Error error -> Error (Canonical_write_failed error)
             | Ok written_file ->
               save_outcome_after_write
                 ~session_dir ~canonical_path ~save_lineage ~memo ~written_file
                 ~known ~history_retained ~payload_writer ~plan payload)
        in
        (match plan ckpt with
         | Ok planned -> install ckpt planned
         (* #31677: a payload-encode refusal means the in-memory checkpoint
            carries a json payload the contract cannot encode -- a
            provider-authored duplicate key or non-finite float. Without
            recovery the write refuses at this stage of every later turn,
            which is what bricked keepers for hours on 2026-08-29. The
            codec still rejects the original; this drop-and-retry-once
            stores the recovered copy, so the keeper survives and the next
            restart loads a clean checkpoint. A refusal with nothing
            droppable keeps the original error. *)
         | Error error -> (
           match Agent_core.Checkpoint.drop_unencodable_json ckpt with
           | None -> Error (Checkpoint_unencodable error)
           | Some recovered ->
             Log.Keeper.warn
               "checkpoint payload unencodable (%s); storing the recovery \
                copy with the offending json dropped for %s"
               (Agent_core.Error.to_string error)
               ckpt.session_id;
             (match plan recovered with
              | Error retry_error -> Error (Checkpoint_unencodable retry_error)
              | Ok planned -> install recovered planned))))

let save_agent_core_classified
    ~(session_dir : string) ~(history_retained : int) ~boundary (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, string) result =
  save_agent_core_classified_typed
    ~write_canonical:write_canonical_durably
    ~save_lineage:Save_without_lineage ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
  |> Result.map_error save_agent_core_error_to_string

let save_agent_core_for_keeper
    ~keeper_name ~(session_dir : string) ~(history_retained : int) ~boundary (ckpt : Agent_core.Checkpoint.t)
  : (save_agent_core_outcome, string) result =
  save_agent_core_classified_typed
    ~write_canonical:write_canonical_durably
    ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
  |> Result.map_error save_agent_core_error_to_string

module For_testing = struct
  let retained_payload_bytes ~directory =
    let seen = Hashtbl.create 16 in
    let rec count total path =
      let stat = Unix.lstat path in
      match stat.Unix.st_kind with
      | Unix.S_DIR ->
        Array.fold_left (fun total leaf -> count total (Filename.concat path leaf))
          total (Sys.readdir path)
      | Unix.S_REG ->
        let key = stat.Unix.st_dev, stat.Unix.st_ino in
        if Hashtbl.mem seen key then total
        else (
          Hashtbl.add seen key ();
          if stat.Unix.st_size > max_int - total then invalid_arg "retained payload byte count overflow";
          total + stat.Unix.st_size)
      | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK -> total
    in
    count 0 directory

  let save_agent_core_for_keeper_measured ~keeper_name ~session_dir ~history_retained ~boundary ckpt =
    let bytes = ref (Some 0) in
    let on_payload observation =
      bytes := (match !bytes, observation with
        | Some total, Some count when count <= max_int - total -> Some (total + count)
        | Some _, Some _ | None, Some _ | Some _, None | None, None -> None)
    in
    save_agent_core_classified_typed
      ~write_canonical:write_canonical_durably
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:(Checkpoint_payload_writer.Measured on_payload) ~session_dir ~history_retained ~boundary ckpt
    |> Result.map (fun outcome -> outcome, !bytes)
    |> Result.map_error save_agent_core_error_to_string

  let with_before_history_link hook f =
    let previous = Atomic.exchange before_history_link_hook (Some hook) in
    Fun.protect ~finally:(fun () -> Atomic.set before_history_link_hook previous) f

  let retain_exact_snapshot_with_writer = retain_exact_snapshot_with

  let save_agent_core_if_source_with_observer
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_release_failure
      ~release_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_release_failure ~session_dir f =
      match canonical_session_location session_dir with
      | Error error ->
        not_installed
          (Source_unavailable
             (Ref_lock_failed (save_agent_core_error_to_string error)))
      | Ok session_dir ->
        let lock_path = session_dir ^ ".checkpoint.lock" in
        File_lock_eio.For_testing.with_durable_lock_observed_with_release_failure
          ~release_failure
          ~lock_path
          (fun () -> f session_dir)
        |> installation_of_lock_observation
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_release_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_acquire_failure
      ~acquire_failure
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_acquire_failure ~session_dir:_ _f =
      installation_of_lock_observation
        (File_lock_eio.Lock_not_acquired acquire_failure)
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_acquire_failure
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_writer
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_if_source_with_post_commit_unwind
      ~post_commit_unwind
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate =
    let with_post_commit_unwind ~session_dir f =
      match with_checkpoint_cas_lock ~session_dir f with
      | Installed _ as installation ->
        post_commit_unwind ();
        installation
      | Not_installed _ as outcome -> outcome
    in
    save_agent_core_if_source_with
      ~with_checkpoint_cas_lock:with_post_commit_unwind
      ~write_checkpoint_bytes
      ~on_checkpoint_commit_observer
      ~session_dir
      ~expected_source_ref
      ~boundary
      candidate
  ;;

  let save_agent_core_for_keeper_with_before_stage
      ~before_stage ~keeper_name ~session_dir ~history_retained ~boundary ckpt
    =
    save_agent_core_classified_typed
      ~write_canonical:(fun ~ownership_root path encoded_source ->
        Keeper_fs.For_testing.save_encoded_durable_atomic_from
          ~before_stage ~ownership_root path encoded_source)
      ~save_lineage:(Save_for_keeper keeper_name) ~payload_writer:Checkpoint_payload_writer.Unmeasured ~session_dir ~history_retained ~boundary ckpt
    |> Result.map_error save_agent_core_error_to_string
  ;;
end
