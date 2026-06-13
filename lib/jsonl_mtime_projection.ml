(* Mtime+size-gated projection cache shared by dashboard read paths.

   Several dashboard routes re-read and re-parse the same JSONL/log files on
   every request (board contributor-quality, keeper decision/memory feeds,
   goal events). The parse is the cost; the underlying files change rarely
   relative to request volume. This module caches a caller-built projection per
   key and rebuilds it only when a source file's (mtime, size) signature
   changes.

   Why (mtime, size) and not mtime alone: these files are append-only and may
   be written several times per second by other agents. A coarse-resolution
   mtime clock can miss a same-second append, but an append always grows the
   file, so size closes that gap. mtime additionally catches rewrites or
   truncations that leave the size unchanged.

   Why stat-on-read and not a file-watch daemon: the runtime already runs a
   saturated fseventsd, and writers are out-of-process (multi-agent). A per-call
   stat (microseconds) is robust to external writers and adds no watch load.

   Concurrency: the server runs on a single Eio domain, so the [Hashtbl]
   mutations here never interleave mid-operation. A [build] that yields (file
   I/O) can let another fiber rebuild the same key concurrently; both produce
   the same projection and the later [replace] wins, so the only cost of the
   race is repeated idempotent work — never a torn or inconsistent entry. *)

type 'a t = (string, (float * int) list * 'a) Hashtbl.t
(* key -> (source signatures, cached projection) *)

let create () : 'a t = Hashtbl.create 16

let file_signature (path : string) : float * int =
  ( (match Fs_compat.file_mtime path with Some m -> m | None -> 0.0),
    (match Fs_compat.file_size path with Some s -> s | None -> -1) )

let signatures (sources : string list) : (float * int) list =
  List.map file_signature sources

let get (t : 'a t) ~(key : string) ~(sources : string list)
    ~(build : unit -> 'a) : 'a =
  let sigs = signatures sources in
  match Hashtbl.find_opt t key with
  | Some (cached_sigs, value) when cached_sigs = sigs -> value
  | _ ->
      let value = build () in
      Hashtbl.replace t key (sigs, value);
      value
