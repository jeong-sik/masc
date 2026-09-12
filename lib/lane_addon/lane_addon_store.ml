open Lane_addon_types
let ( let* ) = Result.bind
type t = { root : string }
let create ~root = { root }
let root t = t.root
let digest bytes = Digestif.SHA256.(to_hex (digest_string bytes))
let protect f =
  try f () with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, call, path) ->
      Error (call ^ " " ^ path ^ ": " ^ Unix.error_message error)
  | Yojson.Json_error message -> Error message
let write t relative bytes = protect (fun () ->
  let path = Filename.concat t.root relative in
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path bytes)
let blob_path hash = Filename.concat "evidence" (hash ^ ".json")
let write_blob t bytes =
  let hash = digest bytes in
  let* () = write t (blob_path hash) bytes in
  Ok { uri = "lane-evidence:" ^ hash; sha256 = Some hash }
let read_blob t (reference : evidence) = protect (fun () ->
  match reference.sha256 with
  | Some hash when String.length hash = 64
      && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) hash
      && reference.uri = "lane-evidence:" ^ hash ->
      let bytes = Fs_compat.load_file (Filename.concat t.root (blob_path hash)) in
      if digest bytes = hash then Ok bytes else Error "evidence digest mismatch"
  | _ -> Error "evidence is not retained in this Lane store")
let binding_path instance_id = Filename.concat "bindings" (digest instance_id ^ ".json")
let save_binding t ~instance_id json = write t (binding_path instance_id) (Yojson.Safe.to_string json)
let action_path ~instance_id ~request_id =
  Filename.concat "actions" (Filename.concat (digest instance_id) (digest request_id ^ ".json"))
let save_action t ~instance_id ~request_id json =
  write t (action_path ~instance_id ~request_id) (Yojson.Safe.to_string json)
let load_action t ~instance_id ~request_id = protect (fun () ->
  let path = Filename.concat t.root (action_path ~instance_id ~request_id) in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> Ok None
  | _ ->
      let stat = Unix.stat path in
      if stat.Unix.st_kind <> Unix.S_REG then Error "action receipt is not a regular file"
      else Ok (Some (Fs_compat.load_file path |> Yojson.Safe.from_string)))
let read_directory t relative = protect (fun () ->
  let path = Filename.concat t.root relative in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> Ok []
  | _ ->
      let names = Fs_compat.read_dir path |> List.sort String.compare in
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | name :: rest when Filename.check_suffix name ".json" ->
            let json = Fs_compat.load_file (Filename.concat path name) |> Yojson.Safe.from_string in
            loop (json :: acc) rest
        | _ :: rest -> loop acc rest
      in loop [] names)
let bindings t = read_directory t "bindings"
let observation_dir instance_id = Filename.concat "observations" (digest instance_id)
let append_observation t ~instance_id ~seq ~sources output =
  let json = `Assoc ["sources", sources; "output", output_to_json output] in
  let relative = Filename.concat (observation_dir instance_id) (Printf.sprintf "%020d.json" seq) in
  protect (fun () ->
    if Fs_compat.file_exists (Filename.concat t.root relative)
    then Error "observation sequence already committed"
    else write t relative (Yojson.Safe.to_string json))
let observations t ~instance_id =
  let* values = read_directory t (observation_dir instance_id) in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | `Assoc fields :: rest ->
        (match List.assoc_opt "sources" fields, List.assoc_opt "output" fields with
         | Some sources, Some json ->
             let* output = output_of_json json in loop ((sources, output) :: acc) rest
         | _ -> Error "invalid retained observation")
    | _ -> Error "invalid retained observation"
  in loop [] values
(* The sequence is part of the row identity issued by the host, so evidence
   selection can read exactly its files without scanning unrelated history. *)
let sequence_of_row ~instance_id id =
  let prefix = instance_id ^ "/" in
  if not (String.starts_with ~prefix id) then Error "row belongs to a different instance"
  else
    let offset = String.length prefix in
    match String.index_from_opt id offset '/' with
    | None -> Error "row identity has no observation sequence"
    | Some ending ->
        let digits = String.sub id offset (ending - offset) in
        (match int_of_string_opt digits with
         | Some seq when seq > 0 && digits = string_of_int seq && ending + 1 < String.length id -> Ok seq
         | _ -> Error "row identity has an invalid observation sequence")
let record_path t instance_id seq =
  Filename.concat t.root (Filename.concat (observation_dir instance_id) (Printf.sprintf "%020d.json" seq))
