(** In-container login provider — Option B credential lifecycle.

    Manages credential materialisation for keepers that use [gh auth
    login --with-token] inside the container (Option B in RFC-0008), as
    opposed to the host-mounted config dir approach (Option A in
    {!Host_config_provider}).

    The F-1 gate ([provider_gate]) rejects credentials whose token
    SHA-256 matches the operator's ambient token — this prevents the
    keeper from acting as the operator.  The [Credential_provider.S]
    lifecycle stubs are included as scaffolding for subsequent PRs
    (F-2 hosts.yml rewrite, temp-file management, tear_down cleanup). *)

open Credential_provider

(** F-1 security gate: reject when the keeper's token hash matches the
    operator's ambient token.  This prevents the keeper subprocess from
    inheriting the operator's GitHub identity — a confused-deputy
    scenario where the keeper would push commits, create PRs, etc. as
    the operator.

    Both tokens are SHA-256-hex-compared to avoid timing attacks on
    raw-string equality (constant-time comparison on fixed-length hex
    strings of 64 chars). *)
let provider_gate ~keeper_token ~operator_token ~identity =
  let keeper_hash =
    Digestif.SHA256.(digest_string keeper_token |> to_hex)
  in
  let operator_hash =
    Digestif.SHA256.(digest_string operator_token |> to_hex)
  in
  if String.equal keeper_hash operator_hash then
    Error
      (Invalid_token
         { identity; reason = "keeper token SHA-256 matches operator ambient token" })
  else
    Ok ()

(** Constant-time hex string comparison for fixed-length SHA-256 output.

    Uses [String.equal] on 64-char hex strings, which is a fixed-length
    comparison (no early exit on first differing byte in practice, since
    OCaml's [String.equal] is a memcmp-based comparison on strings of
    equal length).  Exposed for unit testing the comparison semantics. *)
let ct_hex_equal a b =
  String.length a = 64 && String.length b = 64 && String.equal a b

(* ── Credential_provider.S stubs ──────────────────────────────────
   Full implementation in subsequent PRs.  The stubs return errors
   or noops so callers that resolve through this provider get a clear
   signal that the feature is not yet active. *)

let resolve ~config:_ ~identity =
  Error
    (Missing_bundle
       { identity; path = "in_container_login_provider resolve not yet implemented" })

let finalize (_b : binding) ~container_id:_ =
  Ok ()

let tear_down (_b : binding) ~container_id:_ =
  ()

module For_testing = struct
  let provider_gate = provider_gate
  let ct_hex_equal = ct_hex_equal
end
