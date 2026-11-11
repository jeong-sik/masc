(** See [https_listener_metrics.mli]. *)

type certificate_source =
  | Configured
  | Self_signed

let certificate_source_to_string = function
  | Configured -> "configured"
  | Self_signed -> "self_signed"
;;

type certificate =
  { source : certificate_source
  ; not_after : Ptime.t
  }

type status =
  | Off
  | Not_started
  | Bind_failed
  | Listening
  | Stopped
  | Accept_error

let status_to_string = function
  | Off -> "off"
  | Not_started -> "not_started"
  | Bind_failed -> "bind_failed"
  | Listening -> "listening"
  | Stopped -> "stopped"
  | Accept_error -> "accept_error"
;;

type negotiated =
  | Alpn_h2
  | Alpn_http1
  | Alpn_none

let negotiated_label = function
  | Alpn_h2 -> "h2"
  | Alpn_http1 -> "http/1.1"
  | Alpn_none -> "none"
;;

let negotiated_all = [ Alpn_h2; Alpn_http1; Alpn_none ]
let metric_accepts = "masc_https_accepts_total"
let metric_alpn = "masc_https_alpn_total"
let metric_handshake_failures = "masc_https_handshake_failures_total"
let metric_accept_errors = "masc_https_accept_errors_total"
let metric_active_connections = "masc_https_active_connections"

let () =
  Otel_metric_store.register_counter
    ~name:metric_accepts
    ~help:"TCP connections the HTTPS listener accepted"
    ();
  List.iter
    (fun negotiated ->
      Otel_metric_store.register_counter
        ~name:metric_alpn
        ~help:"Completed TLS handshakes by ALPN result"
        ~labels:[ "protocol", negotiated_label negotiated ]
        ())
    negotiated_all;
  Otel_metric_store.register_counter
    ~name:metric_handshake_failures
    ~help:"TLS handshakes that ended before an application protocol was chosen"
    ();
  Otel_metric_store.register_counter
    ~name:metric_accept_errors
    ~help:"accept failures of the HTTPS listener"
    ();
  Otel_metric_store.register_gauge
    ~name:metric_active_connections
    ~help:"Open connections of the HTTPS listener"
    ()
;;

let status_cell = Atomic.make Off
let port_cell : int option Atomic.t = Atomic.make None
let certificate_cell : certificate option Atomic.t = Atomic.make None
let active = Atomic.make 0
let accepted = Atomic.make 0
let alpn_h2 = Atomic.make 0
let alpn_http1 = Atomic.make 0
let alpn_none = Atomic.make 0
let handshake_failures = Atomic.make 0
let accept_errors = Atomic.make 0
let last_accept_unix : float option Atomic.t = Atomic.make None
let last_error : string option Atomic.t = Atomic.make None

type source_listener = { notify : unit -> unit }
let source_listeners : source_listener list Atomic.t = Atomic.make []
let source_notification_failures = Atomic.make 0

let rec update_source_listeners update =
  let previous = Atomic.get source_listeners in
  if not (Atomic.compare_and_set source_listeners previous (update previous)) then
    update_source_listeners update
;;

let subscribe_source_changed notify =
  let listener = { notify } in
  update_source_listeners (fun previous -> listener :: previous);
  fun () -> update_source_listeners (List.filter (fun current -> current != listener))
;;

let notify_source_changed () =
  List.iter (fun listener ->
    match listener.notify () with
    | () -> ()
    | exception _ ->
      (* cancel-guard-ok: preserve the lifecycle source result. *)
      ignore (Atomic.fetch_and_add source_notification_failures 1))
    (Atomic.get source_listeners)
;;

let with_source_change update = Fun.protect ~finally:notify_source_changed update

