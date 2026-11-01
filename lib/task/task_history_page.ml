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

let same_stat_identity (a : Unix.stats) (b : Unix.stats) =
  a.st_dev = b.st_dev && a.st_ino = b.st_ino

let snapshot_of_stats (stats : Unix.stats) : Fs_compat.owned_regular_file_snapshot =
  { device = stats.st_dev
  ; inode = stats.st_ino
  ; owner_uid = stats.st_uid
  ; permissions = stats.st_perm land 0o7777
  ; file_size = stats.st_size
  ; modified_at = stats.st_mtime
  ; changed_at = stats.st_ctime
  }

let lstat_owned_regular_file ~owner_uid path =
  try
    let st = Unix.lstat path in
    if st.st_kind <> Unix.S_REG
       || st.st_uid <> owner_uid
       || (st.st_perm land 0o022) <> 0
       || (st.st_perm land 0o400) = 0
       || st.st_size < 0
    then Error Source_unavailable
    else Ok (snapshot_of_stats st)
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Source_changed
  | Unix.Unix_error _ -> Error Source_unavailable

let inspect_owned_dir ~root path =
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:root path with
  | Ok (Fs_compat.Owned_directory stat) -> Ok stat
  | Ok Owned_directory_missing -> Error Source_changed
  | Error _ -> Error Source_unavailable

