module H = Keeper_librarian_unread
open Result.Syntax
let path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ ".librarian-unread.json")

let decode = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["schema_version";"unread_messages"] ->
    (match List.assoc "schema_version" fields with
     | `Int 1 -> H.list_of_json (List.assoc "unread_messages" fields)
     | _ -> Error "unsupported unread ledger schema")
  | _ -> Error "unexpected, duplicate or missing unread ledger fields"

let io file f =
  try f () with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | Sys_error detail -> Error (file ^ ": " ^ detail)
  | Eio.Io _ as ex -> Error (file ^ ": " ^ Format.asprintf "%a" Eio.Exn.pp ex)
  | Unix.Unix_error (code, fn, arg) ->
    Error (Printf.sprintf "%s: %s(%s): %s" file fn arg (Unix.error_message code))

let read ~keepers_dir ~keeper_id =
  let file = path ~keepers_dir ~keeper_id in
  io file (fun () -> match Fs_compat.load_file_opt file with
    | None -> Ok []
    | Some raw ->
      (match Yojson.Safe.from_string raw with
       | json -> decode json |> Result.map_error (fun detail -> file ^ ": " ^ detail)
       | exception Yojson.Json_error detail -> Error (file ^ ": " ^ detail)))

let archive ~keepers_dir ~keeper_id added =
  let file = path ~keepers_dir ~keeper_id in
  let* previous = read ~keepers_dir ~keeper_id in
  let* merged = H.merge previous added |> Result.map_error (fun detail -> file ^ ": " ^ detail) in
  if previous = merged then
    (match merged with
     | [] -> Ok []
     | _ :: _ -> io file (fun () ->
         let* () = Fs_compat.sync_file_and_parent_strict file in Ok merged))
  else
  io file (fun () ->
    let* () = Fs_compat.save_file_atomic_strict file
      (Yojson.Safe.to_string (`Assoc ["schema_version", `Int 1;
        "unread_messages", H.list_to_json merged])) in
    Ok merged)
