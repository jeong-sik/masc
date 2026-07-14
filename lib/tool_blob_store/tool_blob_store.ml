module SS = Set_util.StringSet

type t = { root : string } [@@unboxed]

type invalid_sha256 =
  | Invalid_sha256_length of { actual : int }
  | Invalid_sha256_character of { index : int; found : char }

let validate_sha256 value =
  let rec validate_character index =
    if index = String.length value then Ok ()
    else
      let found = String.unsafe_get value index in
      if (found >= '0' && found <= '9') || (found >= 'a' && found <= 'f')
      then validate_character (index + 1)
      else Error (Invalid_sha256_character { index; found })
  in
  let actual = String.length value in
  if actual <> 64 then Error (Invalid_sha256_length { actual })
  else validate_character 0

let invalid_sha256_to_string = function
  | Invalid_sha256_length { actual } ->
      Printf.sprintf
        "expected 64 lowercase hexadecimal characters, got length %d"
        actual
  | Invalid_sha256_character { index; found } ->
      Printf.sprintf
        "expected lowercase hexadecimal character at index %d, got %C"
        index
        found

type fetch_error =
  | Invalid_sha256 of invalid_sha256
  | Inspect_failed of { path : string; cause : exn }
  | Unexpected_file_kind of {
      path : string;
      kind : Fs_compat.exact_path_kind;
    }
  | Read_failed of { path : string; cause : exn }
  | Integrity_mismatch of {
      path : string;
      expected : string;
      actual : string;
    }

let fetch_error_to_string = function
  | Invalid_sha256 invalid -> invalid_sha256_to_string invalid
  | Inspect_failed { path; cause } ->
      Printf.sprintf "inspect failed path=%s cause=%s" path (Printexc.to_string cause)
  | Unexpected_file_kind { path; kind } ->
      let kind_name =
        match kind with
        | Fs_compat.Exact_missing -> "missing"
        | Fs_compat.Exact_unknown -> "unknown"
        | Fs_compat.Exact_kind Unix.S_REG -> "regular"
        | Fs_compat.Exact_kind Unix.S_DIR -> "directory"
        | Fs_compat.Exact_kind Unix.S_CHR -> "character-device"
        | Fs_compat.Exact_kind Unix.S_BLK -> "block-device"
        | Fs_compat.Exact_kind Unix.S_LNK -> "symbolic-link"
        | Fs_compat.Exact_kind Unix.S_FIFO -> "fifo"
        | Fs_compat.Exact_kind Unix.S_SOCK -> "socket"
      in
      Printf.sprintf "expected regular blob file path=%s kind=%s" path kind_name
  | Read_failed { path; cause } ->
      Printf.sprintf "read failed path=%s cause=%s" path (Printexc.to_string cause)
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

let inspect_path path =
  Safe_ops.handle
    (fun () -> Ok (Fs_compat.exact_path_kind ~follow:false path))
    (fun cause -> Error (Inspect_failed { path; cause }))

let read_path path =
  Safe_ops.handle
    (fun () -> Ok (Fs_compat.load_file path))
    (fun cause -> Error (Read_failed { path; cause }))

let fetch t ~sha256 =
  match validate_sha256 sha256 with
  | Error invalid -> Error (Invalid_sha256 invalid)
  | Ok () ->
      let path = shard_path t sha256 in
      (match inspect_path path with
       | Error _ as error -> error
       | Ok Fs_compat.Exact_missing -> Ok None
       | Ok (Fs_compat.Exact_kind Unix.S_REG) ->
           (match read_path path with
            | Error _ as error -> error
            | Ok bytes ->
                let actual = Digestif.SHA256.(digest_string bytes |> to_hex) in
                if String.equal sha256 actual then Ok (Some bytes)
                else Error (Integrity_mismatch { path; expected = sha256; actual }))
       | Ok
           ((Fs_compat.Exact_kind
               (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
               | Unix.S_SOCK)
             | Fs_compat.Exact_unknown) as kind) ->
           Error (Unexpected_file_kind { path; kind }))

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
  Tool_output.Stored {
    sha256;
    bytes = String.length bytes;
    preview = make_preview bytes;
    mime;
  }

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

let gc t ~keep_set =
  let keep = List.fold_left (fun acc s -> SS.add s acc) SS.empty keep_set in
  let deleted = ref 0 in
  List.iter (fun sha256 ->
    if not (SS.mem sha256 keep) then begin
      let path = shard_path t sha256 in
      try
        Unix.unlink path;
        incr deleted
      with Unix.Unix_error _ -> ()
    end
  ) (list_all t);
  !deleted
