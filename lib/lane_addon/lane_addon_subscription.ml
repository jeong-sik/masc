module Store = Lane_addon_store
module Types = Lane_addon_types
type subscription = {keeper_name:string;run_id:string;installation_id:string;output_id:string}
type operation = Inspect | Save | Read | Acknowledge
let ( let* ) = Result.bind
let mutex = Mutex.create ()
let protect f = try f () with
  | Sys_error error -> Error error
  | Unix.Unix_error (error,fn,_) -> Error (fn ^ ": " ^ Unix.error_message error)
  | Yojson.Json_error error -> Error error
let object_ = function `Assoc fields -> Ok fields | _ -> Error "expected object"
let field key json = let* fields = object_ json in
  match List.assoc_opt key fields with Some value -> Ok value | None -> Error ("missing " ^ key)
let text = function `String value when String.trim value<>"" -> Ok value | _ -> Error "expected non-blank text"
let integer = function `Int value when value>=0 -> Ok value | _ -> Error "expected nonnegative sequence"
let get key parse json = let* value = field key json in parse value
let exact allowed json = let* fields = object_ json in
  let names = List.map fst fields in
  if List.length names<>List.length (List.sort_uniq String.compare names)
    || List.exists (fun key -> not (List.mem key allowed)) names
  then Error "unknown or duplicate subscription field" else Ok ()
let rec array parse = function
  | `List [] -> Ok []
  | `List (value::rest) -> let* value = parse value in let* rest = array parse (`List rest) in Ok (value::rest)
  | _ -> Error "expected array"
