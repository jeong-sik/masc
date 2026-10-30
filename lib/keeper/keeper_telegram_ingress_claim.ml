type error = Invalid_claim | Conflicting_claim | Storage_failed of string
let error_to_string = function
  | Invalid_claim -> "Telegram prepared claim is malformed"
  | Conflicting_claim -> "Telegram update already belongs to a different prepared request"
  | Storage_failed detail -> "Telegram prepared claim storage failed: " ^ detail
open Result.Syntax
let path ~root ~operation_id =
  Filename.concat root (Agent_core_sha256.(to_hex (digest_string operation_id)) ^ ".json")
let with_claim ~root ~operation_id body =
  let* () = if String.trim operation_id = "" then Error Invalid_claim else Ok () in
  let* () = match Fs_compat.mkdir_p root with
    | () -> Ok ()
    | exception Sys_error detail -> Error (Storage_failed detail)
    | exception Unix.Unix_error (code,fn,arg) ->
      Error (Storage_failed (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))) in
  let path = path ~root ~operation_id in
  match File_lock_eio.with_durable_lock_observed ~lock_path:(Filename.concat root ".claim.lock") (fun () -> body path) with
  | Lock_not_acquired error -> Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))
  | Body_completed {value;release_error=None} -> value
  | Body_completed {value=_;release_error=Some error} ->
    Error (Storage_failed (File_lock_eio.durable_lock_error_to_string error))
let decode body =
  let* () = if String_util.is_valid_utf8 body then Ok () else Error Invalid_claim in
  let* json = match Yojson.Safe.from_string body with
    | value -> Ok value
    | exception Yojson.Json_error _ -> Error Invalid_claim in
  match json with
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["identity";"operation_id";"schema_version"]
      && List.assoc_opt "schema_version" fields = Some (`Int 1)
      && (match List.assoc_opt "operation_id" fields with Some (`String id) -> String.trim id <> "" | _ -> false)
      && (match List.assoc_opt "identity" fields with Some (`Assoc _) -> true | _ -> false) ->
    Keeper_chat_operation.canonical_json_string json |> Result.map_error (fun _ -> Invalid_claim)
  | _ -> Error Invalid_claim
let read path =
  match Fs_compat.load_file_opt path with
  | None -> Ok None
  | Some body -> decode body |> Result.map Option.some
  | exception Sys_error detail -> Error (Storage_failed detail)
let ensure_with_io ~write ~sync ~root ~operation_id ~identity =
  let* () = match identity with `Assoc _ -> Ok () | _ -> Error Invalid_claim in
  let* expected = Keeper_chat_operation.canonical_json_string
    (`Assoc ["schema_version",`Int 1;"operation_id",`String operation_id;"identity",identity])
    |> Result.map_error (fun _ -> Invalid_claim) in
  let* checked = decode expected in
  let* () = if checked = expected then Ok () else Error Invalid_claim in
  with_claim ~root ~operation_id (fun path ->
    let* previous = read path in
    match previous with
    | None -> write path expected |> Result.map_error (fun detail -> Storage_failed detail)
    | Some previous when previous = expected ->
      sync path |> Result.map_error (fun detail -> Storage_failed detail)
    | Some _ -> Error Conflicting_claim)
let ensure ~root ~operation_id ~identity =
  ensure_with_io ~write:Fs_compat.save_file_atomic_strict ~sync:Fs_compat.sync_file_and_parent_strict
    ~root ~operation_id ~identity
let ensure_unclaimed ~root ~operation_id =
  with_claim ~root ~operation_id (fun path ->
    let* previous = read path in
    match previous with None -> Ok () | Some _ -> Error Conflicting_claim)
module For_testing = struct let ensure_with_io = ensure_with_io end
