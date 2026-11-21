type t =
  { root : string
  ; ownership_root : string
  }

module Validated_file_map = Map.Make (String)

type validated_file =
  { snapshot : Fs_compat.owned_regular_file_snapshot
  ; validated_at : int
  }

let validated_file_snapshots
    : validated_file Validated_file_map.t Atomic.t
  =
  Atomic.make Validated_file_map.empty
;;

let validated_file_sequence = Atomic.make 0
(* This is only a digest-validation accelerator. Eviction never weakens
   integrity: the next range read performs a whole-file validation again. *)
let validated_file_cache_capacity = 1_024

let evict_oldest_validated_file map =
  if Validated_file_map.cardinal map <= validated_file_cache_capacity
  then map
  else
    let oldest =
      Validated_file_map.fold
        (fun path entry oldest ->
           match oldest with
           | None -> Some (path, entry.validated_at)
           | Some (_, oldest_at) when entry.validated_at < oldest_at ->
             Some (path, entry.validated_at)
           | Some _ -> oldest)
        map
        None
    in
    match oldest with
    | None -> map
    | Some (path, _) -> Validated_file_map.remove path map
;;

let cache_validated_snapshot path snapshot =
  let validated_at = Atomic.fetch_and_add validated_file_sequence 1 in
  let rec loop () =
    let current = Atomic.get validated_file_snapshots in
    let updated =
      Validated_file_map.add path { snapshot; validated_at } current
      |> evict_oldest_validated_file
    in
    if not (Atomic.compare_and_set validated_file_snapshots current updated)
    then loop ()
  in
  loop ()
;;

let remove_validated_snapshot path =
  let rec loop () =
    let current = Atomic.get validated_file_snapshots in
    let updated = Validated_file_map.remove path current in
    if updated == current
    then ()
    else if not (Atomic.compare_and_set validated_file_snapshots current updated)
    then loop ()
  in
  loop ()
;;

(* Bounded O(1)-amortized accelerator of recently written blob paths in this
   process. Eviction is purely an optimization boundary: evicting an old path
   never loses data and only causes a future [put] of that digest to re-publish
   atomically. Using a Mutex-protected Hashtbl + FIFO queue avoids O(N) folds
   inside CAS retry loops once capacity is reached. *)
let written_address_cache_capacity = 4_096
let written_addresses_mu = Mutex.create ()
let written_addresses_seq = ref 0
let written_addresses_tbl : (string, int) Hashtbl.t = Hashtbl.create 512
let written_addresses_order : (string * int) Queue.t = Queue.create ()

let with_mutex mu f =
  Mutex.lock mu;
  Fun.protect ~finally:(fun () -> Mutex.unlock mu) f
;;

let was_written path =
  with_mutex written_addresses_mu (fun () -> Hashtbl.mem written_addresses_tbl path)
;;

let record_written path =
  with_mutex written_addresses_mu (fun () ->
    if not (Hashtbl.mem written_addresses_tbl path)
    then (
      incr written_addresses_seq;
      let seq = !written_addresses_seq in
      Hashtbl.add written_addresses_tbl path seq;
      Queue.push (path, seq) written_addresses_order;
      while Hashtbl.length written_addresses_tbl > written_address_cache_capacity do
        match Queue.take_opt written_addresses_order with
        | None -> ()
        | Some (evicted, ev_seq) ->
          (match Hashtbl.find_opt written_addresses_tbl evicted with
           | Some cur_seq when Int.equal cur_seq ev_seq ->
             Hashtbl.remove written_addresses_tbl evicted
           | Some _ | None -> ())
      done))
;;

let forget_written path =
  with_mutex written_addresses_mu (fun () -> Hashtbl.remove written_addresses_tbl path)
;;

(* Bounded two-generation touch ledger for offline sweep safety.
   Hot-path [record_touch] and [rotate_touches] run in O(1) amortized time
   under a Mutex-protected Hashtbl + FIFO queue; [observe_touches] builds an
   immutable snapshot only when an offline sweep inspects the ledger. *)
let touch_generation_capacity = 8_192

type touch =
  { put : bool
  ; read : bool
  }

module Touch_map = Map.Make (String)

type touches =
  { current : touch Touch_map.t
  ; previous : touch Touch_map.t
  }

type touch_ledger_state =
  { mutable current : (string, touch) Hashtbl.t
  ; mutable current_order : string Queue.t
  ; mutable previous : (string, touch) Hashtbl.t
  }

let touch_ledger_mu = Mutex.create ()

let touch_ledger_state : touch_ledger_state =
  { current = Hashtbl.create 256
  ; current_order = Queue.create ()
  ; previous = Hashtbl.create 16
  }
;;

