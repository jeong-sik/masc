type t =
  { root : string
  ; ownership_root : string
  }

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

let preview_max = 200

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
         Fs_compat.load_owned_regular_file
           ~ownership_root:t.ownership_root
           path
       with
       | Error error -> Error (Owned_read_failed error)
       | Ok None -> Ok None
       | Ok (Some bytes) ->
         let actual = Digestif.SHA256.(digest_string bytes |> to_hex) in
         if String.equal sha256 actual
         then Ok (Some bytes)
         else Error (Integrity_mismatch { path; expected = sha256; actual }))

let put t ~bytes ~mime =
  let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let path = shard_path t sha256 in
  ensure_parent_dir path;
  (* An authoritative atomic rewrite avoids reading and hashing a second full
     copy on idempotent puts, and repairs any corrupt prior bytes at this
     content address. Concurrent writers have byte-identical payloads. *)
  (match Fs_compat.save_file_atomic path bytes with
   | Ok () -> ()
   | Error msg ->
       raise (Sys_error (Printf.sprintf "tool_blob_store.put: %s" msg)));
  (* A digestif-produced sha256 and a byte length are always valid; an empty
     [mime] is the only reachable rejection and is a caller bug, raised
     visibly rather than stored. *)
  match
    Tool_output.make_artifact_ref ~sha256 ~bytes:(String.length bytes)
      ~preview:(make_preview bytes) ~mime
  with
  | Ok artifact_ref -> Tool_output.Stored artifact_ref
  | Error err ->
    invalid_arg
      (Printf.sprintf "tool_blob_store.put: %s"
         (Tool_output.make_error_to_string err))

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
  let read_dir path =
    try Ok (Sys.readdir path) with
    | Sys_error reason -> Error { path; reason }
    | Unix.Unix_error (code, fn, arg) ->
      Error
        { path
        ; reason =
            Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
        }
  in
  if not (Sys.file_exists t.root)
  then Ok []
  else
    match read_dir t.root with
    | Error _ as error -> error
    | Ok shards ->
      let rec scan_shards acc index =
        if index = Array.length shards
        then Ok acc
        else
          let shard_dir = Filename.concat t.root shards.(index) in
          try
            if not (Sys.is_directory shard_dir)
            then scan_shards acc (index + 1)
            else
              (match read_dir shard_dir with
               | Error _ as error -> error
               | Ok files ->
                 let acc =
                   Array.fold_left
                     (fun current filename ->
                        match validate_sha256 filename with
                        | Ok () -> filename :: current
                        | Error _ -> current)
                     acc
                     files
                 in
                 scan_shards acc (index + 1))
          with
          | Sys_error reason ->
            Error { path = shard_dir; reason }
      in
      scan_shards [] 0

type delete_error =
  { sha256 : string
  ; path : string
  ; reason : string
  }

let delete_error_to_string { sha256; path; reason } =
  Printf.sprintf "blob delete failed sha256=%s path=%s: %s" sha256 path reason
;;

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
    if not (Sys.file_exists path)
    then Ok false
    else
      (try
         Unix.unlink path;
         Ok true
       with
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
       | Sys_error reason -> Error { sha256; path; reason })
