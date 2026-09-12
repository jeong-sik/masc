let ledger_filename = "articles.jsonl"

let ledger_path ~base_path =
  Filename.concat
    (Config_dir_resolver.constitution_dir ~base_path)
    ledger_filename

type append_error =
  | Directory_unavailable of {
      path : string;
      detail : string;
    }
  | Write_failed of {
      path : string;
      detail : string;
    }

let append_error_to_string = function
  | Directory_unavailable { path; detail } ->
    Printf.sprintf "constitution directory %s is unavailable: %s" path detail
  | Write_failed { path; detail } ->
    Printf.sprintf "constitution ledger %s could not be appended: %s" path
      detail

let append ~base_path entry =
  let dir = Config_dir_resolver.constitution_dir ~base_path in
  let path = ledger_path ~base_path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error (Directory_unavailable { path = dir; detail = Printexc.to_string exn })
  | () -> (
    match
      Fs_compat.append_jsonl path (World_constitution_wire.entry_to_json entry)
    with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | exception exn ->
      Error (Write_failed { path; detail = Printexc.to_string exn })
    | () -> Ok ())

type rejected_line = {
  line_number : int;
  detail : string;
}

type ledger = {
  articles : World_constitution_types.t list;
  rejected : rejected_line list;
}

type read_error =
  | Unreadable of {
      path : string;
      detail : string;
    }

let read_error_to_string = function
  | Unreadable { path; detail } ->
    Printf.sprintf "constitution ledger %s could not be read: %s" path detail

let same_id id (article : World_constitution_types.t) =
  World_constitution_types.Article_id.equal article.id id

(* Folding keeps the order a world wrote its norms in. Re-adding an article
   that is still held replaces it in place, because that is an edit; re-adding
   one that was removed puts it at the end, because the world changed its mind
   and that is when it did. *)
let apply held = function
  | World_constitution_types.Added article ->
    if List.exists (same_id article.id) held then
      List.map
        (fun existing -> if same_id article.id existing then article else existing)
        held
    else held @ [ article ]
  | World_constitution_types.Removed { id; _ } ->
    List.filter (fun existing -> not (same_id id existing)) held

let parse contents =
  let rec scan line_number held rejected = function
    | [] -> { articles = held; rejected = List.rev rejected }
    | line :: rest ->
      if String.equal (String.trim line) "" then
        scan (line_number + 1) held rejected rest
      else (
        let reject detail =
          scan (line_number + 1) held ({ line_number; detail } :: rejected) rest
        in
        match Yojson.Safe.from_string line with
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn -> reject (Printexc.to_string exn)
        | json -> (
          match World_constitution_wire.entry_of_json json with
          | Error error ->
            reject (World_constitution_wire.decode_error_to_string error)
          | Ok entry -> scan (line_number + 1) (apply held entry) rejected rest))
  in
  scan 1 [] [] (String.split_on_char '\n' contents)

let load ~base_path =
  let path = ledger_path ~base_path in
  match Fs_compat.load_file_opt path with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Unreadable { path; detail = Printexc.to_string exn })
  | None -> Ok { articles = []; rejected = [] }
  | Some contents -> Ok (parse contents)