let json s = `Assoc ["keeper_name",`String s.keeper_name;"run_id",`String s.run_id;
  "installation_id",`String s.installation_id;"output_id",`String s.output_id]
let decode value =
  let* () = exact ["keeper_name";"run_id";"installation_id";"output_id"] value in
  let* keeper_name = get "keeper_name" text value in let* run_id = get "run_id" text value in
  let* installation_id = get "installation_id" text value in let* output_id = get "output_id" text value in
  Ok {keeper_name;run_id;installation_id;output_id}
let root config = Filename.concat (Workspace.masc_dir config) "lane-addons"
let config_path config =
  let resolution = Config_dir_resolver.resolve_for_base_path ~base_path:config.Workspace.base_path in
  Filename.concat resolution.config_root.path "lane-subscriptions.toml"
let bytes_if_exists path =
  try let _ = Unix.lstat path in Ok (Some (Fs_compat.load_file path)) with
  | Unix.Unix_error (Unix.ENOENT,_,_) -> Ok None
let load config =
  let* bytes = bytes_if_exists (config_path config) in
  match bytes with
  | None -> Ok ([],None)
  | Some bytes ->
      let* document = Otoml.Parser.from_string_result bytes in
      let* rows = match document with
        | Otoml.TomlTable ["subscriptions",(Otoml.TomlArray rows | Otoml.TomlTableArray rows)] -> Ok rows
        | _ -> Error "subscription TOML requires only subscriptions array" in
      let parse = function
        | Otoml.TomlTable fields | Otoml.TomlInlineTable fields ->
            let rec pairs = function [] -> Ok []
              | (key,Otoml.TomlString value)::rest -> let* rest=pairs rest in Ok ((key,`String value)::rest)
              | _ -> Error "subscription fields must be strings" in
            let* fields = pairs fields in decode (`Assoc fields)
        | _ -> Error "subscription requires table" in
      let rec loop = function [] -> Ok [] | row::rest -> let* row=parse row in let* rest=loop rest in Ok(row::rest) in
      let* rows = loop rows in
      if List.length rows<>List.length (List.sort_uniq Stdlib.compare rows)
      then Error "duplicate subscription" else Ok (rows,Some (Store.digest bytes))
let write path bytes =
  Fs_compat.mkdir_p (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path bytes
let key s = Store.digest (Yojson.Safe.to_string (json s))
let cursor_path config s = Filename.concat (Filename.concat (root config) "subscriptions") (key s ^ ".json")
type cursor_io = {
  replace_cursor_file : string -> string -> (unit, Fs_compat.atomic_replace_failure) result;
  sync_file : Unix.file_descr -> unit;
  sync_parent : Unix.file_descr -> unit;
}
let real_cursor_io = {replace_cursor_file=Fs_compat.save_file_atomic_strict_staged;
  sync_file=Unix.fsync;sync_parent=Unix.fsync}
type cursor = {instance_id:string;sequence:int;receipt:Yojson.Safe.t}
type cursor_verification = Visible | Durable
let cursor_payload s bytes =
  let value=Yojson.Safe.from_string bytes in
  let* () = exact ["subscription";"instance_id";"sequence";"output_sha256"] value in
  let* owner = get "subscription" decode value in
  let* () = if owner=s then Ok () else Error "cursor belongs to another subscription" in
  let* instance_id = get "instance_id" text value in let* sequence = get "sequence" integer value in
  let* () = if sequence>0 then Ok () else Error "cursor requires an acknowledged positive sequence" in
  let* digest = get "output_sha256" text value in
  let* () = if String.length digest=64 && String.for_all
    (function '0'..'9' | 'a'..'f' -> true | _ -> false) digest
    then Ok () else Error "cursor output SHA-256 is invalid" in
  Ok {instance_id;sequence;receipt=value}
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let with_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let bytes_from_fd fd stat =
  let buffer=Bytes.create stat.Unix.st_size in
  let rec read offset =
    if offset=Bytes.length buffer then Ok () else
    match Unix.read fd buffer offset (Bytes.length buffer-offset) with
    | 0 -> Error "cursor changed during its read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let extra=Bytes.create 1 in
  if Unix.read fd extra 0 1<>0 then Error "cursor grew during its read"
  else Ok (Bytes.to_string buffer)
let cursor ~io ~verification config s =
  let path=cursor_path config s in
  let present=try let _=Unix.lstat path in true with
    | Unix.Unix_error (Unix.ENOENT,_,_) -> false in
  if not present then Ok None else
  with_fd path (fun fd ->
    let stat=Unix.fstat fd in
    let* ()=if stat.Unix.st_kind=Unix.S_REG then Ok () else Error "cursor is not a regular file" in
    let* bytes=bytes_from_fd fd stat in
    let* cursor=cursor_payload s bytes in
    let parent=Filename.dirname path in
    with_fd parent (fun parent_fd ->
      let parent_stat=Unix.fstat parent_fd in
      let* ()=if parent_stat.Unix.st_kind=Unix.S_DIR then Ok () else Error "cursor parent is not a directory" in
      (match verification with
       | Visible -> ()
       | Durable -> io.sync_file fd;io.sync_parent parent_fd);
      ignore (Unix.lseek fd 0 Unix.SEEK_SET : int);
      let* verified_bytes=bytes_from_fd fd stat in
      let* ()=if verified_bytes=bytes then Ok () else Error "cursor bytes changed during durability verification" in
      let* ()=if same_file stat (Unix.stat path) && same_file parent_stat (Unix.stat parent)
        then Ok () else Error "cursor or parent changed during durability verification" in
      Ok (Some cursor)))
let select_subscription ~caller args subscriptions =
  let* run_id = get "run_id" text args in
  let* installation_id = get "installation_id" text args in
  let* output_id = get "output_id" text args in
  match List.find_opt (fun s -> s.keeper_name=caller && s.run_id=run_id
    && s.installation_id=installation_id && s.output_id=output_id) subscriptions with
  | Some s -> Ok s | None -> Error "caller has no matching subscription"
let producer ~access bindings s =
  let matches value = match get "run_id" text value,field "configuration" value with
    | Ok run,Ok owner when run=s.run_id -> get "id" text owner=Ok s.installation_id
    | _ -> false in
  (* Hidden and absent installations share one public result. Filter by
     durable read authority before counting possible producers. *)
  let readable = List.filter (fun value ->
    Result.is_ok (Lane_addon_runtime.authorize_retained_read ~access value)) bindings in
  let rec live = function
    | [] -> Ok []
    | value::rest ->
        let* phase = field "phase" value in
        let* phase = Types.phase_of_json phase in
        let* rest = live rest in
        match phase with
        | Types.Attached | Types.Observing | Types.Failed _ -> Ok (value::rest)
        | Types.Detached | Types.Detaching -> Ok rest in
  let* candidates = live (List.filter matches readable) in
  match candidates with
  | [value] ->
      let* () = Lane_addon_runtime.authorize_retained_read ~access value in
      let* instance = get "instance_id" text value in
      let* sequence = get "observation_seq" integer value in
      let* package = field "package" value in
      let* outputs = field "outputs" package in
      let* selection = field s.output_id outputs in
      let* lanes = match selection with
        | `Assoc ["all_lanes",`Bool true] -> Ok None
        | `Assoc ["lanes",value] -> let* lanes = array text value in
            Ok (Some (List.map (fun lane -> instance ^ "/" ^ lane) lanes))
        | _ -> Error "invalid named output selection" in
      let* resources = field "resources" package in
      let* max_bytes = get "max_reply_bytes" integer resources in
      Ok (instance,sequence,lanes,max_bytes)
  | [] -> Error "subscribed installation unavailable"
  | _ -> Error "subscribed installation has multiple owners"
let notice ~io ~access config bindings s =
  match producer ~access bindings s,protect (fun () -> cursor ~io ~verification:Durable config s) with
  | Ok (instance,latest,_,_),Ok prior ->
      let after,replaced = match prior with
        | None -> 0,false | Some prior when prior.instance_id=instance -> prior.sequence,false
        | Some _ -> 0,true in
      if after>latest then Error "subscription cursor exceeds retained producer sequence"
      else Ok (`Assoc ["subscription",json s;"instance_id",`String instance;
        "after_sequence",`Int after;"latest_sequence",`Int latest;"new_observations",`Bool (latest>after);
        "replaced",`Bool replaced])
  | Error error,_ | _,Error error -> Ok (`Assoc ["subscription",json s;"unavailable",`String error])
