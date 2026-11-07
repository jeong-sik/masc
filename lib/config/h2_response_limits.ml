(* RFC9113 section6.5.2 recommends allowing at least100 concurrent streams.
   The #37956 blocked-response experiment at100 streams retained25.8MB of
   payload. The listener's64MiB payload allocation accommodates that workload
   and is independently enforced for larger bodies and streaming queues. This
   is explicit transport memory capacity, not a Keeper time/turn budget. *)
let default_max_concurrent_streams = 100
let default_max_pending_bytes = 64 * 1024 * 1024

(* RFC 9113 §6.9.2 starts every stream with a 65,535-octet window and §6.5.2
   bounds SETTINGS_MAX_FRAME_SIZE to [2^14, 2^24 - 1]. Both defaults are the
   h2 library's; the keys exist so a measured change needs no rebuild. *)
let default_initial_window_size = 65535
let default_max_frame_size = 16384
let min_max_frame_size = 16384
let max_max_frame_size = 16777215

(* The largest value SETTINGS_MAX_CONCURRENT_STREAMS and
   SETTINGS_INITIAL_WINDOW_SIZE carry (RFC 9113 §6.5.2). *)
let max_settings_value = 0x7fffffff

let within ~name ~default ~min_value ~max_value =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value when value >= min_value && value <= max_value -> value
     | Some _ | None -> raise (Env_config_core.Config_error
       (Printf.sprintf "%s must be an integer in [%d,%d]" name min_value max_value)))

let max_concurrent_streams () =
  within ~name:"MASC_H2_MAX_CONCURRENT_STREAMS"
    ~default:default_max_concurrent_streams ~min_value:1 ~max_value:max_settings_value
let max_pending_bytes () =
  within ~name:"MASC_H2_MAX_PENDING_RESPONSE_BYTES"
    ~default:default_max_pending_bytes ~min_value:1 ~max_value:max_int
let initial_window_size () =
  within ~name:"MASC_H2_INITIAL_WINDOW_SIZE"
    ~default:default_initial_window_size ~min_value:1 ~max_value:max_settings_value
let max_frame_size () =
  within ~name:"MASC_H2_MAX_FRAME_SIZE"
    ~default:default_max_frame_size ~min_value:min_max_frame_size ~max_value:max_max_frame_size
