type metadata = { title : string; revision : string; description : string option }
type entry =
  | Folder of string
  | Package of { manifest_path : string; metadata : metadata }
  | Issue of { path : string; message : string }
type t = { directory : string; parent : string option; entries : entry list }
let ( let* ) = Result.bind

let io f =
  try Ok (f ()) with
  | Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error)
  | Sys_error detail -> Error detail

let within ~base path =
  path = base || base = Filename.dir_sep
  || String.starts_with ~prefix:(base ^ Filename.dir_sep) path

let discover ~base_path ~directory ~load_package =
  let* base = io (fun () -> Unix.realpath base_path) in
  let requested = match directory with
    | None -> base
    | Some path -> if Filename.is_relative path then Filename.concat base path else path in
  let directory_error = "Directory must be a readable folder inside the workspace" in
  let* directory = io (fun () -> Unix.realpath requested)
    |> Result.map_error (fun _ -> directory_error) in
  if not (within ~base directory) then Error directory_error
  else
    let* names = io (fun () -> Sys.readdir directory |> Array.to_list |> List.sort String.compare) in
    let issue path message = Issue {path; message} in
    let canonical path =
      let* resolved = io (fun () -> Unix.realpath path) in
      if within ~base resolved then Ok resolved
      else Error "Entry points outside the workspace" in
    let inspect_manifest folder =
      let path = Filename.concat folder "lane.toml" in
      (* lstat distinguishes an absent manifest from a dangling manifest link. *)
      match (try Ok (Some (Unix.lstat path)) with
        | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
        | Unix.Unix_error (error, operation, _) -> Error (operation ^ ": " ^ Unix.error_message error)) with
      | Ok None -> None
      | Error message -> Some (issue path message)
      | Ok (Some _) ->
          Some (match canonical path with
            | Error message -> issue path message
            | Ok manifest_path ->
                match io (fun () -> Unix.stat manifest_path) with
                | Error message -> issue path message
                | Ok stat when stat.Unix.st_kind <> Unix.S_REG -> issue path "Manifest must be a regular file"
                | Ok _ -> match load_package ~path:manifest_path with
                  | Ok metadata -> Package {manifest_path; metadata}
                  | Error message -> issue path message) in
    let children = List.concat_map (fun name ->
      if name = "lane.toml" then [] else
      let path = Filename.concat directory name in
      match canonical path with
      | Error message -> [issue path message]
      | Ok resolved ->
          match io (fun () -> Unix.stat resolved) with
          | Error message -> [issue path message]
          | Ok stat when stat.Unix.st_kind = Unix.S_DIR ->
              (match inspect_manifest resolved with
               | None -> [Folder resolved]
               | Some (Package _ as package) -> [package]
               | Some (Issue _ as error) -> [Folder resolved; error]
               | Some (Folder _) -> [Folder resolved])
          | Ok _ -> []) names in
    let entries = Option.to_list (inspect_manifest directory) @ children in
    Ok {directory; parent=(if directory=base then None else Some (Filename.dirname directory)); entries}

let to_json snapshot =
  let nullable = function None -> `Null | Some s -> `String s in
  let entry = function
    | Folder path -> `Assoc ["kind",`String "folder"; "path",`String path]
    | Issue {path;message} -> `Assoc ["kind",`String "issue"; "path",`String path; "message",`String message]
    | Package {manifest_path;metadata} -> `Assoc ["kind",`String "package";
        "manifest_path",`String manifest_path; "title",`String metadata.title;
        "revision",`String metadata.revision; "description",nullable metadata.description] in
  `Assoc ["directory",`String snapshot.directory; "parent",nullable snapshot.parent;
          "entries",`List (List.map entry snapshot.entries)]

let of_json json =
  let field name = function
    | `Assoc fields -> (match List.assoc_opt name fields with Some x -> Ok x | None -> Error ("missing " ^ name))
    | _ -> Error "expected catalog object" in
  let text name json = let* value = field name json in match value with
    | `String s when String.trim s <> "" -> Ok s | _ -> Error ("expected nonblank " ^ name) in
  let optional name json = let* value = field name json in match value with
    | `Null -> Ok None | `String s -> Ok (Some s) | _ -> Error ("expected string or null: " ^ name) in
  let entry json =
    let* kind = text "kind" json in
    match kind with
    | "folder" -> let* path = text "path" json in Ok (Folder path)
    | "issue" -> let* path = text "path" json in let* message = text "message" json in Ok (Issue {path;message})
    | "package" -> let* manifest_path = text "manifest_path" json in
        let* title = text "title" json in let* revision = text "revision" json in
        let* description = optional "description" json in
        Ok (Package {manifest_path;metadata={title;revision;description}})
    | _ -> Error "unknown catalog entry kind" in
  let* directory = text "directory" json in
  let* parent = optional "parent" json in
  let* () = match parent with
    | Some path when String.trim path="" -> Error "parent must be nonblank or null"
    | None | Some _ -> Ok () in
  let* raw = field "entries" json in
  let rec parse = function
    | [] -> Ok []
    | first::rest -> let* first = entry first in let* rest = parse rest in Ok (first::rest) in
  let* entries = match raw with `List xs -> parse xs | _ -> Error "expected catalog entries" in
  Ok {directory;parent;entries}
