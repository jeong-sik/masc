(** GLM Cloud Multi-Model Load Balancer

    Distributes requests across GLM models with different concurrency limits
    to maximize throughput for MASC social experiments and games.

    Model Concurrency Limits (from Z.ai docs):
    - GLM-4.5: 10 concurrent
    - GLM-4.6V: 10 concurrent
    - GLM-5: 5 concurrent
    - GLM-4.7: 5 concurrent
    - GLM-4.6: 3 concurrent
    - GLM-4.6V-FlashX: 3 concurrent
    - GLM-4.7-FlashX: 3 concurrent
    - GLM-4.7-Flash: 1 concurrent
    - Total: ~39 concurrent calls possible

    @since 2.66.0 *)

type glm_model = {
  model_id: string;
  concurrency_limit: int;
  description: string;
}

(** All available GLM Cloud models with their concurrency limits.
    Ordered by preference (higher concurrency models first for better throughput). *)
let available_models : glm_model array = [|
  { model_id = "glm-4.5"; concurrency_limit = 10; description = "High concurrency, general purpose" };
  { model_id = "glm-4.6v"; concurrency_limit = 10; description = "High concurrency, vision-capable" };
  { model_id = "glm-5"; concurrency_limit = 5; description = "Flagship model" };
  { model_id = "glm-4.7"; concurrency_limit = 5; description = "Latest generation" };
  { model_id = "glm-4.6"; concurrency_limit = 3; description = "Balanced performance" };
  { model_id = "glm-4.6v-flashx"; concurrency_limit = 3; description = "Fast variant with vision" };
  { model_id = "glm-4.7-flashx"; concurrency_limit = 3; description = "Fast latest generation" };
  (* glm-4.7-flash has limit 1, excluded from pool for efficiency *)
|]

(** Pool state: tracks in-flight requests per model. *)
type pool_state = {
  mutable in_flight: int array;  (* Parallel to available_models *)
  mutable last_index: int;       (* For round-robin selection *)
}

(** Global pool state (lazy initialization). *)
let pool_state = lazy (
  let len = Array.length available_models in
  { in_flight = Array.make len 0; last_index = 0 }
)

let get_pool () = Lazy.force pool_state

(** Find model index by model_id, returns -1 if not found. *)
let find_model_index (model_id : string) : int =
  let rec loop i =
    if i >= Array.length available_models then -1
    else if String.equal (String.lowercase_ascii available_models.(i).model_id)
                    (String.lowercase_ascii model_id) then i
    else loop (i + 1)
  in
  loop 0

(** Check if a model_id is in our pool. *)
let is_pool_model (model_id : string) : bool =
  find_model_index model_id >= 0

(** Select best model using least-loaded strategy.
    Returns model_id with lowest in_flight/concurrency_ratio.
    Falls back to round-robin if all at capacity. *)
let select_model () : string =
  let pool = get_pool () in
  let len = Array.length available_models in

  (* Find model with best availability ratio *)
  let best_idx = ref 0 in
  let best_ratio = ref max_float in

  for i = 0 to len - 1 do
    let model = available_models.(i) in
    let in_flight = pool.in_flight.(i) in
    let ratio = float_of_int in_flight /. float_of_int model.concurrency_limit in
    (* Also consider that we can still add requests if under limit *)
    if ratio < !best_ratio && in_flight < model.concurrency_limit then begin
      best_ratio := ratio;
      best_idx := i
    end
  done;

  (* If best_ratio is still max_float, all models at capacity - use round-robin *)
  if !best_ratio = max_float then begin
    pool.last_index <- (pool.last_index + 1) mod len;
    available_models.(pool.last_index).model_id
  end else
    available_models.(!best_idx).model_id

(** Select a specific model if requested and available,
    otherwise fall back to pool selection. *)
let select_model_preferring (preferred : string option) : string =
  match preferred with
  | None -> select_model ()
  | Some model_id ->
    (* If the requested model is in pool and has capacity, use it *)
    let idx = find_model_index model_id in
    if idx >= 0 then begin
      let pool = get_pool () in
      let model = available_models.(idx) in
      if pool.in_flight.(idx) < model.concurrency_limit then
        model_id
      else
        (* Requested model at capacity, select from pool *)
        select_model ()
    end else
      (* Not a pool model, use as-is *)
      model_id

(** Increment in-flight count for a model.
    Call before making the API request. *)
let acquire (model_id : string) : unit =
  let idx = find_model_index model_id in
  if idx >= 0 then begin
    let pool = get_pool () in
    pool.in_flight.(idx) <- pool.in_flight.(idx) + 1;
    (* Debug logging *)
    let model = available_models.(idx) in
    Log.Glm_pool.debug "acquire %s: %d/%d"
      model_id pool.in_flight.(idx) model.concurrency_limit
  end

(** Decrement in-flight count for a model.
    Call after API response or error. *)
let release (model_id : string) : unit =
  let idx = find_model_index model_id in
  if idx >= 0 then begin
    let pool = get_pool () in
    let new_count = max 0 (pool.in_flight.(idx) - 1) in
    pool.in_flight.(idx) <- new_count;
    let model = available_models.(idx) in
    Log.Glm_pool.debug "release %s: %d/%d"
      model_id new_count model.concurrency_limit
  end

(** Execute a GLM request with automatic load balancing.
    Selects best model, tracks in-flight requests, and handles cleanup.

    Usage:
    {[
      Glm_pool.with_model (fun model_id ->
        (* make API call with model_id *)
        ...
      )
    ]}
*)
let with_model (preferred_model : string option) (f : string -> 'a) : 'a =
  let model_id = select_model_preferring preferred_model in
  acquire model_id;
  try
    let result = f model_id in
    release model_id;
    result
  with exn ->
    release model_id;
    raise exn

(** Get pool statistics for monitoring. *)
let get_stats () : (string * int * int) list =
  let pool = get_pool () in
  Array.mapi (fun i model ->
    (model.model_id, pool.in_flight.(i), model.concurrency_limit)
  ) available_models
  |> Array.to_list

(** Total capacity across all pool models. *)
let total_capacity : int =
  Array.fold_left (fun acc m -> acc + m.concurrency_limit) 0 available_models

(** Current total in-flight requests. *)
let current_load () : int =
  let pool = get_pool () in
  Array.fold_left (fun acc n -> acc + n) 0 pool.in_flight

(** Check if pool has available capacity (any model under limit). *)
let has_capacity () : bool =
  let pool = get_pool () in
  let len = Array.length available_models in
  let rec loop i =
    if i >= len then false
    else if pool.in_flight.(i) < available_models.(i).concurrency_limit then true
    else loop (i + 1)
  in
  loop 0
