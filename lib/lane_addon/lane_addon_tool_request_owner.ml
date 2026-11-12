open Result.Syntax
type error = Binding_conflict | Store_unavailable of string | Invalid_identity of string
  | Invalid_request of string
type installation = Configuration of string | Manual of string
let installation_id = function
  | Configuration id -> Yojson.Safe.to_string (`List [`String "configuration"; `String id])
  | Manual id -> Yojson.Safe.to_string (`List [`String "manual"; `String id])
let installation_of_id encoded =
  let* json = try Ok (Yojson.Safe.from_string encoded)
    with Yojson.Json_error detail -> Error detail in
  let* installation = match json with
    | `List [`String "configuration";`String id] when String.trim id<>"" -> Ok (Configuration id)
    | `List [`String "manual";`String id] when String.trim id<>"" -> Ok (Manual id)
    | _ -> Error "invalid original installation identity" in
  if String.equal encoded (installation_id installation) then Ok installation
  else Error "original installation identity is not canonical"
(* A record as discovery reads it: everything but the request body. *)
module Record = struct
  type t = {
    scope : string; request_id : string; installation_id : string;
    package_id : string; tool : string; request_digest : string; summary : Yojson.Safe.t;
    progress : Lane_addon_request_progress.t;
  }
  let scope r = r.scope
  let request_id r = r.request_id
  let installation_id r = r.installation_id
  let package_id r = r.package_id
  let tool r = r.tool
  let request_digest r = r.request_digest
  let summary r = r.summary
  let progress r = r.progress
end
type retained = {
  scope : string; request_id : string; installation_id : string;
  package_id : string; tool : string; request_digest : string; summary : Yojson.Safe.t;
  request : Yojson.Safe.t; progress : Lane_addon_request_progress.t;
}
let schema = "lane.addon.tool-request-owner.v4"
let validate_identity fields =
  match List.find_opt (fun (_, value) -> String.trim value = "") fields with
  | None -> Ok ()
  | Some (field, _) -> Error (Invalid_identity field)
let digest request = Lane_addon_store.digest (Yojson.Safe.to_string request)
let request_digest request = Result.map digest (Lane_addon_action.canonical request)
(* The record names its request by digest; the body is stored once beside it,
   so progress rewrites only this record. The summary is the consumer's own
   index of the request, fixed at retain like the request. *)
let to_json (r : retained) = `Assoc ["schema", `String schema;
  "scope", `String r.scope; "request_id", `String r.request_id;
  "installation_id", `String r.installation_id; "package_id", `String r.package_id;
  "tool", `String r.tool; "request_digest", `String r.request_digest; "summary", r.summary;
  "progress", Lane_addon_request_progress.to_json r.progress]
let with_request (r : Record.t) request : retained =
  {scope=r.scope; request_id=r.request_id; installation_id=r.installation_id; package_id=r.package_id;
   tool=r.tool; request_digest=r.request_digest; summary=r.summary; request; progress=r.progress}
let decode_record ~scope ~request_id json =
  let* fields = match json with
    | `Assoc fields when List.sort String.compare (List.map fst fields) =
        List.sort String.compare ["schema"; "scope"; "request_id";
          "installation_id"; "package_id"; "tool"; "request_digest"; "summary"; "progress"] -> Ok fields
    | _ -> Error "invalid original request record fields" in
  let text key = match List.assoc key fields with
    | `String value when String.trim value <> "" -> Ok value
    | _ -> Error ("invalid original request " ^ key) in
  let* version = text "schema" in
  let* () = if String.equal version schema then Ok () else Error "unknown original request schema" in
  let* stored_scope = text "scope" in
  let* stored_id = text "request_id" in
  let* () = if String.equal stored_scope scope && String.equal stored_id request_id then Ok ()
    else Error "original request does not match its storage key" in
  let* installation_id = text "installation_id" in
  let* package_id = text "package_id" in
  let* tool = text "tool" in
  let* request_digest = text "request_digest" in
  let* () = if String_util.is_lowercase_sha256_hex request_digest then Ok ()
    else Error "original request digest is not a SHA-256 digest" in
  (* Like the body, the summary must already be the canonical form retain wrote. *)
  let stored_summary = List.assoc "summary" fields in
  let* summary = Lane_addon_action.canonical stored_summary in
  let* () = if String.equal (Yojson.Safe.to_string summary) (Yojson.Safe.to_string stored_summary) then Ok ()
    else Error "original request summary is not canonical" in
  let* progress = Lane_addon_request_progress.of_json (List.assoc "progress" fields) in
  Ok ({Record.scope; request_id; installation_id; package_id; tool; request_digest; summary; progress} : Record.t)
