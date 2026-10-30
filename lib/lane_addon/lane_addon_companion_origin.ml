open Result.Syntax
type error = Invalid_source | Binding_conflict | Corrupt | Unavailable | Commit_unconfirmed
let error_to_string = function
  | Invalid_source -> "original companion source is unavailable or contradictory"
  | Binding_conflict -> "original companion invocation already owns a different binding"
  | Corrupt -> "original companion binding is corrupt"
  | Unavailable -> "original companion binding is unavailable"
  | Commit_unconfirmed -> "original companion binding publication is unconfirmed"

type source = {
  keeper_name:string;turn_ref:Ids.Turn_ref.t;tool_use_id:string;task_id:string option;
  channel:Keeper_continuation_channel.t;
}
type destination = {
  instance_id:string;package_id:string;package_revision:string;tool:string;
  declaration_id:string option;configuration_revision:string option;
}
type record = {
  id:string;base_path:string;source:source;destination:destination;arguments_sha256:string;
}
type reservation = Fresh of record | Existing of record
let text value = value<>"" && value=String.trim value
  && String.for_all (fun c -> Char.code c>=32 && Char.code c<>127) value
let valid_source source = text source.keeper_name && text source.tool_use_id
  && Option.fold ~none:true ~some:text source.task_id
  && Result.is_ok (Ids.Turn_ref.of_yojson (Ids.Turn_ref.to_yojson source.turn_ref))
let source ~keeper_name ~turn_ref ~tool_use_id ~trace_id ~source_context ~channel =
  let observed = Option.bind source_context Keeper_tool_call_log_context.source_turn_ref in
  let* turn_ref = match turn_ref,observed with
    | Some actual,Some observed when Ids.Turn_ref.equal actual observed -> Ok actual
    | Some _,Some _ -> Error Invalid_source
    | Some actual,None | None,Some actual -> Ok actual
    | None,None -> Error Invalid_source in
  let* tool_use_id = match tool_use_id with Some value when text value -> Ok value
    | Some _|None -> Error Invalid_source in
  let actual_trace=Ids.Turn_ref.trace_id turn_ref in
  let observed_keeper=Option.bind source_context (fun c -> c.Keeper_tool_call_log_context.agent_name) in
  let observed_trace=Option.bind source_context (fun c -> c.Keeper_tool_call_log_context.trace_id) in
  let observed_turn=Option.bind source_context (fun c -> c.Keeper_tool_call_log_context.keeper_turn_id) in
  let* ()=if List.for_all (Option.fold ~none:true ~some:(String.equal actual_trace)) [trace_id;observed_trace]
      && Option.fold ~none:true ~some:(String.equal keeper_name) observed_keeper
      && Option.fold ~none:true ~some:(fun n -> n=Ids.Turn_ref.absolute_turn turn_ref) observed_turn
    then Ok () else Error Invalid_source in
  let task_id=Option.bind source_context (fun c -> c.Keeper_tool_call_log_context.task_id) in
  let channel=match channel with Some channel -> channel
    | None -> Keeper_continuation_channel.unrouted "original companion conversation was not observed" in
  let value={keeper_name;turn_ref;tool_use_id;task_id;channel} in
  if valid_source value then Ok value else Error Invalid_source
let nullable encode = function None -> `Null | Some value -> encode value
let string value = `String value
let source_json source = `Assoc ["keeper_name",string source.keeper_name;
  "turn_ref",Ids.Turn_ref.to_yojson source.turn_ref;"tool_use_id",string source.tool_use_id;
  "task_id",nullable string source.task_id;"channel",Keeper_continuation_channel.to_yojson source.channel]
let destination_json destination = `Assoc ["instance_id",string destination.instance_id;
  "package_id",string destination.package_id;"package_revision",string destination.package_revision;
  "tool",string destination.tool;"declaration_id",nullable string destination.declaration_id;
  "configuration_revision",nullable string destination.configuration_revision]
let digest value = Lane_addon_action.canonical value |> Result.map (fun value ->
    Lane_addon_store.digest (Yojson.Safe.to_string value)) |> Result.map_error (fun _ -> Invalid_source)
