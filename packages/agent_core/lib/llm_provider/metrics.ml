(** Metrics hooks for LLM completion observability. *)

type circuit_state =
  | Circuit_closed
  | Circuit_open
  | Circuit_half_open

let circuit_state_to_int = function
  | Circuit_closed -> 0
  | Circuit_open -> 1
  | Circuit_half_open -> 2
;;

let circuit_state_to_string = function
  | Circuit_closed -> "closed"
  | Circuit_open -> "open"
  | Circuit_half_open -> "half_open"
;;

type t =
  { on_cache_hit : model_id:string -> unit
  ; on_cache_miss : model_id:string -> unit
  ; on_request_start : model_id:string -> unit
  ; on_request_end : model_id:string -> latency_ms:int option -> unit
  ; on_error : model_id:string -> error:string -> unit
  ; on_http_status : provider:string -> model_id:string -> status:int -> unit
  ; on_circuit_state :
      provider:string
      -> model_id:string
      -> provider_key:string
      -> state:circuit_state
      -> unit
  ; on_capability_drop : model_id:string -> field:string -> unit
    (** Fired when a request parameter is silently dropped because the
      model's capability record reports it as unsupported.
      Consumers can use this to increment a Prometheus counter or emit
      a structured log event for alerting on misconfigured agents.

      @since 0.184.0 *)
  ; on_retry : provider:string -> model_id:string -> attempt:int -> unit
    (** Fired when a request is retried due to a retryable error.
      @since 0.185.0 *)
  ; on_token_usage :
      provider:string -> model_id:string -> input_tokens:int -> output_tokens:int -> unit
    (** Fired when a response carries usage tokens.
      @since 0.185.0 *)
  ; on_tool_calls : provider:string -> model_id:string -> count:int -> unit
  ; on_streaming_first_chunk :
      provider:string -> model_id:string -> ttfrc_ms:float -> unit
  ; on_streaming_chunk :
      provider:string
      -> model_id:string
      -> chunk_index:int
      -> inter_chunk_ms:float
      -> unit
  }

let noop =
  { on_cache_hit = (fun ~model_id:_ -> ())
  ; on_cache_miss = (fun ~model_id:_ -> ())
  ; on_request_start = (fun ~model_id:_ -> ())
  ; on_request_end = (fun ~model_id:_ ~latency_ms:_ -> ())
  ; on_error = (fun ~model_id:_ ~error:_ -> ())
  ; on_http_status = (fun ~provider:_ ~model_id:_ ~status:_ -> ())
  ; on_circuit_state = (fun ~provider:_ ~model_id:_ ~provider_key:_ ~state:_ -> ())
  ; on_capability_drop = (fun ~model_id:_ ~field:_ -> ())
  ; on_retry = (fun ~provider:_ ~model_id:_ ~attempt:_ -> ())
  ; on_token_usage = (fun ~provider:_ ~model_id:_ ~input_tokens:_ ~output_tokens:_ -> ())
  ; on_tool_calls = (fun ~provider:_ ~model_id:_ ~count:_ -> ())
  ; on_streaming_first_chunk = (fun ~provider:_ ~model_id:_ ~ttfrc_ms:_ -> ())
  ; on_streaming_chunk =
      (fun ~provider:_ ~model_id:_ ~chunk_index:_ ~inter_chunk_ms:_ -> ())
  }
;;

(* ── Global registry ────────────────────────────────── *)

(** Process-wide metrics sink used when a caller does not pass [~metrics]
    explicitly.  Initialised to [noop].  Consumers can install their
    own instance once at startup via [set_global].

    Access is guarded by an atomic so reads from a fiber holding the
    cached reference race-cleanly with a concurrent [set_global]; the
    reference itself is immutable once published. *)
let _global : t Atomic.t = Atomic.make noop

let set_global (m : t) : unit = Atomic.set _global m
let get_global () : t = Atomic.get _global

