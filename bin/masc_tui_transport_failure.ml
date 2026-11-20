module Http = Masc_http_client
module Pool = Masc_http_client.Pool

type t =
  | Request_domain_not_started
  | Client of Masc_http_client.failure

let request_domain_not_started =
  "masc-tui: a request was sent before its request domain started (a \
   bootstrap-order bug)"

let host_port (origin : Pool.origin) =
  Printf.sprintf "%s:%d" origin.Pool.host origin.Pool.port

(* What went wrong at [origin], said without the exception: the case is the
   fact, and the exception's text is the log's. *)
let connect_cause (origin : Pool.origin) (failure : Pool.connect_failure) =
  match failure with
  | Pool.No_addresses -> Printf.sprintf "%s resolves to no address" origin.Pool.host
  | Pool.Dns_failure _ -> Printf.sprintf "%s could not be resolved" origin.Pool.host
  | Pool.Tcp_failure _ ->
    Printf.sprintf "%s is not accepting connections" (host_port origin)
  | Pool.Establishment_timeout ->
    Printf.sprintf "%s did not finish connecting in time" (host_port origin)
  | Pool.Client_failure detail ->
    Printf.sprintf "%s connection setup failed: %s" (host_port origin) detail

(* Durations in the spellings of RFC tui-one-screen-grammar 6.2. A timeout is
   a setting, so it reads exactly in at most two units ([30s], [1m30s], [2m]).
   The wait before a retry is a coming moment and reads like one ([5s], [2m]).
   Both round up, so a wait under a second never reads [0s]. *)
let setting_text = Masc_tui_value.Interval.of_seconds

let retry_clause seconds =
  "; retry in " ^ Masc_tui_value.Ongoing.text (Float.ceil seconds)

let exchange_line ~verb ~url detail =
  Printf.sprintf "%s failed: %s (%s)" verb detail url

let line ~verb ~url = function
  | Request_domain_not_started -> request_domain_not_started
  | Client Http.Pool_unavailable -> Http.failure_to_string Http.Pool_unavailable
  | Client (Http.Request_failed error) ->
    (match error with
     | Pool.Connect_failed { origin; failure; retry = Pool.Retry_in seconds } ->
       connect_cause origin failure ^ retry_clause seconds
     | Pool.Connect_failed { origin; failure; retry = Pool.Retry_unblocked } ->
       connect_cause origin failure
     | Pool.Connect_held_back { origin; failure; retry_in_seconds } ->
       connect_cause origin failure ^ retry_clause retry_in_seconds
     | Pool.Timed_out { after_seconds } ->
       exchange_line ~verb ~url
         ("no answer within " ^ setting_text after_seconds)
     | Pool.Idle_timed_out { after_seconds } ->
       exchange_line ~verb ~url
         ("the response stopped for " ^ setting_text after_seconds)
     | Pool.Body_limit_exceeded { status; limit } ->
       exchange_line ~verb ~url
         (Printf.sprintf "the HTTP %d response is larger than %s bytes" status
            (Masc_tui_value.Count.grouped limit))
     | Pool.Exchange_failed detail -> exchange_line ~verb ~url detail
     | Pool.Invalid_request _ ->
       exchange_line ~verb ~url (Pool.request_error_to_string error))

(* Only an attempt that just failed carries news: a held-back request repeats
   the failure the attempt already logged. *)
let log ~verb ~url = function
  | Client (Http.Request_failed (Pool.Connect_failed _ as error)) ->
    Log.Transport.warn "http %s %s: %s" verb url (Pool.request_error_to_string error)
  | Client (Http.Request_failed
              ( Pool.Connect_held_back _ | Pool.Timed_out _ | Pool.Idle_timed_out _
              | Pool.Body_limit_exceeded _ | Pool.Exchange_failed _
              | Pool.Invalid_request _ ))
  | Client Http.Pool_unavailable | Request_domain_not_started -> ()

let report ~verb ~url failure =
  log ~verb ~url failure;
  Masc.Tui_terminal_text.sanitize_terminal_text (line ~verb ~url failure)
