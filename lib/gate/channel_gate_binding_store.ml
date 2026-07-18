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
  mutation_lock : Cross_context_mutex.t;
}

let create ~binding_store_path ~binding_store_read_path ~binding_audit_path
    ~binding_audit_read_path ~guild_id_field =
  {
    binding_store_path;
    binding_store_read_path;
    binding_audit_path;
    binding_audit_read_path;
    guild_id_field;
    mutation_lock = Cross_context_mutex.create ();
  }

type binding_decode_error =
  | Expected_object
  | Blank_channel_id
  | Non_canonical_channel_id of string
  | Keeper_name_not_string of string
  | Blank_keeper_name of string
  | Non_canonical_keeper_name of {
      channel_id : string;
      keeper_name : string;
    }
  | Duplicate_channel_id of string

type binding_store_error =
  | Binding_store_io_failed of string
  | Binding_store_decode_failed of {
      path : string;
      error : binding_decode_error;
    }

type audit_append_error =
  | Audit_append_failed of Fs_compat.private_jsonl_append_error
  | Audit_io_failed of string

type mutation_error =
  | Mutation_rejected of string
  | Mutation_read_failed of binding_store_error
  | Mutation_write_failed of string
  | Mutation_audit_failed of {
      audit_error : audit_append_error;
      binding_rollback_error : string option;
    }

let binding_decode_error_to_string = function
  | Expected_object -> "expected a JSON object mapping channel ids to keeper names"
  | Blank_channel_id -> "channel id must not be blank"
  | Non_canonical_channel_id value ->
    Printf.sprintf "channel id must not contain surrounding whitespace: %S" value
  | Keeper_name_not_string channel_id ->
    Printf.sprintf "keeper name for channel %S must be a string" channel_id
  | Blank_keeper_name channel_id ->
    Printf.sprintf "keeper name for channel %S must not be blank" channel_id
  | Non_canonical_keeper_name { channel_id; keeper_name } ->
    Printf.sprintf
      "keeper name for channel %S must not contain surrounding whitespace: %S"
      channel_id
      keeper_name
  | Duplicate_channel_id channel_id ->
    Printf.sprintf "channel id %S must occur at most once" channel_id

let binding_store_error_to_string = function
  | Binding_store_io_failed detail -> detail
  | Binding_store_decode_failed { path; error } ->
    Printf.sprintf "%s: %s" path (binding_decode_error_to_string error)

let audit_append_error_to_string = function
  | Audit_append_failed error -> Fs_compat.private_jsonl_append_error_to_string error
  | Audit_io_failed detail -> detail

let mutation_error_to_string = function
  | Mutation_rejected detail -> detail
  | Mutation_read_failed error ->
    Printf.sprintf "binding store read failed: %s"
      (binding_store_error_to_string error)
  | Mutation_write_failed detail ->
    Printf.sprintf "binding store write failed: %s" detail
  | Mutation_audit_failed { audit_error; binding_rollback_error = None } ->
    Printf.sprintf
      "binding audit append failed; binding rollback succeeded: %s"
      (audit_append_error_to_string audit_error)
  | Mutation_audit_failed
      { audit_error; binding_rollback_error = Some rollback_error } ->
    Printf.sprintf
      "binding audit append failed: %s; binding rollback failed: %s"
      (audit_append_error_to_string audit_error)
      rollback_error

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

module String_set = Set.Make (String)

let normalize_bindings_json (json : Yojson.Safe.t) :
    (binding list, binding_decode_error) result =
  match json with
  | `Assoc items ->
    let rec decode seen acc = function
      | [] ->
        Ok
          (List.sort
             (fun (a : binding) (b : binding) ->
               String.compare a.channel_id b.channel_id)
             acc)
      | (raw_channel_id, raw_keeper_name) :: rest ->
        let channel_id = String.trim raw_channel_id in
        if String.equal channel_id "" then Error Blank_channel_id
        else if not (String.equal channel_id raw_channel_id) then
          Error (Non_canonical_channel_id raw_channel_id)
        else if String_set.mem channel_id seen then
          Error (Duplicate_channel_id channel_id)
        else
          (match raw_keeper_name with
           | `String raw_keeper_name ->
             let keeper_name = String.trim raw_keeper_name in
             if String.equal keeper_name "" then
               Error (Blank_keeper_name channel_id)
             else if not (String.equal keeper_name raw_keeper_name) then
               Error
                 (Non_canonical_keeper_name
                    { channel_id; keeper_name = raw_keeper_name })
             else
               decode
                 (String_set.add channel_id seen)
                 (({ channel_id; keeper_name } : binding) :: acc)
                 rest
           | _ -> Error (Keeper_name_not_string channel_id))
    in
    decode String_set.empty [] items
  | _ -> Error Expected_object

let read_bindings_result store : (binding list, binding_store_error) result =
  let path = store.binding_store_read_path () in
  match read_json_file_result path with
  | Error msg -> Error (Binding_store_io_failed msg)
  | Ok None -> Ok []
  | Ok (Some json) ->
    normalize_bindings_json json
    |> Result.map_error (fun error ->
         Binding_store_decode_failed { path; error })

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
   primitive board/event-queue/Memory-OS persistence use. The result-returning
   form is the authority for transactional callers; [save_bindings] preserves
   the older connector interface until those callers move to [mutate_bindings]. *)
let save_bindings_result store (bindings : binding list) =
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
  let content = Yojson.Safe.pretty_to_string normalized ^ "\n" in
  try
    Fs_compat.mkdir_p dir;
    Fs_compat.save_file_atomic path content
  with
  | Sys_error detail -> Error detail
  | Unix.Unix_error (code, fn, arg) ->
    Error (unix_error_message path fn arg code)

let save_bindings store bindings =
  match save_bindings_result store bindings with
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

let append_audit_event_result store event =
  let path = store.binding_audit_path () in
  let suffix = Yojson.Safe.to_string (audit_event_json store event) ^ "\n" in
  try
    Fs_compat.append_private_jsonl_durable_locked_result path suffix
    |> Result.map_error (fun error -> Audit_append_failed error)
  with
  | Sys_error detail -> Error (Audit_io_failed detail)
  | Unix.Unix_error (code, fn, arg) ->
    Error (Audit_io_failed (unix_error_message path fn arg code))

let append_audit_event store event =
  match append_audit_event_result store event with
  | Ok () -> ()
  | Error error -> raise (Sys_error (audit_append_error_to_string error))

let mutate_bindings store ~decide =
  Cross_context_mutex.with_durable_lock store.mutation_lock (fun () ->
    match read_bindings_result store with
    | Error error -> Error (Mutation_read_failed error)
    | Ok original_bindings ->
      (match decide original_bindings with
       | Error detail -> Error (Mutation_rejected detail)
       | Ok (updated_bindings, audit_event, committed_value) ->
         (match save_bindings_result store updated_bindings with
          | Error detail -> Error (Mutation_write_failed detail)
          | Ok () ->
            (match append_audit_event_result store audit_event with
             | Ok () -> Ok committed_value
             | Error audit_error ->
               let binding_rollback_error =
                 match save_bindings_result store original_bindings with
                 | Ok () -> None
                 | Error detail -> Some detail
               in
               Error
                 (Mutation_audit_failed
                    { audit_error; binding_rollback_error })))))

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