let record_touch sha256 (mark : touch) =
  with_mutex touch_ledger_mu (fun () ->
    match Hashtbl.find_opt touch_ledger_state.current sha256 with
    | None ->
      Hashtbl.add touch_ledger_state.current sha256 mark;
      Queue.push sha256 touch_ledger_state.current_order;
      while Hashtbl.length touch_ledger_state.current > touch_generation_capacity do
        match Queue.take_opt touch_ledger_state.current_order with
        | None -> ()
        | Some evicted -> Hashtbl.remove touch_ledger_state.current evicted
      done
    | Some existing ->
      let next_mark =
        { put = existing.put || mark.put; read = existing.read || mark.read }
      in
      if not (Bool.equal next_mark.put existing.put && Bool.equal next_mark.read existing.read)
      then Hashtbl.replace touch_ledger_state.current sha256 next_mark)
;;

let mark_put sha256 = record_touch sha256 { put = true; read = false }
let mark_read sha256 = record_touch sha256 { put = false; read = true }

(* sha256 validation SSOT lives in {!Tool_output} (the artifact-ref owner);
   re-exported here so the store boundary keeps its historical surface. *)
type invalid_sha256 = Tool_output.invalid_sha256 =
  | Invalid_sha256_length of { actual : int }
  | Invalid_sha256_character of { index : int; found : char }

let validate_sha256 = Tool_output.validate_sha256
let invalid_sha256_to_string = Tool_output.invalid_sha256_to_string

type fetch_error =
  | Invalid_sha256 of invalid_sha256
  | Owned_read_failed of Fs_compat.owned_regular_file_read_error
  | Too_large of { path : string; actual : int; maximum : int }
  | Invalid_max_bytes of int
  | Integrity_mismatch of {
      path : string;
      expected : string;
      actual : string;
    }

let fetch_error_to_string = function
  | Invalid_sha256 invalid -> invalid_sha256_to_string invalid
  | Owned_read_failed error ->
      Fs_compat.owned_regular_file_read_error_to_string error
  | Too_large { path; actual; maximum } ->
      Printf.sprintf "artifact too large path=%s bytes=%d maximum=%d" path actual maximum
  | Invalid_max_bytes value ->
      Printf.sprintf "max_bytes must be non-negative, got %d" value
  | Integrity_mismatch { path; expected; actual } ->
      Printf.sprintf
        "integrity mismatch path=%s expected=%s actual=%s"
        path
        expected
        actual

(* Shared smart 4 KiB head+tail preview byte ceiling. Planning and storage both
   call [make_preview] so reference size estimates use the exact sanitized
   head+tail bytes, eliminating multi-turn artifact-read loops for typical
   command/build outputs while preserving both beginning context and trailing
   errors/summaries. *)
let preview_max = 4096

let sanitize_utf8_slice slice =
  let len = String.length slice in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len do
    let decoded = String.get_utf_8_uchar slice !i in
    let width = Uchar.utf_decode_length decoded in
    if Uchar.utf_decode_is_valid decoded then (
      let c = String.unsafe_get slice !i in
      if c = '\n' || c = '\r' || c = '\t' then Buffer.add_char buf ' '
      else if Char.code c < 0x20 then Buffer.add_char buf '?'
      else Buffer.add_substring buf slice !i width)
    else Buffer.add_char buf '?';
    i := !i + width
  done;
  Buffer.contents buf

let make_head_tail_preview ~total_bytes ~head ~tail =
  if total_bytes <= preview_max then sanitize_utf8_slice head
  else
    let head_len = String.length head in
    let tail_len = String.length tail in
    let omitted = max 0 (total_bytes - head_len - tail_len) in
    let separator = Printf.sprintf " ... [%d bytes omitted] ... " omitted in
    let budget = max 0 (preview_max - String.length separator) in
    let head_budget = budget / 2 in
    let tail_budget = budget - head_budget in
    let head_part =
      if head_len <= head_budget then head else String.sub head 0 head_budget
    in
    let tail_part =
      if tail_len <= tail_budget then tail
      else String.sub tail (tail_len - tail_budget) tail_budget
    in
    let actual_omitted = max 0 (total_bytes - String.length head_part - String.length tail_part) in
    let final_sep = Printf.sprintf " ... [%d bytes omitted] ... " actual_omitted in
    let final_head_budget = max 0 ((preview_max - String.length final_sep) / 2) in
    let final_tail_budget = max 0 (preview_max - String.length final_sep - final_head_budget) in
    let h =
      if String.length head_part <= final_head_budget then head_part
      else String.sub head_part 0 final_head_budget
    in
    let t =
      if String.length tail_part <= final_tail_budget then tail_part
      else String.sub tail_part (String.length tail_part - final_tail_budget) final_tail_budget
    in
    sanitize_utf8_slice h ^ final_sep ^ sanitize_utf8_slice t

(* Preview metadata travels inside JSON strings, even when the stored bytes
   are binary. Decode bounded head+tail slices before copying Unicode sequences;
   replacing malformed sequences with one ASCII byte cannot exceed [preview_max]. *)
let make_preview bytes =
  let total_bytes = String.length bytes in
  if total_bytes <= preview_max then sanitize_utf8_slice bytes
  else
    let half = preview_max / 2 in
    let head = String.sub bytes 0 half in
    let tail = String.sub bytes (total_bytes - half) half in
    make_head_tail_preview ~total_bytes ~head ~tail

let dirname = "tool_blobs"