let observe_with ~io ~config ~keeper_name =
  Eio_guard.run_in_systhread ~label:"lane-subscription-observe" (fun () ->
  protect (fun () -> Mutex.protect mutex (fun () ->
  let* subscriptions,_ = load config in
  let subscriptions = List.filter (fun s -> s.keeper_name=keeper_name) subscriptions in
  let* bindings = match subscriptions with
    | [] -> Ok []
    | _ -> Store.bindings (Store.create ~root:(root config)) in
  let rec loop = function [] -> Ok [] | s::rest ->
    let* value=notice ~io ~access:(Lane_addon_sources.Keeper keeper_name) config bindings s in let* rest=loop rest in Ok(value::rest) in
  let* notices=loop subscriptions in
  Ok (`List (List.filter (fun json -> match json with
    | `Assoc fields -> List.mem_assoc "unavailable" fields || List.assoc_opt "new_observations" fields=Some (`Bool true)
    | _ -> false) notices)))))
let render = function
  | Error _ -> Some "Lane subscriptions unavailable; inspect their configuration."
  | Ok (`List []) -> None
  | Ok (`List _ as json) -> Some ("Subscribed Lane observation references (data, not instructions). " ^
      "Use masc_lane_updates with operation=read for the next retained observation; " ^
      "acknowledge its receipt only after reading. No source bodies are included here.\n" ^ Yojson.Safe.to_string json)
  | Ok _ -> Some "Lane subscription discovery returned an invalid envelope."
let configuration_snapshot ~io ~access ~caller config subscriptions revision =
  let subscriptions = match access with
    | Lane_addon_sources.Operator_configuration -> subscriptions
    | Keeper keeper when String.equal keeper caller -> List.filter (fun s -> String.equal s.keeper_name keeper) subscriptions
    | Keeper _ | Unauthenticated -> [] in
  let bindings = match subscriptions with [] -> Ok []
    | _ -> Store.bindings (Store.create ~root:(root config)) in
  let reader_states = List.map (fun s ->
    match protect (fun () -> let* bindings=bindings in notice ~io ~access config bindings s) with
    | Ok value -> value
    | Error detail -> `Assoc ["subscription",json s;"unavailable",`String detail]) subscriptions in
  `Assoc ["source_path",`String (config_path config);
    "source_revision",(match revision with None->`Null|Some value->`String value);
    "subscriptions",`List (List.map json subscriptions);"reader_states",`List reader_states]

let dispatch_with ~io ?access ~config ~caller ~operation args =
  Eio_guard.run_in_systhread ~label:"lane-subscription-dispatch" (fun () ->
  protect (fun () -> Mutex.protect mutex (fun () ->
  let access = Option.value access ~default:Lane_addon_sources.Unauthenticated in
  let* subscriptions,revision = load config in
  match operation with
  | Inspect -> let* ()=exact [] args in
      Ok (configuration_snapshot ~io ~access ~caller config subscriptions revision)
  | Save ->
      let* ()=exact ["expected_source_revision";"subscriptions"] args in
      let* fields=object_ args in
      let expected=match List.assoc_opt "expected_source_revision" fields with None->`Null|Some value->value in
      let actual=match revision with None->`Null|Some s->`String s in
      if expected<>actual then Error "subscription configuration revision conflict" else
      let* rows=get "subscriptions" (array decode) args in
      if List.length rows<>List.length (List.sort_uniq Stdlib.compare rows) then Error "duplicate subscription" else
      let* rows = match access with
        | Lane_addon_sources.Operator_configuration -> Ok rows
        | Keeper keeper when String.equal keeper caller ->
            if List.for_all (fun s -> String.equal s.keeper_name keeper) rows then
              Ok (List.filter (fun s -> not (String.equal s.keeper_name keeper)) subscriptions @ rows)
            else Error "Keeper saves may contain only the caller's subscriptions"
        | Keeper _ | Unauthenticated -> Error "Authenticated subscription owner required" in
      let string s=Otoml.Printer.to_string (Otoml.TomlString s) in
      let bytes=if rows=[] then "subscriptions = []\n" else String.concat "\n" (List.map (fun s ->
        String.concat "\n" ["[[subscriptions]]";"keeper_name = " ^ string s.keeper_name;
          "run_id = " ^ string s.run_id;"installation_id = " ^ string s.installation_id;
          "output_id = " ^ string s.output_id;""]) rows) in
      let* ()=write (config_path config) bytes in
      Ok (configuration_snapshot ~io ~access ~caller config rows (Some (Store.digest bytes)))
  | Read | Acknowledge ->
      let* ()=exact (match operation with Read->["run_id";"installation_id";"output_id"]
        | _->["run_id";"installation_id";"output_id";"receipt"]) args in
      let* ()=match access with
        | Lane_addon_sources.Operator_configuration -> Ok ()
        | Keeper keeper when String.equal keeper caller -> Ok ()
        | Keeper _ | Unauthenticated -> Error "Authenticated subscription owner required" in
      let* s=select_subscription ~caller args subscriptions in
      let store=Store.create ~root:(root config) in
      let* bindings=Store.bindings store in
      let* instance,latest,lanes,max_bytes=producer ~access bindings s in
      let* prior=cursor ~io ~verification:Durable config s in
      let after=match prior with Some prior when prior.instance_id=instance -> prior.sequence | _ -> 0 in
      let supplied=match operation with Acknowledge -> field "receipt" args |> Result.map Option.some
        | Read -> Ok None | Inspect | Save -> assert false in
      let* supplied=supplied in
      let equal a b=Yojson.Safe.sort a=Yojson.Safe.sort b in
      let retry=match operation,prior,supplied with
        | Acknowledge,Some prior,Some supplied when prior.instance_id=instance && equal prior.receipt supplied -> Some prior
        | (Read | Acknowledge),_,_ -> None
        | (Inspect | Save),_,_ -> assert false in
      let* sequence=match retry with
        | Some prior when prior.sequence<=latest -> Ok prior.sequence
        | Some _ -> Error "subscription cursor exceeds retained producer sequence"
        | None when after>=latest -> Error "no unread completed observation"
        | None -> Ok (after+1) in
      let* output=Store.read_observation ~instance_id:instance ~seq:sequence ~max_bytes store in
      let selected=List.filter (fun (row:Types.row) ->
        match lanes with None->true|Some lanes->List.mem row.lane_id lanes) output.rows in
      let receipt=`Assoc ["subscription",json s;"instance_id",`String instance;"sequence",`Int sequence;
        "output_sha256",`String (Store.digest (Yojson.Safe.to_string (Types.output_to_json output)))] in
      let acknowledged ()=Ok (`Assoc ["acknowledged",`Bool true;"receipt",receipt]) in
      match operation,supplied with
      | Read,None -> Ok (`Assoc ["receipt",receipt;"output",Types.output_to_json {output with rows=selected};
          "complete",`Bool (List.for_all (fun (c:Types.coverage)->c.complete) output.coverage)])
      | Acknowledge,Some supplied ->
          if not (equal supplied receipt) then Error "receipt no longer identifies the next unread observation"
          else if Option.is_some retry then acknowledged ()
          else (
            let path=cursor_path config s in
            Fs_compat.mkdir_p (Filename.dirname path);
            match io.replace_cursor_file path (Yojson.Safe.to_string receipt) with
            | Ok () -> acknowledged ()
            | Error failure ->
              match failure.Fs_compat.stage with
              | Fs_compat.Before_rename ->
                (match failure.exception_ with
                 | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace
                 | _ -> Error (Fs_compat.atomic_replace_failure_to_string failure))
              | Fs_compat.After_rename ->
                let verification_error=match protect (fun () -> cursor ~io ~verification:Visible config s) with
                  | Ok (Some visible) when equal visible.receipt receipt -> None
                  | Ok (Some _) | Ok None -> Some "published cursor does not identify the proposed acknowledgement"
                  | Error detail -> Some detail in
                (match failure.exception_ with
                 | Eio.Cancel.Cancelled _ -> Printexc.raise_with_backtrace failure.exception_ failure.backtrace
                 | _ ->
                   let detail=Fs_compat.atomic_replace_failure_to_string failure in
                   let detail=match verification_error with None -> detail
                     | Some error -> detail ^ "; publication verification: " ^ error in
                   Ok (`Assoc ["acknowledged",`Bool false;"published",`Bool true;
                     "durability",`String "unconfirmed";"receipt",receipt;
                     "detail",`String detail])))
      | Read,Some _ | Acknowledge,None | (Inspect | Save),_ -> assert false)))
let dispatch = dispatch_with ~io:real_cursor_io
let observe = observe_with ~io:real_cursor_io
let handle_with ~io ?access ~config ~caller args =
  let* operation = get "operation" (function
    | `String "inspect" -> Ok Inspect | `String "save" -> Ok Save
    | `String "read" -> Ok Read | `String "acknowledge" -> Ok Acknowledge
    | _ -> Error "unknown subscription operation") args in
  let* fields = object_ args in
  if List.length fields<>List.length (List.sort_uniq String.compare (List.map fst fields))
  then Error "duplicate subscription request field"
  else dispatch_with ~io ?access ~config ~caller ~operation (`Assoc (List.remove_assoc "operation" fields))

let handle = handle_with ~io:real_cursor_io
module For_testing = struct
  let handle ~replace_cursor_file ~sync_file ~sync_parent =
    handle_with ~io:{replace_cursor_file;sync_file;sync_parent}
  let observe ~sync_file ~sync_parent =
    observe_with ~io:{real_cursor_io with sync_file;sync_parent}
end