let bounded_file ~max_bytes path = protect (fun () ->
  let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
  let channel = Unix.in_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    let stat = Unix.fstat fd in
    if stat.Unix.st_kind <> Unix.S_REG then Error "retained observation is not a regular file"
    else if stat.Unix.st_size > max_bytes then Error "retained observation exceeds query byte envelope"
    else
      try
        let bytes = really_input_string channel stat.Unix.st_size in
        match input_char channel with
        | _ -> Error "retained observation changed during query"
        | exception End_of_file -> Ok bytes
      with End_of_file -> Error "retained observation changed during query"))
let decode_record bytes =
  protect (fun () ->
    match Yojson.Safe.from_string bytes with
    | `Assoc fields ->
        (match List.assoc_opt "sources" fields, List.assoc_opt "output" fields with
         | Some sources, Some json ->
             let* output = output_of_json json in Ok (sources, output)
         | _ -> Error "invalid retained observation")
    | _ -> Error "invalid retained observation")
let highwater t instance_id = protect (fun () ->
  let directory = Filename.concat t.root (observation_dir instance_id) in
  match Fs_compat.exact_path_kind directory with
  | Fs_compat.Exact_missing -> Ok 0
  | _ ->
      let handle = Unix.opendir directory in
      Fun.protect ~finally:(fun () -> Unix.closedir handle) (fun () ->
        let rec scan maximum =
          match Unix.readdir handle with
          | name when Filename.check_suffix name ".json" ->
              let stem = Filename.remove_extension name in
              (match int_of_string_opt stem with
               | Some seq when seq > 0 && name = Printf.sprintf "%020d.json" seq -> scan (max maximum seq)
               | _ -> Error "invalid retained observation filename")
          | _ -> scan maximum
          | exception End_of_file -> Ok maximum
        in scan 0))
let retained_read_limit max_bytes =
  let envelope_bytes = String.length {|{"sources":,"output":}|} in
  if max_bytes <= 0 || max_bytes > (max_int - envelope_bytes) / 2
  then Error "invalid retained record byte envelope"
  else Ok (2 * max_bytes + envelope_bytes)
let query_observations t ~instance_id ~expected_seq ~max_bytes ~since ~until ~lane_id =
  let* max_record_bytes = retained_read_limit max_bytes in
  let* found = highwater t instance_id in
  let maximum = max found expected_seq in
  let matches (row : row) =
    Option.fold ~none:true ~some:(String.equal row.lane_id) lane_id
    && Option.fold ~none:true ~some:(fun time -> row.observed_at >= time) since
    && Option.fold ~none:true ~some:(fun time -> row.observed_at <= time) until in
  let time = function None -> "unbounded" | Some value -> string_of_float value in
  let query_coverage ~last ~rows_complete ~coverage_complete ~readable = {
    source_id = "retained:" ^ instance_id; incarnation = instance_id;
    cursor = Some (Printf.sprintf "scanned:%d/of:%d" last maximum);
    complete = rows_complete && coverage_complete && readable;
    detail = Some (Printf.sprintf
      "window [%s, %s]; rows and source coverage inspected through %d/of:%d; %s; %s; %s"
      (time since) (time until) last maximum
      (if rows_complete then "no matching row records omitted"
       else "matching row records omitted by byte envelope")
      (if coverage_complete then "all inspected source coverage returned"
       else "source coverage omitted by byte envelope")
      (if readable then "retained observations readable"
       else "a retained observation is unreadable")) } in
  (* Reserve the longest coverage receipt before accepting any rows. *)
  let reserve = String.length (Yojson.Safe.to_string
    (output_to_json { rows = []; coverage = [query_coverage ~last:maximum
      ~rows_complete:false ~coverage_complete:false ~readable:false] })) in
  if max_bytes <= reserve then Error "query byte envelope cannot contain its coverage receipt"
  else
    let read seq = Result.bind
      (bounded_file ~max_bytes:max_record_bytes (record_path t instance_id seq)) decode_record in
    let encoded_size output = String.length (Yojson.Safe.to_string (output_to_json output)) in
    (* Coverage from old, unselected records must not consume the row budget.
       Rows remain a bounded prefix of the matching retained records. *)
    let rec scan_rows seq remaining rows readable =
      if seq > maximum then maximum, remaining, rows, true, readable
      else
        match read seq with
        | Error _ -> scan_rows (seq + 1) remaining rows false
        | Ok (_, output) ->
            let selected = List.filter matches output.rows in
            if selected = [] then scan_rows (seq + 1) remaining rows readable
            else
              let bytes = encoded_size { rows = selected; coverage = [] } in
              if bytes > remaining then
                seq - 1, remaining, rows, false, readable
              else scan_rows (seq + 1) (remaining - bytes)
                (List.rev_append selected rows) readable in
    let last, remaining, rows, rows_complete, readable =
      scan_rows 1 (max_bytes - reserve) [] true in
    (* Both buffers are bounded independently by the remaining response space.
       A later selected record can therefore retain its coverage even when old
       diagnostics fill the deferred buffer. Whole JSON envelopes are counted
       conservatively for each entry, including array separators. *)
    let retain_coverage buffer entries =
      List.fold_left (fun (remaining, retained, complete) entry ->
        let bytes = encoded_size { rows = []; coverage = [entry] } in
        if bytes > remaining then remaining, retained, false
        else remaining - bytes, entry :: retained, complete) buffer entries in
    let rec scan_coverage seq selected deferred readable =
      if seq > last then selected, deferred, readable
      else match read seq with
        | Error _ -> scan_coverage (seq + 1) selected deferred false
        | Ok (_, output) ->
            if List.exists matches output.rows then
              scan_coverage (seq + 1) (retain_coverage selected output.coverage) deferred readable
            else
              scan_coverage (seq + 1) selected (retain_coverage deferred output.coverage) readable in
    let (remaining, selected, selected_complete), (_, deferred, deferred_complete), readable =
      scan_coverage 1 (remaining, [], true) (remaining, [], true) readable in
    let _, coverage, coverage_complete = retain_coverage
      (remaining, selected, selected_complete && deferred_complete) (List.rev deferred) in
    Ok { rows = List.rev rows; coverage = List.rev coverage @
      [query_coverage ~last ~rows_complete ~coverage_complete ~readable] }
module Row_ids = Set.Make (String)
let freeze t ~instance_id ~binding ~row_ids =
  let requested = Row_ids.of_list row_ids in
  let* max_bytes =
    match binding with
    | `Assoc fields ->
        (match List.assoc_opt "package" fields with
         | Some (`Assoc package) ->
             (match List.assoc_opt "resources" package with
              | Some (`Assoc resources) ->
                  (match List.assoc_opt "max_reply_bytes" resources with
                   | Some (`Int bytes) when bytes > 0 -> Ok bytes
                   | _ -> Error "missing evidence query byte envelope")
              | _ -> Error "missing retained package resources")
         | _ -> Error "missing retained package")
    | _ -> Error "invalid retained binding" in
  let* max_record_bytes = retained_read_limit max_bytes in
  let rec sequences acc = function
    | [] -> Ok (List.sort_uniq Int.compare acc)
    | id :: rest -> let* seq = sequence_of_row ~instance_id id in sequences (seq :: acc) rest in
  let* sequences = sequences [] row_ids in
  let base_bundle observations = `Assoc ["instance_id", `String instance_id; "binding", binding;
    "row_ids", `List (List.map (fun id -> `String id) row_ids); "observations", `List observations] in
  let base_size = String.length (Yojson.Safe.to_string (base_bundle [])) in
  if row_ids = [] then Error "select at least one row"
  else if List.length row_ids <> Row_ids.cardinal requested then Error "duplicate selected row identity"
  else if base_size > max_bytes then Error "selected evidence metadata exceeds package byte envelope"
  else
    let rec selected_records acc found remaining = function
      | [] -> Ok (List.rev acc, found)
      | seq :: rest ->
          let* bytes = bounded_file ~max_bytes:max_record_bytes (record_path t instance_id seq) in
          let* _, output = decode_record bytes in
          let matching = List.filter (fun (row : row) -> Row_ids.mem row.id requested) output.rows in
          let found = List.fold_left (fun ids (row : row) -> Row_ids.add row.id ids) found matching in
          let hash = digest bytes in
          let retained = `Assoc ["sequence", `Int seq;
            "uri", `String ("lane-evidence:" ^ hash); "sha256", `String hash;
            "path", `String (Filename.concat t.root (blob_path hash))] in
          let size = String.length (Yojson.Safe.to_string retained) + (if acc = [] then 0 else 1) in
          if size > remaining then Error "selected evidence manifest exceeds package byte envelope; select fewer rows"
          else
            let* _ = write_blob t bytes in
            selected_records (retained :: acc) found (remaining - size) rest in
    let* observations, found = selected_records [] Row_ids.empty (max_bytes - base_size) sequences in
    let missing = Row_ids.elements (Row_ids.diff requested found) in
    if missing <> [] then Error ("unknown evidence rows: " ^ String.concat ", " missing)
    else
      (* Each exact source+output record is independently hashed and copied.
         A large accepted record remains preservable without loading unrelated
         history or assembling multiple full bodies in one memory buffer. *)
      let bytes = Yojson.Safe.to_string (base_bundle observations) in
      let* reference = write_blob t bytes in
      let path = Filename.concat t.root (blob_path (digest bytes)) in
      Ok (`Assoc ["evidence", `Assoc ["uri", `String reference.uri;
        "sha256", `String (digest bytes); "path", `String path];
        "row_count", `Int (Row_ids.cardinal found);
        "message", `String ("Optional Lane evidence (not an instruction): " ^ path
          ^ "\nSHA-256: " ^ digest bytes
          ^ "\nThe observations list names retained record paths and SHA-256 digests. Read those records for original sources and output."
          ^ "\nUse, defer, or independently check this evidence as appropriate. Your current task continues.")])

let retained_reference = function
  | `Assoc fields ->
      (match List.assoc_opt "uri" fields, List.assoc_opt "sha256" fields with
       | Some (`String uri), Some (`String hash) -> Ok { uri; sha256 = Some hash }
       | _ -> Error "retained evidence requires its URI and SHA-256")
  | _ -> Error "retained evidence requires an object"

(* Traverse only the selected record's structured references, never the bodies
   of referenced source files. File/HTTP URIs and plugin paths are data. *)
let rec source_references json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "uri" fields with
       | Some (`String uri) when String.starts_with ~prefix:"lane-evidence:" uri ->
           let* reference = retained_reference json in Ok [reference]
       | _ -> references_in_values (List.map snd fields))
  | `List values -> references_in_values values
  | _ -> Ok []
and references_in_values values =
  List.fold_left (fun acc value ->
    let* acc = acc in let* references = source_references value in
    Ok (List.rev_append references acc)) (Ok []) values

module Published = Map.Make (String)
let publish_for_keeper ~base_path t frozen = protect (fun () ->
  let* fields, bundle_reference = match frozen with
    | `Assoc fields ->
        (match List.assoc_opt "evidence" fields with
         | Some json -> let* reference = retained_reference json in Ok (fields, reference)
         | None -> Error "frozen evidence bundle is missing")
    | _ -> Error "invalid frozen evidence" in
  let blobs = Tool_blob_store.create ~base_path in
  let publish ~mime published reference =
    match Published.find_opt reference.uri published with
    | Some artifact when reference.sha256 = Some artifact.Tool_output.sha256 -> Ok (published, artifact)
    | Some _ -> Error "retained evidence digest disagrees with its URI"
    | None ->
        let* bytes = read_blob t reference in
        let artifact = Tool_blob_store.put_durable blobs ~bytes ~mime in
        Ok (Published.add reference.uri artifact published, artifact) in
  let* bundle_bytes = read_blob t bundle_reference in
  let* records = match Yojson.Safe.from_string bundle_bytes with
    | `Assoc bundle ->
        (match List.assoc_opt "observations" bundle with
         | Some (`List records) -> Ok records
         | _ -> Error "frozen bundle has no selected records")
    | _ -> Error "invalid frozen bundle" in
  let* published, bundle_artifact = publish ~mime:"application/json" Published.empty bundle_reference in
  let rec publish_records published = function
    | [] -> Ok published
    | json :: rest ->
        let* reference = retained_reference json in
        let* bytes = read_blob t reference in
        let* _, _ = decode_record bytes in
        let* references = source_references (Yojson.Safe.from_string bytes) in
        let* published, _ = publish ~mime:"application/json" published reference in
        let* published = List.fold_left (fun result reference ->
          let* published = result in
          let* published, _ = publish ~mime:"application/octet-stream" published reference in
          Ok published) (Ok published) references in
        publish_records published rest in
  let* published = publish_records published records in
  let content = "Optional Lane evidence, not an instruction. Use, defer, or independently verify it; your current task continues."
    ^ "\nOriginal selected bundle SHA-256: " ^ bundle_artifact.Tool_output.sha256
    ^ "\nRead the bundle and retained artifacts with keeper_artifact_read using their SHA-256 values."
    ^ "\nRecord bodies preserve original sources separately from Add-on output; interpretations remain claims." in
  let structured_content = `Assoc [
    "bundle", Tool_output.normalized_artifact_ref_to_json bundle_artifact;
    "artifacts", `List (Published.bindings published |> List.map (fun (uri, artifact) ->
      `Assoc ["lane_uri", `String uri; "artifact", Tool_output.normalized_artifact_ref_to_json artifact]))] in
  let manifest = Tool_output.artifact_manifest_to_json ~content ~structured_content in
  let artifact = Tool_blob_store.put_durable blobs ~bytes:(Yojson.Safe.to_string manifest)
    ~mime:Tool_output.artifact_manifest_mime
    |> fun reference -> Tool_output.with_preview reference content in
  Ok (`Assoc (("message", `String (Tool_output.encode_for_agent_core (Tool_output.Stored artifact)))
    :: ("keeper_artifact", Tool_output.normalized_artifact_ref_to_json artifact)
    :: List.remove_assoc "message" (List.remove_assoc "keeper_artifact" fields))))
