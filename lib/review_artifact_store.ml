(** Shared append-only artifact/index helpers for review-only stores. *)

let component_hash raw =
  Digestif.SHA256.(digest_string raw |> to_hex) |> fun hex -> String.sub hex 0 16
;;

let component_prefix raw =
  let safe =
    Workspace_utils_backend_setup.sanitize_namespace_segment raw
    |> String.lowercase_ascii
  in
  let safe =
    match safe with
    | "default" when String.equal (String.trim raw) "" -> "untitled"
    | other -> other
  in
  if String.length safe > 48 then String.sub safe 0 48 else safe
;;

let component ~display_id ~identity_key =
  component_prefix display_id ^ "-" ^ component_hash identity_key
;;

let write_file path content =
  Fs_compat.mkdir_p (Filename.dirname path);
  match Fs_compat.save_file_atomic path content with
  | Ok () -> Ok ()
  | Error msg -> Error (Printf.sprintf "%s: %s" path msg)
;;

let append_index index_path event =
  match Keeper_types_support.append_jsonl_line_result index_path event with
  | Ok () -> Ok ()
  | Error msg -> Error (Printf.sprintf "%s: %s" index_path msg)
;;

let ( let* ) = Result.bind

let write_artifacts ~index_path ~artifacts ~index_event =
  let rec loop = function
    | [] -> append_index index_path index_event
    | (path, content) :: rest ->
      let* () = write_file path content in
      loop rest
  in
  loop artifacts
;;

let artifacts_unchanged artifacts =
  List.for_all
    (fun (path, expected) ->
       match Fs_compat.load_file_opt path with
       | Some content -> String.equal content expected
       | None -> false)
    artifacts
;;

let index_contains ~index_path ~matches =
  if not (Fs_compat.file_exists index_path)
  then Ok false
  else
    try
      Ok (Fs_compat.load_jsonl index_path |> List.exists matches)
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;

let write_if_changed ~index_path ~artifacts ~index_event ~matches =
  let* indexed = index_contains ~index_path ~matches in
  if artifacts_unchanged artifacts && indexed
  then Ok false
  else (
    let* () = write_artifacts ~index_path ~artifacts ~index_event in
    Ok true)
;;

let take n xs =
  let rec loop acc remaining = function
    | _ when remaining <= 0 -> List.rev acc
    | [] -> List.rev acc
    | x :: rest -> loop (x :: acc) (remaining - 1) rest
  in
  loop [] n xs
;;

let latest_unique ~identity_key summaries =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun summary ->
       let key = identity_key summary in
       if Hashtbl.mem seen key
       then false
       else (
         Hashtbl.add seen key ();
         true))
    summaries
;;

let list_index ~index_path ~limit ~of_json ~identity_key =
  let limit = max 0 limit in
  try
    let items =
      if Fs_compat.file_exists index_path
      then
        Fs_compat.load_jsonl index_path
        |> List.rev
        |> List.filter_map of_json
        |> latest_unique ~identity_key
      else []
    in
    let total = List.length items in
    Ok (total, take limit items)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Error (Printf.sprintf "%s: %s" index_path (Printexc.to_string exn))
;;
