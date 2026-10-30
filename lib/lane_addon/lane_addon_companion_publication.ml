open Result.Syntax
module O = Lane_addon_companion_origin
module A = Lane_addon_action
type kind = Attention_required | Effect_submitted | Terminal | Owner_lost
let kind_to_string = function
  | Attention_required -> "attention_required"
  | Effect_submitted -> "effect_submitted"
  | Terminal -> "terminal"
  | Owner_lost -> "owner_lost"
type event = {publication_id:string; kind:kind; output:Yojson.Safe.t}
type error = Invalid_event | Schema_rejected | Binding_conflict | Corrupt
  | Unavailable | Commit_unconfirmed
let error_to_string = function
  | Invalid_event -> "invalid original companion publication"
  | Schema_rejected -> "companion publication does not match its original output contract"
  | Binding_conflict -> "companion publication differs from its immutable original"
  | Corrupt -> "original companion publication is corrupt"
  | Unavailable -> "original companion publication is unavailable"
  | Commit_unconfirmed -> "original companion publication commit is unconfirmed"
let validate_output_schema schema =
  (* General value schemas deliberately accept open objects; action schemas
     additionally require a specific action envelope. Keep the general schema
     validator, then close every supported object container on this boundary. *)
  let* () = Lane_addon_action.validate_value_schema schema in
  let invalid () = Error "private companion output schema must be recursively closed" in
  let rec node = function
    | `Assoc fields ->
      let* () =
        if List.assoc_opt "type" fields = Some (`String "object")
          && List.mem_assoc "properties" fields
          && List.assoc_opt "additionalProperties" fields <> Some (`Bool false)
        then invalid () else Ok () in
      let* () = match List.assoc_opt "properties" fields with
        | None -> Ok ()
        | Some (`Assoc properties) ->
          List.fold_left (fun checked (_, child) -> let* () = checked in node child) (Ok ()) properties
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) -> invalid () in
      let* () = match List.assoc_opt "items" fields with
        | None -> Ok () | Some child -> node child in
      (match List.assoc_opt "oneOf" fields with
       | None -> Ok ()
       | Some (`List children) ->
         List.fold_left (fun checked child -> let* () = checked in node child) (Ok ()) children
       | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) -> invalid ())
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> invalid () in
  node schema

type record = {origin:O.record; output_schema:Yojson.Safe.t; event:event}
let object_ keys = function
  | `Assoc fields when List.sort String.compare (List.map fst fields)=List.sort String.compare keys -> Ok fields
  | _ -> Error Invalid_event
let valid_id id = match Uuidm.of_string id with
  | Some value -> Uuidm.to_string value=id
  | None -> false
type event_authority = Worker | Host_retention
let decode_event ~authority ~output_schema value =
  let* ()=validate_output_schema output_schema |> Result.map_error (fun _ -> Schema_rejected) in
  let* value=A.canonical value |> Result.map_error (fun _ -> Invalid_event) in
  let* fields=object_ ["publication_id";"kind";"output"] value in
  let* publication_id=match List.assoc "publication_id" fields with
    | `String id when valid_id id -> Ok id | _ -> Error Invalid_event in
  let* kind=match List.assoc "kind" fields with
    | `String "attention_required" -> Ok Attention_required
    | `String "effect_submitted" -> Ok Effect_submitted
    | `String "terminal" -> Ok Terminal
    | `String "owner_lost" ->
        (match authority with Worker -> Error Invalid_event | Host_retention -> Ok Owner_lost)
    | _ -> Error Invalid_event in
  let* output=match kind with
    | Attention_required | Effect_submitted | Terminal ->
        A.validate_value ~schema:output_schema ~name:"companion publication" (List.assoc "output" fields)
        |> Result.map_error (fun _ -> Schema_rejected)
    | Owner_lost ->
        if List.assoc "output" fields=`Assoc ["outcome",`String "unknown"]
        then Ok (`Assoc ["outcome",`String "unknown"]) else Error Invalid_event in
  Ok {publication_id;kind;output}
let event ~output_schema value = decode_event ~authority:Worker ~output_schema value
let owner_lost ~publication_id =
  if valid_id publication_id then
    Ok {publication_id;kind=Owner_lost;output=`Assoc ["outcome",`String "unknown"]}
  else Error Invalid_event
let event_json event = `Assoc ["publication_id",`String event.publication_id;
  "kind",`String (kind_to_string event.kind);"output",event.output]
let encode record = Yojson.Safe.to_string (`Assoc ["version",`Int 1;
  "origin_id",`String record.origin.O.id;"output_schema",record.output_schema;"event",event_json record.event]) ^ "\n"
let decode ~origin bytes =
  try
    let* fields=Yojson.Safe.from_string bytes |> object_ ["version";"origin_id";"output_schema";"event"]
      |> Result.map_error (fun _ -> Corrupt) in
    let* ()=if List.assoc "version" fields=`Int 1 && List.assoc "origin_id" fields=`String origin.O.id
      then Ok () else Error Corrupt in
    let* output_schema=A.canonical (List.assoc "output_schema" fields) |> Result.map_error (fun _ -> Corrupt) in
    let* event=decode_event ~authority:Host_retention ~output_schema (List.assoc "event" fields)
      |> Result.map_error (fun _ -> Corrupt) in
    let record={origin;output_schema;event} in
    if encode record=bytes then Ok record else Error Corrupt
  with Yojson.Json_error _ -> Error Corrupt
let blocking work = match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> work ()
  | Fs_compat.Eio_fiber -> Eio_unix.run_in_systhread work
let protect work = try work () with
  | Sys_error _ | Unix.Unix_error _ | Eio.Io _ -> Error Unavailable
let original ~config id =
  let* found=O.find ~config ~id |> Result.map_error (function
    | O.Corrupt -> Corrupt | Invalid_source | Binding_conflict | Unavailable | Commit_unconfirmed -> Unavailable) in
  match found with Some origin -> Ok origin | None -> Error Unavailable
let path origin publication_id = Filename.concat
  (Filename.concat (Filename.concat (Filename.concat
    (Common.masc_dir_from_base_path ~base_path:origin.O.base_path) "lane-addons")
    "companion-publications") origin.id) (publication_id ^ ".json")
let validate_path ~origin ~path ~create =
  let root=Common.masc_dir_from_base_path ~base_path:origin.O.base_path in
  let* directories=Fs_compat.owned_directory_paths ~ownership_root:root (Filename.dirname path)
    |> Result.map_error (fun _ -> Unavailable) in
  let check kind candidate = match Unix.lstat candidate with
    | stat when stat.Unix.st_kind=kind && stat.st_uid=Unix.getuid () && stat.st_perm land 0o022=0
        && (kind<>Unix.S_REG || stat.st_nlink=1 && stat.st_perm land 0o077=0) -> Ok ()
    | _ -> Error Unavailable
    | exception Unix.Unix_error (Unix.ENOENT,_,_) when create && kind=Unix.S_REG && candidate=path -> Ok () in
  let* ()=List.fold_left (fun result directory -> let* ()=result in check Unix.S_DIR directory)
      (Ok ()) (root::directories) in
  check Unix.S_REG path
let outcome = function
  | Fs_compat.Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure _ | Private_file_failed _
  | Private_file_failed_with_cleanup_failure _ -> Error Commit_unconfirmed
let retain ~fs ~config ~origin ~output_schema ~event:notice = protect (fun () ->
  let* current=original ~config origin.O.id in
  let* ()=if current=origin then Ok () else Error Binding_conflict in
  let* output_schema=A.canonical output_schema |> Result.map_error (fun _ -> Schema_rejected) in
  let* event=decode_event ~authority:Host_retention ~output_schema (event_json notice) in
  let proposed={origin;output_schema;event} in
  let path=path origin event.publication_id in
  let* _=Keeper_fs_durable_directory.ensure ~before_prepare:(fun () -> ())
      ~before_directory_fsync:(fun _ -> ()) ~ownership_root:origin.base_path (Filename.dirname path)
    |> Result.map_error (fun _ -> Unavailable) in
  let* ()=blocking (fun () -> validate_path ~origin ~path ~create:true) in
  let* ()=Eio.Path.with_open_dir Eio.Path.(fs / Filename.dirname path) (fun parent ->
    let validate_parent () =
      let opened=Eio.Path.stat ~follow:true parent in
      blocking (fun () ->
        let* ()=validate_path ~origin ~path ~create:true in
        let current=Unix.lstat (Filename.dirname path) in
        if opened.dev=Int64.of_int current.Unix.st_dev && opened.ino=Int64.of_int current.st_ino
        then Ok () else Error Unavailable) in
    let* ()=validate_parent () in
    let* ()=Lane_addon_companion_persistence.with_creation_owner ~path
      ~unavailable:Unavailable ~commit_unconfirmed:Commit_unconfirmed (fun () ->
      let* ()=validate_parent () in
      Eio.Path.with_open_dir
      Eio.Path.(fs / Common.masc_dir_from_base_path ~base_path:origin.base_path) (fun owned_root ->
      let root_stat=Eio.Path.stat ~follow:true owned_root in
      let* target=Fs_compat.capability_publication_target
        ~allowed_root_path:(Common.masc_dir_from_base_path ~base_path:origin.base_path)
        ~allowed_root_device:root_stat.dev ~allowed_root_inode:root_stat.ino
        ~parent_components:["lane-addons";"companion-publications";origin.id]
        ~target_leaf:(Filename.basename path) ~permissions:0o600
        |> Result.map_error (fun _ -> Unavailable) in
      Eio.Switch.run (fun sw ->
        let* registry=Fs_compat.Publication_recovery.open_registry ~sw ~fs
          ~registry_root:owned_root |> Result.map_error (fun _ -> Unavailable) in
        match Fs_compat.Publication_recovery.with_lane ~registry
          ~owner:("companion-publication-" ^ origin.id ^ "-" ^ event.publication_id) (fun recovery ->
            match Fs_compat.create_capability_file_exclusive ~recovery ~parent
              ~target (encode proposed) with
            | Ok () -> Ok () | Error error when Lane_addon_companion_persistence.existing_leaf error -> Ok ()
            | Error _ -> Error Commit_unconfirmed) with
        | Error _ -> Error Unavailable
        | Ok (Fs_compat.Publication_recovery.Lane_released result) -> result
        | Ok (Fs_compat.Publication_recovery.Lane_release_failed _) -> Error Commit_unconfirmed))) in
    validate_parent ()) in
  Fs_compat.reconcile_private_file_durable_locked_result path (fun bytes ->
    let result=let* ()=validate_path ~origin ~path ~create:false in
      let* prior=decode ~origin bytes in
      if encode prior=encode proposed then Ok prior else Error Binding_conflict in
    match result with
    | Ok _ -> Fs_compat.Confirm_existing result
    | Error _ -> Fs_compat.Refuse_update result) |> outcome)
let find ~config ~origin_id ~publication_id = protect (fun () ->
  let* ()=if valid_id publication_id then Ok () else Error Invalid_event in
  let* origin=original ~config origin_id in
  let path=path origin publication_id in
  let* ()=blocking (fun () -> validate_path ~origin ~path ~create:false) in
  Fs_compat.update_private_file_durable_locked_result ~create:false path (fun bytes ->
    let result=let* ()=validate_path ~origin ~path ~create:false in
      let* record=decode ~origin bytes in
      if record.event.publication_id=publication_id then Ok record else Error Binding_conflict in
    None,result) |> outcome)
let queue_payload record =
  let source=record.origin.O.source in
  let ao_source=Keeper_owned_job_identity.{task_id=source.task_id;turn_ref=Some source.turn_ref;
    tool_use_id=Some source.tool_use_id;trace_id=Some (Ids.Turn_ref.trace_id source.turn_ref);
    keeper_turn_id=Some (Ids.Turn_ref.absolute_turn source.turn_ref)} in
  Keeper_event_queue.{ao_origin_id=record.origin.id;ao_publication_id=record.event.publication_id;
    ao_source;ao_channel=source.channel}
let matches_queue ~keeper_name payload record =
  let expected=queue_payload record in
  keeper_name=record.origin.O.source.keeper_name
  && payload.Keeper_event_queue.ao_origin_id=expected.ao_origin_id
  && payload.ao_publication_id=expected.ao_publication_id
  && Keeper_owned_job_identity.source_to_json payload.ao_source=Keeper_owned_job_identity.source_to_json expected.ao_source
  && Keeper_continuation_channel.to_yojson payload.ao_channel=Keeper_continuation_channel.to_yojson expected.ao_channel
