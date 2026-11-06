(** The registry tables of the Runtime TOML parser that sit beside the
    provider layers: SSH exec endpoints, egress allowlists (RFC-0415) and LSP
    servers. *)

open Runtime_toml_base

val parse_egress_allowlists :
  Otoml.t ->
  (Egress_allowlist.t list, parse_error list) result

val parse_exec_endpoints :
  Otoml.t ->
  (Exec_ssh_endpoint.t list, parse_error list) result

val parse_lsp_servers :
  Otoml.t ->
  ((string * (string * string list)) list,
   parse_error list)
  result
