(** Voice config payload — returns public voice configuration as JSON. *)
let voice_config_payload () =
  match Voice_bridge.public_config_json () with
  | Ok json -> `OK, json
  | Error json -> `Error, json
;;
