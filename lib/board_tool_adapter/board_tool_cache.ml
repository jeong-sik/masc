(** Board_tool_cache — TTL cache for [masc_board_list] payloads.

    Reduces redundant JSONL reads when multiple keepers poll
    board_list in the same analysis window. The key includes the
    dispatch-level board mutation version, so mutations outside the
    board-tool path cannot keep serving a stale list payload.

    Stage 10 split of lib/board_tool.ml. *)

(* Cache only the rendered payload — never the full result record.
   Storing the whole record would let cache hits reuse the *original*
   [duration_ms] and [start_time], so a 50 ms reading 30 s later would
   still report the 250 ms it took the first caller. Copilot review
   #14662 thread 3. Each hit rebuilds a fresh result with the current
   caller's [~start_time].

   RFC-0189 PR-1b.2 — typed payload variant: [Ok message] vs
   [Error (class_, message)]. The [class_] survives across the cache
   boundary so a cached failure rebuilds with the same typed
   classification it had on first call (no [classify_from_*] re-parse,
   no [Runtime_failure] default). *)
type cached_payload =
  ( string
  , Tool_result.tool_failure_class * string )
    Stdlib.Result.t

type board_list_cache =
  { mutable key : string option
  ; mutable value : cached_payload option
  ; mutable expires_at : float
  }

let board_list_cache : board_list_cache = { key = None; value = None; expires_at = 0.0 }
let board_list_cache_ttl_s () = 30.0

let invalidate_board_list_cache () =
  board_list_cache.key <- None;
  board_list_cache.value <- None;
  board_list_cache.expires_at <- 0.0
;;

let cached_board_list ~key ~tool_name ~start_time compute : Tool_result.result =
  let now = Time_compat.now () in
  let ttl_s = board_list_cache_ttl_s () in
  let rebuild (payload : cached_payload) : Tool_result.result =
    match payload with
    | Ok message ->
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(`String message)
        ()
    | Error (class_, message) ->
      Tool_result.make_err ~tool_name ~class_ ~start_time message
  in
  let store_and_return (result : Tool_result.result) =
    let payload : cached_payload =
      match result with
      | Ok s ->
        (match s.data with
         | `String msg -> Ok msg
         | other -> Ok (Yojson.Safe.to_string other))
      | Error f -> Error (f.class_, f.message)
    in
    board_list_cache.key <- Some key;
    board_list_cache.value <- Some payload;
    board_list_cache.expires_at <- now +. ttl_s;
    result
  in
  match board_list_cache.key, board_list_cache.value with
  | Some cached_key, Some payload
    when String.equal cached_key key
         && Stdlib.Float.compare now board_list_cache.expires_at < 0 ->
    rebuild payload
  | _ -> store_and_return (compute ())
;;

(** Deterministic cache key from board_list args. Serializes the
    normalized JSON so identical parameter sets hit the same entry. *)
let board_list_cache_key args =
  Yojson.Safe.to_string
    (`Assoc
       [
         ("args", args);
         ("board_mutation_version", `Int (Board_dispatch.mutation_version ()));
       ])
