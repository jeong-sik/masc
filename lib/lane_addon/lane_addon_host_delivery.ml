let ( let* ) = Result.bind
type owner = { instance_id : string; authority : Yojson.Safe.t }
type error = Refused of string | Storage_failed of string
type retained = {
  request : Lane_addon_host_request.t;
  reference : Lane_addon_types.evidence;
  bytes : int;
  snapshot : Fs_compat.owned_regular_file_snapshot;
  next_cursor : Yojson.Safe.t option;
}

let source_id = function
  | Lane_addon_host_request.Read_records {source_id; _}
  | Read_file {source_id; _} -> Some source_id
  | Exact_output _ | Read_result _ -> None
let nullable value = Option.fold ~none:`Null ~some:(fun text -> `String text) value
let storage result = Result.map_error (fun detail -> Storage_failed detail) result
let wrap request_id result = Lane_addon_host_request.result_arguments ~request_id ~result
let fits ~max_bytes value = String.length (Yojson.Safe.to_string value) <= max_bytes

let snapshot_json (snapshot : Fs_compat.owned_regular_file_snapshot) = `Assoc [
  "device", `Int snapshot.device; "inode", `Int snapshot.inode;
  "owner_uid", `Int snapshot.owner_uid; "permissions", `Int snapshot.permissions;
  "file_size", `Int snapshot.file_size; "modified_at", `Float snapshot.modified_at;
  "changed_at", `Float snapshot.changed_at]
let snapshot_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) =
      ["changed_at"; "device"; "file_size"; "inode"; "modified_at"; "owner_uid"; "permissions"] ->
      let integer key = match List.assoc_opt key fields with
        | Some (`Int value) when value >= 0 -> Ok value
        | Some _ | None -> Error (Storage_failed ("invalid retained result snapshot " ^ key)) in
      let time key = match List.assoc_opt key fields with
        | Some (`Float value) when Float.is_finite value -> Ok value
        | Some _ | None -> Error (Storage_failed ("invalid retained result snapshot " ^ key)) in
      let* device = integer "device" in let* inode = integer "inode" in
      let* owner_uid = integer "owner_uid" in let* permissions = integer "permissions" in
      let* file_size = integer "file_size" in let* modified_at = time "modified_at" in
      let* changed_at = time "changed_at" in
      Ok {Fs_compat.device; inode; owner_uid; permissions; file_size; modified_at; changed_at}
  | _ -> Error (Storage_failed "retained result has no valid source snapshot")