(* ── Aggregating implementation ──────────────────── *)

(** Per-provider snapshot of accumulated counters.
    Suitable for downstream OTLP/Prometheus export or structured logging.

    @since 0.188.0 *)
type provider_snapshot =
  { provider : string
  ; model_id : string
  ; request_total : int
  ; error_total : int
  ; retry_total : int
  ; input_tokens_total : int
  ; output_tokens_total : int
  ; tool_call_total : int
  ; latency_ms_sum : int
  ; latency_ms_count : int
  ; ttfrc_ms_sum : float
  ; ttfrc_ms_count : int
  ; inter_chunk_ms_sum : float
  ; inter_chunk_ms_count : int
  }

let provider_snapshot_to_yojson (snapshot : provider_snapshot) : Yojson.Safe.t =
  `Assoc
    [ "provider", `String snapshot.provider
    ; "model_id", `String snapshot.model_id
    ; "request_total", `Int snapshot.request_total
    ; "error_total", `Int snapshot.error_total
    ; "retry_total", `Int snapshot.retry_total
    ; "input_tokens_total", `Int snapshot.input_tokens_total
    ; "output_tokens_total", `Int snapshot.output_tokens_total
    ; "tool_call_total", `Int snapshot.tool_call_total
    ; "latency_ms_sum", `Int snapshot.latency_ms_sum
    ; "latency_ms_count", `Int snapshot.latency_ms_count
    ; "ttfrc_ms_sum", `Float snapshot.ttfrc_ms_sum
    ; "ttfrc_ms_count", `Int snapshot.ttfrc_ms_count
    ; "inter_chunk_ms_sum", `Float snapshot.inter_chunk_ms_sum
    ; "inter_chunk_ms_count", `Int snapshot.inter_chunk_ms_count
    ]
;;

let compare_provider_snapshot left right =
  match String.compare left.provider right.provider with
  | 0 -> String.compare left.model_id right.model_id
  | cmp -> cmp
;;

let provider_snapshots_to_yojson (snapshots : provider_snapshot list) : Yojson.Safe.t =
  let snapshots = List.sort compare_provider_snapshot snapshots in
  `Assoc
    [ "schema_version", `Int 2
    ; "providers", `List (List.map provider_snapshot_to_yojson snapshots)
    ]
;;

let file_error ~op ~path = function
  | Sys_error detail -> Error (Printf.sprintf "%s %s: %s" op path detail)
  | Unix.Unix_error (error, syscall, arg) ->
    Error
      (Printf.sprintf "%s %s: %s(%s): %s" op path syscall arg (Unix.error_message error))
  | exn -> Error (Printf.sprintf "%s %s: %s" op path (Printexc.to_string exn))
;;

let rec ensure_dir path =
  if path = "" || path = "." || Sys.file_exists path
  then Ok ()
  else (
    match ensure_dir (Filename.dirname path) with
    | Error _ as err -> err
    | Ok () ->
      (try
         Sys.mkdir path 0o755;
         Ok ()
       with
       | Sys_error _ when Sys.file_exists path -> Ok ()
       | exn -> file_error ~op:"mkdir" ~path exn))
;;

let fsync_best_effort fd =
  try Unix.fsync fd with
  | Unix.Unix_error ((EINVAL | EOPNOTSUPP), _, _) -> ()
;;

let fsync_dir_best_effort dir =
  try
    let fd = Unix.openfile dir [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close fd with
        | Unix.Unix_error _ -> ())
      (fun () -> fsync_best_effort fd)
  with
  | Unix.Unix_error _ -> ()
;;

