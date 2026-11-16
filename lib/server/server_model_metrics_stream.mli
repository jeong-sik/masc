(** Direct model-metric snapshots shared by REST and mounted native queries.
    REST reads and open streams share a bounded [(base_path, window_minutes)]
    LRU of {!Model_inference_metrics_kept.t} cursors so subsequent queries fold
    only newly appended rows. Each stream still owns its immutable query, typed
    source subscription and semantic deadline, and retains no background fiber
    after closing. *)

val max_window_minutes : int
val max_cached_windows : int
val max_cached_staleness_s : float

type request = {
  window_minutes : int;
  bucket_minutes : int;
}

val request : Httpun.Request.t -> (request, string) result
val stream_path : string

type snapshot = {
  json : Yojson.Safe.t;
  next_change_at : float option;
  retry_read : bool;
}

val read_snapshot :
  base_path:string -> request:request -> now:float ->
  Model_inference_metrics_kept.t ->
  Model_inference_metrics_kept.t * (snapshot, string) result
(** One supplied-time direct reader. Call it on an existing pool lane.
    [retry_read] identifies a failed cost-store read beside a partial snapshot,
    so the stream closes after delivering it and the client retains failed-read
    recovery. Schema diagnostics instead expire at their actual row/day edge.
    Empty windows and empty buckets do not create clock deadlines. *)

val read_cached_snapshot :
  base_path:string -> request:request -> now:float -> (snapshot, string) result
(** Refresh and answer [request] through the bounded shared
    [(base_path, window_minutes)] retained-row LRU. Call it on an existing pool
    lane; atomic CAS state updates touch only the in-memory table, never disk
    I/O. *)

val is_invalidation : Masc.Sse.external_event -> bool
(** Select the existing typed [Model_metrics] input. Workspace authority is
    admitted by {!Masc.Sse.subscribe_external} before the initial read. *)

val add_routes :
  sw:Eio.Switch.t -> clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t
(** Requires the original observation's [Sse_wire.instance_header]. Success
    attests that exact instance; workspace replacement retires the query. *)
