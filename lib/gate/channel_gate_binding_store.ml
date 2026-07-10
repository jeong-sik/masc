type binding = {
  channel_id : string;
  keeper_name : string;
}

type guild_id_field =
  | Omit
  | Include_empty
  | Include_event_value

type audit_event = {
  timestamp : string;
  action : string;
  guild_id : string option;
  channel_id : string;
  keeper_name : string;
  actor_id : string;
  actor_name : string;
  previous_keeper : string;
}

type t = {
  binding_store_path : unit -> string;
  binding_store_read_path : unit -> string;
  binding_audit_path : unit -> string;
  binding_audit_read_path : unit -> string;
  guild_id_field : guild_id_field;
}

let create ~binding_store_path ~binding_store_read_path ~binding_audit_path
    ~binding_audit_read_path ~guild_id_field =
  {
    binding_store_path;
    binding_store_read_path;
    binding_audit_path;
    binding_audit_read_path;
    guild_id_field;
  }

let unix_error_message path fn arg code =
  let callsite =
    if String.equal arg "" then fn else Printf.sprintf "%s(%s)" fn arg
  in
  Printf.sprintf "%s: %s failed: %s" path callsite (Unix.error_message code)

let read_json_file_result path =
  match
    try Ok (Unix.openfile path [ Unix.O_RDONLY ] 0) with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> Error `Missing
    | Unix.Unix_error (code, fn, arg) ->
      Error (`Message (unix_error_message path fn arg code))
  with
  | Error `Missing -> Ok None
  | Error (`Message msg) -> Error msg
  | Ok fd ->
    let ic = Unix.in_channel_of_descr fd in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        try Ok (Some (Yojson.Safe.from_channel ic)) with
        | Yojson.Json_error msg ->
          Error (Printf.sprintf "%s: invalid JSON: %s" path msg)
        | Sys_error msg -> Error (Printf.sprintf "%s: %s" path msg)
        | Unix.Unix_error (code, fn, arg) ->
          Error (unix_error_message path fn arg code))

let read_json_file_opt path =
  match read_json_file_result path with
  | Ok json -> json
  | Error _ -> None

let normalize_bindings_json (json : Yojson.Safe.t) : binding list =
  match json with
  | `Assoc items ->
      items
      |> List.filter_map (fun (raw_channel_id, raw_keeper_name) ->
             let channel_id = String.trim raw_channel_id in
             let keeper_name =
               match raw_keeper_name with
               | `String value -> String.trim value
               | _ -> ""
             in
             if channel_id = "" || keeper_name = "" then None
             else Some ({ channel_id; keeper_name } : binding))
      |> List.sort (fun (a : binding) (b : binding) ->
             String.compare a.channel_id b.channel_id)
  | _ -> []

let read_bindings_result store : (binding list, string) result =
  let path = store.binding_store_read_path () in
  match read_json_file_result path with
  | Error msg -> Error msg
  | Ok None -> Ok []
  | Ok (Some (`Assoc _ as json)) -> Ok (normalize_bindings_json json)
  | Ok (Some _) ->
    Error
      (Printf.sprintf
         "%s: expected JSON object mapping channel ids to keeper names" path)

let read_bindings store : binding list =
  match read_bindings_result store with
  | Ok bindings -> bindings
  | Error _ -> []

let binding_json (binding : binding) =
  `Assoc
    [
      ("channel_id", `String binding.channel_id);
      ("keeper_name", `String binding.keeper_name);
    ]

(* Durable atomic write delegated to the Fs_compat durability SSOT:
   tmp -> fsync(tmp) -> rename -> best-effort fsync(parent dir), the same
   primitive board/event-queue/Memory-OS persistence use. A local hand-rolled
   tmp+rename here (as before) skips both fsyncs, so a crash between rename
   and the kernel's dirty-page flush can leave the binding file truncated
   even though [append_audit_event] already fsynced an audit entry claiming
   the change landed. Mapping [Error] to [Sys_error] preserves this
   function's existing raise-on-failure contract, which [bind]/[unbind] in
   the 3 caller modules already catch via [try ... with Sys_error _ -> ...]. *)
let save_bindings store (bindings : binding list) =
  let path = store.binding_store_path () in
  let normalized =
    bindings
    |> List.sort (fun (a : binding) (b : binding) ->
           String.compare a.channel_id b.channel_id)
    |> List.fold_left
         (fun acc (binding : binding) ->
           (binding.channel_id, `String binding.keeper_name) :: acc)
         []
    |> List.rev
    |> fun items -> `Assoc items
  in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let content = Yojson.Safe.pretty_to_string normalized ^ "\n" in
  match Fs_compat.save_file_atomic path content with
  | Ok () -> ()
  | Error msg -> raise (Sys_error msg)

let guild_id_items store event =
  match store.guild_id_field with
  | Omit -> []
  | Include_empty -> [ ("guild_id", `String "") ]
  | Include_event_value ->
      let guild_id =
        match event.guild_id with
        | Some value -> value
        | None -> ""
      in
      [ ("guild_id", `String guild_id) ]

let audit_event_json store event =
  `Assoc
    ([
       ("timestamp", `String event.timestamp);
       ("action", `String event.action);
     ]
    @ guild_id_items store event
    @ [
        ("channel_id", `String event.channel_id);
        ("keeper_name", `String event.keeper_name);
        ("actor_id", `String event.actor_id);
        ("actor_name", `String event.actor_name);
        ("previous_keeper", `String event.previous_keeper);
      ])

let append_audit_event store event =
  let path = store.binding_audit_path () in
  let dir = Filename.dirname path in
  Fs_compat.mkdir_p dir;
  let oc =
    open_out_gen [ Open_creat; Open_wronly; Open_append; Open_binary ] 0o644 path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc (Yojson.Safe.to_string (audit_event_json store event));
      output_char oc '\n';
      flush oc;
      Unix.fsync (Unix.descr_of_out_channel oc))

let rec drop_left n xs =
  if n <= 0 then xs
  else
    match xs with
    | [] -> []
    | _ :: tl -> drop_left (n - 1) tl

let read_recent_audit store ~limit =
  let path = store.binding_audit_read_path () in
  if limit <= 0 || not (Sys.file_exists path) then
    []
  else
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let rec loop acc =
          match input_line ic with
          | line -> loop (line :: acc)
          | exception End_of_file -> acc
        in
        loop []
        |> List.filter_map (fun line ->
               let trimmed = String.trim line in
               if trimmed = "" then None
               else
                 try Some (Yojson.Safe.from_string trimmed) with
                 | Yojson.Json_error _ -> None)
        |> List.rev
        |> fun rows ->
        let total = List.length rows in
        if total <= limit then List.rev rows
        else rows |> drop_left (total - limit) |> List.rev)
