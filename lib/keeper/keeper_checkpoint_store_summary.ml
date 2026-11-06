module Objects = Agent_core.Checkpoint_objects
open Keeper_checkpoint_store_history_files
open Keeper_checkpoint_store_decode

type 'a checkpoint_summary =
  { created_at : float
  ; message_count : int
  ; system_prompt : string option
  ; latest : 'a option
  }

(* A summary must isolate the same read/decode failures as the full load.
   Cancellation still belongs to the caller and must not become a row error. *)
let protect_summary_read ~on_exception f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn ->
    Printexc.raise_with_backtrace exn (Printexc.get_raw_backtrace ())
  | exn -> Error (on_exception exn)

let canonical_read_exception = function
  | Unix.Unix_error (errno, _, _) as exn ->
    Read_failed { cause = Os_error errno; detail = Printexc.to_string exn }
  | exn -> Read_failed { cause = Read_raised; detail = Printexc.to_string exn }

(* The header's session and what a list shows, from the head and the few
   objects it takes, decoded off the scheduler as a load is. *)
let summarize_head_bytes ~session_dir ~latest bytes =
  offload_checkpoint_cpu (fun () ->
    let read_object = Keeper_checkpoint_object_store.read ~session_dir in
    Result.bind (Objects.head_of_string bytes) (fun (head : Objects.head) ->
      Result.bind (Objects.system_prompt ~read_object head) (fun system_prompt ->
        Result.map
          (fun latest ->
             ( head.header.session_id
             , { created_at = head.header.created_at
               ; message_count = Objects.message_count head.history
               ; system_prompt
               ; latest
               } ))
          (Objects.find_last ~read_object head latest))))
  |> Result.map_error classify_objects_error

let summarize_canonical ~session_dir ~session_id ~latest =
  if not (leaf_is_real_segment session_id) then
    Error (Store_error "session_id is not a real path segment")
  else
    protect_summary_read ~on_exception:canonical_read_exception (fun () ->
      Result.bind
        (read_checkpoint_bytes ~session_dir (agent_core_checkpoint_path ~session_dir ~session_id))
        (fun bytes ->
           Result.bind (summarize_head_bytes ~session_dir ~latest bytes) (fun (named, summary) ->
             if String.equal named session_id
             then Ok summary
             else
               Error
                 (Store_error
                    (Printf.sprintf "the canonical of session %s names session %s" session_id named)))))

let summarize_agent_core_history_file ~session_dir ~snapshot_id ~latest =
  (* As in [load_agent_core_history_file], a non-segment id is absent. *)
  if not (leaf_is_real_segment snapshot_id) then Error Not_found
  else
    protect_summary_read ~on_exception:(fun exn -> Io_error (Printexc.to_string exn)) (fun () ->
      Result.bind
        (read_checkpoint_bytes ~session_dir (agent_core_history_path ~session_dir ~snapshot_id))
        (fun bytes -> Result.map snd (summarize_head_bytes ~session_dir ~latest bytes)))

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
