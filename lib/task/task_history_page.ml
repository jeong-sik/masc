open Result.Syntax
module Layout = Dated_jsonl.Layout

type source = Activity | Audit
type availability = Observed | Not_created
let sources = [Activity; Audit]
let store = function Activity -> Dated_jsonl.Store.Root.Activity_events | Audit -> Events
let source_name source = Dated_jsonl.Store.Root.relative_path (store source)
let source_of_name = function "activity-events" -> Some Activity | "events" -> Some Audit | _ -> None
type position = { file : string; device : int; inode : int; before : int; anchor : string }
type ceiling = { file : string; size : int }
type cursor = { task : string; workspace : string; ceilings : ceiling list; inventory : string; position : position }
type error = Invalid_request | Invalid_cursor | Source_changed
  | Invalid_event of { file : string; offset : int }
  | Invalid_layout of { entry : string } | Source_unavailable
type page = { task_id : string; cursor : cursor option; sources : (source * availability) list;
  events : Yojson.Safe.t list; next_cursor : cursor option }
let hash text = Agent_core_sha256.(digest_string text |> to_hex)
let cursor_json cursor =
  let p=cursor.position in
  `Assoc ["schema",`String "masc.task-history.cursor/v2";"task_id",`String cursor.task;
    "workspace",`String cursor.workspace;"ceilings",`List (List.map (fun (c:ceiling) ->
      `Assoc ["file",`String c.file;"size",`Int c.size]) cursor.ceilings);
    "inventory",`String cursor.inventory;"file",`String p.file;"device",`Int p.device;
    "inode",`Int p.inode;"before",`Int p.before;"anchor",`String p.anchor]
let cursor_to_string cursor = Yojson.Safe.to_string (cursor_json cursor)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let dated_parts relative = match String.split_on_char '/' relative with
  | [source;month;file] -> (match source_of_name source,Layout.year_and_month_of_directory_name month with
    | Some source,Some (year,month_number) when Layout.day_file_name_is_valid ~year ~month:month_number file -> Some (source,month,file)
    | _ -> None)
  | _ -> None
let compare_relative left right = match dated_parts left,dated_parts right with
  | Some (ls,lm,lf),Some (rs,rm,rf) ->
    let order=String.compare lm rm in
    if order<>0 then order else let order=Layout.compare_day_files lf rf in
    if order<>0 then order else String.compare (source_name rs) (source_name ls)
  | _ -> String.compare left right