let inventory ~root ~held =
  let owner_uid = Unix.geteuid () in
  let* observations,roots,files=List.fold_left (fun result source ->
    let* observations,roots,files=result in
    let name=source_name source in
    let directory=Filename.concat root name in
    let* months=Fs_compat.read_owned_directory_if_present ~owner_uid
      ~inventory_root:held ~ownership_root:root directory |> owned in
    match months with
    | None -> Ok ((source,Not_created)::observations,`Assoc ["source",`String name;"state",`String "not-created"]::roots,files)
    | Some months ->
      let* stat=inspect_owned_dir ~root directory in
      let* files=List.fold_left (fun result month ->
        let* collected=result in
        if Layout.entry_is_foreign_to_layout month || root_entry_is_metadata source month
        then Ok collected else
        match Layout.year_and_month_of_directory_name month with
        | None -> Error (Invalid_layout {entry=name ^ "/" ^ month})
        | Some (year,month_number) ->
          let month_dir=Filename.concat directory month in
          let* names=Fs_compat.read_owned_directory ~owner_uid ~inventory_root:held ~ownership_root:root month_dir |> owned in
          let* month_before=inspect_owned_dir ~root month_dir in
          let* collected=
            List.fold_left (fun result filename ->
              let* collected=result in
              if Layout.entry_is_foreign_to_layout filename then Ok collected
              else if not (Layout.day_file_name_is_valid ~year ~month:month_number filename)
              then Error (Invalid_layout {entry=name ^ "/" ^ month ^ "/" ^ filename})
              else
                let path=Filename.concat month_dir filename in
                let* snapshot=lstat_owned_regular_file ~owner_uid path in
                Ok ({source;relative=name ^ "/" ^ month ^ "/" ^ filename;path;snapshot}::collected)
            ) (Ok collected) names
          in
          let* month_after=inspect_owned_dir ~root month_dir in
          if not (same_stat_identity month_before month_after) then Error Source_changed
          else Ok collected
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
  mutable block_len : int;
  mutable block : string;
  mutable top_block_from : int;
  mutable top_block_len : int;
  mutable top_block : string;
  mutable retained_blocks : (int * int * string) list;
}

let matches_file_ownership (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  st.st_kind = Unix.S_REG
  && st.st_uid = s.owner_uid
  && (st.st_perm land 0o7777) = s.permissions
  && (st.st_perm land 0o022) = 0

let matches_file_snapshot (s : Fs_compat.owned_regular_file_snapshot) (st : Unix.stats) =
  matches_file_ownership s st
  && st.st_dev = s.device
  && st.st_ino = s.inode
  && (st.st_size > s.file_size
      || (st.st_size = s.file_size
          && Float.equal st.st_mtime s.modified_at
          && Float.equal st.st_ctime s.changed_at))

let inspect_parent_dir ~root path =
  inspect_owned_dir ~root (Filename.dirname path)

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
  let r =
    {
      root;
      file;
      fd = None;
      parent_stat = None;
      block_from = -1;
      block_len = 0;
      block = "";
      top_block_from = -1;
      top_block_len = 0;
      top_block = "";
      retained_blocks = [];
    }
  in
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

let reset_reader_block_memo reader =
  reader.block_from <- -1;
  reader.block_len <- 0;
  reader.block <- "";
  reader.top_block_from <- -1;
  reader.top_block_len <- 0;
  reader.top_block <- "";
  reader.retained_blocks <- []

let rec read_exact fd bytes offset remaining =
  if remaining = 0 then Ok ()
  else
    match Unix.read fd bytes offset remaining with
    | 0 -> Error Source_changed
    | n -> read_exact fd bytes (offset + n) (remaining - n)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> read_exact fd bytes offset remaining
    | exception Unix.Unix_error _ -> Error Source_unavailable

let load_block reader offset =
  if offset<0 || offset>=reader.file.snapshot.file_size then Error Source_changed
  else if offset>=reader.block_from && offset-reader.block_from<reader.block_len then Ok ()
  else
    let from=offset-(offset mod io_block_bytes) in
    if from=reader.top_block_from && offset-from<reader.top_block_len then (
      reader.block_from<-reader.top_block_from;
      reader.block_len<-reader.top_block_len;
      reader.block<-reader.top_block;
      Ok ()
    ) else
      match List.find_opt (fun (f, l, _) -> f=from && offset-f<l) reader.retained_blocks with
      | Some (f, l, b) ->
        reader.block_from<-f;
        reader.block_len<-l;
        reader.block<-b;
        Ok ()
      | None ->
        let length=min io_block_bytes (reader.file.snapshot.file_size-from) in
        let* fd=ensure_reader_fd reader in
        let* ()=
          try if Unix.lseek fd from Unix.SEEK_SET=from then Ok () else Error Source_changed
          with Unix.Unix_error _ -> Error Source_unavailable in
        let bytes=Bytes.create length in
        let* ()=read_exact fd bytes 0 length in
        let* ()=
          try
            let st=Unix.fstat fd in
            if not (matches_file_ownership reader.file.snapshot st) then Error Source_unavailable
            else if matches_file_snapshot reader.file.snapshot st then Ok () else Error Source_changed
          with Unix.Unix_error _ -> Error Source_unavailable in
        let block=Bytes.unsafe_to_string bytes in
        reader.block_from<-from;
        reader.block_len<-length;
        reader.block<-block;
        if reader.top_block_from<0 then (
          reader.top_block_from<-from;
          reader.top_block_len<-length;
          reader.top_block<-block);
        if reader.file.snapshot.file_size <= 8 * io_block_bytes then
          reader.retained_blocks <- (from, length, block) :: reader.retained_blocks;
        Ok ()

let byte reader offset =
  let* ()=load_block reader offset in
  Ok reader.block.[offset-reader.block_from]

type row_slice = {
  mutable row_offset : int;
  mutable row_buf : string;
  mutable row_pos : int;
  mutable row_len : int;
}

let slice_to_string (s : row_slice) =
  if s.row_pos = 0 && s.row_len = String.length s.row_buf then s.row_buf
  else String.sub s.row_buf s.row_pos s.row_len

let rec rindex_newline s i =
  if i < 0 then -1
  else if String.unsafe_get s i = '\n' then i
  else rindex_newline s (i - 1)

let rec index_newline s limit i =
  if i >= limit then -1
  else if String.unsafe_get s i = '\n' then i
  else index_newline s limit (i + 1)

let rec previous_slice_walk reader (out : row_slice) offset chunks =
  if offset < 0 then (
    let line = match chunks with [ single ] -> single | _ -> String.concat "" chunks in
    out.row_offset <- 0;
    out.row_buf <- line;
    out.row_pos <- 0;
    out.row_len <- String.length line;
    Ok true)
  else
    let* () = load_block reader offset in
    let index = offset - reader.block_from in
    let ending = rindex_newline reader.block index in
    if ending >= 0 then
      let start_in_block = ending + 1 in
      let chunk_len = index - ending in
      match chunks with
      | [] ->
        out.row_offset <- reader.block_from + start_in_block;
        out.row_buf <- reader.block;
        out.row_pos <- start_in_block;
        out.row_len <- chunk_len;
        Ok true
      | _ ->
        let chunk = String.sub reader.block start_in_block chunk_len in
        let line = String.concat "" (chunk :: chunks) in
        out.row_offset <- reader.block_from + start_in_block;
        out.row_buf <- line;
        out.row_pos <- 0;
        out.row_len <- String.length line;
        Ok true
    else
      let chunk = String.sub reader.block 0 (index + 1) in
      previous_slice_walk reader out (reader.block_from - 1) (chunk :: chunks)

let previous_slice reader (out : row_slice) before =
  if before = 0 then Ok false
  else
    let* ending = byte reader (before - 1) in
    if ending <> '\n' then Error (Invalid_event { file = reader.file.relative; offset = before - 1 })
    else previous_slice_walk reader out (before - 2) []

let read_line_at reader offset =
  let buffer=Buffer.create 256 in
  let rec walk pos =
    if pos>=reader.file.snapshot.file_size then Error Source_changed
    else
      let* ()=load_block reader pos in
      let index=pos-reader.block_from in
      let ending = index_newline reader.block reader.block_len index in
      if ending >= 0 then
        if Buffer.length buffer=0 then
          Ok (String.sub reader.block index (ending-index))
        else (
          Buffer.add_substring buffer reader.block index (ending-index);
          Ok (Buffer.contents buffer))
      else (
        Buffer.add_substring buffer reader.block index (reader.block_len-index);
        walk (reader.block_from+reader.block_len)) in
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
        let avail = min reader.block_len (limit - reader.block_from) in
        if avail <= index then Ok None
        else
          let ending = index_newline reader.block avail index in
          if ending >= 0 then
            if Buffer.length buffer = 0 then
              Ok (Some (String.sub reader.block index (ending - index)))
            else (
              Buffer.add_substring buffer reader.block index (ending - index);
              Ok (Some (Buffer.contents buffer)))
          else (
            Buffer.add_substring buffer reader.block index (avail - index);
            walk (reader.block_from + avail))
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

let rec is_blank_slice_loop s stop i =
  if i = stop then true
  else if is_whitespace (String.unsafe_get s i) then is_blank_slice_loop s stop (i + 1)
  else false

let is_blank_slice s ~pos ~len =
  is_blank_slice_loop s (pos + len) pos

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
  | [ `String id ] when is_nonempty_trimmed id -> Row_task { task_id = id; json }
  | [ `String id1; `String id2 ] when is_nonempty_trimmed id1 && String.equal id1 id2 ->
    Row_task { task_id = id1; json }
  | identities ->
    let string_ids =
      List.filter_map
        (function `String id when is_nonempty_trimmed id -> Some id | _ -> None)
        identities
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

(* Zero-AST single-pass RFC 8259 scanner over a slice [pos, pos + len) in [s].
   Handles standard rows with unescaped ASCII keys and task IDs without
   allocating a Yojson.Safe.t AST or lexer buffer. Any escape in a key/ID,
   non-integer seq/ts_ms, >64 keys in an object, nesting >32, or malformed
   input falls back to [classify_row] so Yojson parity is exact. *)
let max_fast_depth = 32
let max_fast_keys = 64
let key_stride = max_fast_keys

let rec skip_ws s stop i =
  if i >= stop then i
  else
    match String.unsafe_get s i with
    | ' ' | '\t' | '\n' | '\r' -> skip_ws s stop (i + 1)
    | '\x0c' -> -1
    | _ -> i

let is_hex_digit = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let is_utf8_cont c =
  let code = Char.code c in
  code >= 0x80 && code <= 0xbf

let rec skip_valid_string s stop i =
  if i >= stop then -1
  else
    let c = String.unsafe_get s i in
    match c with
    | '"' -> i + 1
    | '\\' ->
      if i + 1 >= stop then -1
      else (
        match String.unsafe_get s (i + 1) with
        | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' ->
          skip_valid_string s stop (i + 2)
        | 'u' ->
          if i + 5 >= stop then -1
          else
            let h0 = String.unsafe_get s (i + 2) in
            let h1 = String.unsafe_get s (i + 3) in
            let h2 = String.unsafe_get s (i + 4) in
            let h3 = String.unsafe_get s (i + 5) in
            if not (is_hex_digit h0 && is_hex_digit h1 && is_hex_digit h2 && is_hex_digit h3) then -1
            else if (h0 = 'd' || h0 = 'D')
                    && (match h1 with '8' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false)
            then -1
            else skip_valid_string s stop (i + 6)
        | _ -> -1)
    | '\x00' .. '\x1f' -> -1
    | '\x20' .. '\x7f' -> skip_valid_string s stop (i + 1)
    | '\xc2' .. '\xdf' ->
      if i + 1 < stop && is_utf8_cont (String.unsafe_get s (i + 1)) then
        skip_valid_string s stop (i + 2)
      else -1
    | '\xe0' ->
      if i + 2 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0xa0 && b1 <= 0xbf)
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xe1' .. '\xec' | '\xee' .. '\xef' ->
      if i + 2 < stop
         && is_utf8_cont (String.unsafe_get s (i + 1))
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xed' ->
      if i + 2 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x80 && b1 <= 0x9f)
         && is_utf8_cont (String.unsafe_get s (i + 2))
      then skip_valid_string s stop (i + 3)
      else -1
    | '\xf0' ->
      if i + 3 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x90 && b1 <= 0xbf)
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | '\xf1' .. '\xf3' ->
      if i + 3 < stop
         && is_utf8_cont (String.unsafe_get s (i + 1))
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | '\xf4' ->
      if i + 3 < stop
         && (let b1 = Char.code (String.unsafe_get s (i + 1)) in b1 >= 0x80 && b1 <= 0x8f)
         && is_utf8_cont (String.unsafe_get s (i + 2))
         && is_utf8_cont (String.unsafe_get s (i + 3))
      then skip_valid_string s stop (i + 4)
      else -1
    | _ -> -1

let rec find_unescaped_ascii_end s stop i =
  if i >= stop then -1
  else
    match String.unsafe_get s i with
    | '"' -> i
    | '\\' | '\x00' .. '\x1f' | '\x7f' .. '\xff' -> -1
    | _ -> find_unescaped_ascii_end s stop (i + 1)

let slice_is_nonempty_trimmed s off len =
  len > 0
  && not (is_whitespace (String.unsafe_get s off))
  && not (is_whitespace (String.unsafe_get s (off + len - 1)))

let rec slice_eq_lit_loop s off lit len k =
  if k = len then true
  else if String.unsafe_get s (off + k) <> String.unsafe_get lit k then false
  else slice_eq_lit_loop s off lit len (k + 1)

let slice_eq_lit s off len lit =
  len = String.length lit && slice_eq_lit_loop s off lit len 0

let rec slice_eq_slice_loop s off1 off2 len k =
  if k = len then true
  else if String.unsafe_get s (off1 + k) <> String.unsafe_get s (off2 + k) then false
  else slice_eq_slice_loop s off1 off2 len (k + 1)

let slice_eq_slice s off1 len1 off2 len2 =
  len1 = len2 && slice_eq_slice_loop s off1 off2 len1 0

let pack_key_fingerprint s k_off k_len =
  let first_char = if k_len > 0 then Char.code (String.unsafe_get s k_off) else 0 in
  (k_len lsl 40) lor (first_char lsl 32) lor k_off

let rec register_unique_key_loop s (key_buf : int array) base count k_off k_len fp fp_tag j =
  if j = count then (
    Array.unsafe_set key_buf (base + count) fp;
    true)
  else
    let prev_fp = Array.unsafe_get key_buf (base + j) in
    if (prev_fp lsr 32) = fp_tag
       && slice_eq_slice_loop s k_off (prev_fp land 0xffffffff) k_len 0
    then false
    else register_unique_key_loop s key_buf base count k_off k_len fp fp_tag (j + 1)

let register_unique_key s (key_buf : int array) base count k_off k_len =
  count < max_fast_keys
  && k_len <= 0xffff
  && k_off <= 0x7fffffff
  && (
    let fp = pack_key_fingerprint s k_off k_len in
    let fp_tag = fp lsr 32 in
    register_unique_key_loop s key_buf base count k_off k_len fp fp_tag 0)

let rec count_digits s stop i =
  if i < stop then
    match String.unsafe_get s i with
    | '0' .. '9' -> count_digits s stop (i + 1)
    | _ -> i
  else i

let scan_int_field s stop i =
  if i >= stop then -1
  else
    let i = if String.unsafe_get s i = '-' then i + 1 else i in
    if i >= stop then -1
    else
      match String.unsafe_get s i with
      | '0' ->
        let next = i + 1 in
        if next < stop
           && (match String.unsafe_get s next with '0' .. '9' | '.' | 'e' | 'E' -> true | _ -> false)
        then -1
        else next
      | '1' .. '9' ->
        let next = count_digits s stop (i + 1) in
        let digits = next - i in
        if digits > 18 then -1
        else if next < stop
                && (match String.unsafe_get s next with '.' | 'e' | 'E' -> true | _ -> false)
        then -1
        else next
      | _ -> -1

let skip_exponent s stop i =
  if i >= stop then i
  else
    match String.unsafe_get s i with
    | 'e' | 'E' ->
      let i = i + 1 in
      if i >= stop then -1
      else
        let i =
          match String.unsafe_get s i with
          | '+' | '-' -> i + 1
          | _ -> i
        in
        if i >= stop then -1
        else
          let exp_end = count_digits s stop i in
          let exp_digits = exp_end - i in
          if exp_digits < 1 || exp_digits > 2 then -1
          else exp_end
    | _ -> i

let skip_valid_number s stop i =
  if i >= stop then -1
  else
    let i = if String.unsafe_get s i = '-' then i + 1 else i in
    if i >= stop then -1
    else
      let int_end =
        match String.unsafe_get s i with
        | '0' ->
          let next = i + 1 in
          if next < stop && (match String.unsafe_get s next with '0' .. '9' -> true | _ -> false)
          then -1
          else next
        | '1' .. '9' ->
          let next = count_digits s stop (i + 1) in
          if next - i > 18 then -1 else next
        | _ -> -1
      in
      if int_end < 0 then -1
      else if int_end < stop && String.unsafe_get s int_end = '.' then
        let frac_start = int_end + 1 in
        let frac_end = count_digits s stop frac_start in
        let frac_digits = frac_end - frac_start in
        if frac_digits < 1 || frac_digits > 64 then -1
        else skip_exponent s stop frac_end
      else skip_exponent s stop int_end

let rec skip_valid_value s stop key_buf depth i =
  if depth >= max_fast_depth then -1
  else
    let i = skip_ws s stop i in
    if i < 0 || i >= stop then -1
    else
      match String.unsafe_get s i with
      | '"' -> skip_valid_string s stop (i + 1)
      | '-' | '0' .. '9' -> skip_valid_number s stop i
      | 't' ->
        if i + 4 <= stop
           && String.unsafe_get s (i + 1) = 'r'
           && String.unsafe_get s (i + 2) = 'u'
           && String.unsafe_get s (i + 3) = 'e'
        then i + 4
        else -1
      | 'f' ->
        if i + 5 <= stop
           && String.unsafe_get s (i + 1) = 'a'
           && String.unsafe_get s (i + 2) = 'l'
           && String.unsafe_get s (i + 3) = 's'
           && String.unsafe_get s (i + 4) = 'e'
        then i + 5
        else -1
      | 'n' ->
        if i + 4 <= stop
           && String.unsafe_get s (i + 1) = 'u'
           && String.unsafe_get s (i + 2) = 'l'
           && String.unsafe_get s (i + 3) = 'l'
        then i + 4
        else -1
      | '[' ->
        let i = skip_ws s stop (i + 1) in
        if i < 0 || i >= stop then -1
        else if String.unsafe_get s i = ']' then i + 1
        else skip_valid_array s stop key_buf (depth + 1) i
      | '{' ->
        let i = skip_ws s stop (i + 1) in
        if i < 0 || i >= stop then -1
        else if String.unsafe_get s i = '}' then i + 1
        else skip_valid_object s stop key_buf depth 0 i
      | _ -> -1

and skip_valid_array s stop key_buf depth i =
  let i = skip_valid_value s stop key_buf depth i in
  if i < 0 then -1
  else
    let i = skip_ws s stop i in
    if i < 0 || i >= stop then -1
    else
      match String.unsafe_get s i with
      | ']' -> i + 1
      | ',' -> skip_valid_array s stop key_buf depth (i + 1)
      | _ -> -1

and skip_valid_object s stop key_buf depth count i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '"' then -1
  else
    let k_off = i + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      let base = depth * key_stride in
      if not (register_unique_key s key_buf base count k_off k_len) then -1
      else
        let i = skip_ws s stop (k_end + 1) in
        if i < 0 || i >= stop || String.unsafe_get s i <> ':' then -1
        else
          let i = skip_valid_value s stop key_buf (depth + 1) (i + 1) in
          if i < 0 then -1
          else
            let i = skip_ws s stop i in
            if i < 0 || i >= stop then -1
            else
              match String.unsafe_get s i with
              | '}' -> i + 1
              | ',' -> skip_valid_object s stop key_buf depth (count + 1) (i + 1)
              | _ -> -1

(* Pre-allocated [state : int array] layout (13 ints, zero heap allocation):
   - Slot 0 (subject / audit task):   state[0] = 0(absent)|1(null)|2(slice), state[1]=off, state[2]=len
   - Slot 3 (payload / audit task_id): state[3] = 0|1|2, state[4]=off, state[5]=len
   - Slot 6 (context):                 state[6] = 0|1|2, state[7]=off, state[8]=len
   - Entity scratch:                   state[9]=kind_off, state[10]=kind_len, state[11]=id_off, state[12]=id_len
   Return code of [scan_row_slice_fast]:
   - 0  = Fast_unrelated
   - 1  = Fast_task (matched slice offset in state[1], length in state[2])
   - -1 = Fast_fallback *)

let scan_entity_field s stop (state : int array) ~is_subject i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop then -1
  else
    match String.unsafe_get s i with
    | 'n' ->
      if i + 4 <= stop
         && String.unsafe_get s (i + 1) = 'u'
         && String.unsafe_get s (i + 2) = 'l'
         && String.unsafe_get s (i + 3) = 'l'
      then i + 4
      else -1
    | '{' ->
      let i1 = skip_ws s stop (i + 1) in
      if i1 < 0 || i1 >= stop || String.unsafe_get s i1 <> '"' then -1
      else
        let k1_off = i1 + 1 in
        let k1_end = find_unescaped_ascii_end s stop k1_off in
        if k1_end < 0 then -1
        else
          let k1_len = k1_end - k1_off in
          let c1 = skip_ws s stop (k1_end + 1) in
          if c1 < 0 || c1 >= stop || String.unsafe_get s c1 <> ':' then -1
          else
            let v1 = skip_ws s stop (c1 + 1) in
            if v1 < 0 || v1 >= stop || String.unsafe_get s v1 <> '"' then -1
            else
              let v1_off = v1 + 1 in
              let v1_end = find_unescaped_ascii_end s stop v1_off in
              if v1_end < 0 then -1
              else
                let v1_len = v1_end - v1_off in
                if not (slice_is_nonempty_trimmed s v1_off v1_len) then -1
                else
                  let sep = skip_ws s stop (v1_end + 1) in
                  if sep < 0 || sep >= stop || String.unsafe_get s sep <> ',' then -1
                  else
                    let i2 = skip_ws s stop (sep + 1) in
                    if i2 < 0 || i2 >= stop || String.unsafe_get s i2 <> '"' then -1
                    else
                      let k2_off = i2 + 1 in
                      let k2_end = find_unescaped_ascii_end s stop k2_off in
                      if k2_end < 0 then -1
                      else
                        let k2_len = k2_end - k2_off in
                        let c2 = skip_ws s stop (k2_end + 1) in
                        if c2 < 0 || c2 >= stop || String.unsafe_get s c2 <> ':' then -1
                        else
                          let v2 = skip_ws s stop (c2 + 1) in
                          if v2 < 0 || v2 >= stop || String.unsafe_get s v2 <> '"' then -1
                          else
                            let v2_off = v2 + 1 in
                            let v2_end = find_unescaped_ascii_end s stop v2_off in
                            if v2_end < 0 then -1
                            else
                              let v2_len = v2_end - v2_off in
                              if not (slice_is_nonempty_trimmed s v2_off v2_len) then -1
                              else
                                let close = skip_ws s stop (v2_end + 1) in
                                if close < 0 || close >= stop || String.unsafe_get s close <> '}' then
                                  -1
                                else if slice_eq_lit s k1_off k1_len "kind"
                                        && slice_eq_lit s k2_off k2_len "id"
                                then (
                                  if is_subject && slice_eq_lit s v1_off v1_len "task" then (
                                    Array.unsafe_set state 0 2;
                                    Array.unsafe_set state 1 v2_off;
                                    Array.unsafe_set state 2 v2_len);
                                  close + 1
                                ) else if slice_eq_lit s k1_off k1_len "id"
                                          && slice_eq_lit s k2_off k2_len "kind"
                                then (
                                  if is_subject && slice_eq_lit s v2_off v2_len "task" then (
                                    Array.unsafe_set state 0 2;
                                    Array.unsafe_set state 1 v1_off;
                                    Array.unsafe_set state 2 v1_len);
                                  close + 1
                                ) else -1
    | _ -> -1

let scan_id_value s stop (state : int array) slot_base i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop then -1
  else
    match String.unsafe_get s i with
    | 'n' ->
      if i + 4 <= stop
         && String.unsafe_get s (i + 1) = 'u'
         && String.unsafe_get s (i + 2) = 'l'
         && String.unsafe_get s (i + 3) = 'l'
      then (
        Array.unsafe_set state slot_base 1;
        i + 4)
      else -1
    | '"' ->
      let v_off = i + 1 in
      let v_end = find_unescaped_ascii_end s stop v_off in
      if v_end < 0 then -1
      else
        let v_len = v_end - v_off in
        if not (slice_is_nonempty_trimmed s v_off v_len) then -1
        else (
          Array.unsafe_set state slot_base 2;
          Array.unsafe_set state (slot_base + 1) v_off;
          Array.unsafe_set state (slot_base + 2) v_len;
          v_end + 1)
    | _ -> -1

let rec scan_assoc_loop s stop key_buf (state : int array) slot_base depth base count pos =
  let pos = skip_ws s stop pos in
  if pos < 0 || pos >= stop || String.unsafe_get s pos <> '"' then -1
  else
    let k_off = pos + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      if not (register_unique_key s key_buf base count k_off k_len) then -1
      else
        let colon = skip_ws s stop (k_end + 1) in
        if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
        else
          let next_pos =
            if slice_eq_lit s k_off k_len "task_id" then
              scan_id_value s stop state slot_base (colon + 1)
            else
              skip_valid_value s stop key_buf (depth + 1) (colon + 1)
          in
          if next_pos < 0 then -1
          else
            let after = skip_ws s stop next_pos in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | '}' -> after + 1
              | ',' ->
                scan_assoc_loop s stop key_buf state slot_base depth base (count + 1) (after + 1)
              | _ -> -1

let scan_assoc_extracting_task_id s stop key_buf (state : int array) slot_base depth i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = '}' then i + 1
    else scan_assoc_loop s stop key_buf state slot_base depth (depth * key_stride) 0 i

let rec skip_string_list s stop i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '"' then -1
  else
    let i = skip_valid_string s stop (i + 1) in
    if i < 0 then -1
    else
      let i = skip_ws s stop i in
      if i < 0 || i >= stop then -1
      else
        match String.unsafe_get s i with
        | ']' -> i + 1
        | ',' -> skip_string_list s stop (i + 1)
        | _ -> -1

let scan_tags_field s stop i =
  let i = skip_ws s stop i in
  if i < 0 || i >= stop || String.unsafe_get s i <> '[' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = ']' then i + 1
    else skip_string_list s stop i

let reconcile_fast_state s (state : int array) : int =
  let s0 = Array.unsafe_get state 0 in
  let s1 = Array.unsafe_get state 3 in
  let s2 = Array.unsafe_get state 6 in
  let has_null = s0 = 1 || s1 = 1 || s2 = 1 in
  let has_slice = s0 = 2 || s1 = 2 || s2 = 2 in
  if not has_slice then
    0 (* Fast_unrelated *)
  else if has_null then
    -1 (* Fast_fallback: mix of string task_id and explicit null *)
  else
    let base_off =
      if s0 = 2 then Array.unsafe_get state 1
      else if s1 = 2 then Array.unsafe_get state 4
      else Array.unsafe_get state 7
    in
    let base_len =
      if s0 = 2 then Array.unsafe_get state 2
      else if s1 = 2 then Array.unsafe_get state 5
      else Array.unsafe_get state 8
    in
    let ok1 =
      s1 <> 2
      || s0 <> 2
      || slice_eq_slice s base_off base_len (Array.unsafe_get state 4) (Array.unsafe_get state 5)
    in
    let ok2 =
      s2 <> 2
      || (s0 <> 2 && s1 <> 2)
      || slice_eq_slice s base_off base_len (Array.unsafe_get state 7) (Array.unsafe_get state 8)
    in
    if ok1 && ok2 then (
      Array.unsafe_set state 1 base_off;
      Array.unsafe_set state 2 base_len;
      1 (* Fast_task *))
    else -1 (* Fast_fallback *)

let rec scan_activity_loop s stop key_buf (state : int array) mask cur =
  let cur = skip_ws s stop cur in
  if cur < 0 || cur >= stop || String.unsafe_get s cur <> '"' then -1
  else
    let k_off = cur + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      let colon = skip_ws s stop (k_end + 1) in
      if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
      else
        let v_start = colon + 1 in
        let bit =
          match k_len with
          | 3 -> if slice_eq_lit_loop s k_off "seq" 3 0 then 1 else 0
          | 4 ->
            if slice_eq_lit_loop s k_off "kind" 4 0 then 8
            else if slice_eq_lit_loop s k_off "tags" 4 0 then 128
            else 0
          | 5 ->
            if slice_eq_lit_loop s k_off "ts_ms" 5 0 then 2
            else if slice_eq_lit_loop s k_off "actor" 5 0 then 16
            else 0
          | 6 -> if slice_eq_lit_loop s k_off "ts_iso" 6 0 then 4 else 0
          | 7 ->
            if slice_eq_lit_loop s k_off "subject" 7 0 then 32
            else if slice_eq_lit_loop s k_off "payload" 7 0 then 64
            else if slice_eq_lit_loop s k_off "context" 7 0 then 256
            else 0
          | _ -> 0
        in
        if bit = 0 || (mask land bit) <> 0 then -1
        else
          let next_i =
            match bit with
            | 1 | 2 -> scan_int_field s stop v_start
            | 4 | 8 ->
              let v = skip_ws s stop v_start in
              if v >= 0 && v < stop && String.unsafe_get s v = '"' then
                skip_valid_string s stop (v + 1)
              else -1
            | 16 -> scan_entity_field s stop state ~is_subject:false v_start
            | 32 -> scan_entity_field s stop state ~is_subject:true v_start
            | 64 ->
              let v = skip_ws s stop v_start in
              if v < 0 || v >= stop then -1
              else if String.unsafe_get s v = '{' then
                scan_assoc_extracting_task_id s stop key_buf state 3 1 v
              else
                skip_valid_value s stop key_buf 1 v
            | 128 -> scan_tags_field s stop v_start
            | 256 -> scan_assoc_extracting_task_id s stop key_buf state 6 1 v_start
            | _ -> -1
          in
          if next_i < 0 then -1
          else
            let mask = mask lor bit in
            let after = skip_ws s stop next_i in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | ',' -> scan_activity_loop s stop key_buf state mask (after + 1)
              | '}' ->
                let tail = skip_ws s stop (after + 1) in
                if tail <> stop || (mask land 0xff) <> 0xff then -1
                else reconcile_fast_state s state
              | _ -> -1

let scan_activity_slice_fast s ~pos ~len key_buf (state : int array) =
  let stop = pos + len in
  let i = skip_ws s stop pos in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop || String.unsafe_get s i = '}' then -1
    else (
      Array.unsafe_set state 0 0;
      Array.unsafe_set state 3 0;
      Array.unsafe_set state 6 0;
      scan_activity_loop s stop key_buf state 0 i)

let rec scan_audit_loop s stop key_buf (state : int array) count cur =
  let cur = skip_ws s stop cur in
  if cur < 0 || cur >= stop || String.unsafe_get s cur <> '"' then -1
  else
    let k_off = cur + 1 in
    let k_end = find_unescaped_ascii_end s stop k_off in
    if k_end < 0 then -1
    else
      let k_len = k_end - k_off in
      if not (register_unique_key s key_buf 0 count k_off k_len) then -1
      else
        let colon = skip_ws s stop (k_end + 1) in
        if colon < 0 || colon >= stop || String.unsafe_get s colon <> ':' then -1
        else
          let v_start = colon + 1 in
          let next_i =
            if slice_eq_lit s k_off k_len "task" then
              scan_id_value s stop state 0 v_start
            else if slice_eq_lit s k_off k_len "task_id" then
              scan_id_value s stop state 3 v_start
            else
              skip_valid_value s stop key_buf 1 v_start
          in
          if next_i < 0 then -1
          else
            let after = skip_ws s stop next_i in
            if after < 0 || after >= stop then -1
            else
              match String.unsafe_get s after with
              | ',' -> scan_audit_loop s stop key_buf state (count + 1) (after + 1)
              | '}' ->
                if skip_ws s stop (after + 1) <> stop then -1
                else reconcile_fast_state s state
              | _ -> -1

let scan_audit_slice_fast s ~pos ~len key_buf (state : int array) =
  let stop = pos + len in
  let i = skip_ws s stop pos in
  if i < 0 || i >= stop || String.unsafe_get s i <> '{' then -1
  else
    let i = skip_ws s stop (i + 1) in
    if i < 0 || i >= stop then -1
    else if String.unsafe_get s i = '}' then
      if skip_ws s stop (i + 1) = stop then 0 else -1
    else (
      Array.unsafe_set state 0 0;
      Array.unsafe_set state 3 0;
      Array.unsafe_set state 6 0;
      scan_audit_loop s stop key_buf state 0 i)

let scan_row_slice_fast ~source s ~pos ~len key_buf state =
  match source with
  | Activity -> scan_activity_slice_fast s ~pos ~len key_buf state
  | Audit -> scan_audit_slice_fast s ~pos ~len key_buf state

type task_bucket = {
  hash : int;
  key : string;
  mutable rev_offsets : int list;
  mutable next : task_bucket option;
}

type task_table = {
  mutable buckets : task_bucket option array;
  mutable mask : int;
  mutable size : int;
}

let create_task_table () =
  { buckets = Array.make 1024 None; mask = 1023; size = 0 }

let full_slice_hash s off len =
  let stop = off + len in
  let rec loop h i =
    if i >= stop then h land max_int
    else
      let c = Char.code (String.unsafe_get s i) in
      loop (((h lxor c) * 16777619) + (h lsr 16)) (i + 1)
  in
  loop 2166136261 off

let grow_task_table (t : task_table) =
  let old_buckets = t.buckets in
  let old_cap = Array.length old_buckets in
  let new_cap = old_cap lsl 1 in
  let new_mask = new_cap - 1 in
  let new_buckets = Array.make new_cap None in
  let rec reinsert = function
    | None -> ()
    | Some b ->
      let next = b.next in
      let idx = b.hash land new_mask in
      b.next <- Array.unsafe_get new_buckets idx;
      Array.unsafe_set new_buckets idx (Some b);
      reinsert next
  in
  for i = 0 to old_cap - 1 do
    reinsert (Array.unsafe_get old_buckets i)
  done;
  t.buckets <- new_buckets;
  t.mask <- new_mask

let rec add_slice_to_chain (t : task_table) idx h s off len offset = function
  | Some b when b.hash = h && slice_eq_lit s off len b.key ->
    b.rev_offsets <- offset :: b.rev_offsets
  | Some b -> add_slice_to_chain t idx h s off len offset b.next
  | None ->
    let key = String.sub s off len in
    let b = { hash = h; key; rev_offsets = [ offset ]; next = Array.unsafe_get t.buckets idx } in
    Array.unsafe_set t.buckets idx (Some b);
    t.size <- t.size + 1;
    if t.size > t.mask then grow_task_table t

let add_slice_to_table (t : task_table) s off len offset =
  let h = full_slice_hash s off len in
  let idx = h land t.mask in
  add_slice_to_chain t idx h s off len offset (Array.unsafe_get t.buckets idx)

let rec add_string_to_chain (t : task_table) idx h key offset = function
  | Some b when b.hash = h && String.equal key b.key ->
    b.rev_offsets <- offset :: b.rev_offsets
  | Some b -> add_string_to_chain t idx h key offset b.next
  | None ->
    let b = { hash = h; key; rev_offsets = [ offset ]; next = Array.unsafe_get t.buckets idx } in
    Array.unsafe_set t.buckets idx (Some b);
    t.size <- t.size + 1;
    if t.size > t.mask then grow_task_table t

let add_string_to_table (t : task_table) key offset =
  let h = full_slice_hash key 0 (String.length key) in
  let idx = h land t.mask in
  add_string_to_chain t idx h key offset (Array.unsafe_get t.buckets idx)

let rec fold_bucket_chain map = function
  | None -> map
  | Some b ->
    let map = String_map.add b.key (List.rev b.rev_offsets) map in
    fold_bucket_chain map b.next

let rec buckets_to_map_loop (buckets : task_bucket option array) i map =
  if i >= Array.length buckets then map
  else buckets_to_map_loop buckets (i + 1) (fold_bucket_chain map (Array.unsafe_get buckets i))

let task_table_to_map (t : task_table) =
  buckets_to_map_loop t.buckets 0 String_map.empty

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
  row_count : int;
  first_row_offset : int;
  block_digests : (int * int * string) list;
  by_task : int list String_map.t;
  conflicting : int list String_map.t;
  verified_settled : bool;
  mutable last_used : int;
}

let max_cached_files = 256
(* Bound total retained row offsets across all cached segments in addition to
   the file-count bound so a small number of dense files cannot retain an
   unbounded offset map. *)
let max_cached_segment_rows = 2_000_000
let full_digest_max_bytes = 8 * io_block_bytes
let cache_mutex = Stdlib.Mutex.create ()
let cache_clock = ref 0
let segment_cache_retained_rows = ref 0
let segment_cache : (string * string, cached_segment) Hashtbl.t = Hashtbl.create 64

let segment_weight (seg : cached_segment) = max 1 seg.row_count

let find_cached_segment ~root ~relative =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt segment_cache (root, relative) with
    | None -> None
    | Some seg ->
      incr cache_clock;
      seg.last_used <- !cache_clock;
      Some seg)

let invalidate_cached_segment_if_same ~root ~relative (stale : cached_segment) =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    match Hashtbl.find_opt segment_cache (root, relative) with
    | Some existing when existing == stale ->
      segment_cache_retained_rows :=
        max 0 (!segment_cache_retained_rows - segment_weight existing);
      Hashtbl.remove segment_cache (root, relative)
    | Some _ | None -> ())

let evict_lru_locked () =
  let oldest_key = ref None in
  let oldest_tick = ref max_int in
  Hashtbl.iter
    (fun key (seg : cached_segment) ->
      if seg.last_used < !oldest_tick then (
        oldest_tick := seg.last_used;
        oldest_key := Some key))
    segment_cache;
  match !oldest_key with
  | Some key ->
    (match Hashtbl.find_opt segment_cache key with
     | Some existing ->
       segment_cache_retained_rows :=
         max 0 (!segment_cache_retained_rows - segment_weight existing)
     | None -> ());
    Hashtbl.remove segment_cache key
  | None -> ()

let evict_segment_cache_if_needed_locked () =
  while Hashtbl.length segment_cache > 0
        && (Hashtbl.length segment_cache > max_cached_files
            || !segment_cache_retained_rows > max_cached_segment_rows)
  do
    evict_lru_locked ()
  done

let store_cached_segment ~root ~relative (seg : cached_segment) =
  Stdlib.Mutex.protect cache_mutex (fun () ->
    let replace =
      match Hashtbl.find_opt segment_cache (root, relative) with
      | None -> true
      | Some existing ->
        let range_contains_existing =
          seg.scanned_from <= existing.scanned_from
          && seg.scanned_to >= existing.scanned_to
        in
        let snapshot_supersedes_or_matches =
          seg.snapshot.owner_uid = existing.snapshot.owner_uid
          && seg.snapshot.permissions = existing.snapshot.permissions
          && (seg.snapshot.file_size > existing.snapshot.file_size
              || (seg.snapshot.file_size = existing.snapshot.file_size
                  && Fs_compat.equal_owned_regular_file_snapshot
                       existing.snapshot
                       seg.snapshot))
        in
        existing.device <> seg.device
        || existing.inode <> seg.inode
        || (snapshot_supersedes_or_matches && range_contains_existing)
    in
    if replace then (
      (match Hashtbl.find_opt segment_cache (root, relative) with
       | Some existing ->
         segment_cache_retained_rows :=
           max 0 (!segment_cache_retained_rows - segment_weight existing)
       | None -> ());
      incr cache_clock;
      seg.last_used <- !cache_clock;
      Hashtbl.replace segment_cache (root, relative) seg;
      segment_cache_retained_rows :=
        !segment_cache_retained_rows + segment_weight seg;
      evict_segment_cache_if_needed_locked ()))

let block_digest_at reader ~limit offset =
  let from = offset - (offset mod io_block_bytes) in
  let len = min io_block_bytes (limit - from) in
  let* () = load_block reader from in
  if reader.block_len < len then Error Source_changed
  else
    let d =
      Agent_core_sha256.digest_string ~off:0 ~len reader.block
      |> Agent_core_sha256.to_hex
    in
    Ok (from, len, d)

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

let snapshot_is_settled (s : Fs_compat.owned_regular_file_snapshot) =
  let now = Unix.gettimeofday () in
  now -. s.modified_at > 2.0 && now -. s.changed_at > 2.0

let make_cached_segment reader ~scanned_from ~scanned_to ~row_count ~first_row_offset ~by_task ~conflicting =
  let* block_digests = compute_block_digests reader ~scanned_from ~scanned_to in
  let snap = reader.file.snapshot in
  Ok {
    device = snap.device;
    inode = snap.inode;
    snapshot = snap;
    scanned_from;
    scanned_to;
    row_count;
    first_row_offset;
    block_digests;
    by_task;
    conflicting;
    verified_settled =
      snapshot_is_settled snap
      && (first_row_offset <= 0 || first_row_offset < scanned_to);
    last_used = 0;
  }

let verify_cached_segment ~is_ceiling reader (cached : cached_segment) =
  let cur = reader.file.snapshot in
  if cached.device <> cur.device
     || cached.inode <> cur.inode
     || cached.snapshot.owner_uid <> cur.owner_uid
     || cached.snapshot.permissions <> cur.permissions
     || cur.file_size < cached.snapshot.file_size
     || cached.snapshot.file_size < cached.scanned_to
     || cached.scanned_from < 0
     || cached.scanned_from >= cached.scanned_to
     || cached.row_count < 0
     || (cur.file_size = cached.snapshot.file_size
         && not (Fs_compat.equal_owned_regular_file_snapshot cached.snapshot cur))
  then Ok false
  else if not is_ceiling
          && cached.verified_settled
          && cur.file_size = cached.snapshot.file_size
          && Fs_compat.equal_owned_regular_file_snapshot cached.snapshot cur
  then Ok true
  else
    let rec verify_blocks = function
      | [] ->
        if cached.first_row_offset <= 0 then Ok true
        else if cached.first_row_offset >= cached.scanned_to then Ok false
        else (
          let* prev = byte reader (cached.first_row_offset - 1) in
          Ok (prev = '\n'))
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
      row_count : int;
      first_row_offset : int;
      collected : Yojson.Safe.t list;
      count : int;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }
  | Filled_page of {
      stopped_from : int;
      row_count : int;
      first_row_offset : int;
      anchor_line : string;
      collected : Yojson.Safe.t list;
      by_task : int list String_map.t;
      conflicting : int list String_map.t;
    }

let scan_range_raw ~task_id ~file ~reader ~start_before ~stop_at ~max_events ~collected ~count =
  let key_buf = Array.make (max_fast_depth * key_stride) 0 in
  let state = Array.make 13 0 in
  let table = create_task_table () in
  let slice = { row_offset = 0; row_buf = ""; row_pos = 0; row_len = 0 } in
  let rec loop before row_count first_row_offset collected count rev_conflicting =
    if before <= stop_at then
      Ok (Reached_stop {
        stopped_from = before;
        row_count;
        first_row_offset;
        collected;
        count;
        by_task = task_table_to_map table;
        conflicting = String_map.map List.rev rev_conflicting;
      })
    else
      let* has_row = previous_slice reader slice before in
      if not has_row then
        Ok (Reached_stop {
          stopped_from = 0;
          row_count;
          first_row_offset;
          collected;
          count;
          by_task = task_table_to_map table;
          conflicting = String_map.map List.rev rev_conflicting;
        })
      else
        let offset = slice.row_offset in
        if is_blank_slice slice.row_buf ~pos:slice.row_pos ~len:slice.row_len then
          loop offset row_count first_row_offset collected count rev_conflicting
        else
          let row_count = row_count + 1 in
          let first_row_offset = offset in
          match scan_row_slice_fast ~source:file.source slice.row_buf ~pos:slice.row_pos ~len:slice.row_len key_buf state with
          | 0 (* Fast_unrelated *) ->
            loop offset row_count first_row_offset collected count rev_conflicting
          | 1 (* Fast_task *) ->
            let id_off = Array.unsafe_get state 1 in
            let id_len = Array.unsafe_get state 2 in
            if not (slice_eq_lit slice.row_buf id_off id_len task_id) then (
              add_slice_to_table table slice.row_buf id_off id_len offset;
              loop offset row_count first_row_offset collected count rev_conflicting)
            else
              let line = slice_to_string slice in
              (match classify_row ~source:file.source line with
               | Row_task { task_id = row_tid; json } when String.equal row_tid task_id ->
                 add_string_to_table table row_tid offset;
                 let event = event_envelope ~file ~offset json in
                 let collected = event :: collected in
                 let count = count + 1 in
                 if count < max_events then
                   loop offset row_count first_row_offset collected count rev_conflicting
                 else
                   Ok (Filled_page {
                     stopped_from = offset;
                     row_count;
                     first_row_offset;
                     anchor_line = line;
                     collected;
                     by_task = task_table_to_map table;
                     conflicting = String_map.map List.rev rev_conflicting;
                   })
               | Row_invalid | Row_unrelated | Row_conflicting _ | Row_task _ ->
                 Error (Invalid_event { file = file.relative; offset }))
          | _ (* Fast_fallback *) ->
            let line = slice_to_string slice in
            match classify_row ~source:file.source line with
            | Row_invalid ->
              Error (Invalid_event { file = file.relative; offset })
            | Row_unrelated ->
              loop offset row_count first_row_offset collected count rev_conflicting
            | Row_conflicting { string_ids } ->
              let rev_conflicting =
                List.fold_left (fun acc tid -> add_offset_to_map tid offset acc) rev_conflicting string_ids
              in
              if List.exists (String.equal task_id) string_ids then
                Error (Invalid_event { file = file.relative; offset })
              else
                loop offset row_count first_row_offset collected count rev_conflicting
            | Row_task { task_id = row_tid; json } ->
              add_string_to_table table row_tid offset;
              if not (String.equal row_tid task_id) then
                loop offset row_count first_row_offset collected count rev_conflicting
              else
                let event = event_envelope ~file ~offset json in
                let collected = event :: collected in
                let count = count + 1 in
                if count < max_events then
                  loop offset row_count first_row_offset collected count rev_conflicting
                else
                  Ok (Filled_page {
                    stopped_from = offset;
                    row_count;
                    first_row_offset;
                    anchor_line = line;
                    collected;
                    by_task = task_table_to_map table;
                    conflicting = String_map.map List.rev rev_conflicting;
                  })
  in
  loop start_before 0 (-1) collected count String_map.empty

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
          let ceiling_opt = List.find_opt (fun (c : ceiling) -> c.file = file.relative) ceilings in
          let is_ceiling = Option.is_some ceiling_opt in
          (* Scans, block digests, and index construction run unlocked so a slow
             cold scan never blocks another worker domain that would hash to the
             same stripe. [store_cached_segment] serializes only publication and
             enforces monotonic range/snapshot replacement; [invalidate_cached_segment_if_same]
             removes only the exact stale entry observed by this fiber. *)
          with_reader ~root file (fun reader ->
            let* initial_before =
              match first, cursor with
              | true, Some cursor ->
                let* () = anchor_matches reader cursor.position in
                Ok cursor.position.before
              | false, _ | true, None ->
                Ok (match ceiling_opt with
                  | Some c -> c.size
                  | None -> file.snapshot.file_size)
            in
            if initial_before = 0 then Ok (Step_next_file (initial_collected, initial_count))
            else
              let raw_cached_opt = find_cached_segment ~root ~relative:file.relative in
              let scan_cold_from_initial ?stale () =
                Option.iter
                  (invalidate_cached_segment_if_same ~root ~relative:file.relative)
                  raw_cached_opt;
                Option.iter
                  (invalidate_cached_segment_if_same ~root ~relative:file.relative)
                  stale;
                reset_reader_block_memo reader;
                let* outcome =
                  scan_range_raw ~task_id ~file ~reader ~start_before:initial_before
                    ~stop_at:0 ~max_events ~collected:initial_collected ~count:initial_count
                in
                let cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting =
                  if stopped_from >= initial_before then Ok ()
                  else
                    let* seg =
                      make_cached_segment reader ~scanned_from:stopped_from
                        ~scanned_to:initial_before ~row_count ~first_row_offset ~by_task ~conflicting
                    in
                    Ok (store_cached_segment ~root ~relative:file.relative seg)
                in
                match outcome with
                | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                  Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                  let* () = cache_cold ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                  Ok (Step_next_file (collected, count))
              in
              let* cached_opt =
                match raw_cached_opt with
                | None -> Ok None
                | Some cached ->
                  let* ok = verify_cached_segment ~is_ceiling reader cached in
                  if ok then Ok (Some cached)
                  else (
                    invalidate_cached_segment_if_same ~root ~relative:file.relative cached;
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
                  let merge_first_offset upper_first lower_first =
                    if lower_first >= 0 then lower_first else upper_first
                  in
                  (match outcome with
                   | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                     if stopped_from < cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let* () =
                         if stopped_from = cached.scanned_to then
                           let by_task' = merge_desc_maps by_task cached.by_task in
                           let conflicting' = merge_desc_maps conflicting cached.conflicting in
                           let* seg =
                             make_cached_segment reader ~scanned_from:cached.scanned_from
                               ~scanned_to:initial_before
                               ~row_count:(row_count + cached.row_count)
                               ~first_row_offset:(merge_first_offset first_row_offset cached.first_row_offset)
                               ~by_task:by_task' ~conflicting:conflicting'
                           in
                           Ok (store_cached_segment ~root ~relative:file.relative seg)
                         else Ok ()
                       in
                       Ok (`Done (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line)))
                   | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                     if stopped_from <> cached.scanned_to then
                       Ok `Fallback_cold
                     else
                       let by_task' = merge_desc_maps by_task cached.by_task in
                       let conflicting' = merge_desc_maps conflicting cached.conflicting in
                       let* seg =
                         make_cached_segment reader ~scanned_from:cached.scanned_from
                           ~scanned_to:initial_before
                           ~row_count:(row_count + cached.row_count)
                           ~first_row_offset:(merge_first_offset first_row_offset cached.first_row_offset)
                           ~by_task:by_task' ~conflicting:conflicting'
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
                             let* line_opt = read_line_at_bounded reader ~limit:before off in
                             match line_opt with
                             | None -> Ok `Invalidated
                             | Some line ->
                               let line_end = off + String.length line in
                               let* end_ok =
                                 if line_end >= before then Ok false
                                 else
                                   let* term = byte reader line_end in
                                   Ok (term = '\n')
                               in
                               if not end_ok then Ok `Invalidated
                               else
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
                | `Fallback_cold -> scan_cold_from_initial ?stale:cached_opt ()
                | `Done done_step -> Ok done_step
                | `Continue (before, collected, count, cached_opt) ->
                  (* Step 3: scan remaining prefix [0, before) *)
                  if before = 0 then Ok (Step_next_file (collected, count))
                  else
                    let* outcome =
                      scan_range_raw ~task_id ~file ~reader ~start_before:before
                        ~stop_at:0 ~max_events ~collected ~count
                    in
                    let cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting =
                      if stopped_from >= before then Ok ()
                      else
                        match cached_opt with
                        | Some cached when before = cached.scanned_from ->
                          let by_task' = merge_desc_maps cached.by_task by_task in
                          let conflicting' = merge_desc_maps cached.conflicting conflicting in
                          let merged_first =
                            if first_row_offset >= 0 then first_row_offset else cached.first_row_offset
                          in
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:cached.scanned_to
                              ~row_count:(cached.row_count + row_count)
                              ~first_row_offset:merged_first
                              ~by_task:by_task' ~conflicting:conflicting'
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | None ->
                          let* seg =
                            make_cached_segment reader ~scanned_from:stopped_from
                              ~scanned_to:before ~row_count ~first_row_offset ~by_task ~conflicting
                          in
                          Ok (store_cached_segment ~root ~relative:file.relative seg)
                        | Some _ -> Ok ()
                    in
                    (match outcome with
                     | Filled_page { stopped_from; row_count; first_row_offset; anchor_line; collected; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
                       Ok (Step_done (List.rev collected, make_next_cursor file rest stopped_from anchor_line))
                     | Reached_stop { stopped_from; row_count; first_row_offset; collected; count; by_task; conflicting } ->
                       let* () = cache_lower ~stopped_from ~row_count ~first_row_offset ~by_task ~conflicting in
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
