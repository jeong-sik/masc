type reading = {
  body : Keeper_tool_result_source.body;
  source_id : string;
  sha256 : string;
}
let ( let* ) = Result.bind
let digest text = Digestif.SHA256.(to_hex (digest_string text))
(* Same transfer buffer as Fs_compat's streaming owned SHA reader. This is
   not a file, record, result or history limit. *)
let chunk_bytes = 65536

let read_with_range ~read_range ~config ~keeper target =
  let run = Keeper_tool_result_source.run_ref target in
  let directory = Keeper_types_support.keeper_raw_trace_dir config keeper in
  let file = Filename.basename run.path in
  if not (Keeper_config.validate_name keeper)
     || not (String.equal (Filename.dirname run.path) directory)
     || not (Filename.check_suffix file Keeper_types_support.raw_trace_file_extension)
  then Error "Original trace is outside this keeper's retained raw-trace directory"
  else
    let line = Buffer.create chunk_bytes in
    let decode scan =
      let text = Buffer.contents line in
      Buffer.clear line;
      if String.equal (String.trim text) "" then Ok scan
      else
        let* json = match Yojson.Safe.from_string text with
          | json -> Ok json
          | exception Yojson.Json_error _ -> Error "Invalid original JSONL record" in
        let* record = Agent_core.Raw_trace.record_of_yojson json
          |> Result.map_error (fun _ -> "Invalid original raw-trace record schema") in
        Keeper_tool_result_source.observe scan record
        |> Result.map_error Keeper_tool_result_source.error_to_string in
    let consume scan chunk =
      let rec loop scan offset =
        match String.index_from_opt chunk offset '\n' with
        | None -> Buffer.add_substring line chunk offset (String.length chunk-offset); Ok scan
        | Some stop ->
            Buffer.add_substring line chunk offset (stop-offset);
            let* scan = decode scan in
            loop scan (stop+1) in
      loop scan 0 in
    let range offset =
      read_range ~offset ~max_bytes:chunk_bytes run.path
      |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
    let rec loop snapshot context offset scan =
      let* chunk = range offset in
      let* chunk = match chunk with
        | Some (chunk : Fs_compat.owned_regular_file_range) -> Ok chunk
        | None -> Error "Original trace is no longer retained" in
      let* snapshot = match snapshot with
        | None -> Ok chunk.snapshot
        | Some first when Fs_compat.equal_owned_regular_file_snapshot first chunk.snapshot -> Ok first
        | Some _ -> Error "Original trace changed while reading" in
      let remaining = snapshot.file_size - offset in
      if remaining < 0 || String.length chunk.content <> min chunk_bytes remaining
      then Error "Original trace returned a short or inconsistent range"
      else if remaining = 0 then
        if Buffer.length line <> 0 then Error "Original trace ends with an incomplete JSONL record"
        else
          let* body = Keeper_tool_result_source.finish scan
            |> Result.map_error Keeper_tool_result_source.error_to_string in
          let sha256 = digest body.content in
          let file_sha256 = Digestif.SHA256.(to_hex (get context)) in
          let source_id = digest (Yojson.Safe.to_string (`Assoc [
            "keeper", `String keeper;
            "execution_id", Ids.Execution_id.to_yojson body.execution_id;
            "turn_ref", Ids.Turn_ref.to_yojson body.turn_ref;
            "worker_run_id", `String run.worker_run_id;
            "start_seq", `Int run.start_seq; "end_seq", `Int run.end_seq;
            "file", `String file;"file_sha256", `String file_sha256;
            "body_sha256", `String sha256;"snapshot", `Assoc [
              "device",`Int snapshot.device;"inode",`Int snapshot.inode;
              "owner_uid",`Int snapshot.owner_uid;"permissions",`Int snapshot.permissions;
              "file_size",`Int snapshot.file_size;"mtime",`Float snapshot.modified_at;
              "ctime",`Float snapshot.changed_at]])) in
          Ok {body;sha256;source_id}
      else
        let* scan = consume scan chunk.content in
        loop (Some snapshot) (Digestif.SHA256.feed_string context chunk.content)
          (offset+String.length chunk.content) scan in
    loop None Digestif.SHA256.empty 0 (Keeper_tool_result_source.start target)

let read ~config ~keeper target =
  read_with_range ~read_range:(Fs_compat.load_owned_regular_file_range
    ~ownership_root:config.Workspace.base_path) ~config ~keeper target
module For_testing = struct let read = read_with_range end
