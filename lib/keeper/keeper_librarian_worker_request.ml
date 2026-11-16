module Exact = Lane_addon_exact
open Result.Syntax

type command = Read of string | Submit of Exact.request

let context = "Original Librarian worker command"
let rec integer_schema_json = function
  | `Float _ -> false
  | `Assoc fields -> List.for_all (fun (_, value) -> integer_schema_json value) fields
  | `List values -> List.for_all integer_schema_json values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `String _ -> true
let decode arguments =
  let* fields = Candle_json.object_fields ~context arguments in
  let* kind, fields = Candle_json.field ~context "kind" Candle_json.as_string fields in
  let* command, fields = match kind with
    | "read" ->
      let+ request_id, fields = Candle_json.field ~context "request_id" Candle_json.as_non_blank fields in
      Read request_id, fields
    | "submit" ->
      let+ request, fields = Candle_json.field ~context "request" Exact.request_of_json fields in
      Submit request, fields
    | _ -> Error "Original Librarian worker command must be read or submit" in
  let+ () = Candle_json.finish ~context fields in command

let prepare ~max_reply_bytes ~request_id ~tool ~arguments =
  let* () = if max_reply_bytes > 0 then Ok ()
    else Error "Librarian worker reply frame must be positive" in
  let* command = decode arguments in
  let* actual_id = match command with
    | Read actual_id -> Ok actual_id
    | Submit request ->
      let* output = match tool with
        | "admit_memory" -> Ok "admission"
        | "derive_memory" -> Ok "durable"
        | _ -> Error "Captured Librarian command has no matching exported tool" in
      if request.output = output then Ok request.request_id
      else Error "Captured Librarian submission belongs to another tool" in
  let* () = if actual_id = request_id then Ok ()
    else Error "Captured Librarian command belongs to another original request" in
  match command with
  | Read _ -> Ok arguments
  | Submit request ->
    let* canonical = Lane_addon_action.canonical (Exact.request_to_json request) in
    let bytes = Yojson.Safe.to_string canonical in
    let request_bytes = String.length bytes in
    if request_bytes <= max_reply_bytes then Ok arguments else
    let* () = if integer_schema_json canonical then Ok () else
      Error "Oversized Librarian request has non-integral schema numbers; its worker digest cannot be confirmed" in
      Ok (`Assoc ["kind", `String "refuse_body"; "request_id", `String request_id;
        "request_digest", `String (Lane_addon_store.digest bytes);
        "request_bytes", `Int request_bytes])