(* Writes a state cell and says whether its value moved; see
   [Transport_metrics.cell_moved]. A connection notifies only when it moved
   the listener's status or last error. *)
let cell_moved cell value = Atomic.exchange cell value <> value

let set_active_gauge value =
  Otel_metric_store.set_gauge metric_active_connections (float_of_int (max 0 value))
;;

let configure ~port ~certificate =
  with_source_change (fun () ->
    Atomic.set port_cell (Some port);
    Atomic.set certificate_cell (Some certificate);
    Atomic.set status_cell Not_started)
;;

let record_bind_failure ~error =
  with_source_change (fun () ->
    Atomic.set status_cell Bind_failed;
    Atomic.set last_error (Some error))
;;

let record_started () = with_source_change (fun () -> Atomic.set status_cell Listening)
let record_stopped () = with_source_change (fun () -> Atomic.set status_cell Stopped)

let record_accept () =
  let status_moved = cell_moved status_cell Listening in
  let error_cleared = cell_moved last_error None in
  Atomic.set last_accept_unix (Some (Unix.gettimeofday ()));
  ignore (Atomic.fetch_and_add accepted 1);
  Otel_metric_store.inc_counter metric_accepts ();
  set_active_gauge (Atomic.fetch_and_add active 1 + 1);
  if status_moved || error_cleared then notify_source_changed ()
;;

let rec dec_active () =
  let before = Atomic.get active in
  let after = max 0 (before - 1) in
  if Atomic.compare_and_set active before after then after else dec_active ()
;;

let record_connection_closed () = set_active_gauge (dec_active ())

let record_negotiated negotiated =
  let cell =
    match negotiated with
    | Alpn_h2 -> alpn_h2
    | Alpn_http1 -> alpn_http1
    | Alpn_none -> alpn_none
  in
  ignore (Atomic.fetch_and_add cell 1);
  Otel_metric_store.inc_counter
    metric_alpn
    ~labels:[ "protocol", negotiated_label negotiated ]
    ()
;;

let record_handshake_failure () =
  ignore (Atomic.fetch_and_add handshake_failures 1);
  Otel_metric_store.inc_counter metric_handshake_failures ()
;;

let record_accept_error ~error =
  let status_moved = cell_moved status_cell Accept_error in
  let error_moved = cell_moved last_error (Some error) in
  ignore (Atomic.fetch_and_add accept_errors 1);
  Otel_metric_store.inc_counter metric_accept_errors ();
  if status_moved || error_moved then notify_source_changed ()
;;

let status () = Atomic.get status_cell

let certificate_json = function
  | None -> `Null
  | Some { source; not_after } ->
    `Assoc
      [ "source", `String (certificate_source_to_string source)
      ; "not_after", `String (Ptime.to_rfc3339 ~tz_offset_s:0 not_after)
      ]
;;

let json ?now () =
  let now =
    match now with
    | Some value -> value
    | None -> Unix.gettimeofday ()
  in
  let last_accept_unix = Atomic.get last_accept_unix in
  let last_accept_age_seconds =
    Option.map (fun ts -> Float.max 0.0 (now -. ts)) last_accept_unix
  in
  `Assoc
    [ "status", `String (status_to_string (Atomic.get status_cell))
    ; "port", Json_util.int_opt_to_json (Atomic.get port_cell)
    ; "certificate", certificate_json (Atomic.get certificate_cell)
    ; "active_connections", `Int (Atomic.get active)
    ; "accepted_total", `Int (Atomic.get accepted)
    ; "alpn_h2_total", `Int (Atomic.get alpn_h2)
    ; "alpn_http1_total", `Int (Atomic.get alpn_http1)
    ; "alpn_none_total", `Int (Atomic.get alpn_none)
    ; "handshake_failures_total", `Int (Atomic.get handshake_failures)
    ; "accept_errors_total", `Int (Atomic.get accept_errors)
    ; "source_notification_failures", `Int (Atomic.get source_notification_failures)
    ; "last_accept_unix", Json_util.float_opt_to_json last_accept_unix
    ; "last_accept_age_seconds", Json_util.float_opt_to_json last_accept_age_seconds
    ; "last_error", Json_util.string_opt_to_json (Atomic.get last_error)
    ]
;;
