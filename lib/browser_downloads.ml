type completion = File of string | Path_unavailable
type status = Pending | Completed of completion | Canceled | Interrupted of string
type download = {
  id : string; context : string; url : string; filename : string option;
  status : status;
}
type t = {
  downloads : (string, download) Hashtbl.t;
  parents : (string, string option) Hashtbl.t;
  mutable order : string list;
}
let create () = { downloads = Hashtbl.create 16; parents = Hashtbl.create 16; order = [] }
let ( let* ) = Result.bind
let field key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let string key json = match field key json with
  | Some (`String value) when value <> "" -> Ok value
  | _ -> Error ("BiDi missing string: " ^ key)
let context ?parent t json =
  let* id = string "context" json in
  let* parent = match field "parent" json with
    | Some `Null -> Ok None
    | None -> Ok parent
    | Some (`String parent) when parent <> "" -> Ok (Some parent)
    | _ -> Error "BiDi invalid context parent" in
  Hashtbl.replace t.parents id parent;
  Ok ()
let rec tree ?parent t json =
  let* id = string "context" json in
  let* () = context ?parent t json in
  match field "children" json with
  | None | Some `Null -> Ok ()
  | Some (`List children) ->
    List.fold_left (fun result child -> let* () = result in tree ~parent:id t child) (Ok ()) children
  | _ -> Error "BiDi invalid context children"
let add_tree t json = match field "contexts" json with
  | Some (`List contexts) ->
    List.fold_left (fun result child -> let* () = result in tree t child) (Ok ()) contexts
  | _ -> Error "BiDi getTree lacks contexts"
let event t ~method_ json =
  match method_ with
  | "browsingContext.contextCreated" -> tree t json
  | "browsingContext.downloadWillBegin" | "browsingContext.downloadEnd" ->
    let* id = string "download" json in
    let* context = string "context" json in
    let* url = string "url" json in
    let previous = Hashtbl.find_opt t.downloads id in
    let* filename, status = match method_ with
      | "browsingContext.downloadWillBegin" ->
        let* filename = string "suggestedFilename" json in
        Ok (Some filename, Pending)
      | _ ->
        let* status = match field "status" json with
          | Some (`String "canceled") -> Ok Canceled
          | Some (`String "complete") ->
            (match field "filepath" json with
             | Some `Null -> Ok (Completed Path_unavailable)
             | Some (`String path) when path <> "" -> Ok (Completed (File path))
             | _ -> Error "BiDi completion lacks filepath or explicit null")
          | _ -> Error "BiDi invalid download terminal status" in
        Ok (Option.bind previous (fun d -> d.filename), status) in
    let* () = match previous with
      | Some d when d.context <> context || d.url <> url -> Error "BiDi download identity changed"
      | Some { status = (Completed _ | Canceled); _ } -> Error "BiDi repeated terminal download"
      | _ -> Ok () in
    if previous = None then t.order <- id :: t.order;
    Hashtbl.replace t.downloads id {id; context; url; filename; status};
    Ok ()
  | _ -> Ok ()
let interrupt t reason =
  Hashtbl.filter_map_inplace (fun _ d -> Some (match d.status with
    | Pending -> {d with status = Interrupted reason}
    | Completed _ | Canceled | Interrupted _ -> d)) t.downloads
let for_context t requested =
  let rec belongs visited current =
    current = requested ||
    (not (List.mem current visited) &&
     match Hashtbl.find_opt t.parents current with
     | Some (Some parent) -> belongs (current :: visited) parent
     | None | Some None -> false) in
  List.rev t.order |> List.filter_map (fun id ->
    let d = Hashtbl.find t.downloads id in
    if belongs [] d.context then Some d else None)
let to_json ~verify d =
  let status, details = match d.status with
    | Pending -> "pending", []
    | Canceled -> "canceled", []
    | Interrupted reason -> "interrupted", ["reason", `String reason]
    | Completed Path_unavailable -> "completed", ["file", `String "path_unavailable"]
    | Completed (File path) ->
      "completed", (match verify path with
        | Ok (path, bytes) -> ["file", `String "available"; "path", `String path; "bytes", `Int bytes]
        | Error reason -> ["file", `String "unavailable"; "reason", `String reason]) in
  `Assoc (["downloadId", `String d.id; "context", `String d.context;
    "url", `String d.url; "status", `String status;
    "suggestedFilename", (match d.filename with None -> `Null | Some s -> `String s)] @ details)
type connection = {
  read : context:string -> (Yojson.Safe.t, string) result;
  check : unit -> (unit, string) result;
  close : unit -> unit;
}
type start = session_id:string -> websocket_url:string -> (connection, string) result
