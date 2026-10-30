module History = Agent_core_base.History

(* The block keeps its media type; the blob's mime only labels the bytes,
   and the artifact address cannot carry a parameter ("text/plain;
   charset=utf-8"), whitespace or an empty type. The label is the type and
   subtype before any parameter, or application/octet-stream, the name for
   bytes of unrecorded type, when that part is empty or still unencodable. *)
let blob_mime media_type =
  let essence =
    String.trim
      (match String.index_opt media_type ';' with
       | None -> media_type
       | Some cut -> String.sub media_type 0 cut)
  in
  if String.equal essence "" || not (Tool_output.mime_is_encodable essence)
  then "application/octet-stream"
  else essence
;;

let put store ~media_type ~raw =
  match Tool_blob_store.put_durable_reuse store ~bytes:raw ~mime:(blob_mime media_type) with
  | artifact ->
    (match History.stored ~sha256:artifact.Tool_output.sha256 ~bytes:artifact.bytes with
     | Ok stored -> Ok stored
     | Error error ->
       Error (History.Store_failed { detail = History.stored_error_to_string error }))
  | exception Sys_error detail -> Error (History.Store_failed { detail })
;;

let get store (expected : History.stored) =
  match Tool_blob_store.fetch store ~sha256:expected.sha256 with
  | Ok None -> Error (History.Missing_bytes expected)
  | Ok (Some raw) ->
    if String.length raw = expected.bytes
    then Ok raw
    else Error (History.Digest_mismatch { expected; actual = History.stored_of_raw raw })
  | Error error ->
    Error (History.Store_failed { detail = Tool_blob_store.fetch_error_to_string error })
;;

let create store : History.media_store =
  { put = (fun ~media_type ~raw -> put store ~media_type ~raw)
  ; get = (fun expected -> get store expected)
  }
;;

let of_base_path ~base_path = create (Tool_blob_store.create ~base_path)
