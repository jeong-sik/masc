type status = Pending | Completed of string | Interrupted of string
type download = {
  id : string; context : string; url : string; filename : string option;
  status : status;
}
let fields ~verify d =
  let status, details = match d.status with
    | Pending -> "pending", []
    | Interrupted reason -> "interrupted", ["reason", `String reason]
    | Completed path ->
      "completed", (match verify path with
        | Ok (path, bytes) -> ["file", `String "available"; "path", `String path; "bytes", `Int bytes]
        | Error reason -> ["file", `String "unavailable"; "reason", `String reason]) in
  ["downloadId", `String d.id; "context", `String d.context;
    "url", `String d.url; "status", `String status;
    "suggestedFilename", (match d.filename with None -> `Null | Some s -> `String s)] @ details
let published_json ~verify ~publish ~published d =
  let fields = fields ~verify d in
  let artifact = match Hashtbl.find_opt published d.id with
    | Some value -> Some (Ok value)
    | None -> (match List.assoc_opt "path" fields with
      | Some (`String path) ->
        let result = publish path in
        Result.iter (Hashtbl.replace published d.id) result;
        Some result
      | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Assoc _) | None -> None) in
  `Assoc (match artifact with
    | Some (Ok value) -> ("artifact", value) :: fields
    | Some (Error reason) -> ("artifactError", `String reason) :: fields
    | None -> fields)
