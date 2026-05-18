(** Tool_board_cache — TTL cache for [masc_board_list] payloads.

    Reduces redundant JSONL reads when multiple keepers poll
    board_list in the same analysis window. Invalidated on any board
    mutation (post, comment, vote, delete, cleanup).

    Stage 10 split of lib/tool_board.ml. *)

(* Cache only the rendered payload (success flag + message string) — never
   the full [Tool_result.t]. Storing the whole record would let cache
   hits reuse the *original* [duration_ms] and [start_time], so a 50 ms
   reading 30 s later would still report the 250 ms it took the first
   caller — and any other per-call telemetry baked into the record would
   leak the same way. Copilot review #14662 thread 3. Each hit rebuilds
   a fresh [Tool_result] with the current caller's [~start_time]. *)
type cached_payload =
  { success : bool
  ; message : string
  }

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

let cached_board_list ~key ~tool_name ~start_time compute =
  let now = Time_compat.now () in
  let ttl_s = board_list_cache_ttl_s () in
  let rebuild (payload : cached_payload) : Tool_result.t =
    if payload.success
    then Tool_result.ok ~tool_name ~start_time payload.message
    else Tool_result.error ~tool_name ~start_time payload.message
  in
  match board_list_cache.key, board_list_cache.value with
  | Some cached_key, Some payload
    when String.equal cached_key key
         && Stdlib.Float.compare now board_list_cache.expires_at < 0 ->
    rebuild payload
  | _ ->
    let result : Tool_result.t = compute () in
    let payload =
      { success = result.success; message = Tool_result.message result }
    in
    board_list_cache.key <- Some key;
    board_list_cache.value <- Some payload;
    board_list_cache.expires_at <- now +. ttl_s;
    result
;;

(** Deterministic cache key from board_list args. Serializes the
    normalized JSON so identical parameter sets hit the same entry. *)
let board_list_cache_key args = Yojson.Safe.to_string args
