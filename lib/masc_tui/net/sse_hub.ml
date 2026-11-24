open Masc_tui_core
open Masc_tui_protocol

module Stream_spec = struct
  type kind =
    | Observer
    | Fleet
    | Model_metrics
    | Tool_metrics_series
    | Logs of { since_seq : int option }

  type t = {
    kind : kind;
    stale_after_s : float;
    idle_timeout_s : float;
  }

  let id = function
    | Observer -> "observer"
    | Fleet -> "fleet"
    | Model_metrics -> "model_metrics"
    | Tool_metrics_series -> "tool_metrics_series"
    | Logs _ -> "logs"

  let path = function
    | Observer -> Wire_observer.observer_stream_path
    | Fleet -> Wire_fleet.fleet_stream_path
    | Model_metrics -> Wire_runtime.models_metrics_stream_path
    | Tool_metrics_series -> "/api/v1/tool-metrics/series/stream"
    | Logs { since_seq } -> Wire_infra.system_logs_stream_path ?since_seq ()

  let is_persistent = function
    | Observer | Fleet -> true
    | Model_metrics | Tool_metrics_series | Logs _ -> false

  let equal_kind a b =
    match (a, b) with
    | Observer, Observer -> true
    | Fleet, Fleet -> true
    | Model_metrics, Model_metrics -> true
    | Tool_metrics_series, Tool_metrics_series -> true
    | Logs x, Logs y -> Option.equal Int.equal x.since_seq y.since_seq
    | (Observer | Fleet | Model_metrics | Tool_metrics_series | Logs _), _ ->
        false

  let equal a b =
    equal_kind a.kind b.kind
    && Float.equal a.stale_after_s b.stale_after_s
    && Float.equal a.idle_timeout_s b.idle_timeout_s

  let default_observer =
    { kind = Observer; stale_after_s = 65.0; idle_timeout_s = 90.0 }

  let default_fleet =
    { kind = Fleet; stale_after_s = 65.0; idle_timeout_s = 90.0 }

  let model_metrics =
    { kind = Model_metrics; stale_after_s = 65.0; idle_timeout_s = 90.0 }

  let tool_metrics_series =
    { kind = Tool_metrics_series; stale_after_s = 65.0; idle_timeout_s = 90.0 }

  let logs ?since_seq () =
    { kind = Logs { since_seq }; stale_after_s = 65.0; idle_timeout_s = 90.0 }
end

type sync_diff = {
  to_start : Stream_spec.t list;
  to_stop : Stream_spec.kind list;
  kept : Stream_spec.kind list;
}

let max_persistent_streams = 2
let max_view_scoped_streams = 1

let validate_desired desired =
  let deduped =
    List.fold_left
      (fun acc (spec : Stream_spec.t) ->
        if
          List.exists
            (fun (s : Stream_spec.t) -> Stream_spec.equal_kind s.kind spec.kind)
            acc
        then acc
        else spec :: acc)
      [] desired
    |> List.rev
  in
  let persistent_count =
    List.fold_left
      (fun n (s : Stream_spec.t) ->
        if Stream_spec.is_persistent s.kind then n + 1 else n)
      0 deduped
  in
  let view_count = List.length deduped - persistent_count in
  if persistent_count > max_persistent_streams then
    Error
      (Printf.sprintf "requested %d persistent streams (max %d)"
         persistent_count max_persistent_streams)
  else if view_count > max_view_scoped_streams then
    Error
      (Printf.sprintf "requested %d view-scoped streams (max %d)" view_count
         max_view_scoped_streams)
  else Ok deduped

let diff_streams ~active ~desired =
  let to_stop =
    List.filter_map
      (fun (a : Stream_spec.t) ->
        if List.exists (fun (d : Stream_spec.t) -> Stream_spec.equal a d) desired
        then None
        else Some a.kind)
      active
  in
  let to_start =
    List.filter
      (fun (d : Stream_spec.t) ->
        not (List.exists (fun (a : Stream_spec.t) -> Stream_spec.equal a d) active))
      desired
  in
  let kept =
    List.filter_map
      (fun (a : Stream_spec.t) ->
        if List.exists (fun (d : Stream_spec.t) -> Stream_spec.equal a d) desired
        then Some a.kind
        else None)
      active
  in
  { to_start; to_stop; kept }

let reconnect_delay_s ~attempt ~jitter_unit =
  let exp_step = min 5 (max 0 (attempt - 1)) in
  let base = Float.min 10.0 (0.5 *. Float.ldexp 1.0 exp_step) in
  let j = Float.max (-1.0) (Float.min 1.0 jitter_unit) in
  Float.max 0.1 (base *. (1.0 +. (0.2 *. j)))

let next_reconnect_attempt ~prev_attempt ~reached_live =
  if reached_live then 1 else prev_attempt + 1