let identity source = digest (`Assoc ["keeper_name",string source.keeper_name;
  "turn_ref",Ids.Turn_ref.to_yojson source.turn_ref;"tool_use_id",string source.tool_use_id])
let encode record = Yojson.Safe.to_string (`Assoc ["version",`Int 1;"id",string record.id;
  "base_path",string record.base_path;"source",source_json record.source;
  "destination",destination_json record.destination;"arguments_sha256",string record.arguments_sha256]) ^ "\n"
let object_ expected = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare expected -> Ok fields
  | _ -> Error Corrupt
let read_text = function `String value when text value -> Ok value | _ -> Error Corrupt
let read_optional parse = function `Null -> Ok None | value -> Result.map Option.some (parse value)
let read_hash value =
  let* value=read_text value in
  if String.length value=64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value
  then Ok value else Error Corrupt
let decode_source value =
  let* fields=object_ ["keeper_name";"turn_ref";"tool_use_id";"task_id";"channel"] value in
  let get key=List.assoc key fields in
  let* keeper_name=read_text (get "keeper_name") in
  let* turn_ref=Ids.Turn_ref.of_yojson (get "turn_ref") |> Result.map_error (fun _ -> Corrupt) in
  let* tool_use_id=read_text (get "tool_use_id") in
  let* task_id=read_optional read_text (get "task_id") in
  let* channel=Keeper_continuation_channel.of_yojson (get "channel") |> Result.map_error (fun _ -> Corrupt) in
  Ok {keeper_name;turn_ref;tool_use_id;task_id;channel}
let valid_destination destination =
  List.for_all text [destination.instance_id;destination.package_id;destination.package_revision;destination.tool]
  && (match destination.declaration_id,destination.configuration_revision with
      | None,None -> true | Some id,Some revision -> text id && text revision
      | None,Some _ | Some _,None -> false)
let decode_destination value =
  let* fields=object_ ["instance_id";"package_id";"package_revision";"tool";"declaration_id";"configuration_revision"] value in
  let get key=List.assoc key fields in
  let* instance_id=read_text (get "instance_id") in
  let* package_id=read_text (get "package_id") in
  let* package_revision=read_text (get "package_revision") in
  let* tool=read_text (get "tool") in
  let* declaration_id=read_optional read_text (get "declaration_id") in
  let* configuration_revision=read_optional read_text (get "configuration_revision") in
  let value={instance_id;package_id;package_revision;tool;declaration_id;configuration_revision} in
  if valid_destination value then Ok value else Error Corrupt
let decode bytes =
  try
    let* fields=Yojson.Safe.from_string bytes |> object_ ["version";"id";"base_path";"source";"destination";"arguments_sha256"] in
    let get key=List.assoc key fields in
    let* ()=if get "version"=`Int 1 then Ok () else Error Corrupt in
    let* id=read_hash (get "id") in
    let* base_path=read_text (get "base_path") in
    let* source=decode_source (get "source") in
    let* destination=decode_destination (get "destination") in
    let* arguments_sha256=read_hash (get "arguments_sha256") in
    let value={id;base_path;source;destination;arguments_sha256} in
    let* actual=identity source |> Result.map_error (fun _ -> Corrupt) in
    if actual=id && encode value=bytes then Ok value else Error Corrupt
  with Yojson.Json_error _ -> Error Corrupt
let blocking work = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> work ()
  | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread work
let protect work = try work () with
  | Sys_error _ | Unix.Unix_error _ | Eio.Io _ -> Error Unavailable
let canonical config =
  let* absolute=Config_dir_resolver.canonical_base_path config.Workspace.base_path
    |> Result.map_error (fun _ -> Unavailable) in
  blocking (fun () -> if (Unix.lstat absolute).Unix.st_kind=Unix.S_DIR
    then Ok (Unix.realpath absolute) else Error Unavailable)
let location base_path id = Filename.concat
  (Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "lane-addons") "companion-invocations")
  (id ^ ".jsonl")
let validate_path ~base_path ~path ~create =
  let root=Common.masc_dir_from_base_path ~base_path in
  let* directories=Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname path)
    |> Result.map_error (fun _ -> Unavailable) in
  let check kind candidate = match Unix.lstat candidate with
    | stat when stat.Unix.st_kind=kind && stat.st_uid=Unix.getuid () && stat.st_perm land 0o022=0
        && (kind<>Unix.S_REG || stat.st_nlink=1 && stat.st_perm land 0o077=0) -> Ok ()
    | _ -> Error Unavailable
    | exception Unix.Unix_error (Unix.ENOENT,_,_) when create && kind=Unix.S_REG && candidate=path -> Ok () in
  let* ()=List.fold_left (fun result directory -> let* ()=result in check Unix.S_DIR directory) (Ok ()) (root::directories) in
  check Unix.S_REG path
let scoped ~base_path ~source ~id record =
  if record.base_path=base_path && record.id=id && source_json record.source=source_json source
  then Ok record else Error Binding_conflict
let outcome = function
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure _ -> Error Commit_unconfirmed
  | Private_file_failed _ -> Error Commit_unconfirmed
  | Private_file_failed_with_cleanup_failure _ -> Error Commit_unconfirmed