let load ~store ~(owner : owner) ~original_request_id =
  let* saved = Lane_addon_store.load_host_result store ~instance_id:owner.instance_id
      ~request_id:original_request_id |> storage in
  match saved with
  | None -> Ok None
  | Some (`Assoc fields) ->
    let get key = List.assoc_opt key fields in
    let keys = List.map fst fields |> List.sort String.compare in
    let expected = ["instance_id"; "authority"; "request"; "reference"; "bytes"; "snapshot"]
      @ (if List.mem_assoc "next_cursor" fields then ["next_cursor"] else []) |> List.sort String.compare in
    if keys <> expected then Error (Storage_failed "retained result link has unexpected or duplicate fields")
    else if get "instance_id" <> Some (`String owner.instance_id)
       || get "authority" <> Some owner.authority then
      Error (Refused "retained result belongs to another installation or grant authority")
    else
      let* request = match get "request" with
        | None -> Error (Storage_failed "retained result has no original request")
        | Some request ->
            let* listing = Lane_addon_host_request.listing_of_json (`Assoc ["requests", `List [request]]) |> storage in
            (match listing with
             | [((Lane_addon_host_request.Exact_output _ | Read_records _ | Read_file _) as request)]
                 when Lane_addon_host_request.request_id request = original_request_id -> Ok request
             | [] | _ :: _ -> Error (Storage_failed "retained result original request mismatch")) in
      let* reference = match get "reference" with
        | Some value -> Lane_addon_types.evidence_of_json value |> storage
        | None -> Error (Storage_failed "retained result has no byte reference") in
      let* bytes = match get "bytes" with
        | Some (`Int bytes) when bytes >= 0 -> Ok bytes
        | Some _ | None -> Error (Storage_failed "retained result has no byte count") in
      let* snapshot = match get "snapshot" with
        | Some value -> snapshot_of_json value
        | None -> Error (Storage_failed "retained result has no source snapshot") in
      Ok (Some {request; reference; bytes; snapshot; next_cursor=get "next_cursor"})
  | Some _ -> Error (Storage_failed "retained result link is not an object")

let save ~store ~(owner : owner) retained =
  let link = `Assoc
    (["instance_id", `String owner.instance_id; "authority", owner.authority;
      "request", Lane_addon_host_request.to_json retained.request;
      "reference", Lane_addon_types.evidence_to_json retained.reference;
      "bytes", `Int retained.bytes; "snapshot", snapshot_json retained.snapshot]
     @ match retained.next_cursor with None -> [] | Some cursor -> ["next_cursor", cursor]) in
  Lane_addon_store.save_host_result store ~instance_id:owner.instance_id
    ~request_id:(Lane_addon_host_request.request_id retained.request) link |> storage

let slice ~store ~owner retained ~offset ~max_bytes =
  let* captured = match Lane_addon_store.read_blob_slice ~snapshot:retained.snapshot
      store retained.reference ~offset ~max_bytes with
    | Ok captured -> Ok captured
    | Error _ ->
        (* A second request may atomically publish identical content at the same
           hash address. Revalidate that content before refreshing this link. *)
        Lane_addon_store.read_blob_slice store retained.reference ~offset ~max_bytes |> storage in
  let* () = if captured.snapshot.file_size = retained.bytes then Ok ()
    else Error (Storage_failed "retained result byte count changed") in
  let* () = if Fs_compat.equal_owned_regular_file_snapshot retained.snapshot captured.snapshot then Ok ()
    else save ~store ~owner {retained with snapshot=captured.snapshot} in
  Ok captured

let marker ~max_bytes ~request_id retained =
  let* sha256 = match retained.reference.Lane_addon_types.sha256 with
    | Some sha256 -> Ok sha256
    | None -> Error (Storage_failed "retained result has no digest") in
  let arguments = wrap request_id (`Assoc
    (["status", `String "result_exceeds_frame";
      "original_request_id", `String (Lane_addon_host_request.request_id retained.request);
      "source_id", nullable (source_id retained.request);
      "retained_sha256", `String sha256; "bytes", `Int retained.bytes;
      "encoding", `String "json-utf8"; "complete", `Bool false]
     @ match retained.next_cursor with None -> [] | Some cursor -> ["next_cursor", cursor])) in
  if fits ~max_bytes arguments then Ok arguments
  else Error (Refused "retained result reference does not fit the package frame")

let restore ~store ~owner ~request ~max_bytes =
  match request with
  | Lane_addon_host_request.Read_result _ -> Ok None
  | Exact_output _ | Read_records _ | Read_file _ ->
      let request_id = Lane_addon_host_request.request_id request in
      let* retained = load ~store ~owner ~original_request_id:request_id in
      match retained with
      | None -> Ok None
      | Some retained ->
          if Lane_addon_host_request.to_json retained.request <> Lane_addon_host_request.to_json request then
            Error (Refused "request id already names a different retained result")
          else
            let* _ = slice ~store ~owner retained ~offset:0 ~max_bytes:0 in
            marker ~max_bytes ~request_id retained |> Result.map Option.some

let arguments ~store ~owner ~request ~max_bytes ~result =
  let request_id = Lane_addon_host_request.request_id request in
  let inline = wrap request_id result in
  match request with
  | Lane_addon_host_request.Read_result _ ->
      if fits ~max_bytes inline then Ok inline
      else Error (Refused "result continuation does not fit the package frame")
  | Exact_output _ | Read_records _ | Read_file _ ->
      let* existing = restore ~store ~owner ~request ~max_bytes in
      (match existing with
       | Some arguments -> Ok arguments
       | None when fits ~max_bytes inline -> Ok inline
       | None ->
           let bytes = Yojson.Safe.to_string result in
           let* reference = Lane_addon_store.write_blob store bytes |> storage in
           let* captured = Lane_addon_store.read_blob_slice store reference ~offset:0 ~max_bytes:0 |> storage in
           let* () = if captured.snapshot.file_size=String.length bytes then Ok ()
             else Error (Storage_failed "retained result byte count changed during publication") in
           let next_cursor = match result with
             | `Assoc fields -> List.assoc_opt "next_cursor" fields
             | _ -> None in
           let retained = {request; reference; bytes=String.length bytes; snapshot=captured.snapshot; next_cursor} in
           let* () = save ~store ~owner retained in
           marker ~max_bytes ~request_id retained)

let read ~store ~owner ~request_id ~original_request_id ~source_id:requested_source ~sha256
    ~offset ~max_bytes =
  let* retained = load ~store ~owner ~original_request_id in
  match retained with
  | None -> Error (Refused "no retained result for this installation and original request")
  | Some retained ->
      if source_id retained.request <> requested_source || retained.reference.sha256 <> Some sha256 then
        Error (Refused "continuation source or digest does not match the original request")
      else if offset < 0 || offset > retained.bytes then Error (Refused "invalid result continuation offset")
      else
        let body ~content ~length = `Assoc [
          "status", `String "result_chunk"; "original_request_id", `String original_request_id;
          "source_id", nullable requested_source; "sha256", `String sha256;
          "bytes", `Int retained.bytes; "offset", `Int offset; "next_offset", `Int (offset+length);
          "eof", `Bool (offset+length=retained.bytes); "encoding", `String "base64"; "content", `String content] in
        let frame length = wrap request_id (body ~length ~content:(String.make (((length+2)/3)*4) 'a')) in
        (* The last chunk changes false to true, making its envelope one byte
           smaller. Measure with false at the end too, so fitting is monotone. *)
        let measure length =
          let arguments = frame length in
          String.length (Yojson.Safe.to_string arguments) + (if offset+length=retained.bytes then 1 else 0) in
        let rec choose low high =
          if low >= high then low else
            let middle = low + (high-low+1)/2 in
            if measure middle <= max_bytes then choose middle high else choose low (middle-1) in
        let length = choose 0 (min max_bytes (retained.bytes-offset)) in
        if measure length > max_bytes || (length=0 && offset<retained.bytes) then
          Error (Refused "package frame cannot hold a progressing result continuation")
        else
          let* slice = slice ~store ~owner retained ~offset ~max_bytes:length in
          if slice.snapshot.file_size <> retained.bytes || String.length slice.content <> length then
            Error (Storage_failed "retained result byte count changed")
          else Ok (body ~length ~content:(Base64.encode_string slice.content))
