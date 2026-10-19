open Result.Syntax
module Layout = Dated_jsonl.Layout

type position = { file : string; device : int; inode : int; before : int; anchor : string }
type cursor = { task : string; workspace : string; ceiling : string; inventory : string; position : position }
type error = Invalid_request | Invalid_cursor | Source_changed
  | Invalid_event of { file : string; offset : int }
  | Invalid_layout of { entry : string } | Source_unavailable
type page = { task_id : string; cursor : cursor option; events : Yojson.Safe.t list; next_cursor : cursor option }
let hash text = Digestif.SHA256.(digest_string text |> to_hex)
let cursor_json cursor =
  let p=cursor.position in
  `Assoc ["schema",`String "masc.task-history.cursor/v1";"task_id",`String cursor.task;
    "workspace",`String cursor.workspace;"ceiling",`String cursor.ceiling;
    "inventory",`String cursor.inventory;"file",`String p.file;"device",`Int p.device;
    "inode",`Int p.inode;"before",`Int p.before;"anchor",`String p.anchor]
let cursor_to_string cursor = Yojson.Safe.to_string (cursor_json cursor)
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet
let dated_parts relative = match String.split_on_char '/' relative with
  | [month;file] -> (match Layout.year_and_month_of_directory_name month with
    | Some (year,month_number) when Layout.day_file_name_is_valid ~year ~month:month_number file -> Some (month,file)
    | Some _ | None -> None)
  | _ -> None
let compare_relative left right = match dated_parts left,dated_parts right with
  | Some (lm,lf),Some (rm,rf) -> let order=String.compare lm rm in
    if order=0 then Layout.compare_day_files lf rf else order
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
       (match text "schema",text "task_id",text "workspace",text "ceiling",text "inventory",
              text "file",integer "device",integer "inode",integer "before",text "anchor" with
        | Some "masc.task-history.cursor/v1",Some task,Some workspace,Some ceiling,Some inventory,
          Some file,Some device,Some inode,Some before,Some anchor
          when Option.is_some (dated_parts ceiling) && Option.is_some (dated_parts file) ->
          let cursor={task;workspace;ceiling;inventory;position={file;device;inode;before;anchor}} in
          if cursor_to_string cursor=encoded then Ok cursor else Error Invalid_cursor
        | _ -> Error Invalid_cursor)
     | _ -> Error Invalid_cursor
     | exception Yojson.Json_error _ -> Error Invalid_cursor)

type file = { relative : string; path : string; snapshot : Fs_compat.owned_regular_file_snapshot }
let owned result = Result.map_error (fun _ -> Source_unavailable) result
let inventory ~root ~held =
  let events=Filename.concat root "events" in
  let* months=Fs_compat.read_owned_directory ~inventory_root:held ~ownership_root:root events |> owned in
  let* files=List.fold_left (fun result month ->
    let* collected=result in
    if Layout.entry_is_foreign_to_layout month then Ok collected else
    match Layout.year_and_month_of_directory_name month with
    | None -> Error (Invalid_layout {entry="events/" ^ month})
    | Some (year,month_number) ->
      let directory=Filename.concat events month in
      let* names=Fs_compat.read_owned_directory ~inventory_root:held ~ownership_root:root directory |> owned in
      List.fold_left (fun result name ->
        let* collected=result in
        if Layout.entry_is_foreign_to_layout name then Ok collected
        else if not (Layout.day_file_name_is_valid ~year ~month:month_number name)
        then Error (Invalid_layout {entry="events/" ^ month ^ "/" ^ name})
        else
          let path=Filename.concat directory name in
          let* observed=Fs_compat.load_owned_regular_file_range ~ownership_root:root ~offset:0 ~max_bytes:0 path |> owned in
          match observed with
          | None -> Error Source_changed
          | Some observed -> Ok ({relative=month ^ "/" ^ name;path;snapshot=observed.snapshot}::collected)
      ) (Ok collected) names
  ) (Ok []) months in
  Ok (List.sort (fun left right -> compare_relative right.relative left.relative) files)
let prefix ~ceiling files = List.filter (fun file -> compare_relative file.relative ceiling<=0) files
let inventory_hash ~ceiling files =
  List.map (fun file -> let s=file.snapshot in
    let identity=["file",`String file.relative;"device",`Int s.device;"inode",`Int s.inode] in
    let fields=if file.relative=ceiling then identity else identity @
      ["size",`Int s.file_size;"modified",`Float s.modified_at;"changed",`Float s.changed_at] in
    `Assoc fields) files |> fun fields -> hash (Yojson.Safe.to_string (`List fields))

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
  match Yojson.Safe.from_string line with
  | `Assoc fields as json ->
    let* ()=Agent_core.Execution_json.validate ~context:"Task history event" json
      |> Result.map_error (fun _ -> Invalid_event {file;offset}) in
    let values=List.filter_map (fun name -> List.assoc_opt name fields) ["task";"task_id"] in
    let matches=List.exists (function `String id -> id=task_id | _ -> false) values in
    if not matches then Ok None
    else if List.for_all (function `String id -> id=task_id | _ -> false) values then Ok (Some json)
    else Error (Invalid_event {file;offset})
  | _ -> Error (Invalid_event {file;offset})
  | exception Yojson.Json_error _ -> Error (Invalid_event {file;offset})

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
        let ceiling=match cursor,all with
          | Some cursor,_ -> Some cursor.ceiling
          | None,file::_ -> Some file.relative
          | None,[] -> None in
        match ceiling with
        | None -> Ok {task_id;cursor=None;events=[];next_cursor=None}
        | Some ceiling ->
          let files=prefix ~ceiling all in
          let fingerprint=inventory_hash ~ceiling files in
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
                | false,_ | true,None -> Ok file.snapshot.file_size in
              let rec scan before collected count =
                let* row=previous reader before in
                match row with
                | None -> scan_files false collected count rest
                | Some (offset,line) ->
                  let* event=if String.trim line="" then Ok None
                    else matches_task ~task_id ~file:file.relative ~offset line in
                  let collected,count=match event with None -> collected,count | Some event -> event::collected,count+1 in
                  if count<max_events then scan offset collected count
                  else
                    let next_cursor=if offset=0 && rest=[] then None else
                      Some {task=task_id;workspace;ceiling;inventory=fingerprint;
                        position={file=file.relative;device=file.snapshot.device;inode=file.snapshot.inode;
                          before=offset;anchor=hash line}} in
                    Ok (List.rev collected,next_cursor) in
              scan before collected count in
          let* events,next_cursor=scan_files true [] 0 files in
          let* after=inventory ~root ~held in
          if inventory_hash ~ceiling (prefix ~ceiling after)<>fingerprint then Error Source_changed
          else Ok {task_id;cursor;events;next_cursor} in
      Ok (run ()))
    |> function Ok result -> result | Error _ -> Error Source_unavailable

let to_json page =
  let token = function None -> `Null | Some cursor -> `String (cursor_to_string cursor) in
  `Assoc ["schema",`String "masc.task-history.page/v1";"task_id",`String page.task_id;
    "cursor",token page.cursor;"events",`List page.events;"next_cursor",token page.next_cursor]