type publication = Newly_created | Already_present
let reserve ~fs ~config ~source ~destination ~arguments = protect (fun () ->
  let* ()=if valid_source source && valid_destination destination then Ok () else Error Invalid_source in
  let* base_path=canonical config in
  let* id=identity source in
  let* arguments_sha256=digest arguments in
  let path=location base_path id in
  let* _=Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:base_path (Filename.dirname path)
    |> Result.map_error (fun _ -> Unavailable) in
  let* ()=blocking (fun () -> validate_path ~base_path ~path ~create:true) in
  let proposed={id;base_path;source;destination;arguments_sha256} in
  let* publication=Eio.Path.with_open_dir Eio.Path.(fs / Filename.dirname path) (fun parent ->
    let validate_parent () =
      let opened=Eio.Path.stat ~follow:true parent in
      blocking (fun () ->
        let* ()=validate_path ~base_path ~path ~create:true in
        let current=Unix.lstat (Filename.dirname path) in
        if opened.dev=Int64.of_int current.Unix.st_dev && opened.ino=Int64.of_int current.st_ino
        then Ok () else Error Unavailable) in
    let* ()=validate_parent () in
    let* publication=Lane_addon_companion_persistence.with_creation_owner ~path
      ~unavailable:Unavailable ~commit_unconfirmed:Commit_unconfirmed (fun () ->
      let* ()=validate_parent () in
      Eio.Path.with_open_dir
      Eio.Path.(fs / Common.masc_dir_from_base_path ~base_path) (fun owned_root ->
      let root_stat=Eio.Path.stat ~follow:true owned_root in
      let* target=Fs_compat.capability_publication_target
        ~allowed_root_path:(Common.masc_dir_from_base_path ~base_path)
        ~allowed_root_device:root_stat.dev ~allowed_root_inode:root_stat.ino
        ~parent_components:["lane-addons";"companion-invocations"]
        ~target_leaf:(Filename.basename path) ~permissions:0o600
        |> Result.map_error (fun _ -> Unavailable) in
      Eio.Switch.run (fun sw ->
        let* registry=Fs_compat.Publication_recovery.open_registry ~sw ~fs
          ~registry_root:owned_root |> Result.map_error (fun _ -> Unavailable) in
        match Fs_compat.Publication_recovery.with_lane ~registry
          ~owner:("companion-origin-" ^ id) (fun recovery ->
            match Fs_compat.create_capability_file_exclusive ~recovery ~parent
              ~target (encode proposed) with
            | Ok () -> Ok Newly_created
            | Error error when Lane_addon_companion_persistence.existing_leaf error -> Ok Already_present
            | Error _ -> Error Commit_unconfirmed) with
        | Error _ -> Error Unavailable
        | Ok (Fs_compat.Publication_recovery.Lane_released result) -> result
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) -> Error Commit_unconfirmed))) in
    let* ()=validate_parent () in
    Ok publication) in
  Fs_compat.reconcile_private_file_durable_locked_result path (fun bytes ->
    match validate_path ~base_path ~path ~create:false with
    | Error error -> Fs_compat.Refuse_update (Error error)
    | Ok () ->
        let result=let* prior=decode bytes in
          let* prior=scoped ~base_path ~source ~id prior in
          if destination_json prior.destination=destination_json destination && prior.arguments_sha256=arguments_sha256
          then Ok (match publication with Newly_created -> Fresh prior | Already_present -> Existing prior)
          else Error Binding_conflict in
        (match result with Ok _ -> Fs_compat.Confirm_existing result | Error _ -> Fs_compat.Refuse_update result))
  |> outcome)
let find ~config ~id = protect (fun () ->
  let* _=read_hash (`String id) |> Result.map_error (fun _ -> Invalid_source) in
  let* base_path=canonical config in
  let path=location base_path id in
  let* parent=blocking (fun () -> Fs_compat.inspect_owned_directory_chain
      ~ownership_root:(Common.masc_dir_from_base_path ~base_path) (Filename.dirname path)
    |> Result.map_error (fun _ -> Unavailable)) in
  match parent with
  | Fs_compat.Owned_directory_missing -> Ok None
  | Fs_compat.Owned_directory _ ->
    (match blocking (fun () -> Unix.lstat path) with
     | _ ->
       let* ()=blocking (fun () -> validate_path ~base_path ~path ~create:false) in
       Fs_compat.update_private_file_durable_locked_result ~create:false path (fun bytes ->
         let result=let* ()=validate_path ~base_path ~path ~create:false in
           let* prior=decode bytes in
           if prior.base_path=base_path && prior.id=id then Ok (Some prior) else Error Binding_conflict in
         None,result) |> outcome
     | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None))
let lookup ~config ~source =
  let* ()=if valid_source source then Ok () else Error Invalid_source in
  let* id=identity source in
  let* record=find ~config ~id in
  match record with
  | None -> Ok None
  | Some record -> scoped ~base_path:record.base_path ~source ~id record |> Result.map Option.some