(* Decoding a record checks its summary and every receipt of its progress by
   writing them canonical again and hashing them, so it costs CPU in proportion
   to what the record carries. On the server's main domain this was the largest
   allocator (7.1% of the domain's samples, with the canonical walk another
   5.2%; 2026-11-12, twelve minutes after a start). A fiber hands the decode to
   the CPU pool and waits; it reads nothing but its arguments. A caller that is
   not a fiber, a job of the pool itself, or a process with no pool decodes
   where it is. *)
let decode_job = "lane-addon-original-request-record-decode"
let decode ~scope ~request_id json =
  Domain_pool_ref.submit_cpu_or_inline ~name:decode_job (fun () ->
    decode_record ~scope ~request_id json)
(* The body a record names: present, its bytes named by that digest, and the
   canonical JSON of the request. *)
let check_body ~request_digest bytes =
  let* () = if String.equal (Lane_addon_store.digest bytes) request_digest then Ok ()
    else Error "original request body does not match its record's digest" in
  let* json = try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail in
  let* request = Lane_addon_action.canonical json in
  if String.equal (Yojson.Safe.to_string request) bytes then Ok request
  else Error "original request body is not canonical"
(* The check hashes the body, parses it and writes it out again: CPU work in
   proportion to its size, and a body can be tens of megabytes. A fiber doing
   that itself keeps every other fiber of its domain waiting until it is done,
   so the fiber hands it to the CPU pool and waits. The check reads nothing but
   its arguments. A caller that is not a fiber, or a process with no pool, runs
   it where it is. *)
let request_of_body ~request_digest = function
  | None -> Error "original request body named by its record is missing"
  | Some bytes ->
    Domain_pool_ref.submit_cpu_or_inline ~name:"lane-addon-original-request-check" (fun () ->
      check_body ~request_digest bytes)
(* A record names its request by digest, so equal digests are equal requests;
   comparing them never walks the request itself. *)
let same_listed (a : Record.t) (b : Record.t) =
  String.equal a.scope b.scope && String.equal a.request_id b.request_id
  && String.equal a.installation_id b.installation_id && String.equal a.package_id b.package_id
  && String.equal a.tool b.tool && String.equal a.request_digest b.request_digest
  && Yojson.Safe.equal a.summary b.summary && a.progress = b.progress
let listed (r : retained) : Record.t =
  {scope=r.scope; request_id=r.request_id; installation_id=r.installation_id; package_id=r.package_id;
   tool=r.tool; request_digest=r.request_digest; summary=r.summary; progress=r.progress}
