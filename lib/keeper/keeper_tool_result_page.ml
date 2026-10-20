type identity = {
  source_id : string;
  sha256 : string;
  recorded_bytes : int;
  is_error : bool;
}
type response = Pending | Unavailable of string | Page of identity * Keeper_artifact_read.page
let ( let* ) = Result.bind
let page_envelope ~keeper ~execution_id identity page =
  `Assoc ["keeper",`String keeper;"execution_id",`String execution_id;
    "state",`String "page";"source_id",`String identity.source_id;
    "body_sha256",`String identity.sha256;"recorded_bytes",`Int identity.recorded_bytes;
    "is_error",`Bool identity.is_error;"page",page]
let to_json ~keeper ~execution_id = function
  | Page (identity,page) ->
      page_envelope ~keeper ~execution_id identity (Keeper_artifact_read.page_to_json page)
  | Pending -> `Assoc ["keeper",`String keeper;"execution_id",`String execution_id;
      "state",`String "pending"]
  | Unavailable reason -> `Assoc ["keeper",`String keeper;"execution_id",`String execution_id;
      "state",`String "unavailable";"reason",`String reason]
let field json name = match json with
  | `Assoc fields ->
      (match List.filter (fun (key,_) -> String.equal key name) fields with
       | [_,value] -> Ok value | [] -> Error ("Missing "^name)
       | _ :: _ :: _ -> Error ("Duplicate "^name))
  | _ -> Error "Original result response must be an object"
let string json name = let* value=field json name in match value with
  | `String text -> Ok text | _ -> Error ("Expected string "^name)
let int json name = let* value=field json name in match value with
  | `Int n when n>=0 -> Ok n | _ -> Error ("Expected nonnegative integer "^name)
let bool json name = let* value=field json name in match value with
  | `Bool value -> Ok value | _ -> Error ("Expected boolean "^name)
let sha json name = let* text=string json name in
  match Tool_output.validate_sha256 text with
  | Ok () -> Ok text | Error _ -> Error ("Invalid digest "^name)
let of_json ~keeper ~execution_id json =
  let* owner=string json "keeper" in let* execution=string json "execution_id" in
  if not (String.equal keeper owner && String.equal execution_id execution)
  then Error "Original result execution or keeper mismatch"
  else let* state=string json "state" in match state with
    | "pending" -> Ok Pending
    | "unavailable" -> let* reason=string json "reason" in Ok (Unavailable reason)
    | "page" ->
      let* source_id=sha json "source_id" in let* sha256=sha json "body_sha256" in
      let* recorded_bytes=int json "recorded_bytes" in let* is_error=bool json "is_error" in
      let* page=field json "page" in let* ok=bool page "ok" in
      if not ok then Error "Original result page is not successful"
      else
        let* page_sha=sha page "sha256" in
        let* offset=int page "offset" in let* next_offset=int page "next_offset" in
        let* total_bytes=int page "total_bytes" in let* eof=bool page "eof" in
        let* content=string page "content" in let* encoding=string page "encoding" in
        let* encoding=match encoding with
          | "utf-8" -> Ok Keeper_artifact_read.Utf_8
          | "base64" -> Ok Keeper_artifact_read.Base64
          | _ -> Error "Unknown original page encoding" in
        if not (String.equal page_sha sha256) then Error "Original page digest differs"
        else Ok (Page ({source_id;sha256;recorded_bytes;is_error},
          {Keeper_artifact_read.sha256;offset;next_offset;total_bytes;eof;content;encoding}))
    | _ -> Error "Unknown original result state"
let bytes (page:Keeper_artifact_read.page) = match page.encoding with
  | Utf_8 -> if String.is_valid_utf_8 page.content then Ok page.content
      else Error "Original UTF8 page is malformed"
  | Base64 -> Base64.decode page.content
      |> Result.map_error (fun _ -> "Invalid original result base64 bytes")
let validate_continuation ~offset ~previous identity (page:Keeper_artifact_read.page) =
  let* content=bytes page in
  if page.offset<>offset || page.next_offset<page.offset
     || page.next_offset>page.total_bytes || page.eof<>(page.next_offset=page.total_bytes)
     || String.length content<>page.next_offset-page.offset
     || (not page.eof && page.next_offset=page.offset)
     || not (String.equal page.sha256 identity.sha256)
  then Error "Inconsistent original result page bounds or progress"
  else match previous with
    | None when offset=0 -> Ok ()
    | None -> Error "Original result continuation has no source identity"
    | Some (first,initial) ->
      if String.equal first.source_id identity.source_id
         && String.equal first.sha256 identity.sha256
         && first.recorded_bytes=identity.recorded_bytes && first.is_error=identity.is_error
         && initial.total_bytes=page.total_bytes
      then Ok () else Error "Original result source changed between pages"

let verify_body identity (page:Keeper_artifact_read.page) content =
  if not page.eof || String.length content<>page.total_bytes then
    Error "Original result body is incomplete"
  else if not (String.is_valid_utf_8 content) then Error "Original result is not valid UTF8"
  else if not (String.equal Digestif.SHA256.(to_hex (digest_string content)) identity.sha256)
  then Error "Original result body digest mismatch" else Ok ()
