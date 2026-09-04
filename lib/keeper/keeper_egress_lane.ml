let ( let* ) = Result.bind

(* Same resolver SSOT the SSH lane uses (RFC-0121): runtime.toml lives under
   .masc/config/, and a hand-built path under the base has never named it. *)
let runtime_config_path ~base_path =
  let workspace_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if Sys.file_exists workspace_path then Some workspace_path else Runtime.config_path ()
;;

let resolve_allowlist ~base_path ~keeper_name =
  let* config_path =
    runtime_config_path ~base_path
    |> Option.to_result
         ~none:
           (Printf.sprintf
              "egress_runtime_config_missing: keeper %s is in the policy lane and \
               runtime.toml is unavailable, so what it may reach is unknown"
              keeper_name)
  in
  let* runtime_config =
    Runtime_toml.parse_file config_path
    |> Result.map_error (fun errors ->
      Printf.sprintf
        "egress_runtime_config_invalid: keeper %s: %s"
        keeper_name
        (errors |> List.map Runtime_toml.show_parse_error |> String.concat "; "))
  in
  (* No table is an empty allowlist rather than a failure. Omitting it is a
     coherent way to say "reaches nothing", and it is what a listener with no
     rules does anyway; refusing here would make the two spellings disagree. *)
  match
    Egress_allowlist.for_keeper runtime_config.Runtime_schema.egress_allowlists ~keeper_name
  with
  | None -> Ok []
  | Some entry -> Ok entry.Egress_allowlist.allow
;;

let listen_backlog = 16
let request_line_read_timeout_s = 10.0
let listen_address = `Tcp (Eio.Net.Ipaddr.V4.any, 0)
