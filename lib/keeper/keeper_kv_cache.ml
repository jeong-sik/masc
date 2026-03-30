(** Keeper KV cache persistence via llama-server slot save/restore.

    Wraps llama-server's slot save/restore HTTP API to persist KV cache
    across server restarts. Avoids re-processing the entire conversation
    prefix on session resume.

    Requires llama-server started with [--slot-save-path <dir>].

    @since 2.177.0 *)

(** Save a slot's KV cache to disk.

    Calls [POST /slots/{slot_id}?action=save] on the llama-server.
    The server writes KV cache tensor data to [--slot-save-path/filename].

    Returns [Ok ()] on success, [Error message] on failure. *)
let save_slot ~sw ~net ~endpoint ~slot_id ~filename =
  let url =
    Printf.sprintf "%s/slots/%d?action=save" endpoint slot_id
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc [("filename", `String filename)])
  in
  let headers = [("Content-Type", "application/json")] in
  match
    Llm_provider.Http_client.post_sync ~sw ~net ~url ~headers ~body
  with
  | Ok (code, _) when code >= 200 && code < 300 ->
    Log.Keeper.info "keeper:kv_cache slot=%d saved as %s"
      slot_id filename;
    Ok ()
  | Ok (code, resp_body) ->
    let msg =
      Printf.sprintf "slot save HTTP %d: %s" code
        (if String.length resp_body > 200
         then String.sub resp_body 0 200
         else resp_body)
    in
    Log.Keeper.warn "keeper:kv_cache %s" msg;
    Error msg
  | Error (Llm_provider.Http_client.HttpError { code; body }) ->
    let msg = Printf.sprintf "slot save HTTP error %d: %s" code body in
    Log.Keeper.warn "keeper:kv_cache %s" msg;
    Error msg
  | Error (Llm_provider.Http_client.NetworkError { message }) ->
    Log.Keeper.warn "keeper:kv_cache slot save network error: %s" message;
    Error message

(** Restore a slot's KV cache from disk.

    Calls [POST /slots/{slot_id}?action=restore] on the llama-server.
    The server loads KV cache tensor data from [--slot-save-path/filename].

    Returns [Ok ()] on success, [Error message] on failure.
    Failures are expected when:
    - The file does not exist (first session, no prior save)
    - Model/quant mismatch (different model loaded)
    - Server was not started with [--slot-save-path] *)
let restore_slot ~sw ~net ~endpoint ~slot_id ~filename =
  let url =
    Printf.sprintf "%s/slots/%d?action=restore" endpoint slot_id
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc [("filename", `String filename)])
  in
  let headers = [("Content-Type", "application/json")] in
  match
    Llm_provider.Http_client.post_sync ~sw ~net ~url ~headers ~body
  with
  | Ok (code, _) when code >= 200 && code < 300 ->
    Log.Keeper.info "keeper:kv_cache slot=%d restored from %s"
      slot_id filename;
    Ok ()
  | Ok (code, resp_body) ->
    let msg =
      Printf.sprintf "slot restore HTTP %d: %s" code
        (if String.length resp_body > 200
         then String.sub resp_body 0 200
         else resp_body)
    in
    Log.Keeper.info "keeper:kv_cache %s (non-fatal)" msg;
    Error msg
  | Error (Llm_provider.Http_client.HttpError { code; body }) ->
    let msg = Printf.sprintf "slot restore HTTP error %d: %s" code body in
    Log.Keeper.info "keeper:kv_cache %s (non-fatal)" msg;
    Error msg
  | Error (Llm_provider.Http_client.NetworkError { message }) ->
    Log.Keeper.info "keeper:kv_cache slot restore network error: %s (non-fatal)"
      message;
    Error message

(** Generate a stable filename for a keeper's slot cache.

    Format: [keeper-{name}-slot{id}.bin]
    Each keeper agent gets its own cache file. *)
let cache_filename ~keeper_name ~slot_id =
  Printf.sprintf "keeper-%s-slot%d.bin" keeper_name slot_id