let cursor_of_string encoded =
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet encoded with
  | Error _ -> Error Invalid_cursor
  | Ok bytes ->
    (match Yojson.Safe.from_string bytes with
     | `Assoc fields when List.length fields=10 ->
       let text name = match List.assoc_opt name fields with
         | Some (`String value) when value<>"" && value=String.trim value -> Some value
         | Some _ | None -> None in
       let integer name = match List.assoc_opt name fields with
         | Some (`Int value) when value>=0 -> Some value | Some _ | None -> None in
       let ceilings=match List.assoc_opt "ceilings" fields with
         | Some (`List rows) ->
           List.fold_left (fun result row -> let* acc=result in match row with
             | `Assoc ["file",`String file;"size",`Int size] when size>=0 && Option.is_some (dated_parts file) ->
               if List.exists (fun (c:ceiling) -> match dated_parts c.file,dated_parts file with
                 | Some (left,_,_),Some (right,_,_) -> left=right | _ -> false) acc
               then Error Invalid_cursor else Ok (acc @ [{file;size}])
             | _ -> Error Invalid_cursor) (Ok []) rows
         | _ -> Error Invalid_cursor in
       (match text "schema",text "task_id",text "workspace",ceilings,text "inventory",
              text "file",integer "device",integer "inode",integer "before",text "anchor" with
        | Some "masc.task-history.cursor/v2",Some task,Some workspace,Ok ceilings,Some inventory,
          Some file,Some device,Some inode,Some before,Some anchor
          when ceilings<>[] && Option.is_some (dated_parts file) ->
          let cursor={task;workspace;ceilings;inventory;position={file;device;inode;before;anchor}} in
          if cursor_to_string cursor=encoded then Ok cursor else Error Invalid_cursor
        | _ -> Error Invalid_cursor)
     | _ -> Error Invalid_cursor
     | exception Yojson.Json_error _ -> Error Invalid_cursor)

type file = { source : source; relative : string; path : string; snapshot : Fs_compat.owned_regular_file_snapshot }
type inventory = { files : file list; observations : (source * availability) list; roots : Yojson.Safe.t list }
let owned result = Result.map_error (fun _ -> Source_unavailable) result
let root_entry_is_metadata source name = match source with
  | Activity -> Activity_graph.root_entry_is_metadata name
  | Audit -> false
let inventory ~root ~held =
  let* observations,roots,files=List.fold_left (fun result source ->
    let* observations,roots,files=result in
    let name=source_name source in
    let directory=Filename.concat root name in
    let* months=Fs_compat.read_owned_directory_if_present ~owner_uid:(Unix.geteuid ())
      ~inventory_root:held ~ownership_root:root directory |> owned in
    match months with
    | None -> Ok ((source,Not_created)::observations,`Assoc ["source",`String name;"state",`String "not-created"]::roots,files)
    | Some months ->
      let* stat=match Fs_compat.inspect_owned_directory_chain ~ownership_root:root directory with
        | Ok (Fs_compat.Owned_directory stat) -> Ok stat
        | Ok Owned_directory_missing | Error _ -> Error Source_changed in
      let* files=List.fold_left (fun result month ->
        let* collected=result in
        if Layout.entry_is_foreign_to_layout month || root_entry_is_metadata source month
        then Ok collected else
        match Layout.year_and_month_of_directory_name month with
        | None -> Error (Invalid_layout {entry=name ^ "/" ^ month})
        | Some (year,month_number) ->
          let directory=Filename.concat directory month in
          let* names=Fs_compat.read_owned_directory ~owner_uid:(Unix.geteuid ()) ~inventory_root:held ~ownership_root:root directory |> owned in
          List.fold_left (fun result filename ->
            let* collected=result in
            if Layout.entry_is_foreign_to_layout filename then Ok collected
            else if not (Layout.day_file_name_is_valid ~year ~month:month_number filename)
            then Error (Invalid_layout {entry=name ^ "/" ^ month ^ "/" ^ filename})
            else
              let path=Filename.concat directory filename in
              let* observed=Fs_compat.load_owned_regular_file_range ~ownership_root:root ~offset:0 ~max_bytes:0 path |> owned in
              match observed with
              | None -> Error Source_changed
              | Some observed -> Ok ({source;relative=name ^ "/" ^ month ^ "/" ^ filename;path;snapshot=observed.snapshot}::collected)
          ) (Ok collected) names
      ) (Ok files) months in
      Ok ((source,Observed)::observations,`Assoc ["source",`String name;"state",`String "observed";
        "device",`Int stat.st_dev;"inode",`Int stat.st_ino]::roots,files)
  ) (Ok ([],[],[])) sources in
  if List.for_all (fun (_,availability) -> availability=Not_created) observations then Error Source_unavailable
  else Ok {observations=List.rev observations;roots=List.rev roots;
    files=List.sort (fun left right -> compare_relative right.relative left.relative) files}
let capture files = List.filter_map (fun source ->
  Option.map (fun file -> {file=file.relative;size=file.snapshot.file_size})
    (List.find_opt (fun file -> file.source=source) files)) sources
let prefix ~ceilings files = List.filter (fun file ->
  List.exists (fun (c:ceiling) -> match dated_parts c.file with
    | Some (source,_,_) -> file.source=source && compare_relative file.relative c.file<=0
    | None -> false) ceilings) files
let inventory_hash ~ceilings inventory =
  let rows=List.map (fun file -> let s=file.snapshot in
    let identity=["file",`String file.relative;"device",`Int s.device;"inode",`Int s.inode] in
    let fields=if List.exists (fun (c:ceiling) -> c.file=file.relative && c.size<=s.file_size) ceilings
      then identity else identity @ ["size",`Int s.file_size;"modified",`Float s.modified_at;"changed",`Float s.changed_at] in
    `Assoc fields) (prefix ~ceilings inventory.files) in
  hash (Yojson.Safe.to_string (`List (inventory.roots @ rows)))
(* The same 64 KiB transfer size used by Fs_compat's streaming file readers.
   This amortizes owned opens and systhread crossings without loading a dated
   file into memory. It is not a row/history limit: rows span arbitrary blocks. *)
let io_block_bytes=65536
module String_set = Set.Make (String)
module String_map = Map.Make (String)

type reader = {
  root : string;
  file : file;
  mutable fd : Unix.file_descr option;
  mutable parent_stat : Unix.stats option;
  mutable block_from : int;
  mutable block : string;
}

let same_stat_identity (a : Unix.stats) (b : Unix.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino

let matches_file_ownership (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  st.st_kind = Unix.S_REG
  && st.st_uid = s.owner_uid
  && (st.st_perm land 0o022) = 0

let matches_file_snapshot (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  matches_file_ownership s st
  && st.st_dev = s.device
  && st.st_ino = s.inode
  && st.st_size >= s.file_size

let inspect_parent_dir ~root path =
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:root (Filename.dirname path) with
  | Ok (Fs_compat.Owned_directory stat) -> Ok stat
  | Ok Owned_directory_missing -> Error Source_changed
  | Error _ -> Error Source_unavailable

let inspect_leaf_path (file : file) =
  try
    let st = Unix.lstat file.path in
    if not (matches_file_ownership file.snapshot st) then Error Source_unavailable
    else if matches_file_snapshot file.snapshot st then Ok st
    else Error Source_changed
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
  | Unix.Unix_error _ -> Error Source_unavailable

let verify_reader_current reader fd (parent_before : Unix.stats) =
  let* parent_now = inspect_parent_dir ~root:reader.root reader.file.path in
  if not (same_stat_identity parent_before parent_now) then Error Source_changed
  else
    let* _leaf = inspect_leaf_path reader.file in
    try
      let st = Unix.fstat fd in
      if not (matches_file_ownership reader.file.snapshot st) then Error Source_unavailable
      else if matches_file_snapshot reader.file.snapshot st then Ok ()
      else Error Source_changed
    with Unix.Unix_error _ -> Error Source_unavailable

let ensure_reader_fd reader =
  match reader.fd with
  | Some fd -> Ok fd
  | None ->
    let* parent_before = inspect_parent_dir ~root:reader.root reader.file.path in
    let* _leaf_before = inspect_leaf_path reader.file in
    let* fd =
      try
        Ok (Unix.openfile reader.file.path [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0)
      with
      | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
      | Unix.Unix_error _ -> Error Source_unavailable
    in
    (match verify_reader_current reader fd parent_before with
     | Ok () ->
       reader.fd <- Some fd;
       reader.parent_stat <- Some parent_before;
       Ok fd
     | Error _ as err ->
       (try Unix.close fd with Unix.Unix_error _ -> ());
       err)

let with_reader ~root file fn =
  let r = { root; file; fd = None; parent_stat = None; block_from = -1; block = "" } in
  let close_quiet () =
    match r.fd with
    | None -> ()
    | Some fd ->
      r.fd <- None;
      (try Unix.close fd with Unix.Unix_error _ -> ())
  in
  Fun.protect ~finally:close_quiet (fun () ->
    let* result = fn r in
    match r.fd, r.parent_stat with
    | None, _ -> Ok result
    | Some fd, Some parent_before ->
      let* () = verify_reader_current r fd parent_before in
      r.fd <- None;
      (try Unix.close fd; Ok result with Unix.Unix_error _ -> Error Source_unavailable)
    | Some _, None -> Error Source_changed)

let rec read_exact fd bytes offset remaining =
  if remaining = 0 then Ok (Bytes.unsafe_to_string bytes)
  else
    match Unix.read fd bytes offset remaining with
    | 0 -> Error Source_changed
    | n -> read_exact fd bytes (offset + n) (remaining - n)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_exact fd bytes offset remaining
    | exception Unix.Unix_error _ -> Error Source_unavailable

let load_block reader offset =
  if offset<0 || offset>=reader.file.snapshot.file_size then Error Source_changed
  else if offset>=reader.block_from && offset-reader.block_from<String.length reader.block then Ok ()
  else
    let from=offset-(offset mod io_block_bytes) in
    let length=min io_block_bytes (reader.file.snapshot.file_size-from) in
    let* fd=ensure_reader_fd reader in
    let* ()=
      try if Unix.lseek fd from Unix.SEEK_SET=from then Ok () else Error Source_changed
      with Unix.Unix_error _ -> Error Source_unavailable in
    let* content=read_exact fd (Bytes.create length) 0 length in
    let* ()=
      try
        let st=Unix.fstat fd in
        if not (matches_file_ownership reader.file.snapshot st) then Error Source_unavailable
        else if matches_file_snapshot reader.file.snapshot st then Ok () else Error Source_changed
      with Unix.Unix_error _ -> Error Source_unavailable in
    reader.block_from<-from;
    reader.block<-content;
    Ok ()

let byte reader offset =
  let* ()=load_block reader offset in
  Ok reader.block.[offset-reader.block_from]

let previous reader before =
  if before=0 then Ok None
  else
    let* ending=byte reader (before-1) in
    if ending<>'\n' then Error (Invalid_event {file=reader.file.relative;offset=before-1})
    else
      (* Search whole slices, preserving their forward byte order. Walking
         Result/Buffer once per byte and reversing every row made sparse
         histories spend seconds on unrelated workspace activity. *)
      let rec walk offset chunks =
        if offset<0 then
          Ok (Some (0, match chunks with [ single ] -> single | _ -> String.concat "" chunks))
        else
          let* ()=load_block reader offset in
          let index=offset-reader.block_from in
          match String.rindex_from_opt reader.block index '\n' with
          | Some ending ->
            let chunk=String.sub reader.block (ending+1) (index-ending) in
            let line=match chunks with [] -> chunk | _ -> String.concat "" (chunk::chunks) in
            Ok (Some (reader.block_from+ending+1,line))
          | None ->
            let chunk=String.sub reader.block 0 (index+1) in
            walk (reader.block_from-1) (chunk::chunks) in
      walk (before-2) []

let read_line_at reader offset =
  let buffer=Buffer.create 256 in
  let rec walk pos =
    if pos>=reader.file.snapshot.file_size then Error Source_changed
    else
      let* ()=load_block reader pos in
      let index=pos-reader.block_from in
      match String.index_from_opt reader.block index '\n' with
      | Some ending ->
        if Buffer.length buffer=0 then
          Ok (String.sub reader.block index (ending-index))
        else (
          Buffer.add_substring buffer reader.block index (ending-index);
          Ok (Buffer.contents buffer))
      | None ->
        Buffer.add_substring buffer reader.block index (String.length reader.block-index);
        walk (reader.block_from+String.length reader.block) in
  walk offset

let read_line_at_bounded reader ~limit offset =
  if offset < 0 || offset >= limit || limit > reader.file.snapshot.file_size then
    Ok None
  else
    let buffer = Buffer.create 256 in
    let rec walk pos =
      if pos >= limit then Ok None
      else
        let* () = load_block reader pos in
        let index = pos - reader.block_from in
        let avail = min (String.length reader.block) (limit - reader.block_from) in
        if avail <= index then Ok None
        else
          match String.index_from_opt reader.block index '\n' with
          | Some ending when ending < avail ->
            if Buffer.length buffer = 0 then
              Ok (Some (String.sub reader.block index (ending - index)))
            else (
              Buffer.add_substring buffer reader.block index (ending - index);
              Ok (Some (Buffer.contents buffer)))
          | Some _ | None ->
            Buffer.add_substring buffer reader.block index (avail - index);
            walk (reader.block_from + avail)
    in
    walk offset

let anchor_matches reader position =
  let* () = if position.device=reader.file.snapshot.device && position.inode=reader.file.snapshot.inode
      && position.before<reader.file.snapshot.file_size then Ok () else Error Source_changed in
  let* () = if position.before=0 then Ok () else
    let* value=byte reader (position.before-1) in if value='\n' then Ok () else Error Source_changed in
  let* line = read_line_at reader position.before in
  if hash line=position.anchor then Ok () else Error Source_changed

let is_whitespace = function
  | ' ' | '\x0c' | '\n' | '\r' | '\t' -> true
  | _ -> false

let is_blank_line s =
  let len = String.length s in
  let rec loop i =
    if i = len then true
    else if is_whitespace s.[i] then loop (i + 1)
    else false
  in
  loop 0

let is_nonempty_trimmed s =
  let len = String.length s in
  len > 0 && not (is_whitespace s.[0]) && not (is_whitespace s.[len - 1])

let rec small_keys_unique = function
  | [] | [ _ ] -> true
  | (k1, _) :: rest ->
    not (List.exists (fun (k2, _) -> String.equal k1 k2) rest) && small_keys_unique rest

let keys_unique fields =
  let rec is_small n = function
    | [] -> true
    | _ :: rest -> if n >= 16 then false else is_small (n + 1) rest
  in
  if is_small 0 fields then small_keys_unique fields
  else
    let rec check seen = function
      | [] -> true
      | (k, _) :: rest ->
        if String_set.mem k seen then false else check (String_set.add k seen) rest
    in
    check String_set.empty fields

let valid_intlit value =
  try
    match Yojson.Safe.from_string value with
    | `Int _ | `Intlit _ -> true
    | `Null | `Bool _ | `Float _ | `String _ | `Assoc _ | `List _ -> false
  with Yojson.Json_error _ -> false

let rec valid_json_depth depth json =
  if depth > 64 then
    Result.is_ok (Agent_core.Execution_json.validate ~context:"Task history event" json)
  else
    match json with
    | `Null | `Bool _ | `Int _ | `String _ -> true
    | `Float value -> Float.is_finite value
    | `Intlit value -> valid_intlit value
    | `List values -> List.for_all (valid_json_depth (depth + 1)) values
    | `Assoc fields ->
      keys_unique fields
      && List.for_all (fun (_, value) -> valid_json_depth (depth + 1) value) fields

let valid_json json = valid_json_depth 0 json

let parse_entity = function
  | `Null -> Some None
  | `Assoc [ ("kind", `String kind); ("id", `String id) ]
  | `Assoc [ ("id", `String id); ("kind", `String kind) ] ->
    if is_nonempty_trimmed kind && is_nonempty_trimmed id then Some (Some (kind, id))
    else None
  | _ -> None

let valid_activity_int = function
  | `Int _ -> true
  | other -> Option.is_some (Safe_ops.json_int_opt "k" (`Assoc [ "k", other ]))

