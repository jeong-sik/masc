(** Pin the typed-error -> dashboard auth-error-code mapping.

    [Masc_error.dashboard_auth_error_code] is the SSOT consumed by both
    the dashboard shell summary JSON and the HTTP 401/403 error body
    ([Server_auth.auth_error_json]). The dashboard keeper stream retry
    gate dispatches on these codes (TS enum in
    dashboard/src/types/dashboard-execution.ts) instead of
    substring-matching the error message. This suite locks the
    per-variant mapping so a drift between the two server surfaces, or a
    code rename, fails a test rather than silently breaking the client
    gate. *)

module E = Masc_error

let check label expected actual =
  if expected <> actual then (
    Printf.eprintf
      "test_masc_error_dashboard_auth_code: %s expected=%s got=%s\n" label
      (match expected with Some s -> s | None -> "<none>")
      (match actual with Some s -> s | None -> "<none>");
    exit 1)

let () =
  check "invalid_token" (Some "invalid_token")
    (E.dashboard_auth_error_code (E.Auth (E.Auth_error.InvalidToken "x")));
  check "token_expired" (Some "token_expired")
    (E.dashboard_auth_error_code (E.Auth (E.Auth_error.TokenExpired "agent")));
  check "same_origin_blocked" (Some "same_origin_blocked")
    (E.dashboard_auth_error_code
       (E.Auth
          (E.Auth_error.Forbidden
             { agent = "browser"; action = "cross-origin HTTP mutation" })));
  check "insufficient_role" (Some "insufficient_role")
    (E.dashboard_auth_error_code
       (E.Auth (E.Auth_error.Forbidden { agent = "alice"; action = "delete" })));
  check "unauthorized actor_mismatch" (Some "actor_mismatch")
    (E.dashboard_auth_error_code
       (E.Auth
          (E.Auth_error.Unauthorized { reason = Actor_mismatch; message = "x" })));
  check "unauthorized missing_token" (Some "missing_token")
    (E.dashboard_auth_error_code
       (E.Auth
          (E.Auth_error.Unauthorized { reason = Missing_token; message = "x" })));
  check "unauthorized generic -> unknown" (Some "unknown")
    (E.dashboard_auth_error_code
       (E.Auth (E.Auth_error.Unauthorized { reason = Generic; message = "x" })));
  check "non-auth -> unknown" (Some "unknown")
    (E.dashboard_auth_error_code (E.Task (E.Task_error.NotFound "id")));
  print_endline
    "test_masc_error_dashboard_auth_code: all assertions passed"
