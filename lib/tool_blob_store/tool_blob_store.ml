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
  | Integrity_mismatch of {
      path : string;
      expected : string;
      actual : string;
    }

let fetch_error_to_string = function
  | Invalid_sha256 invalid -> invalid_sha256_to_string invalid
  | Owned_read_failed error ->
      Fs_compat.owned_regular_file_read_error_to_string error
  | Integrity_mismatch { path; expected; actual } ->
      Printf.sprintf
        "integrity mismatch path=%s expected=%s actual=%s"
        path
        expected
        actual

(* Exported (see the .mli): a caller bounding a marker it has not stored yet
   builds a saturating preview from this, so a copy of the number at that call
   site would silently become an underestimate if this changed. *)
let preview_max = 200

(* Adds exactly one character per source byte and stops at [preview_max], so
   the result length is a hard ceiling rather than an approximation. The
   exported bound depends on that. *)
let make_preview bytes =
  let len = min (String.length bytes) preview_max in
  let buf = Buffer.create len in
  let i = ref 0 in
  while !i < len && Buffer.length buf < preview_max do
    let c = String.unsafe_get bytes !i in
    if c = '\n' || c = '\r' || c = '\t' then Buffer.add_char buf ' '
    else if Char.code c < 0x20 then Buffer.add_char buf '?'
    else Buffer.add_char buf c;
    incr i
  done;
  Buffer.contents buf

let create ~base_path =
  {
    root =
      Filename.concat
        (Common.masc_dir_from_base_path ~base_path)
        "tool_blobs";
    ownership_root = base_path;
  }

let root_dir t = t.root

let shard_path t sha256 =
  let prefix = String.sub sha256 0 2 in
  Filename.concat (Filename.concat t.root prefix) sha256

let rec mkdir_p p =
  if Sys.file_exists p then ()
  else begin
    mkdir_p (Filename.dirname p);
    try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let ensure_parent_dir path = mkdir_p (Filename.dirname path)

let fetch t ~sha256 =
  match validate_sha256 sha256 with
  | Error invalid -> Error (Invalid_sha256 invalid)
  | Ok () ->
      let path = shard_path t sha256 in
      (match
         Fs_compat.load_owned_regular_file_with_snapshot
           ~ownership_root:t.ownership_root
           path
       with
       | Error error -> Error (Owned_read_failed error)
       | Ok None ->
         remove_validated_snapshot path;
         Ok None
       | Ok (Some { content = bytes; snapshot }) ->
         let actual = Digestif.SHA256.(digest_string bytes |> to_hex) in
         if String.equal sha256 actual
         then (
           cache_validated_snapshot path snapshot;
           Ok (Some bytes))
         else (
           remove_validated_snapshot path;
           Error (Integrity_mismatch { path; expected = sha256; actual })))

type range =
  { content : string
  ; total_bytes : int
  }

let range_of_bytes ~offset ~max_bytes bytes =
  let total_bytes = String.length bytes in
  let available = max 0 (total_bytes - offset) in
  let length = min max_bytes available in
  let content =
    if offset > total_bytes
    then ""
    else String.sub bytes offset length
  in
  { content; total_bytes }
;;

let fetch_range t ~sha256 ~offset ~max_bytes =
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
    let path = shard_path t sha256 in
    let cached =
      Validated_file_map.find_opt path (Atomic.get validated_file_snapshots)
    in
    let validate_whole_snapshot () =
      match fetch t ~sha256 with
      | Error _ as error -> error
      | Ok None -> Ok None
      | Ok (Some bytes) ->
        Ok (Some (range_of_bytes ~offset ~max_bytes bytes))
    in
    (match cached with
     | None -> validate_whole_snapshot ()
     | Some { snapshot = validated_snapshot; _ } ->
       (match
          Fs_compat.load_owned_regular_file_range
            ~ownership_root:t.ownership_root
            ~offset
            ~max_bytes
            path
        with
        | Error error -> Error (Owned_read_failed error)
        | Ok None ->
          remove_validated_snapshot path;
          Ok None
        | Ok (Some { content; snapshot })
          when Fs_compat.equal_owned_regular_file_snapshot
                 validated_snapshot
                 snapshot ->
          Ok (Some { content; total_bytes = snapshot.file_size })
        | Ok (Some _) -> validate_whole_snapshot ()))
;;

let put_with_atomic_replace ~atomic_replace ~operation t ~bytes ~mime =
  let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let path = shard_path t sha256 in
  ensure_parent_dir path;
  (* An authoritative atomic rewrite avoids reading and hashing a second full
     copy on idempotent puts, and repairs any corrupt prior bytes at this
     content address. Concurrent writers have byte-identical payloads. *)
  (match atomic_replace path bytes with
   | Ok () -> ()
   | Error msg ->
       raise (Sys_error (Printf.sprintf "tool_blob_store.%s: %s" operation msg)));
  remove_validated_snapshot path;
  (* A digestif-produced sha256 and a byte length are always valid; an empty
     [mime] is the only reachable rejection and is a caller bug, raised
     visibly rather than stored. *)
  match
    Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
      ~preview:(make_preview bytes) ~mime
  with
  | Ok artifact_ref -> artifact_ref
  | Error err ->
    invalid_arg
      (Printf.sprintf "tool_blob_store.%s: %s" operation
         (Tool_output.make_error_to_string err))

let put t ~bytes ~mime =
  Tool_output.Stored
    (put_with_atomic_replace
       ~atomic_replace:Fs_compat.save_file_atomic
       ~operation:"put"
       t
       ~bytes
       ~mime)
;;

let put_durable =
  put_with_atomic_replace
    ~atomic_replace:Fs_compat.save_file_atomic_strict
    ~operation:"put_durable"
;;

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