let extract_activity_identities fields =
  let rec loop mask subject_id payload_id context_id = function
    | [] ->
      if mask <> 0xff then None
      else
        let acc = match context_id with Some v -> [ v ] | None -> [] in
        let acc = match payload_id with Some v -> v :: acc | None -> acc in
        let acc = match subject_id with Some v -> v :: acc | None -> acc in
        Some acc
    | (key, value) :: rest ->
      (match key with
       | "seq" ->
         if valid_activity_int value then loop (mask lor 1) subject_id payload_id context_id rest
         else None
       | "ts_ms" ->
         if valid_activity_int value then loop (mask lor 2) subject_id payload_id context_id rest
         else None
       | "ts_iso" ->
         (match value with
          | `String _ -> loop (mask lor 4) subject_id payload_id context_id rest
          | _ -> None)
       | "kind" ->
         (match value with
          | `String _ -> loop (mask lor 8) subject_id payload_id context_id rest
          | _ -> None)
       | "actor" ->
         (match parse_entity value with
          | Some _ -> loop (mask lor 16) subject_id payload_id context_id rest
          | None -> None)
       | "subject" ->
         (match parse_entity value with
          | Some (Some ("task", id)) ->
            loop (mask lor 32) (Some (`String id)) payload_id context_id rest
          | Some (Some _ | None) ->
            loop (mask lor 32) subject_id payload_id context_id rest
          | None -> None)
       | "payload" ->
         let pid =
           match value with
           | `Assoc pf -> List.assoc_opt "task_id" pf
           | _ -> None
         in
         loop (mask lor 64) subject_id pid context_id rest
       | "tags" ->
         (match value with
          | `List tags when List.for_all (function `String _ -> true | _ -> false) tags ->
            loop (mask lor 128) subject_id payload_id context_id rest
          | _ -> None)
       | "context" ->
         (match value with
          | `Assoc cf ->
            loop mask subject_id payload_id (List.assoc_opt "task_id" cf) rest
          | _ -> None)
       | _ -> None)
  in
  loop 0 None None None fields

let extract_audit_identities fields =
  match List.assoc_opt "task" fields, List.assoc_opt "task_id" fields with
  | None, None -> []
  | Some v1, None -> [ v1 ]
  | None, Some v2 -> [ v2 ]
  | Some v1, Some v2 -> [ v1; v2 ]

type row_outcome =
  | Row_unrelated
  | Row_task of { task_id : string; json : Yojson.Safe.t }
  | Row_conflicting of { string_ids : string list }
  | Row_invalid

let classify_identities ~json = function
  | [] | [ `Null ] | [ `Null; `Null ] -> Row_unrelated
  | [ `String id ] -> Row_task { task_id = id; json }
  | [ `String id1; `String id2 ] when String.equal id1 id2 ->
    Row_task { task_id = id1; json }
  | identities ->
    let string_ids =
      List.filter_map (function `String id -> Some id | _ -> None) identities
    in
    (match string_ids with
     | [] -> Row_unrelated
     | id0 :: _ ->
       if List.for_all (function `String id -> String.equal id id0 | _ -> false) identities then
         Row_task { task_id = id0; json }
       else
         Row_conflicting { string_ids = List.sort_uniq String.compare string_ids })

let classify_row ~source line =
  match Yojson.Safe.from_string line with
  | `Assoc fields as json ->
    if not (valid_json json) then Row_invalid
    else
      (match source with
       | Audit -> classify_identities ~json (extract_audit_identities fields)
       | Activity ->
         (match extract_activity_identities fields with
          | None -> Row_invalid
          | Some identities -> classify_identities ~json identities))
  | _ -> Row_invalid
  | exception Yojson.Json_error _ -> Row_invalid

let event_envelope ~file ~offset json =
  `Assoc [
    "source", `String (source_name file.source);
    "file", `String file.relative;
    "offset", `Int offset;
    "event", json;
  ]

type cached_segment = {
  device : int;
  inode : int;
  snapshot : Fs_compat.owned_regular_file_snapshot;
  scanned_from : int;
  scanned_to : int;
  block_digests : (int * int * string) list;
  by_task : int list String_map.t;
  conflicting : int list String_map.t;
}

let max_cached_files = 256
let full_digest_max_bytes = 8 * io_block_bytes
let cache_mutex = Stdlib.Mutex.create ()
let segment_cache : (string * string, cached_segment) Hashtbl.t = Hashtbl.create 64

let find_cached_segment ~root ~relative =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    Hashtbl.find_opt segment_cache (root, relative))

let invalidate_cached_segment ~root ~relative =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    Hashtbl.remove segment_cache (root, relative))

let store_cached_segment ~root ~relative (seg : cached_segment) =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    let replace =
      match Hashtbl.find_opt segment_cache (root, relative) with
      | None -> true
      | Some existing ->
        existing.device <> seg.device
        || existing.inode <> seg.inode
        || seg.scanned_to > existing.scanned_to
        || seg.scanned_from < existing.scanned_from
        || (seg.scanned_to - seg.scanned_from) >= (existing.scanned_to - existing.scanned_from)
    in
    if replace then (
      if Hashtbl.length segment_cache >= max_cached_files
         && not (Hashtbl.mem segment_cache (root, relative))
      then Hashtbl.clear segment_cache;
      Hashtbl.replace segment_cache (root, relative) seg))

let block_digest_at reader ~limit offset =
  let from = offset - (offset mod io_block_bytes) in
  let len = min io_block_bytes (limit - from) in
  let* () = load_block reader from in
  if String.length reader.block < len then Error Source_changed
  else
    let slice =
      if String.length reader.block = len then reader.block
      else String.sub reader.block 0 len
    in
    Ok (from, len, hash slice)

let blocks_to_hash ~scanned_from ~scanned_to =
  let first_block = scanned_from - (scanned_from mod io_block_bytes) in
  let last_block = (scanned_to - 1) - ((scanned_to - 1) mod io_block_bytes) in
  if scanned_to - scanned_from <= full_digest_max_bytes then (
    let rec all_blocks acc pos =
      if pos > last_block then List.rev acc
      else all_blocks (pos :: acc) (pos + io_block_bytes)
    in
    all_blocks [] first_block
  ) else if first_block = last_block then
    [ first_block ]
  else
    [ first_block; last_block ]

let compute_block_digests reader ~scanned_from ~scanned_to =
  let offsets = blocks_to_hash ~scanned_from ~scanned_to in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | off :: rest ->
      let* d = block_digest_at reader ~limit:scanned_to off in
      loop (d :: acc) rest
  in
  loop [] offsets

let make_cached_segment reader ~scanned_from ~scanned_to ~by_task ~conflicting =
  let* block_digests = compute_block_digests reader ~scanned_from ~scanned_to in
  Ok {
    device = reader.file.snapshot.device;
    inode = reader.file.snapshot.inode;
    snapshot = reader.file.snapshot;
    scanned_from;
    scanned_to;
    block_digests;
    by_task;
    conflicting;
  }

let verify_cached_segment reader (cached : cached_segment) =
  let cur = reader.file.snapshot in
  if cached.device <> cur.device
     || cached.inode <> cur.inode
     || cached.snapshot.owner_uid <> cur.owner_uid
     || cached.snapshot.permissions <> cur.permissions
     || cur.file_size < cached.snapshot.file_size
     || cached.snapshot.file_size < cached.scanned_to
     || cached.scanned_from < 0
     || cached.scanned_from >= cached.scanned_to
     || (cur.file_size = cached.snapshot.file_size
         && not (Fs_compat.equal_owned_regular_file_snapshot cached.snapshot cur))
  then Ok false
  else
    let rec verify_blocks = function
      | [] -> Ok true
      | (expected_from, expected_len, expected_sha256) :: rest ->
        let* actual_from, actual_len, actual_sha256 =
          block_digest_at reader ~limit:cached.scanned_to expected_from
        in
        if actual_from = expected_from
           && actual_len = expected_len
           && String.equal actual_sha256 expected_sha256
        then verify_blocks rest
        else Ok false
    in
    verify_blocks cached.block_digests

let add_offset_to_map key offset map =
  let existing = Option.value ~default:[] (String_map.find_opt key map) in
  String_map.add key (offset :: existing) map

let merge_desc_maps upper_map lower_map =
  String_map.merge
    (fun _key upper_opt lower_opt ->
      match upper_opt, lower_opt with
      | Some u, Some l -> Some (u @ l)
      | Some u, None -> Some u
      | None, Some l -> Some l
      | None, None -> None)
    upper_map lower_map

type range_scan_outcome =
  | Reached_stop of {
      stopped_from : int;
      collected : Yojson.Safe.t list;
      count : int;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }
  | Filled_page of {
      stopped_from : int;
      anchor_line : string;
      collected : Yojson.Safe.t list;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }

let scan_range_raw ~task_id ~file ~reader ~start_before ~stop_at ~max_events ~collected ~count =
  let rec loop before collected count rev_by_task rev_conflicting =
    if before <= stop_at then
      Ok (Reached_stop {
        stopped_from = before;
        collected;
        count;
        by_task = String_map.map List.rev rev_by_task;
        conflicting = String_map.map List.rev rev_conflicting;
      })
    else
      let* row = previous reader before in
      match row with
      | None ->
        Ok (Reached_stop {
          stopped_from = 0;
          collected;
          count;
          by_task = String_map.map List.rev rev_by_task;
          conflicting = String_map.map List.rev rev_conflicting;
        })
      | Some (offset, line) ->
        if is_blank_line line then
          loop offset collected count rev_by_task rev_conflicting
        else
          match classify_row ~source:file.source line with
          | Row_invalid ->
            Error (Invalid_event { file = file.relative; offset })
          | Row_unrelated ->
            loop offset collected count rev_by_task rev_conflicting
          | Row_conflicting { string_ids } ->
            let rev_conflicting =
              List.fold_left (fun acc tid -> add_offset_to_map tid offset acc) rev_conflicting string_ids
            in
            if List.exists (String.equal task_id) string_ids then
              Error (Invalid_event { file = file.relative; offset })
            else
              loop offset collected count rev_by_task rev_conflicting
          | Row_task { task_id = row_tid; json } ->
            let rev_by_task = add_offset_to_map row_tid offset rev_by_task in
            if not (String.equal row_tid task_id) then
              loop offset collected count rev_by_task rev_conflicting
            else
              let event = event_envelope ~file ~offset json in
              let collected = event :: collected in
              let count = count + 1 in
              if count < max_events then
                loop offset collected count rev_by_task rev_conflicting
              else
                Ok (Filled_page {
                  stopped_from = offset;
                  anchor_line = line;
                  collected;
                  by_task = String_map.map List.rev rev_by_task;
                  conflicting = String_map.map List.rev rev_conflicting;
                })
  in
  loop start_before collected count String_map.empty String_map.empty

let rec drop_ge limit = function
  | off :: rest when off >= limit -> drop_ge limit rest
  | list -> list

let rec take_up_to n acc = function
  | [] -> List.rev acc, None
  | x :: _ when n <= 1 -> List.rev (x :: acc), Some x
  | x :: rest -> take_up_to (n - 1) (x :: acc) rest

type file_step =
  | Step_done of Yojson.Safe.t list * cursor option
  | Step_next_file of Yojson.Safe.t list * int

let read ~config ~task_id ~max_events ?cursor () =
  if task_id="" || task_id<>String.trim task_id || max_events<=0 then Error Invalid_request
  else
    Fs_compat.with_owned_inventory_root (Workspace_core.masc_dir config) (fun held ->
      let root=Fs_compat.owned_inventory_root_path held in
      let run () =
        let* workspace=match Fs_compat.inspect_owned_directory_chain ~ownership_root:root root with
          | Ok (Fs_compat.Owned_directory stat) ->
            Ok (hash (Yojson.Safe.to_string (`List [`String root;`Int stat.st_dev;`Int stat.st_ino])))
          | Ok Owned_directory_missing | Error _ -> Error Source_changed in
        let* all=inventory ~root ~held in
        let ceilings=match cursor with Some cursor -> cursor.ceilings | None -> capture all.files in
        let files=prefix ~ceilings all.files in
        let fingerprint=inventory_hash ~ceilings all in
        let* ()=match cursor with
          | None -> Ok ()
          | Some cursor when cursor.task=task_id && cursor.workspace=workspace
              && cursor.inventory=fingerprint -> Ok ()
          | Some _ -> Error Source_changed in
        let* files=match cursor with
          | None -> Ok files
          | Some cursor ->
            let rec find = function
              | [] -> Error Source_changed
              | file::rest as files -> if file.relative=cursor.position.file then Ok files else find rest in
            find files in
        let make_next_cursor (file : file) rest offset anchor_line =
          if offset=0 && rest=[] then None
          else
            Some {
              task=task_id;
              workspace;
              ceilings;
              inventory=fingerprint;
              position={
                file=file.relative;
                device=file.snapshot.device;
                inode=file.snapshot.inode;
                before=offset;
                anchor=hash anchor_line;
              };
            }
        in
        let scan_one_file ~first ~file ~rest initial_collected initial_count =
          with_reader ~root file (fun reader ->
            let* initial_before =
              match first, cursor with
              | true, Some cursor ->
                let* () = anchor_matches reader cursor.position in
                Ok cursor.position.before
              | false, _ | true, None ->
                Ok (match List.find_opt (fun (c : ceiling) -> c.file = file.relative) ceilings with
                  | Some c -> c.size
                  | None -> file.snapshot.file_size)
            in
            if initial_before = 0 then Ok (Step_next_file (initial_collected, initial_count))
            else
              let scan_cold_from_initial () =
                invalidate_cached_segment ~root ~relative:file.relative;
                let* outcome =
                  scan_range_raw ~task_id ~file ~reader ~start_before:initial_before
                    ~stop_at:0 ~max_events ~collected:initial_collected ~count:initial_count
                in
                let cache_cold ~stopped_from ~by_task ~conflicting =
                  if stopped_from >= initial_before then Ok ()
                  else
                    let* seg =
                      make_cached_segment reader ~scanned_from:stopped_from
                        ~scanned_to:initial_before ~by_task ~conflicting
                    in
                    Ok (store_cached_segment ~root ~relative:file.relative seg)
                in
                match outcome with
                | Filled_page { stopped_from; anchor_line; collected; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~by_task ~conflicting in
                  Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                | Reached_stop { stopped_from; collected; count; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~by_task ~conflicting in
                  Ok (Step_next_file (collected, count))
              in
              let* cached_opt =
                match find_cached_segment ~root ~relative:file.relative with
                | None -> Ok None
                | Some cached ->
                  let* ok = verify_cached_segment reader cached in
                  if ok then Ok (Some cached)
                  else (
                    invalidate_cached_segment ~root ~relative:file.relative;
                    Ok None)
              in
              (* Step 1: if initial_before > cached.scanned_to, scan the appended upper delta [cached.scanned_to, initial_before) *)
              let* step1 =
                match cached_opt with
                | Some cached when initial_before > cached.scanned_to ->
                  let* outcome =
                    scan_range_raw ~task_id ~file ~reader ~start_before:initial_before
                      ~stop_at:cached.scanned_to ~max_events ~collected:initial_collected ~count:initial_count
                  in
                  (match outcome with
                   | Filled_page { stopped_from; anchor_line; collected; by_task; conflicting } ->
                     if stopped_from < cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let* () =
                         if stopped_from = cached.scanned_to then
                           let by_task' = merge_desc_maps by_task cached.by_task in
                           let conflicting' = merge_desc_maps conflicting cached.conflicting in
                           let* seg =
                             make_cached_segment reader ~scanned_from:cached.scanned_from
                               ~scanned_to:initial_before ~by_task:by_task' ~conflicting:conflicting'
                           in
                           Ok (store_cached_segment ~root ~relative:file.relative seg)
                         else Ok ()
                       in
                       Ok (`Done (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line)))
                   | Reached_stop { stopped_from; collected; count; by_task; conflicting } ->
                     if stopped_from <> cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let by_task' = merge_desc_maps by_task cached.by_task in
                       let conflicting' = merge_desc_maps conflicting cached.conflicting in
                       let* seg =
                         make_cached_segment reader ~scanned_from:cached.scanned_from
                           ~scanned_to:initial_before ~by_task:by_task' ~conflicting:conflicting'
                       in
                       store_cached_segment ~root ~relative:file.relative seg;
                       Ok (`Continue (cached.scanned_to, collected, count, Some seg)))
                | _ -> Ok (`Continue (initial_before, initial_collected, initial_count, cached_opt))
              in
              match step1 with
              | `Fallback_cold -> scan_cold_from_initial ()
              | `Done done_step -> Ok done_step
              | `Continue (before, collected, count, cached_opt) ->
                (* Step 2: if cached.scanned_from < before <= cached.scanned_to, use cached segment *)
                let* step2 =
                  match cached_opt with
                  | Some cached when cached.scanned_from < before && before <= cached.scanned_to ->
                    let* () =
                      if before = cached.scanned_to then Ok ()
                      else
                        let* ending = byte reader (before - 1) in
                        if ending = '\n' then Ok ()
                        else Error (Invalid_event { file = file.relative; offset = before - 1 })
                    in
                    let task_offsets =
                      match String_map.find_opt task_id cached.by_task with
                      | None -> []
                      | Some list -> drop_ge before list
                    in
                    let conflict_offsets =
                      match String_map.find_opt task_id cached.conflicting with
                      | None -> []
                      | Some list -> drop_ge before list
                    in
                    let needed = max_events - count in
                    let taken, stop_offset_opt = take_up_to needed [] task_offsets in
                    let lower_bound =
                      match stop_offset_opt with
                      | Some stop_off -> stop_off
                      | None -> cached.scanned_from - 1
                    in
                    (match conflict_offsets with
                     | c_off :: _ when c_off > lower_bound ->
                       Ok `Fallback_cold
                     | _ ->
                       let rec materialize collected count last_line = function
                         | [] -> Ok (`Materialized (collected, count, last_line))
                         | off :: more ->
                           let* start_ok =
                             if off = 0 then Ok true
                             else
                               let* prev = byte reader (off - 1) in
                               Ok (prev = '\n')
                           in
                           if not start_ok then Ok `Invalidated
                           else
                             let* line_opt = read_line_at_bounded reader ~limit:cached.scanned_to off in
                             match line_opt with
                             | None -> Ok `Invalidated
                             | Some line ->
                               match classify_row ~source:file.source line with
                               | Row_task { task_id = row_tid; json } when String.equal row_tid task_id ->
                                 let event = event_envelope ~file ~offset:off json in
                                 materialize (event :: collected) (count + 1) line more
                               | Row_task _ | Row_unrelated | Row_conflicting _ | Row_invalid ->
                                 Ok `Invalidated
                       in
                       let* mat_result = materialize collected count "" taken in
                       match mat_result with
                       | `Invalidated -> Ok `Fallback_cold
                       | `Materialized (collected, count, last_line) ->
                         (match stop_offset_opt with
                          | Some stop_off ->
                            Ok (`Done (Step_done (List.rev collected, make_next_cursor file rest stop_off last_line)))
                          | None ->
                            if cached.scanned_from = 0 then
                              Ok (`Continue (0, collected, count, Some cached))
                            else
                              let* prev = byte reader (cached.scanned_from - 1) in
                              if prev = '\n' then
                                Ok (`Continue (cached.scanned_from, collected, count, Some cached))
                              else
                                Ok `Fallback_cold))
                  | _ -> Ok (`Continue (before, collected, count, cached_opt))
                in
                match step2 with
                | `Fallback_cold -> scan_cold_from_initial ()
                | `Done done_step -> Ok done_step
                | `Continue (before, collected, count, cached_opt) ->
                  (* Step 3: scan remaining prefix [0, before) *)
                  if before = 0 then Ok (Step_next_file (collected, count))
                  else
                    let* outcome =
                      scan_range_raw ~task_id ~file ~reader ~start_before:before
                        ~stop_at:0 ~max_events ~collected ~count
                    in
                    let cache_lower ~stopped_from ~by_task ~conflicting =
                      if stopped_from >= before then Ok ()
                      else
                        match cached_opt with
                        | Some cached when before = cached.scanned_from ->
                          let by_task' = merge_desc_maps cached.by_task by_task in
                          let conflicting' = merge_desc_maps cached.conflicting conflicting in
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:cached.scanned_to ~by_task:by_task' ~conflicting:conflicting'
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | None ->
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:before ~by_task ~conflicting
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | Some _ -> Ok ()
                    in
                    (match outcome with
                     | Filled_page { stopped_from; anchor_line; collected; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~by_task ~conflicting in
                       Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                     | Reached_stop { stopped_from; collected; count; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~by_task ~conflicting in
                       Ok (Step_next_file (collected, count))))
        in
        let rec scan_files first collected count = function
          | [] -> Ok (List.rev collected, None)
          | file :: rest ->
            let* step = scan_one_file ~first ~file ~rest collected count in
            match step with
            | Step_done (events, next_cursor) -> Ok (events, next_cursor)
            | Step_next_file (collected, count) -> scan_files false collected count rest
        in
        let* events,next_cursor=scan_files true [] 0 files in
        let* after=inventory ~root ~held in
        if inventory_hash ~ceilings after<>fingerprint then Error Source_changed
        else Ok {task_id;cursor;sources=all.observations;events;next_cursor} in
      Ok (run ()))
    |> function Ok result -> result | Error _ -> Error Source_unavailable

let to_json page =
  let token = function None -> `Null | Some cursor -> `String (cursor_to_string cursor) in
  let sources=List.map (fun (source,availability) -> `Assoc ["source",`String (source_name source);
    "state",`String (match availability with Observed -> "observed" | Not_created -> "not-created")]) page.sources in
  `Assoc ["schema",`String "masc.task-history.page/v2";"task_id",`String page.task_id;
    "cursor",token page.cursor;"sources",`List sources;"events",`List page.events;"next_cursor",token page.next_cursor]
