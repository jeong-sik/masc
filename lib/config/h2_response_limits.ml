(* RFC9113 section6.5.2 recommends allowing at least100 concurrent streams.
   The #37956 blocked-response experiment at100 streams retained25.8MB of
   payload. The listener's64MiB payload allocation accommodates that workload
   and is independently enforced for larger bodies and streaming queues. This
   is explicit transport memory capacity, not a Keeper time/turn budget. *)
let default_max_concurrent_streams = 100
let default_max_pending_bytes = 64 * 1024 * 1024

let positive ~name ~default ~max_value =
  match Env_config_core.raw_value_opt name with
  | None -> default
  | Some raw ->
    (match int_of_string_opt (String.trim raw) with
     | Some value when value >= 1 && value <= max_value -> value
     | Some _ | None -> raise (Env_config_core.Config_error
       (Printf.sprintf "%s must be an integer in [1,%d]" name max_value)))

let max_concurrent_streams () =
  positive ~name:"MASC_H2_MAX_CONCURRENT_STREAMS"
    ~default:default_max_concurrent_streams ~max_value:0x7fffffff
let max_pending_bytes () =
  positive ~name:"MASC_H2_MAX_PENDING_RESPONSE_BYTES"
    ~default:default_max_pending_bytes ~max_value:max_int
