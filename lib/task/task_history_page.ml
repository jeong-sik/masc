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
let hash text = Digestif.SHA256.(digest_string text |> to_hex)
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
        if Layout.entry_is_foreign_to_layout month then Ok collected else
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
(* A transfer buffer, not a record/window/history limit. A row can span any
   number of blocks. Owned reads validate the no-follow path and descriptor. *)
let io_block_bytes=4096
type reader = { root : string; file : file; mutable block_from : int; mutable block : string }
let reader ~root file = {root;file;block_from=(-1);block=""}
let byte reader offset =
  if offset<0 || offset>=reader.file.snapshot.file_size then Error Source_changed
  else
    let* () =
      if offset>=reader.block_from && offset-reader.block_from<String.length reader.block then Ok ()
      else
        let from=offset-(offset mod io_block_bytes) in
        let length=min io_block_bytes (reader.file.snapshot.file_size-from) in
        let* range=Fs_compat.load_owned_regular_file_range ~ownership_root:reader.root
          ~offset:from ~max_bytes:length reader.file.path |> owned in
        match range with
        | None -> Error Source_changed
        | Some range when range.snapshot.device=reader.file.snapshot.device
            && range.snapshot.inode=reader.file.snapshot.inode
            && range.snapshot.file_size>=reader.file.snapshot.file_size
            && String.length range.content=length ->
          reader.block_from<-from;reader.block<-range.content;Ok ()
        | Some _ -> Error Source_changed in
    Ok reader.block.[offset-reader.block_from]
let previous reader before =
  if before=0 then Ok None
  else
    let* ending=byte reader (before-1) in
    if ending<>'\n' then Error (Invalid_event {file=reader.file.relative;offset=before-1})
    else
      let buffer=Buffer.create 128 in
      let finish start = let backwards=Buffer.contents buffer in
        let length=String.length backwards in
        Some (start,String.init length (fun i -> backwards.[length-i-1])) in
      let rec walk offset =
        if offset<0 then Ok (finish 0)
        else let* value=byte reader offset in
          if value='\n' then Ok (finish (offset+1))
          else (Buffer.add_char buffer value;walk (offset-1)) in
      walk (before-2)
let anchor_matches reader position =
  let* () = if position.device=reader.file.snapshot.device && position.inode=reader.file.snapshot.inode
      && position.before<reader.file.snapshot.file_size then Ok () else Error Source_changed in
  let* () = if position.before=0 then Ok () else
    let* value=byte reader (position.before-1) in if value='\n' then Ok () else Error Source_changed in
  let buffer=Buffer.create 128 in
  let rec walk offset =
    if offset>=reader.file.snapshot.file_size then Error Source_changed
    else let* value=byte reader offset in
      if value='\n' then if hash (Buffer.contents buffer)=position.anchor then Ok () else Error Source_changed
      else (Buffer.add_char buffer value;walk (offset+1)) in
  walk position.before
let matches_task ~task_id ~file ~offset line =
  let invalid () = Error (Invalid_event {file=file.relative;offset}) in
  match Yojson.Safe.from_string line with
  | `Assoc fields as json ->
    let* ()=Agent_core.Execution_json.validate ~context:"Task history event" json
      |> Result.map_error (fun _ -> Invalid_event {file=file.relative;offset}) in
    let ids fields = List.filter_map (fun key -> List.assoc_opt key fields) ["task";"task_id"] in
    let* identities=match file.source with
      | Audit -> Ok (ids fields)
      | Activity ->
        let* _fields=Agent_core.Execution_json.object_fields ~context:"canonical Task activity"
          ~required:["seq";"ts_ms";"ts_iso";"kind";"actor";"subject";"payload";"tags"]
          ~optional:["context"] json |> Result.map_error (fun _ -> Invalid_event {file=file.relative;offset}) in
        let ids fields=Option.to_list (List.assoc_opt "task_id" fields) in
        let* ()=match List.assoc_opt "tags" fields with
          | Some (`List tags) when List.for_all (function `String _ -> true | _ -> false) tags -> Ok ()
          | Some _ | None -> invalid () in
        (match Activity_graph.event_of_yojson json with
         | None -> invalid ()
         | Some event ->
           let payload=match event.payload with `Assoc fields -> ids fields | _ -> [] in
           let* context=match List.assoc_opt "context" fields with
             | None -> Ok [] | Some (`Assoc fields) -> Ok (ids fields) | Some _ -> invalid () in
           let entity name = match List.assoc_opt name fields with
             | Some `Null -> Ok None
             | Some (`Assoc fields) when List.length fields=2 ->
               (match List.assoc_opt "kind" fields,List.assoc_opt "id" fields with
                | Some (`String kind),Some (`String id) when kind<>"" && kind=String.trim kind
                    && id<>"" && id=String.trim id -> Ok (Some (kind,id))
                | _ -> invalid ())
             | Some _ | None -> invalid () in
           let* _actor=entity "actor" in
           let* subject=entity "subject" in
           let subject=match subject with Some ("task",id) -> [`String id] | Some _ | None -> [] in
           Ok (subject @ payload @ context)) in
    let matches=List.exists (function `String id -> id=task_id | _ -> false) identities in
    if not matches then Ok None
    else if List.for_all (function `String id -> id=task_id | _ -> false) identities then
      Ok (Some (`Assoc ["source",`String (source_name file.source);"file",`String file.relative;
        "offset",`Int offset;"event",json]))
    else invalid ()
  | _ -> invalid ()
  | exception Yojson.Json_error _ -> invalid ()

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
        let rec scan_files first collected count = function
          | [] -> Ok (List.rev collected,None)
          | file::rest ->
            let reader=reader ~root file in
            let* before=match first,cursor with
              | true,Some cursor -> let* ()=anchor_matches reader cursor.position in Ok cursor.position.before
              | false,_ | true,None ->
                Ok (match List.find_opt (fun (c:ceiling) -> c.file=file.relative) ceilings with
                  | Some c -> c.size | None -> file.snapshot.file_size) in
            let rec scan before collected count =
              let* row=previous reader before in
              match row with
              | None -> scan_files false collected count rest
              | Some (offset,line) ->
                let* event=if String.trim line="" then Ok None else matches_task ~task_id ~file ~offset line in
                let collected,count=match event with None -> collected,count | Some event -> event::collected,count+1 in
                if count<max_events then scan offset collected count
                else
                  let next_cursor=if offset=0 && rest=[] then None else
                    Some {task=task_id;workspace;ceilings;inventory=fingerprint;
                      position={file=file.relative;device=file.snapshot.device;inode=file.snapshot.inode;
                        before=offset;anchor=hash line}} in
                  Ok (List.rev collected,next_cursor) in
            scan before collected count in
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