type handshake_outcome =
  | Handshake_ok of Wire_observer.handshake_result
  | Handshake_retry_without_cursor of {
      stale_cursor : Sse_wire.observer_cursor;
      reason : string;
    }
  | Handshake_invalid of string

let evaluate_observer_handshake ~cursor ~headers =
  match Wire_observer.validate_handshake ~cursor ~headers with
  | Ok res -> Handshake_ok res
  | Error (Sse_wire.Retry_without_cursor (stale_cursor, reason)) ->
      Handshake_retry_without_cursor { stale_cursor; reason }
  | Error (Sse_wire.Invalid_observer_response reason) ->
      Handshake_invalid reason

type hub_event =
  | Freshness of {
      stream : Stream_spec.kind;
      freshness : Health.source_freshness;
    }
  | Observer_handshake of Wire_observer.handshake_result
  | Observer_delivery of Wire_observer.delivery
  | Fleet_event of Wire_fleet.fleet_stream_event
  | Raw_frame of { stream : Stream_spec.kind; frame : Sse_wire.frame }

type active_entry = {
  generation : int;
  cancelled : bool Atomic.t;
  spec : Stream_spec.t;
  handle : Io_domain.stream_handle;
}

type t = {
  io : Io_domain.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  endpoint : Http_client.endpoint Atomic.t;
  on_event : hub_event -> unit;
  next_gen : int Atomic.t;
  mu : Eio.Mutex.t;
  mutable active : active_entry list;
}

let create ~io ~clock ~endpoint ~on_event =
  {
    io;
    clock = (clock :> float Eio.Time.clock_ty Eio.Resource.t);
    endpoint = Atomic.make endpoint;
    on_event;
    next_gen = Atomic.make 0;
    mu = Eio.Mutex.create ();
    active = [];
  }

let update_endpoint t ep = Atomic.set t.endpoint ep

exception Handshake_rejected of handshake_outcome

let emit_if_active t ~cancelled ev =
  if not (Atomic.get cancelled) then t.on_event ev

let emit_freshness_if_active t ~cancelled stream freshness =
  emit_if_active t ~cancelled (Freshness { stream; freshness })

let remove_active_generation t ~generation =
  Eio.Mutex.use_rw ~protect:true t.mu (fun () ->
      t.active <-
        List.filter (fun e -> not (Int.equal e.generation generation)) t.active)

let dispatch_frame t ~cancelled (spec : Stream_spec.t)
    ~(revision_ref : int Atomic.t)
    ~(cursor_ref : Sse_wire.observer_cursor option Atomic.t)
    ~(instance_id_ref : string option Atomic.t) (frame : Sse_wire.frame) =
  match spec.kind with
  | Stream_spec.Observer ->
      let delivery = Wire_observer.decode_frame frame in
      (match (delivery.cursor, Atomic.get instance_id_ref) with
      | Some event_id, Some instance_id ->
          Atomic.set revision_ref event_id;
          Atomic.set cursor_ref (Some { Sse_wire.instance_id; event_id })
      | Some event_id, None -> Atomic.set revision_ref event_id
      | None, _ -> ());
      emit_if_active t ~cancelled (Observer_delivery delivery)
  | Stream_spec.Fleet -> (
      match Yojson.Safe.from_string frame.data with
      | json -> (
          match Wire_fleet.decode_fleet_stream_event json with
          | Ok ev ->
              let rev =
                match ev with
                | Wire_fleet.Fleet_snapshot { revision; _ }
                | Wire_fleet.Fleet_changed { revision; _ }
                | Wire_fleet.Fleet_unavailable_snapshot { revision; _ }
                | Wire_fleet.Fleet_degraded { revision; _ } ->
                    revision
              in
              Atomic.set revision_ref rev;
              emit_if_active t ~cancelled (Fleet_event ev)
          | Error _ ->
              emit_if_active t ~cancelled (Raw_frame { stream = spec.kind; frame }))
      | exception Yojson.Json_error _ ->
          emit_if_active t ~cancelled (Raw_frame { stream = spec.kind; frame }))
  | Stream_spec.Model_metrics | Stream_spec.Tool_metrics_series
  | Stream_spec.Logs _ ->
      emit_if_active t ~cancelled (Raw_frame { stream = spec.kind; frame })

