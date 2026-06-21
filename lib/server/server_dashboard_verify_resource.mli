(** Read-only verification of operator-supplied Settings resources (RFC-0273 §3.4).

    Replaces the dashboard {b VerifyBtn} fake (settings-surface.ts, which always
    landed on "✓ 정상" via a 700ms [setTimeout] with zero network activity).

    Boundary vs {!Server_dashboard_http_runtime_info} runtime-probe: the
    runtime-probe only probes URLs read from the server's own [runtime.toml]
    SSOT. This module verifies values the {e caller supplies} in the request
    body, so the HTTP path is an SSRF surface and the filesystem path is an
    info-disclosure surface. The route ([POST /api/v1/dashboard/verify-resource])
    is therefore gated behind operator ([CanAdmin]) auth at the call site —
    stricter than the public-read runtime-probe.

    Scope (RFC-0273 §3.4, Option A): real verification for HTTP endpoints
    ([Mcp_endpoint], [Gate_url]) and filesystem paths ([Worktree_path]). DB
    connection strings and GitHub repo refs are deferred to a follow-up (they
    need DB-ping / GitHub-API infra and their own credential boundary); the
    frontend renders an honest "수동 확인" state for those rather than a
    fabricated success. *)

type kind =
  | Mcp_endpoint  (** an HTTP(S) MCP endpoint URL — reachability via GET *)
  | Gate_url  (** an HTTP(S) external-gate base URL — reachability via GET *)
  | Worktree_path  (** a server-local filesystem directory — existence via stat *)

val kind_of_string : string -> (kind, string) result
(** Parse a verify [kind]. An unrecognized kind returns [Error]; it is never
    coerced to a permissive default (AI anti-pattern §2 "unknown → permissive
    default"). *)

type outcome = {
  ok : bool;  (** the resource was verified to be reachable / present *)
  detail : string;  (** human-readable explanation (status text, error, …) *)
  http_status : int option;  (** the observed HTTP status for HTTP kinds *)
  target : string;
      (** the verified value echoed back, sanitized for HTTP kinds (userinfo /
          query / fragment stripped per RFC-0132) so credentials never leak *)
}

val verify : kind:kind -> value:string -> outcome
(** [verify ~kind ~value] runs the read-only probe. It never raises: connection
    failures, timeouts, unresolved hosts, and missing paths all surface as
    [{ ok = false; detail = <reason>; _ }]. No write, no credential exposure. *)

val to_json : kind:kind -> outcome -> Yojson.Safe.t
(** Encode an [outcome] as the dashboard JSON response
    [{ ok; kind; detail; target; http_status }]. *)

val parse_request : string -> (kind * string, string) result
(** Parse the POST body [{ "kind": <string>; "value": <string> }]. Missing or
    non-string fields, malformed JSON, and unknown kinds all return [Error]. *)

(** {1 Test hooks}

    Mirrors {!Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests}:
    inject a deterministic HTTP-status function so the HTTP verify path is unit
    testable without real network IO. *)

val set_http_get_for_tests : (url:string -> (int, string) result) -> unit
val clear_http_get_for_tests : unit -> unit