let create ~base_path =
  {
    root =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        dirname;
    ownership_root = base_path;
  }

let root_dir t = t.root

let shard_path t sha256 =
  let prefix = String.sub sha256 0 2 in
  Filename.concat (Filename.concat t.root prefix) sha256

type parent_durability =
  | Durable
  | Volatile

(* Every blob writer reaches its shard directory through this one owned chain.
   Each component from the ownership root down is looked at with [lstat], so a
   symbolic link, another owner, or a group- or world-writable directory at the
   blob root or a shard stops the write before any byte is written behind it.
   [lstat] is as strong as what follows: the atomic writers resolve the same
   pathname again, and the caller keeps this subtree process-owned while
   writing. The ownership root must already exist; it is never created here.

   [Durable] also syncs every directory and the ownership root, existing ones
   included, because an earlier failed preparation may have created a name
   without durably linking it.

   Every failure is [Sys_error], the failure contract of the atomic replacement
   that comes next, so a directory that cannot be prepared does not escape as a
   raw [Unix.Unix_error] only because it failed earlier. *)
let prepare_owned_parent ~durability ~ownership_root path =
  let parent = Filename.dirname path in
  let owner_uid = Unix.geteuid () in
  let require_owned directory (stat : Unix.stats) =
    if stat.st_kind <> Unix.S_DIR
       || stat.st_uid <> owner_uid
       || stat.st_perm land 0o022 <> 0
    then
      raise
        (Sys_error
           (Printf.sprintf
              "tool_blob_store: %s is not a private owned directory (kind %s, uid %d, mode %o)"
              directory
              (Fs_compat.file_kind_to_string stat.st_kind)
              stat.st_uid
              (stat.st_perm land 0o7777)))
  in
  let sync directory =
    let fd = Unix.openfile directory [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 in
    match Unix.fsync fd with
    | () -> Unix.close fd
    | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      (try Unix.close fd with Unix.Unix_error _ -> ());
      Printexc.raise_with_backtrace exn backtrace
  in
  try
    let descendants =
      match Fs_compat.owned_directory_paths ~ownership_root parent with
      | Ok paths -> paths
      | Error rejection ->
        raise (Sys_error (Fs_compat.owned_directory_chain_rejection_to_string rejection))
    in
    require_owned ownership_root (Unix.lstat ownership_root);
    List.iter
      (fun directory ->
         match Unix.lstat directory with
         | stat -> require_owned directory stat
         | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
           (try Unix.mkdir directory 0o755 with
            | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
           require_owned directory (Unix.lstat directory))
      descendants;
    match durability with
    | Volatile -> ()
    | Durable -> List.iter sync (List.rev (ownership_root :: descendants))
  with
  | Unix.Unix_error (code, fn, arg) ->
    raise
      (Sys_error
         (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))

let fetch t ~sha256 =
  match validate_sha256 sha256 with
  | Error invalid -> Error (Invalid_sha256 invalid)
  | Ok () ->
      mark_read sha256;
      let path = shard_path t sha256 in
      (match
         Fs_compat.load_owned_regular_file_with_snapshot
           ~ownership_root:t.ownership_root
           path
       with
       | Error error ->
         forget_written path;
         Error (Owned_read_failed error)
       | Ok None ->
         remove_validated_snapshot path;
         forget_written path;
         Ok None
       | Ok (Some { content = bytes; snapshot }) ->
         let actual = Agent_core_sha256.(digest_string bytes |> to_hex) in
         if String.equal sha256 actual
         then (
           cache_validated_snapshot path snapshot;
           Ok (Some bytes))
         else (
           remove_validated_snapshot path;
           forget_written path;
           Error (Integrity_mismatch { path; expected = sha256; actual })))

let max_served_bytes = 32 * 1024 * 1024

let fetch_bounded t ~sha256 ~max_bytes =
  match validate_sha256 sha256 with
  | Error invalid -> Error (Invalid_sha256 invalid)
  | Ok () when max_bytes < 0 -> Error (Invalid_max_bytes max_bytes)
  | Ok () ->
    mark_read sha256;
    let path = shard_path t sha256 in
    (match
       Fs_compat.load_owned_regular_file_prefix
         ~ownership_root:t.ownership_root
         ~max_bytes
         path
     with
     | Error error ->
       forget_written path;
       Error (Owned_read_failed error)
     | Ok None ->
       remove_validated_snapshot path;
       forget_written path;
       Ok None
     | Ok (Some { truncated = true; file_size; _ }) ->
       Error (Too_large { path; actual = file_size; maximum = max_bytes })
     | Ok (Some { content = bytes; _ }) ->
       let actual = Agent_core_sha256.(digest_string bytes |> to_hex) in
       if String.equal sha256 actual
       then Ok (Some bytes)
       else (
         remove_validated_snapshot path;
         forget_written path;
         Error (Integrity_mismatch { path; expected = sha256; actual })))
;;

type range =
  { content : string
  ; total_bytes : int
  }

let fetch_range_with ~after_window_read t ~sha256 ~offset ~max_bytes =
  match validate_sha256 sha256 with
  | Error invalid -> Error (Invalid_sha256 invalid)
  | Ok () when offset < 0 || max_bytes < 0 ->
    Error
      (Owned_read_failed
         { failure =
             Fs_compat.Owned_file_operation_failed
               { path = shard_path t sha256
               ; operation = Fs_compat.Read_contents
               ; cause =
                   Invalid_argument
                     "offset and max_bytes must be non-negative"
               }
         ; close_failure = None
         })
  | Ok () ->
    mark_read sha256;
    let path = shard_path t sha256 in
    let cached =
      Validated_file_map.find_opt path (Atomic.get validated_file_snapshots)
    in
    (* Cold-cache and changed-snapshot admission: one owned descriptor streams
       the whole-file digest through a fixed buffer (never materialising the
       file) and copies the caller's window out of the same pass.  A
       nonexistent shard fails fast on that open instead of falling into a
       whole-file materialising read.

       The window and the digest come from the same descriptor, so the bytes
       returned are the bytes hashed by construction (#38972, #38874). *)
    let validate_and_read_streaming () =
      (* The full-file digest is CPU work. Keep cache admission on the caller
         so a cancelled pool wait cannot publish a validated snapshot. *)
      match
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          Fs_compat.load_owned_regular_file_range_with_sha256
            ~ownership_root:t.ownership_root
            ~offset
            ~max_bytes
            path)
      with
      | Error error ->
        forget_written path;
        Error (Owned_read_failed error)
      | Ok None ->
        remove_validated_snapshot path;
        forget_written path;
        Ok None
      | Ok (Some (observed : Fs_compat.owned_regular_file_range_digest)) ->
        after_window_read ();
        let actual = observed.sha256 in
        if String.equal sha256 actual
        then (
          cache_validated_snapshot path observed.snapshot;
          Ok
            (Some
               { content = observed.content
               ; total_bytes = observed.snapshot.file_size
               }))
        else (
          remove_validated_snapshot path;
          forget_written path;
          Error (Integrity_mismatch { path; expected = sha256; actual }))
    in
    (match cached with
     | None -> validate_and_read_streaming ()
     | Some { snapshot = validated_snapshot; _ } ->
       (match
          Fs_compat.load_owned_regular_file_range
            ~ownership_root:t.ownership_root
            ~offset
            ~max_bytes
            path
        with
        | Error error ->
          forget_written path;
          Error (Owned_read_failed error)
        | Ok None ->
          remove_validated_snapshot path;
          forget_written path;
          Ok None
        | Ok (Some { content; snapshot })
          when Fs_compat.equal_owned_regular_file_snapshot
                 validated_snapshot
                 snapshot ->
          Ok (Some { content; total_bytes = snapshot.file_size })
        | Ok (Some _) -> validate_and_read_streaming ()))
;;

let fetch_range t ~sha256 ~offset ~max_bytes =
  fetch_range_with ~after_window_read:(fun () -> ()) t ~sha256 ~offset ~max_bytes
;;

(* Whether a put writes an address this process already wrote. The model
   input demotion puts every aged tool result on every provider request, so a
   long-lived keeper rewrote the same thousands of files each request: about
   2,776 blob files in one to two and a half minutes on 2026-09-15, each a temp
   write, an fsync, a rename and a parent fsync. *)
type rewrite =
  | Rewrite_every_put
  | Skip_address_this_process_wrote

(* The half of a put that reads no filesystem and writes none: the sha256 over
   the whole body, the preview cut from it, and the path that address occupies.
   A put whose address this process already wrote does nothing else, so for a
   caller holding many bodies this is the whole cost, and it is the half that
   can be computed away from the domain the caller runs on. *)
type addressed =
  { addressed_bytes : string
  ; addressed_path : string
  ; addressed_ownership_root : string
  ; addressed_ref : Tool_output.artifact_ref
  }

type prepared_payload =
  { prepared_bytes : string
  ; prepared_sha256 : string
  }

let prepare_payload ~bytes =
  { prepared_bytes = bytes
  ; prepared_sha256 = Agent_core_sha256.(digest_string bytes |> to_hex)
  }

let prepared_bytes payload = payload.prepared_bytes
let prepared_sha256 payload = payload.prepared_sha256

let address_with_digest ~operation t ~bytes ~mime ~sha256 =
  (* A digestif-produced sha256 and a byte length are always valid; an empty
     [mime] is the only reachable rejection and is a caller bug, raised
     visibly rather than stored. *)
  match
    Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
      ~preview:(make_preview bytes) ~mime
  with
  | Ok artifact_ref ->
    { addressed_bytes = bytes
    ; addressed_path = shard_path t sha256
    ; addressed_ownership_root = t.ownership_root
    ; addressed_ref = artifact_ref
    }
  | Error err ->
    invalid_arg
      (Printf.sprintf "tool_blob_store.%s: %s" operation
         (Tool_output.make_error_to_string err))

let address_with ~operation t ~bytes ~mime =
  let sha256 = Agent_core_sha256.(digest_string bytes |> to_hex) in
  address_with_digest ~operation t ~bytes ~mime ~sha256

let address_prepared_with ~operation t ~payload ~mime =
  address_with_digest ~operation t ~bytes:payload.prepared_bytes ~mime
    ~sha256:payload.prepared_sha256

let store_addressed ~rewrite ~durability ~atomic_replace ~operation addressed =
  mark_put addressed.addressed_ref.Tool_output.sha256;
  let path = addressed.addressed_path in
  let write () =
    prepare_owned_parent ~durability ~ownership_root:addressed.addressed_ownership_root path;
    (* An authoritative atomic rewrite avoids reading and hashing a second
       full copy, and repairs any corrupt prior bytes at this content
       address. Concurrent writers have byte-identical payloads. *)
    (match atomic_replace path addressed.addressed_bytes with
     | Ok () -> ()
     | Error msg ->
         raise (Sys_error (Printf.sprintf "tool_blob_store.%s: %s" operation msg)));
    remove_validated_snapshot path
  in
  (* Only [put] reads the set, so only [put] adds to it. *)
  (match rewrite with
   | Skip_address_this_process_wrote when was_written path -> ()
   | Skip_address_this_process_wrote ->
     write ();
     record_written path
   | Rewrite_every_put -> write ());
  addressed.addressed_ref

let address t ~bytes ~mime = address_with ~operation:"address" t ~bytes ~mime

let put_addressed addressed =
  Tool_output.Stored
    (store_addressed
       ~rewrite:Skip_address_this_process_wrote
       ~durability:Volatile
       ~atomic_replace:Fs_compat.save_file_atomic
       ~operation:"put"
       addressed)
;;

(* [address_with ~operation:"put"] rather than [address], so a caller that
   passes an empty mime still reads [put] in the failure. It now raises before
   writing instead of after: a call that cannot return a reference no longer
   leaves the bytes at their address. *)
let put t ~bytes ~mime = put_addressed (address_with ~operation:"put" t ~bytes ~mime)

let put_durable t ~bytes ~mime =
  let addressed = address_with ~operation:"put_durable" t ~bytes ~mime in
  Eio_guard.run_in_systhread ~label:"tool-blob-put-durable" (fun () ->
    store_addressed
      ~rewrite:Rewrite_every_put
      ~durability:Durable
      ~atomic_replace:Fs_compat.save_file_atomic_strict
      ~operation:"put_durable"
      addressed)
;;

(* A content address proves identity, not durability of a replacement file.
   Reuse is bound to the owned snapshot observed after strict publication. *)
let durable_snapshots : validated_file Validated_file_map.t Atomic.t =
  Atomic.make Validated_file_map.empty

let record_durable path snapshot =
  let validated_at = Atomic.fetch_and_add validated_file_sequence 1 in
  let rec loop () =
    let current = Atomic.get durable_snapshots in
    let updated = Validated_file_map.add path { snapshot; validated_at } current
      |> evict_oldest_validated_file in
    if not (Atomic.compare_and_set durable_snapshots current updated) then loop () in
  loop ()

let store_durable_reuse ~operation addressed =
  let bytes = addressed.addressed_bytes in
  let ownership_root = addressed.addressed_ownership_root in
  mark_put addressed.addressed_ref.Tool_output.sha256;
  let path = addressed.addressed_path in
  let read () = Fs_compat.load_owned_regular_file_with_snapshot
      ~owner_uid:(Unix.geteuid ()) ~ownership_root path in
  let reusable =
    match Validated_file_map.find_opt path (Atomic.get durable_snapshots) with
    | None -> false
    | Some previous ->
      (match read () with
       | Ok (Some observed) ->
         Fs_compat.equal_owned_regular_file_snapshot previous.snapshot observed.snapshot
         && String.equal observed.content bytes
       | Ok None | Error _ -> false) in
  if reusable then addressed.addressed_ref
  else
    let written_identity = ref None in
    Eio_guard.run_in_systhread ~label:"tool-blob-put-durable-reuse-parent" (fun () ->
      prepare_owned_parent ~durability:Durable ~ownership_root path);
    (match Fs_compat.write_file_atomic_strict_staged path ~write:(fun channel ->
       output_string channel bytes;
       flush channel;
       let stat = Unix.fstat (Unix.descr_of_out_channel channel) in
       written_identity := Some (stat.Unix.st_dev, stat.Unix.st_ino)) with
     | Error error ->
       raise (Sys_error (Printf.sprintf "tool_blob_store.%s: %s" operation
         (Fs_compat.atomic_replace_failure_to_string error)))
     | Ok () -> ());
    remove_validated_snapshot path;
    (* A concurrent non-strict writer may replace the pathname after our
       rename. Only the inode produced by the strict writer earns reuse. *)
    (match written_identity.contents, read () with
     | Some (device, inode), Ok (Some observed)
       when observed.snapshot.device = device && observed.snapshot.inode = inode
            && String.equal observed.content bytes ->
       record_durable path observed.snapshot
     | (Some _ | None), (Ok (Some _) | Ok None | Error _) -> ());
    addressed.addressed_ref
;;

let put_durable_reuse t ~bytes ~mime =
  let operation = "put_durable_reuse" in
  let addressed = address_with ~operation t ~bytes ~mime in
  store_durable_reuse ~operation addressed

let put_prepared_durable_reuse t ~payload ~mime =
  let operation = "put_prepared_durable_reuse" in
  let addressed = address_prepared_with ~operation t ~payload ~mime in
  store_durable_reuse ~operation addressed

let scan_file_for_ingest ~buffer ~copy_to channel =
  let head_buf = Buffer.create preview_max in
  let tail_cap = preview_max / 2 in
  let tail_ring = Bytes.create tail_cap in
  let tail_pos = ref 0 in
  let tail_filled = ref 0 in
  let push_tail src count =
    if count >= tail_cap then (
      Bytes.blit src (count - tail_cap) tail_ring 0 tail_cap;
      tail_pos := 0;
      tail_filled := tail_cap)
    else
      let first = min count (tail_cap - !tail_pos) in
      Bytes.blit src 0 tail_ring !tail_pos first;
      let rem = count - first in
      if rem > 0 then Bytes.blit src first tail_ring 0 rem;
      tail_pos := (!tail_pos + count) mod tail_cap;
      tail_filled := min tail_cap (!tail_filled + count)
  in
  let extract_tail () =
    if !tail_filled < tail_cap then Bytes.sub_string tail_ring 0 !tail_filled
    else
      let out = Bytes.create tail_cap in
      let first = tail_cap - !tail_pos in
      Bytes.blit tail_ring !tail_pos out 0 first;
      Bytes.blit tail_ring 0 out first !tail_pos;
      Bytes.unsafe_to_string out
  in
  let rec loop digest total =
    match input channel buffer 0 (Bytes.length buffer) with
    | 0 ->
      let preview =
        if total <= preview_max then sanitize_utf8_slice (Buffer.contents head_buf)
        else
          make_head_tail_preview ~total_bytes:total
            ~head:(Buffer.contents head_buf) ~tail:(extract_tail ())
      in
      Agent_core_sha256.get digest, total, preview
    | count ->
      Option.iter (fun output_channel -> output output_channel buffer 0 count) copy_to;
      let head_remaining = preview_max - Buffer.length head_buf in
      if head_remaining > 0 then
        Buffer.add_subbytes head_buf buffer 0 (min count head_remaining);
      push_tail buffer count;
      loop
        (Agent_core_sha256.feed_bytes digest ~off:0 ~len:count buffer)
        (total + count)
  in
  loop Agent_core_sha256.empty 0
;;

let same_ingest_source (before : Unix.stats) (after : Unix.stats) =
  before.st_dev = after.st_dev
  && before.st_ino = after.st_ino
  && before.st_kind = after.st_kind
  && before.st_size = after.st_size
  && before.st_mtime = after.st_mtime
  && before.st_ctime = after.st_ctime
;;

let ingest_open_file_blocking ~after_hash ~expected_sha256 t ~source_path ~source_fd ~mime =
    try
      let source, source_stat =
        match
          let source_stat = Unix.fstat source_fd in
          if source_stat.Unix.st_kind <> Unix.S_REG
          then
            raise
              (Sys_error
                 ("tool_blob_store.put_file_durable: source is not a regular file: "
                  ^ source_path));
          Unix.in_channel_of_descr source_fd, source_stat
        with
        | value -> value
        | exception exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          (try Unix.close source_fd with Unix.Unix_error _ -> ());
          Printexc.raise_with_backtrace exception_ backtrace
      in
      (* fun-protect-finally-ok: this entire operation is synchronous inside
         the blocking job. A normal close failure is reported; cleanup while
         unwinding preserves the original read/publication exception. *)
      Fun.protect ~finally:(fun () -> close_in_noerr source) (fun () ->
        let check_source_snapshot () =
          if not (same_ingest_source source_stat (Unix.fstat (Unix.descr_of_in_channel source)))
          then
            raise
              (Sys_error
                 ("tool_blob_store.put_file_durable: source changed during ingestion: "
                  ^ source_path))
        in
        seek_in source 0;
        let buffer = Bytes.create Sys.io_buffer_size in
        let digest, bytes, preview = scan_file_for_ingest ~buffer ~copy_to:None source in
        check_source_snapshot ();
        after_hash ();
        let sha256 = Agent_core_sha256.to_hex digest in
        mark_put sha256;
        (match expected_sha256 with
         | Some expected when not (String.equal expected sha256) ->
             raise (Sys_error "tool_blob_store: descriptor contents do not match the granted digest")
         | Some _ | None -> ());
        let reference =
          match Tool_output.make_artifact_ref ~sha256 ~bytes ~preview ~mime with
          | Ok reference -> reference
          | Error error ->
            invalid_arg
              ("tool_blob_store.put_file_durable: " ^ Tool_output.make_error_to_string error)
        in
        let target = shard_path t sha256 in
        prepare_owned_parent ~durability:Durable ~ownership_root:t.ownership_root target;
        seek_in source 0;
        let publication =
          Fs_compat.write_file_atomic_strict_staged_blocking target ~write:(fun output_channel ->
            let copied_digest, copied_bytes, _ =
              scan_file_for_ingest ~buffer ~copy_to:(Some output_channel) source
            in
            if copied_bytes <> bytes || not (Agent_core_sha256.equal copied_digest digest)
            then
              raise
                (Sys_error
                   ("tool_blob_store.put_file_durable: source contents changed while copying: "
                    ^ source_path));
            check_source_snapshot ())
        in
        (match publication with
         | Ok () -> ()
         | Error failure ->
           (match failure.Fs_compat.exception_ with
            | Sys_error _ | Unix.Unix_error _ ->
              Printexc.raise_with_backtrace
                (Sys_error (Fs_compat.atomic_replace_failure_to_string failure))
                failure.backtrace
            | exception_ ->
              Printexc.raise_with_backtrace exception_ failure.backtrace));
        remove_validated_snapshot target;
        close_in source;
        reference)
    with
    | Unix.Unix_error _ as exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace
        (Sys_error
           (Printf.sprintf
              "tool_blob_store.put_file_durable %s: %s"
              source_path
              (Printexc.to_string exception_)))
        backtrace
;;

let put_file_durable_blocking_with ~after_hash t ~path ~mime =
  (* Nonblocking open rejects a FIFO without waiting for a writer. *)
  let source_fd = try Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0
    with Unix.Unix_error _ as exn ->
      raise (Sys_error (Printf.sprintf "tool_blob_store.put_file_durable %s: %s" path (Printexc.to_string exn))) in
  ingest_open_file_blocking ~after_hash ~expected_sha256:None t
    ~source_path:path ~source_fd ~mime

let put_file_descriptor_durable_blocking t ~source ~expected_sha256 ~mime =
  let source_fd = try Unix.dup ~cloexec:true source with Unix.Unix_error _ as exn ->
    raise (Sys_error ("tool_blob_store.put_file_descriptor_durable: " ^ Printexc.to_string exn)) in
  ingest_open_file_blocking ~after_hash:(fun () -> ())
    ~expected_sha256:(Some expected_sha256) t ~source_path:"<granted descriptor>" ~source_fd ~mime

let put_file_durable_with ~after_hash t ~path ~mime =
  Eio_guard.run_in_systhread ~label:"tool-blob-put-file-durable" (fun () ->
    put_file_durable_blocking_with ~after_hash t ~path ~mime)

let put_file_durable_blocking =
  put_file_durable_blocking_with ~after_hash:(fun () -> ())

let put_file_durable = put_file_durable_with ~after_hash:(fun () -> ())

module For_testing = struct
  let address_prepared t ~payload ~mime =
    address_prepared_with ~operation:"put_prepared_durable_reuse" t ~payload ~mime
  let put_file_durable = put_file_durable_with
  let fetch_range = fetch_range_with

  let validated_snapshot t ~sha256 =
    Validated_file_map.find_opt
      (shard_path t sha256)
      (Atomic.get validated_file_snapshots)
    |> Option.map (fun (entry : validated_file) -> entry.snapshot)
  ;;
end

let list_all t =
  if not (Sys.file_exists t.root) then []
  else
    let acc = ref [] in
    let shards =
      try Sys.readdir t.root with Sys_error _ -> [||]
    in
    Array.iter (fun shard ->
      let shard_dir = Filename.concat t.root shard in
      if try Sys.is_directory shard_dir with Sys_error _ -> false then begin
        let files =
          try Sys.readdir shard_dir with Sys_error _ -> [||]
        in
        Array.iter (fun fname ->
          if String.length fname = 64 then acc := fname :: !acc
        ) files
      end
    ) shards;
    !acc

type list_error =
  { path : string
  ; reason : string
  }

let list_all_result t =
  let same_directory (left : Unix.stats) (right : Unix.stats) =
    left.st_dev = right.st_dev
    && left.st_ino = right.st_ino
    && left.st_kind = Unix.S_DIR
    && right.st_kind = Unix.S_DIR
  in
  let inspect_dir path =
    match
      Fs_compat.inspect_owned_directory_chain
        ~ownership_root:t.ownership_root
        path
    with
    | Ok observation -> Ok observation
    | Error rejection ->
      Error
        { path
        ; reason =
            Fs_compat.owned_directory_chain_rejection_to_string rejection
        }
  in
  let read_dir path =
    match inspect_dir path with
    | Error _ as error -> error
    | Ok Fs_compat.Owned_directory_missing -> Ok None
    | Ok (Fs_compat.Owned_directory before) ->
      (try
         let entries = Sys.readdir path in
         match inspect_dir path with
         | Error _ as error -> error
         | Ok Fs_compat.Owned_directory_missing ->
           Error { path; reason = "directory disappeared during listing" }
         | Ok (Fs_compat.Owned_directory after) ->
           if same_directory before after
           then Ok (Some entries)
           else Error { path; reason = "directory identity changed during listing" }
       with
       | Sys_error reason -> Error { path; reason }
       | Unix.Unix_error (code, fn, arg) ->
         Error
           { path
           ; reason =
               Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
           })
  in
  match read_dir t.root with
  | Error _ as error -> error
  | Ok None -> Ok []
  | Ok (Some shards) ->
      let rec scan_shards acc index =
        if index = Array.length shards
        then Ok acc
        else
          let shard_dir = Filename.concat t.root shards.(index) in
          match read_dir shard_dir with
          | Error _ as error -> error
          | Ok None -> scan_shards acc (index + 1)
          | Ok (Some files) ->
            let acc =
              Array.fold_left
                (fun current filename ->
                   match validate_sha256 filename with
                   | Ok () -> filename :: current
                   | Error _ -> current)
                acc
                files
            in
            scan_shards acc (index + 1)
      in
      scan_shards [] 0

type delete_error =
  { sha256 : string
  ; path : string
  ; reason : string
  }

let delete t ~sha256 =
  match validate_sha256 sha256 with
  | Error invalid ->
    Error
      { sha256
      ; path = t.root
      ; reason = invalid_sha256_to_string invalid
      }
  | Ok () ->
    let path = shard_path t sha256 in
    remove_validated_snapshot path;
    forget_written path;
    let parent = Filename.dirname path in
    (match
       Fs_compat.inspect_owned_directory_chain
         ~ownership_root:t.ownership_root
         parent
     with
     | Error rejection ->
       Error
         { sha256
         ; path
         ; reason =
             Fs_compat.owned_directory_chain_rejection_to_string rejection
         }
     | Ok Fs_compat.Owned_directory_missing -> Ok false
     | Ok (Fs_compat.Owned_directory parent_before) ->
       (try
          let target = Unix.lstat path in
          if target.st_kind <> Unix.S_REG
          then
            Error
              { sha256
              ; path
              ; reason =
                  Printf.sprintf
                    "refusing to delete non-regular blob kind=%s"
                    (Fs_compat.file_kind_to_string target.st_kind)
              }
          else
            (match
               Fs_compat.inspect_owned_directory_chain
                 ~ownership_root:t.ownership_root
                 parent
             with
             | Error rejection ->
               Error
                 { sha256
                 ; path
                 ; reason =
                     Fs_compat.owned_directory_chain_rejection_to_string
                       rejection
                 }
             | Ok Fs_compat.Owned_directory_missing ->
               Error { sha256; path; reason = "blob parent disappeared" }
             | Ok (Fs_compat.Owned_directory parent_after) ->
               if
                 parent_before.st_dev <> parent_after.st_dev
                 || parent_before.st_ino <> parent_after.st_ino
               then
                 Error
                   { sha256
                   ; path
                   ; reason = "blob parent identity changed before deletion"
                   }
               else (
                 Unix.unlink path;
                 Ok true))
        with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
        | Unix.Unix_error (code, fn, arg) ->
          Error
            { sha256
            ; path
            ; reason =
                Printf.sprintf
                  "%s(%s): %s"
                  fn
                  arg
                  (Unix.error_message code)
            }
        | Sys_error reason -> Error { sha256; path; reason }))

(* Once a scan has written its record, the sweep drops the
   older generation and starts a new one in O(1). *)
let rotate_touches () =
  with_mutex touch_ledger_mu (fun () ->
    touch_ledger_state.previous <- touch_ledger_state.current;
    touch_ledger_state.current <- Hashtbl.create 256;
    touch_ledger_state.current_order <- Queue.create ())
;;

let snapshot_touch_tbl tbl =
  Hashtbl.fold (fun sha mark acc -> Touch_map.add sha mark acc) tbl Touch_map.empty
;;

let observe_touches () =
  with_mutex touch_ledger_mu (fun () ->
    { current = snapshot_touch_tbl touch_ledger_state.current
    ; previous = snapshot_touch_tbl touch_ledger_state.previous
    })
;;

let touch_of (observed : touches) ~sha256 =
  match Touch_map.find_opt sha256 observed.current, Touch_map.find_opt sha256 observed.previous with
  | None, None -> None
  | Some mark, None | None, Some mark -> Some mark
  | Some current, Some previous ->
    Some { put = current.put || previous.put; read = current.read || previous.read }
;;

type touch_counts =
  { current_addresses : int
  ; previous_addresses : int
  }

let touch_counts (observed : touches) =
  { current_addresses = Touch_map.cardinal observed.current
  ; previous_addresses = Touch_map.cardinal observed.previous
  }
;;

type blob_status =
  | Present of
      { bytes : int
      ; modified_at : float
      }
  | Absent
  | Not_regular of Unix.file_kind
  | Stat_failed of string

let blob_status t ~sha256 =
  match validate_sha256 sha256 with
  | Error invalid -> Stat_failed (invalid_sha256_to_string invalid)
  | Ok () ->
    (match Unix.lstat (shard_path t sha256) with
     | { Unix.st_kind = Unix.S_REG; st_size; st_mtime; _ } ->
       Present { bytes = st_size; modified_at = st_mtime }
     | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK) as kind; _ } ->
       Not_regular kind
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Absent
     | exception Unix.Unix_error (code, fn, arg) ->
       Stat_failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
;;