let write_file_atomic path content =
  let dir = Filename.dirname path in
  match ensure_dir dir with
  | Error _ as err -> err
  | Ok () ->
    (try
       let base = Filename.basename path in
       let tmp_path = Filename.temp_file ~temp_dir:dir (base ^ ".") ".tmp" in
       let clean_tmp () =
         try Sys.remove tmp_path with
         | Sys_error _ | Unix.Unix_error _ -> ()
       in
       try
         Out_channel.with_open_bin tmp_path (fun oc ->
           Out_channel.output_string oc content;
           Out_channel.flush oc;
           fsync_best_effort (Unix.descr_of_out_channel oc));
         Sys.rename tmp_path path;
         fsync_dir_best_effort dir;
         Ok ()
       with
       | exn ->
         clean_tmp ();
         raise exn
     with
     | exn -> file_error ~op:"write" ~path exn)
;;

type aggregate_key = string

type aggregate_state =
  { mutable request_total : int
  ; mutable error_total : int
  ; mutable retry_total : int
  ; mutable input_tokens_total : int
  ; mutable output_tokens_total : int
  ; mutable tool_call_total : int
  ; mutable latency_ms_sum : int
  ; mutable latency_ms_count : int
  ; mutable ttfrc_ms_sum : float
  ; mutable ttfrc_ms_count : int
  ; mutable inter_chunk_ms_sum : float
  ; mutable inter_chunk_ms_count : int
  }

let empty_state () : aggregate_state =
  { request_total = 0
  ; error_total = 0
  ; retry_total = 0
  ; input_tokens_total = 0
  ; output_tokens_total = 0
  ; tool_call_total = 0
  ; latency_ms_sum = 0
  ; latency_ms_count = 0
  ; ttfrc_ms_sum = 0.0
  ; ttfrc_ms_count = 0
  ; inter_chunk_ms_sum = 0.0
  ; inter_chunk_ms_count = 0
  }
;;

(** Thread-safe aggregating metrics backend.
    Accumulates per-provider counters in a hash table guarded by an
    {!Stdlib.Mutex}. The guarded sections are pure counter updates, so this
    remains safe on Eio callback paths without requiring exporters/tests to run
    inside an Eio scheduler. Call {!Aggregating.snapshot} to read all counters
    as an immutable list.

    @since 0.188.0 *)
type hooks = t