let run_stream_loop t ~generation ~cancelled (spec : Stream_spec.t) ~sw =
  Eio.Switch.check sw;
  let rng = Random.State.make_self_init () in
  let last_live_ns = Atomic.make (-1L) in
  let is_connected = Atomic.make false in
  let reported_stale = Atomic.make false in
  let revision_ref = Atomic.make 0 in
  let last_emitted_rev = Atomic.make (-1) in
  let cursor_ref : Sse_wire.observer_cursor option Atomic.t =
    Atomic.make None
  in
  let instance_id_ref : string option Atomic.t = Atomic.make None in
  if Float.is_finite spec.stale_after_s && spec.stale_after_s > 0.0 then
    Eio.Fiber.fork_daemon ~sw (fun () ->
        let poll_s = Float.max 0.25 (spec.stale_after_s /. 2.0) in
        let rec watch () =
          Eio.Switch.check sw;
          Eio.Time.sleep t.clock poll_s;
          if (not (Atomic.get cancelled)) && Atomic.get is_connected then begin
            let last_ns = Atomic.get last_live_ns in
            if last_ns >= 0L then begin
              let last_mono = Clock.Mono.of_ns last_ns in
              let age_sec =
                Clock.Mono.seconds_since (Clock.Mono.now ()) ~since:last_mono
              in
              if age_sec >= spec.stale_after_s then begin
                Atomic.set reported_stale true;
                emit_freshness_if_active t ~cancelled spec.kind
                  (Health.Stale { last_live_ns = last_mono; age_sec })
              end
            end
          end;
          watch ()
        in
        watch ());
  let last_live_opt () =
    let ns = Atomic.get last_live_ns in
    if ns >= 0L then Some (Clock.Mono.of_ns ns) else None
  in
  let rec loop ~attempt =
    Eio.Switch.check sw;
    if Atomic.get cancelled then ()
    else begin
      if attempt = 0 then
        emit_freshness_if_active t ~cancelled spec.kind Health.Connecting;
      let reached_live = Atomic.make false in
      let mark_live () =
        let now = Clock.Mono.now () in
        Atomic.set last_live_ns (Clock.Mono.to_ns now);
        Atomic.set reached_live true;
        let was_connected = Atomic.exchange is_connected true in
        let was_stale = Atomic.exchange reported_stale false in
        let rev = Atomic.get revision_ref in
        let prev_rev = Atomic.get last_emitted_rev in
        if (not was_connected) || was_stale || rev <> prev_rev then begin
          Atomic.set last_emitted_rev rev;
          emit_freshness_if_active t ~cancelled spec.kind
            (Health.Live { last_event_ns = now; revision = rev })
        end
      in
      let ep = Atomic.get t.endpoint in
      let stream_path = Stream_spec.path spec.kind in
      let url = Http_client.build_url ep ~path:stream_path in
      let cursor_headers =
        match spec.kind with
        | Stream_spec.Observer ->
            Sse_wire.observer_cursor_headers (Atomic.get cursor_ref)
        | Stream_spec.Fleet | Stream_spec.Model_metrics
        | Stream_spec.Tool_metrics_series | Stream_spec.Logs _ ->
            []
      in
      let headers =
        Http_client.build_headers
          ~extra:(("Accept", "text/event-stream") :: cursor_headers)
          ep
      in
      let decoder = Sse_wire.create_decoder () in
      let on_response ~status ~headers:resp_headers =
        if status >= 200 && status <= 299 then begin
          (match spec.kind with
          | Stream_spec.Observer -> (
              let requested_cursor = Atomic.get cursor_ref in
              match
                evaluate_observer_handshake ~cursor:requested_cursor
                  ~headers:resp_headers
              with
              | Handshake_ok res ->
                  (match res.handshake with
                  | Some hs -> Atomic.set instance_id_ref (Some hs.instance_id)
                  | None -> ());
                  emit_if_active t ~cancelled (Observer_handshake res)
              | (Handshake_retry_without_cursor _ | Handshake_invalid _) as bad
                ->
                  raise (Handshake_rejected bad))
          | Stream_spec.Fleet | Stream_spec.Model_metrics
          | Stream_spec.Tool_metrics_series | Stream_spec.Logs _ ->
              ());
          mark_live ()
        end
      in
      let on_chunk chunk =
        let frames = Sse_wire.feed decoder chunk in
        List.iter
          (dispatch_frame t ~cancelled spec ~revision_ref ~cursor_ref
             ~instance_id_ref)
          frames;
        mark_live ()
      in
      let outcome =
        match
          Masc_http_client.request_stream
            ~retention:Masc_http_client.Pool.Discard_body ~clock:t.clock
            ~idle_timeout_sec:spec.idle_timeout_s ~method_:`GET ~url ~headers
            ~on_response ~on_chunk ()
        with
        | res -> `Result res
        | exception (Eio.Cancel.Cancelled _ as cancelled_exn) ->
            raise cancelled_exn
        | exception Handshake_rejected outcome -> `Handshake_rejected outcome
      in
      Atomic.set is_connected false;
      let schedule_reconnect reason =
        let next_attempt =
          next_reconnect_attempt ~prev_attempt:attempt
            ~reached_live:(Atomic.get reached_live)
        in
        emit_freshness_if_active t ~cancelled spec.kind
          (Health.Reconnecting
             { last_live_ns = last_live_opt (); attempt = next_attempt; reason });
        Eio.Switch.check sw;
        let delay =
          reconnect_delay_s ~attempt:next_attempt
            ~jitter_unit:((Random.State.float rng 2.0) -. 1.0)
        in
        Eio.Time.sleep t.clock delay;
        loop ~attempt:next_attempt
      in
      match outcome with
      | `Handshake_rejected
          (Handshake_retry_without_cursor { stale_cursor; reason }) ->
          (match Atomic.get cursor_ref with
          | Some cur
            when String.equal cur.instance_id stale_cursor.instance_id
                 && cur.event_id = stale_cursor.event_id ->
              Atomic.set cursor_ref None
          | Some _ | None -> ());
          schedule_reconnect (Health.Protocol_error reason)
      | `Handshake_rejected (Handshake_invalid reason) ->
          schedule_reconnect (Health.Protocol_error reason)
      | `Handshake_rejected (Handshake_ok _) ->
          schedule_reconnect (Health.Protocol_error "unexpected handshake retry")
      | `Result (Ok (Masc_http_client.Pool.Buffered resp)) -> (
          match
            Http_client.classify_response ep ~status:resp.status ~body:resp.body
          with
          | Error
              (Http_client.Workspace_mismatch
                { expected_instance; observed_instance; _ }) ->
              emit_freshness_if_active t ~cancelled spec.kind
                (Health.Workspace_mismatch
                   {
                     expected_instance = Option.value ~default:"" expected_instance;
                     observed_instance = Option.value ~default:"" observed_instance;
                   });
              (* Remove this exited stream from [t.active] so [sync_streams] can
                 restart it cleanly after [update_endpoint]. *)
              remove_active_generation t ~generation
          | Error
              ( Http_client.Transport _
              | Http_client.Http_error _
              | Http_client.Decode_error _ )
          | Ok _ ->
              schedule_reconnect (Health.Http_status resp.status))
      | `Result (Ok (Masc_http_client.Pool.Streamed _)) ->
          schedule_reconnect Health.Stream_eof
      | `Result (Error failure) ->
          schedule_reconnect
            (Http_client.transport_error_of_failure ~path:stream_path
               ~streaming:true failure)
    end
  in
  loop ~attempt:0

let sync_streams t desired =
  match validate_desired desired with
  | Error _ as err -> err
  | Ok valid_desired ->
      let diff, unsubscribed_kinds =
        Eio.Mutex.use_rw ~protect:true t.mu (fun () ->
            let active_specs = List.map (fun e -> e.spec) t.active in
            let diff = diff_streams ~active:active_specs ~desired:valid_desired in
            let stop_entries, keep_entries =
              List.partition
                (fun e ->
                  List.exists (Stream_spec.equal_kind e.spec.kind) diff.to_stop)
                t.active
            in
            List.iter
              (fun e ->
                Atomic.set e.cancelled true;
                Io_domain.cancel_stream e.handle)
              stop_entries;
            let started_entries =
              List.map
                (fun spec ->
                  let generation = Atomic.fetch_and_add t.next_gen 1 in
                  let cancelled = Atomic.make false in
                  let handle =
                    Io_domain.spawn_stream t.io (fun ~sw ->
                        run_stream_loop t ~generation ~cancelled spec ~sw)
                  in
                  { generation; cancelled; spec; handle })
                diff.to_start
            in
            t.active <- keep_entries @ started_entries;
            let unsubscribed =
              List.filter_map
                (fun e ->
                  if
                    List.exists
                      (fun (s : Stream_spec.t) ->
                        Stream_spec.equal_kind s.kind e.spec.kind)
                      diff.to_start
                  then None
                  else Some e.spec.kind)
                stop_entries
            in
            (diff, unsubscribed))
      in
      let now = Clock.Mono.now () in
      List.iter
        (fun kind ->
          t.on_event
            (Freshness
               {
                 stream = kind;
                 freshness =
                   Health.Disconnected { since_ns = now; reason = Health.Stream_eof };
               }))
        unsubscribed_kinds;
      Ok diff

let active_streams t =
  Eio.Mutex.use_ro t.mu (fun () -> List.map (fun e -> e.spec) t.active)

let shutdown t =
  let entries =
    Eio.Mutex.use_rw ~protect:true t.mu (fun () ->
        let old = t.active in
        t.active <- [];
        List.iter
          (fun e ->
            Atomic.set e.cancelled true;
            Io_domain.cancel_stream e.handle)
          old;
        old)
  in
  let now = Clock.Mono.now () in
  List.iter
    (fun e ->
      t.on_event
        (Freshness
           {
             stream = e.spec.kind;
             freshness =
               Health.Disconnected { since_ns = now; reason = Health.Stream_eof };
           }))
    entries
