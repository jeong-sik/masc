(** JSON-RPC 2.0 + MCP server-defined error code variant (RFC-0097).

    Closed sum type. Adding a new variant requires RFC-level discussion;
    there is no [Other] escape hatch by design — the absence forces
    contributors to either reuse {!Internal_error} (and accept the lint
    comment requirement) or RFC the new code.

    Wire codes follow JSON-RPC 2.0 §5.1:
    - Well-known: -32700, -32600, -32601, -32602, -32603
    - Implementation-defined: -32000 to -32099 (server) *)

type t =
  | Parse_error           (** -32700 — JSON parse failed at the transport layer. *)
  | Invalid_request       (** -32600 — request was not a well-formed JSON-RPC object. *)
  | Method_not_found      (** -32601 — method/tool name unknown to the server. *)
  | Invalid_params        (** -32602 — params do not match the method schema. *)
  | Internal_error        (** -32603 — last-resort catch-all.  PRs MUST justify
                              in a code comment why no specific variant fits. *)
  | Auth_error            (** -32001 — unauthenticated or token rejected. *)
  | Not_ready             (** -32002 — server is starting up; [Retry-After] header
                              SHOULD be hinted by the response factory. *)
  | Provider_timeout      (** -32003 — upstream LLM/tool provider stalled past
                              the call-site budget. *)
  | Tool_dispatch_failure (** -32004 — tool exists and was dispatched but
                              execution failed at runtime. *)
  | Backpressure_shed     (** -32005 — mailbox / pool capacity exceeded;
                              client SHOULD resume via Last-Event-ID. *)
  | Session_evicted       (** -32006 — session lifecycle terminated by server
                              policy (oldest-eviction at cap, idle timeout). *)
  | Quiet of { reason : string ; recovered : bool }
        (** -32099 — last-resort silent-skip annotation.

            "Skipping is OK here" must be DECLARED — never inferred.
            [reason] is non-empty operator-visible text describing why the
            skip is intentional; [recovered] discriminates self-healed
            (true: a fallback succeeded) from data-loss (false: the
            failed operation produced no observable downstream effect).

            The lint extension in {!Anti_fake_audit_production_scan}
            (scripts/anti-fake-audit.sh --production-scan) requires
            every [Quiet] construction to carry non-empty [reason]; an
            empty-string [reason] is treated as a missing declaration
            and fails the gate. *)

val to_wire_code : t -> int
(** [to_wire_code t] returns the integer JSON-RPC error code that goes
    into the [error.code] slot of the response. Stable across releases
    — clients pin on these integers. *)

val of_wire_code : int -> t option
(** Inverse of {!to_wire_code} for well-known codes.

    [None] for codes outside the closed variant, including any
    [-32099 Quiet] response (the [reason]/[recovered] payload is not
    derivable from the integer alone). *)

val to_wire_message_default : t -> string
(** Default English [error.message] string. Callers may override by
    passing a more specific message to {!respond_mcp_error}; this is
    the fallback when the caller has nothing better to say.

    These strings are operator-visible in JSON bodies — keep them stable
    across builds so grep alerts remain valid (matches the existing
    {!Server_mcp_transport_http_respond} contract for [respond_not_ready]).
*)

val to_http_status : t -> Httpun.Status.t
(** Mapping from error code to HTTP status, colocated with the variant
    so the transport cannot drift from envelope semantics.

    [Quiet _] returns [`OK] — by definition a quiet skip is not a
    failure response, and embedding the [Quiet] envelope in a 200
    response body lets clients see the declaration without HTTP
    error-handling kicking in. *)

val all : t list
(** Enumerable list of every constructor, with a canonical exemplar for
    [Quiet] (reason = ["<exemplar>"], recovered = false). Used by
    {!test/test_mcp_error_code.ml} to assert wire-code uniqueness. *)

val pp : Format.formatter -> t -> unit
(** Pretty-printer for test failures and operator diagnostics. *)