module Aggregating = struct
  type t =
    { hooks : hooks
    ; states : (aggregate_key, aggregate_state) Hashtbl.t
    ; mutex : Mutex.t
    }

  let key ~provider ~model_id = provider ^ "/" ^ model_id

  let create ?(inner = noop) () : t =
    { hooks = inner; states = Hashtbl.create 16; mutex = Mutex.create () }
  ;;

  let with_lock agg f =
    Mutex.lock agg.mutex;
    Fun.protect f ~finally:(fun () -> Mutex.unlock agg.mutex)
  ;;

  let with_state agg key f =
    with_lock agg (fun () ->
      let state =
        match Hashtbl.find_opt agg.states key with
        | Some s -> s
        | None ->
          let s = empty_state () in
          Hashtbl.replace agg.states key s;
          s
      in
      f state)
  ;;

  let to_hooks (agg : t) : hooks =
    { on_cache_hit = (fun ~model_id -> agg.hooks.on_cache_hit ~model_id)
    ; on_cache_miss = (fun ~model_id -> agg.hooks.on_cache_miss ~model_id)
    ; on_request_start =
        (fun ~model_id ->
          agg.hooks.on_request_start ~model_id;
          with_state agg ("unknown/" ^ model_id) (fun s ->
            s.request_total <- s.request_total + 1))
    ; on_request_end =
        (fun ~model_id ~latency_ms ->
          agg.hooks.on_request_end ~model_id ~latency_ms;
          match latency_ms with
          | Some measured ->
            with_state agg ("unknown/" ^ model_id) (fun s ->
              s.latency_ms_sum <- s.latency_ms_sum + measured;
              s.latency_ms_count <- s.latency_ms_count + 1)
          | None -> ())
    ; on_error =
        (fun ~model_id ~error ->
          agg.hooks.on_error ~model_id ~error;
          with_state agg ("unknown/" ^ model_id) (fun s ->
            s.error_total <- s.error_total + 1))
    ; on_http_status =
        (fun ~provider ~model_id ~status ->
          agg.hooks.on_http_status ~provider ~model_id ~status)
    ; on_circuit_state =
        (fun ~provider ~model_id ~provider_key ~state ->
          agg.hooks.on_circuit_state ~provider ~model_id ~provider_key ~state)
    ; on_capability_drop =
        (fun ~model_id ~field -> agg.hooks.on_capability_drop ~model_id ~field)
    ; on_retry =
        (fun ~provider ~model_id ~attempt ->
          agg.hooks.on_retry ~provider ~model_id ~attempt;
          with_state agg (key ~provider ~model_id) (fun s ->
            s.retry_total <- s.retry_total + 1))
    ; on_token_usage =
        (fun ~provider ~model_id ~input_tokens ~output_tokens ->
          agg.hooks.on_token_usage ~provider ~model_id ~input_tokens ~output_tokens;
          with_state agg (key ~provider ~model_id) (fun s ->
            s.input_tokens_total <- s.input_tokens_total + input_tokens;
            s.output_tokens_total <- s.output_tokens_total + output_tokens))
    ; on_tool_calls =
        (fun ~provider ~model_id ~count ->
          agg.hooks.on_tool_calls ~provider ~model_id ~count;
          if count > 0
          then
            with_state agg (key ~provider ~model_id) (fun s ->
              s.tool_call_total <- s.tool_call_total + count))
    ; on_streaming_first_chunk =
        (fun ~provider ~model_id ~ttfrc_ms ->
          agg.hooks.on_streaming_first_chunk ~provider ~model_id ~ttfrc_ms;
          with_state agg (key ~provider ~model_id) (fun s ->
            s.ttfrc_ms_sum <- s.ttfrc_ms_sum +. ttfrc_ms;
            s.ttfrc_ms_count <- s.ttfrc_ms_count + 1))
    ; on_streaming_chunk =
        (fun ~provider ~model_id ~chunk_index ~inter_chunk_ms ->
          agg.hooks.on_streaming_chunk ~provider ~model_id ~chunk_index ~inter_chunk_ms;
          with_state agg (key ~provider ~model_id) (fun s ->
            s.inter_chunk_ms_sum <- s.inter_chunk_ms_sum +. inter_chunk_ms;
            s.inter_chunk_ms_count <- s.inter_chunk_ms_count + 1))
    }
  ;;

  let snapshot (agg : t) : provider_snapshot list =
    with_lock agg (fun () ->
      Hashtbl.fold
        (fun (k : aggregate_key) (s : aggregate_state) acc ->
           let provider, model_id =
             match String.index_opt k '/' with
             | Some i -> String.sub k 0 i, String.sub k (i + 1) (String.length k - i - 1)
             | None -> k, ""
           in
           { provider
           ; model_id
           ; request_total = s.request_total
           ; error_total = s.error_total
           ; retry_total = s.retry_total
           ; input_tokens_total = s.input_tokens_total
           ; output_tokens_total = s.output_tokens_total
           ; tool_call_total = s.tool_call_total
           ; latency_ms_sum = s.latency_ms_sum
           ; latency_ms_count = s.latency_ms_count
           ; ttfrc_ms_sum = s.ttfrc_ms_sum
           ; ttfrc_ms_count = s.ttfrc_ms_count
           ; inter_chunk_ms_sum = s.inter_chunk_ms_sum
           ; inter_chunk_ms_count = s.inter_chunk_ms_count
           }
           :: acc)
        agg.states
        [])
  ;;

  let snapshot_to_yojson agg = provider_snapshots_to_yojson (snapshot agg)

  let save_snapshot_json agg ~path =
    let payload = snapshot_to_yojson agg |> Yojson.Safe.pretty_to_string in
    write_file_atomic path payload
  ;;

  let reset (agg : t) = with_lock agg (fun () -> Hashtbl.reset agg.states)
end
