module SS = Set.Make (String)

type t = { root : string }

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
  { root = Filename.concat base_path ".masc/tool_blobs" }

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

let put t ~bytes ~mime =
  let sha256 = Digestif.SHA256.(digest_string bytes |> to_hex) in
  let path = shard_path t sha256 in
  if not (Fs_compat.file_exists path) then begin
    ensure_parent_dir path;
    let _ : (unit, string) result = Fs_compat.save_file_atomic path bytes in
    ()
  end;
  Tool_output.Stored {
    sha256;
    bytes = String.length bytes;
    preview = make_preview bytes;
    mime;
  }

let fetch t ~sha256 =
  let path = shard_path t sha256 in
  if Fs_compat.file_exists path then
    try Some (Fs_compat.load_file path) with _ -> None
  else None

let fetch_exn t ~sha256 =
  match fetch t ~sha256 with
  | Some s -> s
  | None -> raise Not_found

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
