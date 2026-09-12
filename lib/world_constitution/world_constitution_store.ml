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

let append ~base_path article =
  let dir = Config_dir_resolver.constitution_dir ~base_path in
  let path = ledger_path ~base_path in
  match Fs_compat.mkdir_p dir with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    Error (Directory_unavailable { path = dir; detail = Printexc.to_string exn })
  | () -> (
    match Fs_compat.append_jsonl path (World_constitution_wire.to_json article) with
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

let find_article id entries =
  Option.map snd
    (List.find_opt (fun (candidate, _) -> String.equal candidate id) entries)

let replace_article id article entries =
  let without =
    List.filter (fun (candidate, _) -> not (String.equal candidate id)) entries
  in
  (id, article) :: without

(* One line per move, so a later line for the same id is that article's newer
   state. Order of first appearance is the order a world wrote its norms, and
   the prompt slot renders them in that order rather than re-sorting by a
   timestamp the ledger does not have to carry. *)
let parse contents =
  let rec scan line_number order latest rejected = function
    | [] ->
      let articles =
        List.filter_map
          (fun id -> find_article id latest)
          (List.rev order)
      in
      { articles; rejected = List.rev rejected }
    | line :: rest ->
      if String.equal (String.trim line) "" then
        scan (line_number + 1) order latest rejected rest
      else (
        let reject detail =
          scan (line_number + 1) order latest
            ({ line_number; detail } :: rejected)
            rest
        in
        match Yojson.Safe.from_string line with
        | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
        | exception exn -> reject (Printexc.to_string exn)
        | json -> (
          match World_constitution_wire.of_json json with
          | Error error ->
            reject (World_constitution_wire.decode_error_to_string error)
          | Ok article ->
            let id = World_constitution_types.Article_id.to_string article.id in
            let order = if Option.is_some (find_article id latest) then order else id :: order in
            scan (line_number + 1) order
              (replace_article id article latest)
              rejected rest))
  in
  scan 1 [] [] [] (String.split_on_char '\n' contents)

let load ~base_path =
  let path = ledger_path ~base_path in
  match Fs_compat.load_file_opt path with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn -> Error (Unreadable { path; detail = Printexc.to_string exn })
  | None -> Ok { articles = []; rejected = [] }
  | Some contents -> Ok (parse contents)

let in_force ledger =
  List.filter
    (fun (article : World_constitution_types.t) ->
      match article.state with
      | Ratified _ -> true
      | Proposed _ | Superseded _ | Repealed _ -> false)
    ledger.articles
