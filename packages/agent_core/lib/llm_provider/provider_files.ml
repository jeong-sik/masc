(* Provider Files API client — RFC-0430 Phase 3, first slice.

   DeepSeek's Files API (https://api-docs.deepseek.com/guides/files_api,
   probed live 2026-09-06: upload→file_id vision reference→list→retrieve→
   delete) is image-only and pairs with the vision-exp model. The upload is
   multipart/form-data over the same bearer-auth HTTP surface as chat, so it
   rides [Http_client.post_sync] once the body is encoded — no new transport.

   Scope of this module: encode + dispatch + decode. Keeper tool registration
   and the vision request's {"type":"file","file_id":…} part are separate
   slices; nothing here is wired into a turn. *)

type file_object =
  { id : string
  ; bytes : int
  ; created_at : float
  ; filename : string
  ; purpose : string
  }

let file_object_of_yojson (json : Yojson.Safe.t) : (file_object, string) result =
  let open Yojson.Safe.Util in
  match json with
  | `Assoc fields ->
    let field name = List.assoc_opt name fields in
    let string_field name =
      match field name with Some (`String v) -> Ok v | _ -> Error ("missing or non-string " ^ name)
    in
    let ( let* ) = Result.bind in
    let* id = string_field "id" in
    let* filename = string_field "filename" in
    let* purpose = string_field "purpose" in
    let* bytes =
      match field "bytes" with
      | Some (`Int v) -> Ok v
      | _ -> Error "missing or non-int bytes"
    in
    let* created_at =
      match field "created_at" with
      | Some (`Float v) -> Ok v
      | Some (`Int v) -> Ok (float_of_int v)
      | _ -> Error "missing or non-numeric created_at"
    in
    Ok { id; bytes; created_at; filename; purpose }
  | _ -> Error "file object is not a JSON object"
;;

(* multipart/form-data encoder. The boundary is caller-supplied so tests can
   pin the exact bytes; production callers mint one from the random id module.
   Two form fields per the API: `file` (filename + bytes) and `purpose`
   ("user_data" is the only accepted value today). *)
let multipart_upload_body ~(boundary : string) ~(filename : string)
    ~(purpose : string) ~(content : string)
  : string =
  let dash = "--" in
  let crlf = "\r\n" in
  String.concat ""
    [ dash; boundary; crlf
    ; "Content-Disposition: form-data; name=\"file\"; filename=\""; filename; "\""; crlf
    ; "Content-Type: application/octet-stream"; crlf
    ; crlf
    ; content; crlf
    ; dash; boundary; crlf
    ; "Content-Disposition: form-data; name=\"purpose\""; crlf
    ; crlf
    ; purpose; crlf
    ; dash; boundary; dash; crlf
    ]
;;

let content_type_with_boundary ~(boundary : string) : string =
  "multipart/form-data; boundary=" ^ boundary
;;

(* Dispatch helpers. Each returns the decoded body of the API's JSON reply;
   the caller maps HTTP-level failures to its own error vocabulary. *)
let files_base_url = "https://api.deepseek.com"

let auth_headers ~(api_key : string) : (string * string) list =
  [ ("Authorization", "Bearer " ^ api_key) ]
;;

let parse_body_file_object (body : string) : (file_object, string) result =
  match Yojson.Safe.from_string body with
  | exception _ -> Error "files reply is not JSON"
  | json -> file_object_of_yojson json
;;

let upload ~sw ~net ~(api_key : string) ~boundary ~filename ~purpose ~content ()
  : (file_object, string) result =
  let body = multipart_upload_body ~boundary ~filename ~purpose ~content in
  match
    Http_client.post_sync ~sw ~net
      ~url:(files_base_url ^ "/files")
      ~headers:
        (auth_headers ~api_key
        @ [ ("Content-Type", content_type_with_boundary ~boundary) ])
      ~body ()
  with
  | Error _ -> Error "files upload: HTTP dispatch failed"
  | Ok response -> (
    match response.Http_client.status with
    | 200 -> parse_body_file_object response.body
    | code -> Error (Printf.sprintf "files upload: HTTP %d" code))
;;