let record_to_json record = to_json (with_request record `Null)
let same_record a b = same_listed (listed a) (listed b)
let load ~store ~scope ~request_id =
  let* () = validate_identity ["scope", scope; "request_id", request_id] in
  let unavailable detail = Store_unavailable detail in
  (* The record and its body in one read, so a settle between them cannot
     leave a record whose body looks lost. *)
  let* read = Lane_addon_store.load_tool_request store ~scope ~request_id ~name_body:(fun json ->
      Result.map (fun (record : Record.t) -> record,record.request_digest) (decode ~scope ~request_id json))
    |> Result.map_error unavailable in
  match read with
  | None -> Ok None
  | Some (record,body) ->
    let* request = request_of_body ~request_digest:record.request_digest body |> Result.map_error unavailable in
    Ok (Some (with_request record request))
let discover ~store ~scope =
  let* () = validate_identity ["scope",scope] in
  let unavailable value = Result.map_error (fun detail -> Store_unavailable detail) value in
  let* rows = Lane_addon_store.tool_request_owner_inventory store ~scope |> unavailable in
  let rec decode_all records = function
    | [] -> Ok (List.rev records)
    | (name,json) :: rest ->
      let* request_id = (match json with
        | `Assoc fields -> (match List.assoc_opt "request_id" fields with
            | Some (`String value) when String.trim value <> "" -> Ok value
            | _ -> Error "missing original request ID")
        | _ -> Error "invalid original request record") |> unavailable in
      let* () = if String.equal name (Lane_addon_store.digest request_id ^ ".json") then Ok ()
        else Error (Store_unavailable "original request filename does not match its ID") in
      let* record = decode_record ~scope ~request_id json |> unavailable in
      decode_all (record :: records) rest in
  (* One job for the whole inventory, not one per record. *)
  Domain_pool_ref.submit_cpu_or_inline ~name:decode_job (fun () -> decode_all [] rows)
let decode_published ~directory_name ~file_name json =
  let field key = match json with
    | `Assoc fields -> (match List.assoc_opt key fields with
        | Some (`String value) when String.trim value <> "" -> Ok value
        | Some _ | None -> Error ("missing original request " ^ key))
    | _ -> Error "invalid original request record" in
  let* scope = field "scope" in
  let* request_id = field "request_id" in
  let* record = decode ~scope ~request_id json in
  if not (String.equal directory_name (Lane_addon_store.digest scope))
  then Error "original request directory does not match its scope"
  else if not (String.equal file_name (Lane_addon_store.digest request_id ^ ".json"))
  then Error "original request filename does not match its ID"
  else Ok record

type observation_issue = Malformed_owner_metadata
type observation = { records : Record.t list; issues : observation_issue list }

(* Unlike strict discovery, a verified file's malformed JSON or owner schema is
   reported alongside other records. Filesystem/durability errors and a valid
   claimed scope or key that differs from its physical name remain failures. *)
let observe ~store ~scope =
  let* () = validate_identity ["scope",scope] in
  let* entries = Lane_addon_store.observe_tool_request_owner_metadata store ~scope
    |> Result.map_error (fun detail -> Store_unavailable detail) in
  let field name = function
    | `Assoc fields -> (match List.assoc_opt name fields with
        | Some (`String value) when String.trim value <> "" -> Some value
        | Some _ | None -> None)
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> None in
  (* Check every claimed identity, including later duplicate fields, before a
     malformed record can be classified as merely unattributable. *)
  let identity_conflicts file_name = function
    | `Assoc fields -> List.exists (fun (name,value) ->
        match value with
        | `String claimed when String.trim claimed <> "" && String.equal name "scope" ->
          not (String.equal claimed scope)
        | `String claimed when String.trim claimed <> "" && String.equal name "request_id" ->
          not (String.equal file_name (Lane_addon_store.digest claimed ^ ".json"))
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _ -> false)
        fields
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false in
  let rec collect records issues = function
    | [] -> Ok {records=List.rev records; issues=List.rev issues}
    | Lane_addon_store.Malformed_owner_json :: rest ->
      collect records (Malformed_owner_metadata::issues) rest
    | Published_owner_metadata (file_name,json) :: rest ->
      if identity_conflicts file_name json
      then Error (Store_unavailable "observed original metadata does not match its scope or filename")
      else (match field "scope" json, field "request_id" json with
       | Some _, Some request_id ->
         (match decode_record ~scope ~request_id json with
           | Ok record -> collect (record::records) issues rest
           | Error _ -> collect records (Malformed_owner_metadata::issues) rest)
       | None, (Some _ | None) | Some _, None ->
         collect records (Malformed_owner_metadata::issues) rest) in
  Domain_pool_ref.submit_cpu_or_inline ~name:decode_job (fun () -> collect [] [] entries)

module Published_reader = struct
  type verified = { bytes : string; request : Yojson.Safe.t }
  type t = {
    read_body : scope:string -> request_digest:string -> (string option, string) result;
    verified : (string * string, verified) Hashtbl.t;
  }
  let create ~read_body = {read_body; verified=Hashtbl.create 0}
  let request reader ~scope ~request_digest =
    let key=scope,request_digest in
    match reader.read_body ~scope ~request_digest with
    | Error detail -> Hashtbl.remove reader.verified key; Error detail
    | Ok None ->
      Hashtbl.remove reader.verified key;
      request_of_body ~request_digest None
    | Ok (Some bytes) ->
      (match Hashtbl.find_opt reader.verified key with
       | Some verified when String.equal bytes verified.bytes -> Ok verified.request
       | None | Some _ ->
         Hashtbl.remove reader.verified key;
         let+ request=request_of_body ~request_digest (Some bytes) in
         Hashtbl.replace reader.verified key {bytes;request};
         request)
  let read reader ~directory_name ~file_name json =
    let* record=decode_published ~directory_name ~file_name json in
    let+ request=request reader ~scope:record.Record.scope ~request_digest:record.request_digest in
    with_request record request
end
let unavailable result = Result.map_error (fun detail -> Store_unavailable detail) result
let load_listed ~store (record : Record.t) =
  let* original = load ~store ~scope:record.scope ~request_id:record.request_id in
  match original with
  | Some original when same_listed record (listed original) -> Ok original
  | Some _ -> Error (Store_unavailable "an inventoried original changed")
  | None -> Error (Store_unavailable "an inventoried original disappeared")
(* Retain fixes the digest a record names its body by, so the record of the
   same ID naming the same digest names the body [previous] already read and
   checked; only its progress can differ. Reading the record alone keeps a
   progress re-check from parsing the body again. *)
let reload ~store (previous : retained) =
  let* () = validate_identity ["scope", previous.scope; "request_id", previous.request_id] in
  let* json = Lane_addon_store.load_tool_request_owner store
      ~scope:previous.scope ~request_id:previous.request_id |> unavailable in
  match json with
  | None -> Ok None
  | Some json ->
    let* record = decode ~scope:previous.scope ~request_id:previous.request_id json |> unavailable in
    if String.equal record.request_digest previous.request_digest
    && String.equal record.installation_id previous.installation_id
    && String.equal record.package_id previous.package_id
    && String.equal record.tool previous.tool
    && Yojson.Safe.equal record.summary previous.summary
    then Ok (Some (with_request record previous.request))
    else Error (Store_unavailable "a reloaded original names another request or binding")
let load_scope ~store ~scope =
  let* records = discover ~store ~scope in
  let rec restore found = function
    | [] -> Ok (List.rev found)
    | record::rest ->
      let* original = load_listed ~store record in
      restore (original::found) rest in
  restore [] records
let fold_all_with ~after_inventory ~store ~init ~f =
  let* records_rev =
    Lane_addon_store.fold_tool_request_owner_inventory_all store ~init:[]
      ~f:(fun records ~directory_name ~file_name json ->
        let* record = decode_published ~directory_name ~file_name json in
        Ok (record::records))
    |> unavailable
  in
  after_inventory ();
  let rec restore acc = function
    | [] -> Ok acc
    | record::rest ->
      let* original = load_listed ~store record in
      restore (f acc original) rest in
  restore init (List.rev records_rev)
let fold_all ~store ~init ~f = fold_all_with ~after_inventory:(fun () -> ()) ~store ~init ~f
let discover_all ~store =
  let* records = fold_all ~store ~init:[] ~f:(fun records original -> original::records) in
  Ok (List.rev records)
let prepare_successor ~store ~scope ~request_id ~request =
  let* () = validate_identity ["scope",scope;"request_id",request_id] in
  let* request = Lane_addon_action.canonical request
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let bytes = Yojson.Safe.to_string request in
  let request_digest = Lane_addon_store.digest bytes in
  let* () = Lane_addon_store.save_tool_request_body store ~scope ~request_digest bytes |> unavailable in
  Ok {Lane_addon_request_progress.request_id;request_digest}
let load_successor_request ~store ~scope (successor : Lane_addon_request_progress.successor) =
  let* () = validate_identity ["scope",scope;"request_id",successor.request_id] in
  let* bytes = Lane_addon_store.load_tool_request_body store ~scope
    ~request_digest:successor.request_digest |> unavailable in
  request_of_body ~request_digest:successor.request_digest bytes |> unavailable
let retain ~store ~scope ~request_id ~installation_id ~package_id ~tool ~summary ~request =
  let* () = validate_identity ["scope", scope; "request_id", request_id;
    "installation_id", installation_id; "package_id", package_id; "tool", tool] in
  let* request = Lane_addon_action.canonical request
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let* summary = Lane_addon_action.canonical summary
    |> Result.map_error (fun detail -> Invalid_request detail) in
  let bytes = Yojson.Safe.to_string request in
  let expected = {scope; request_id; installation_id; package_id; tool;
    request_digest = Lane_addon_store.digest bytes; summary; request; progress=Lane_addon_request_progress.captured} in
  let* previous = load ~store ~scope ~request_id in
  match previous with
  | Some previous ->
    (* Retaining the immutable input must not reset an already advancing tail. *)
    if same_record {previous with progress=Lane_addon_request_progress.captured} expected
    then Ok () else Error Binding_conflict
  | None ->
    (* The body is durable before any record names it. A retain interrupted
       between the two writes leaves a body no record names: retaining the same
       request again writes it again, and nothing reads it otherwise. *)
    let* () = Lane_addon_store.save_tool_request_body store ~scope ~request_digest:expected.request_digest bytes
      |> Result.map_error (fun detail -> Store_unavailable detail) in
    Lane_addon_store.save_tool_request_owner store ~scope ~request_id (to_json expected)
      |> Result.map_error (fun detail -> Store_unavailable detail)
type update_error = Ownership_error of error | State_conflict | Invalid_transition of string
type publication = Stored of retained | Already_stored of retained | Unconfirmed of string
let advance_events_with ~save ~store ~(expected : retained) ~events =
  let rec append_events progress = function
    | [] -> Ok progress
    | event :: rest ->
      let* progress = Lane_addon_request_progress.append progress event
        |> Result.map_error (fun detail -> Invalid_transition detail) in
      append_events progress rest in
  let* progress = match events with
    | [] -> Error (Invalid_transition "progress event batch is empty")
    | _ -> append_events expected.progress events in
  let next = {expected with progress} in
  let unavailable detail = Ownership_error (Store_unavailable detail) in
  let* stored = Lane_addon_store.load_tool_request_owner store ~scope:expected.scope ~request_id:expected.request_id
    |> Result.map_error unavailable in
  match stored with
  | None -> Error State_conflict
  | Some json ->
    (* Progress reads and rewrites only the record. A record naming another
       body differs from [expected] in its digest. *)
    let* stored = decode ~scope:expected.scope ~request_id:expected.request_id json
      |> Result.map_error unavailable in
    if not (String.equal stored.request_digest expected.request_digest) then Error State_conflict else
    let previous = with_request stored expected.request in
    if same_record previous next then Ok (Already_stored previous)
    else if not (same_record previous expected) then Error State_conflict
    else match save store
        ~scope:expected.scope ~request_id:expected.request_id (to_json next) with
      | Ok () -> Ok (Stored next)
      | Error detail -> Ok (Unconfirmed detail)
let advance_events ~store ~expected ~events =
  advance_events_with ~save:Lane_addon_store.save_tool_request_owner ~store ~expected ~events
let advance ~store ~expected ~event =
  advance_events ~store ~expected ~events:[event]
module For_testing = struct
  let fold_all ~store ~(after_inventory : unit -> unit) ~init ~f =
    fold_all_with ~after_inventory ~store ~init ~f
  let advance_events = advance_events_with
end
type settle_error = Settle_unavailable of string | Settle_changed
let settle ~store ~date (expected : Record.t) =
  let unavailable detail = Settle_unavailable detail in
  let check_record = function
    (* An absent record was settled already, or is in neither place, which the
       store reports. *)
    | None -> Ok true
    | Some json ->
      let* stored = decode ~scope:expected.scope ~request_id:expected.request_id json in
      Ok (same_listed stored expected) in
  let* moved = Lane_addon_store.settle_tool_request store ~scope:expected.scope ~date
      ~request_id:expected.request_id ~request_digest:expected.request_digest ~check_record
    |> Result.map_error unavailable in
  if moved then Ok () else Error Settle_changed
let settled ~store ~scope ~date ~request_id =
  Lane_addon_store.tool_request_settled store ~scope ~date ~request_id
  |> Result.map_error (fun detail -> Store_unavailable detail)
let load_settled ~store ~scope ~date ~request_id =
  let unavailable detail = Store_unavailable detail in
  let* () = validate_identity ["scope",scope;"request_id",request_id] in
  let* record = Lane_addon_store.load_settled_tool_request_owner store ~scope ~date ~request_id
    |> Result.map_error unavailable in
  match record with
  | None -> Ok None
  | Some json -> Result.map Option.some (decode ~scope ~request_id json)
    |> Result.map_error unavailable
let settle_error_to_string = function
  | Settle_unavailable detail -> "Add-on request ownership unavailable: " ^ detail
  | Settle_changed -> "Original Add-on request changed before it was settled"
let error_to_string = function
  | Binding_conflict -> "Original Add-on request is bound to another installation, tool or captured input"
  | Store_unavailable detail -> "Add-on request ownership unavailable: " ^ detail
  | Invalid_identity field -> "Add-on request ownership requires " ^ field
  | Invalid_request detail -> "Invalid captured Add-on request: " ^ detail
let update_error_to_string = function
  | Ownership_error error -> error_to_string error
  | State_conflict -> "Original Add-on request changed before progress publication"
  | Invalid_transition detail -> "Invalid Add-on request progress: " ^ detail
