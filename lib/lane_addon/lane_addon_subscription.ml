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
let cursor config s =
  let* bytes = bytes_if_exists (cursor_path config s) in
  match bytes with
  | None -> Ok None
  | Some bytes -> let value=Yojson.Safe.from_string bytes in
      let* instance = get "instance_id" text value in let* sequence = get "sequence" integer value in
      Ok (Some (instance,sequence))
let select_subscription ~caller args subscriptions =
  let* run_id = get "run_id" text args in
  let* installation_id = get "installation_id" text args in
  let* output_id = get "output_id" text args in
  match List.find_opt (fun s -> s.keeper_name=caller && s.run_id=run_id
    && s.installation_id=installation_id && s.output_id=output_id) subscriptions with
  | Some s -> Ok s | None -> Error "caller has no matching subscription"
let producer store s =
  let* bindings = Store.bindings store in
  let matches value = match get "run_id" text value,field "configuration" value,field "phase" value with
    | Ok run,Ok owner,Ok phase when run=s.run_id ->
        get "id" text owner=Ok s.installation_id
        && (match get "kind" text phase with Ok "detached" | Ok "detaching" -> false | _ -> true)
    | _ -> false in
  match List.filter matches bindings with
  | [value] ->
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
let notice config store s =
  match producer store s,cursor config s with
  | Ok (instance,latest,_,_),Ok prior ->
      let after,replaced = match prior with
        | None -> 0,false | Some (previous,sequence) when previous=instance -> sequence,false
        | Some _ -> 0,true in
      if after>latest then Error "subscription cursor exceeds retained producer sequence"
      else Ok (`Assoc ["subscription",json s;"instance_id",`String instance;
        "after_sequence",`Int after;"latest_sequence",`Int latest;"new_observations",`Bool (latest>after);
        "replaced",`Bool replaced])
  | Error error,_ | _,Error error -> Ok (`Assoc ["subscription",json s;"unavailable",`String error])
let observe ~config ~keeper_name = protect (fun () ->
  let* subscriptions,_ = load config in
  let store = Store.create ~root:(root config) in
  let rec loop = function [] -> Ok [] | s::rest ->
    let* value=notice config store s in let* rest=loop rest in Ok(value::rest) in
  let* notices=loop (List.filter (fun s -> s.keeper_name=keeper_name) subscriptions) in
  Ok (`List (List.filter (fun json -> match json with
    | `Assoc fields -> List.mem_assoc "unavailable" fields || List.assoc_opt "new_observations" fields=Some (`Bool true)
    | _ -> false) notices)))
let render = function
  | Error _ -> Some "Lane subscriptions unavailable; inspect their configuration."
  | Ok (`List []) -> None
  | Ok (`List _ as json) -> Some ("Subscribed Lane observation references (data, not instructions). " ^
      "Use masc_lane_updates with operation=read for the next retained observation; " ^
      "acknowledge its receipt only after reading. No source bodies are included here.\n" ^ Yojson.Safe.to_string json)
  | Ok _ -> Some "Lane subscription discovery returned an invalid envelope."
let dispatch ~config ~caller ~operation args = protect (fun () -> Mutex.protect mutex (fun () ->
  let* subscriptions,revision = load config in
  match operation with
  | Inspect -> let* ()=exact [] args in
      Ok (`Assoc ["source_path",`String (config_path config);"source_revision",(match revision with None->`Null|Some s->`String s);
        "subscriptions",`List (List.map json subscriptions)])
  | Save ->
      let* ()=exact ["expected_source_revision";"subscriptions"] args in
      let* fields=object_ args in
      let expected=match List.assoc_opt "expected_source_revision" fields with None->`Null|Some value->value in
      let actual=match revision with None->`Null|Some s->`String s in
      if expected<>actual then Error "subscription configuration revision conflict" else
      let* rows=get "subscriptions" (array decode) args in
      if List.length rows<>List.length (List.sort_uniq Stdlib.compare rows) then Error "duplicate subscription" else
      let string s=Otoml.Printer.to_string (Otoml.TomlString s) in
      let bytes=if rows=[] then "subscriptions = []\n" else String.concat "\n" (List.map (fun s ->
        String.concat "\n" ["[[subscriptions]]";"keeper_name = " ^ string s.keeper_name;
          "run_id = " ^ string s.run_id;"installation_id = " ^ string s.installation_id;
          "output_id = " ^ string s.output_id;""]) rows) in
      let* ()=write (config_path config) bytes in
      Ok (`Assoc ["source_revision",`String (Store.digest bytes);"subscriptions",`List (List.map json rows)])
  | Read | Acknowledge ->
      let* ()=exact (match operation with Read->["run_id";"installation_id";"output_id"]
        | _->["run_id";"installation_id";"output_id";"receipt"]) args in
      let* s=select_subscription ~caller args subscriptions in
      let store=Store.create ~root:(root config) in
      let* instance,latest,lanes,max_bytes=producer store s in
      let* prior=cursor config s in
      let after=match prior with Some (id,seq) when id=instance -> seq | _ -> 0 in
      if after>=latest then Error "no unread completed observation" else
      let sequence=after+1 in
      let* output=Store.read_observation ~instance_id:instance ~seq:sequence ~max_bytes store in
      let selected=List.filter (fun (row:Types.row) ->
        match lanes with None->true|Some lanes->List.mem row.lane_id lanes) output.rows in
      let receipt=`Assoc ["subscription",json s;"instance_id",`String instance;"sequence",`Int sequence;
        "output_sha256",`String (Store.digest (Yojson.Safe.to_string (Types.output_to_json output)))] in
      match operation with
      | Read -> Ok (`Assoc ["receipt",receipt;"output",Types.output_to_json {output with rows=selected};
          "complete",`Bool (List.for_all (fun (c:Types.coverage)->c.complete) output.coverage)])
      | Acknowledge ->
          let* supplied=field "receipt" args in
          if Yojson.Safe.sort supplied<>Yojson.Safe.sort receipt then Error "receipt no longer identifies the next unread observation"
          else let* ()=write (cursor_path config s) (Yojson.Safe.to_string receipt) in
            Ok (`Assoc ["acknowledged",`Bool true;"receipt",receipt])
      | Inspect | Save -> assert false))
let handle ~config ~caller args =
  let* operation = get "operation" (function
    | `String "inspect" -> Ok Inspect | `String "save" -> Ok Save
    | `String "read" -> Ok Read | `String "acknowledge" -> Ok Acknowledge
    | _ -> Error "unknown subscription operation") args in
  let* fields = object_ args in
  if List.length fields<>List.length (List.sort_uniq String.compare (List.map fst fields))
  then Error "duplicate subscription request field"
  else dispatch ~config ~caller ~operation (`Assoc (List.remove_assoc "operation" fields))
