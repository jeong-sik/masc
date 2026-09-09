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

let list_files ~sw ~net ~(api_key : string) ()
  : (file_object list, string) result =
  match
    Http_client.get_sync ~sw ~net
      ~url:(files_base_url ^ "/files")
      ~headers:(auth_headers ~api_key)
      ()
  with
  | Error _ -> Error "files list: HTTP dispatch failed"
  | Ok response -> (
    (* GET /files; the reply is
       {"object":"list","data":[file…],"has_more":bool}. Pagination
       parameters exist but default to everything the account holds, which
       is the shape a keeper listing its uploads wants. *)
    match response.Http_client.status with
    | 200 -> (
      match Yojson.Safe.from_string response.body with
      | exception _ -> Error "files list: reply is not JSON"
      | `Assoc fields -> (
        match List.assoc_opt "data" fields with
        | Some (`List rows) ->
          let decoded =
            List.filter_map
              (fun row ->
                 match file_object_of_yojson row with
                 | Ok obj -> Some obj
                 | Error _ -> None)
              rows
          in
          (* A row that does not decode is a forward-compat addition the
             client has not been taught; dropping it silently would hide
             files the operator owns, so the count must disagree visibly. *)
          if List.length decoded = List.length rows then Ok decoded
          else Error "files list: a row did not decode"
        | _ -> Error "files list: reply carries no data array")
      | _ -> Error "files list: reply is not a JSON object")
    | code -> Error (Printf.sprintf "files list: HTTP %d" code))
;;

let delete ~sw ~net ~(api_key : string) ~(file_id : string) ()
  : (bool, string) result =
  match
    Http_client.delete_sync ~sw ~net
      ~url:(files_base_url ^ "/files/" ^ file_id)
      ~headers:(auth_headers ~api_key)
      ()
  with
  | Error _ -> Error "files delete: HTTP dispatch failed"
  | Ok response -> (
    (* The API answers {"id":…,"object":"file","deleted":true}; the boolean is
       the whole fact, and a non-200 is the caller's error. *)
    match response.Http_client.status with
    | 200 ->
      (match Yojson.Safe.from_string response.body with
       | exception _ -> Error "files delete: reply is not JSON"
       | `Assoc fields -> (
         match List.assoc_opt "deleted" fields with
         | Some (`Bool true) -> Ok true
         | _ -> Error "files delete: reply did not confirm deletion")
       | _ -> Error "files delete: reply is not a JSON object")
    | code -> Error (Printf.sprintf "files delete: HTTP %d" code))
;;
