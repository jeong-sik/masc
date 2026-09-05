let ( let* ) = Result.bind

(* Same resolver SSOT the SSH lane uses (RFC-0121): runtime.toml lives under
   .masc/config/, and a hand-built path under the base has never named it. *)
let runtime_config_path ~base_path =
  let workspace_path = Config_dir_resolver.runtime_toml_path_for_base_path ~base_path in
  if Sys.file_exists workspace_path then Some workspace_path else Runtime.config_path ()
;;

(* Which file governs this keeper, decided once.

   The lane re-reads its rules per request, and for a while it re-decided
   this too. That put the workspace-or-global choice inside the window an
   editor opens when it saves by temp-and-rename: for the moment the
   workspace file does not exist, [Sys.file_exists] says no and the request
   is answered by the *global* file -- different rules, reported as an
   ordinary read, and then cached as the last set that parsed.

   Which file governs a keeper is a fact about the deployment, not about the
   request. It is settled at lane start; after that only its contents are
   read, and a file that vanishes mid-lane is a read failure, which the
   caller already knows how to hold. *)
let resolve_config_path ~base_path ~keeper_name =
  runtime_config_path ~base_path
  |> Option.to_result
       ~none:
         (Printf.sprintf
            "egress_runtime_config_missing: keeper %s is in the policy lane and \
             runtime.toml is unavailable, so what it may reach is unknown"
            keeper_name)
;;

let read_allowlist ~config_path ~keeper_name =
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
