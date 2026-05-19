(** Byte-equivalence + label tests for the dashboard_actor_fallback typed
    surface on [Auth_error_kind].

    The two prior inline warn sites at [lib/server/server_auth.ml] used
    Printf format strings that the OCaml lexer concatenates across the
    [\<newline><whitespace>] escape into a single line. Operators key
    prometheus log alerts on the literal [silent:dashboard_actor_fallback]
    prefix and on the [Remediation:] substring in the [token_mismatch]
    arm, so the consolidated helper MUST emit the byte-identical message.

    These tests lock the rendered string for both outcome arms against an
    explicit hex-literal expected value, and check that the prometheus
    label list matches the prior call. Reference:
    [auth_error_kind.mli §Dashboard actor fallback typed surface]. *)

open Alcotest
module Aek = Masc_mcp.Auth_error_kind
module Sda = Masc_mcp.Silent_dashboard_actor_outcome

(* ----- Outcome_none: byte-equivalent log message --------------------- *)

let test_outcome_none_log_message_byte_equivalent () =
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "deadbeef" }
  in
  let actual = Aek.dashboard_actor_fallback_log_message fb in
  let expected =
    "[silent:dashboard_actor_fallback] outcome=none \
     token_hash_prefix=deadbeef \xe2\x80\x94 bearer token resolved to no \
     agent, falling back to request actor hint"
  in
  Alcotest.(check string) "byte-equivalent rendering" expected actual

let test_outcome_none_log_message_starts_with_alert_prefix () =
  (* Lock the [silent:dashboard_actor_fallback] prefix — prometheus log
     alerts grep for this literal substring. *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "ab12cd34" }
  in
  let msg = Aek.dashboard_actor_fallback_log_message fb in
  let prefix = "[silent:dashboard_actor_fallback] outcome=none" in
  let n = String.length prefix in
  Alcotest.(check string)
    "alert prefix preserved"
    prefix
    (String.sub msg 0 n)

let test_outcome_none_log_message_no_leading_whitespace_after_dash () =
  (* The OCaml [\<newline><whitespace>] continuation collapses to nothing,
     so the source-level visual indent must NOT appear in the rendered
     string. A regression that inserted a literal space-newline-space
     would shift downstream log parsers — guard it. *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "zz" }
  in
  let msg = Aek.dashboard_actor_fallback_log_message fb in
  (* Must contain "zz \xe2\x80\x94 bearer" — em-dash directly after the
     single space, no double-space. *)
  let needle = "zz \xe2\x80\x94 bearer" in
  Alcotest.(check bool)
    "single space before em-dash"
    true
    (Astring.String.is_infix ~affix:needle msg)

(* ----- Outcome_error: byte-equivalent log message -------------------- *)

let invalid_token_err =
  Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken "stale-token-x")

let unauthorized_err =
  Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized "no perms")

let test_outcome_error_token_mismatch_renders_remediation () =
  (* [Token_mismatch] is the only [err_kind] that appends the
     remediation tail. Lock the literal "Remediation:" substring +
     trailing period from the original format. *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome =
        Aek.Outcome_error
          { err = invalid_token_err
          ; err_kind = Aek.Token_mismatch
          ; actor_hint = Some "dashboard-admin"
          }
    ; token_hash_prefix = "feed1234"
    }
  in
  let msg = Aek.dashboard_actor_fallback_log_message fb in
  (* Spot-check critical substrings independently — the full byte
     equivalence is locked by a separate test below. *)
  Alcotest.(check bool)
    "alert prefix"
    true
    (Astring.String.is_prefix
       ~affix:
         "[silent:dashboard_actor_fallback] outcome=error \
          token_hash_prefix=feed1234"
       msg);
  Alcotest.(check bool)
    "err_kind label"
    true
    (Astring.String.is_infix ~affix:"err_kind=token_mismatch" msg);
  Alcotest.(check bool)
    "actor_hint inlined"
    true
    (Astring.String.is_infix ~affix:"actor_hint=dashboard-admin" msg);
  Alcotest.(check bool)
    "remediation tail present"
    true
    (Astring.String.is_infix ~affix:" Remediation: " msg);
  Alcotest.(check bool)
    "localStorage hint"
    true
    (Astring.String.is_infix
       ~affix:"localStorage masc_dashboard_token"
       msg)

let test_outcome_error_token_mismatch_byte_equivalent () =
  let fb : Aek.dashboard_actor_fallback =
    { outcome =
        Aek.Outcome_error
          { err = invalid_token_err
          ; err_kind = Aek.Token_mismatch
          ; actor_hint = Some "dashboard-admin"
          }
    ; token_hash_prefix = "feed1234"
    }
  in
  let actual = Aek.dashboard_actor_fallback_log_message fb in
  let err_str = Masc_domain.masc_error_to_string invalid_token_err in
  let expected =
    Printf.sprintf
      "[silent:dashboard_actor_fallback] outcome=error \
       token_hash_prefix=feed1234 err_kind=token_mismatch \
       actor_hint=dashboard-admin err=%s \xe2\x80\x94 falling back to \
       request actor hint. Remediation: clear the browser's stored \
       dashboard token (localStorage masc_dashboard_token) or delete \
       .masc/auth/dashboard.token so a fresh token is minted on the \
       next dashboard load."
      err_str
  in
  Alcotest.(check string) "byte-equivalent rendering" expected actual

let test_outcome_error_non_token_mismatch_no_remediation () =
  (* The remediation tail is exclusive to [Token_mismatch]. Other
     [err_kind] arms must end at the trailing period of "actor hint." *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome =
        Aek.Outcome_error
          { err = unauthorized_err
          ; err_kind = Aek.Unauthorized
          ; actor_hint = None
          }
    ; token_hash_prefix = "0000abcd"
    }
  in
  let msg = Aek.dashboard_actor_fallback_log_message fb in
  Alcotest.(check bool)
    "no remediation tail"
    false
    (Astring.String.is_infix ~affix:" Remediation: " msg);
  Alcotest.(check bool)
    "actor_hint=<none> placeholder"
    true
    (Astring.String.is_infix ~affix:"actor_hint=<none>" msg);
  Alcotest.(check bool)
    "ends at hint period"
    true
    (Astring.String.is_suffix
       ~affix:"falling back to request actor hint."
       msg)

(* ----- Prometheus label correspondence ------------------------------- *)

let labels_eq actual expected =
  let sort = List.sort compare in
  Alcotest.(check (list (pair string string)))
    "label set"
    (sort expected)
    (sort actual)

let test_outcome_none_labels () =
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "x" }
  in
  let labels = Aek.dashboard_actor_fallback_prometheus_labels fb in
  labels_eq labels [ ("outcome", Sda.to_label Sda.None_resolved) ];
  Alcotest.(check string)
    "outcome label is 'none'"
    "none"
    (Sda.to_label Sda.None_resolved)

let test_outcome_error_labels_include_err_kind () =
  let fb : Aek.dashboard_actor_fallback =
    { outcome =
        Aek.Outcome_error
          { err = invalid_token_err
          ; err_kind = Aek.Token_mismatch
          ; actor_hint = Some "dashboard-admin"
          }
    ; token_hash_prefix = "x"
    }
  in
  let labels = Aek.dashboard_actor_fallback_prometheus_labels fb in
  labels_eq labels
    [ ("outcome", Sda.to_label Sda.Error_classified)
    ; ("err_kind", "token_mismatch")
    ];
  Alcotest.(check string)
    "outcome label is 'error'"
    "error"
    (Sda.to_label Sda.Error_classified)

let test_outcome_error_labels_for_every_err_kind () =
  (* Walk every modelled [Auth_error_kind.t] and confirm the
     prometheus label list shape is stable: ("outcome", "error") +
     ("err_kind", <stable_label>). This guards against the
     [Other]-collapse anti-pattern (CLAUDE.md §Workaround Rejection Bar
     §2 String/Substring classifier). *)
  List.iter
    (fun err_kind ->
      let fb : Aek.dashboard_actor_fallback =
        { outcome =
            Aek.Outcome_error
              { err = invalid_token_err
              ; err_kind
              ; actor_hint = None
              }
        ; token_hash_prefix = "x"
        }
      in
      let labels = Aek.dashboard_actor_fallback_prometheus_labels fb in
      let outcome =
        List.assoc_opt "outcome" labels
        |> Option.value ~default:"<missing>"
      in
      let err_kind_lbl =
        List.assoc_opt "err_kind" labels
        |> Option.value ~default:"<missing>"
      in
      Alcotest.(check string)
        "outcome='error'" "error" outcome;
      Alcotest.(check string)
        "err_kind label matches to_string"
        (Aek.to_string err_kind)
        err_kind_lbl)
    Aek.all

(* ----- Side-effect: prometheus counter increments -------------------- *)

let test_outcome_none_increments_counter () =
  let module Prom = Masc_mcp.Prometheus in
  let labels = [ ("outcome", "none") ] in
  let before =
    Prom.metric_value_or_zero
      Prom.metric_silent_dashboard_actor_fallback ~labels ()
  in
  (* Drive the helper directly via the same internal entry point as
     server_auth.ml — exercise [Auth_error_kind] then increment via the
     prometheus surface. The helper itself lives in [Server_auth] so we
     call [record_dashboard_actor_fallback] there. *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "feedface" }
  in
  Masc_mcp.Server_auth.record_dashboard_actor_fallback fb;
  let after =
    Prom.metric_value_or_zero
      Prom.metric_silent_dashboard_actor_fallback ~labels ()
  in
  Alcotest.(check (float 0.0))
    "counter +1.0 for outcome=none"
    (before +. 1.0)
    after

let test_outcome_error_increments_counter_with_err_kind () =
  let module Prom = Masc_mcp.Prometheus in
  let labels =
    [ ("outcome", "error"); ("err_kind", "unauthorized") ]
  in
  let before =
    Prom.metric_value_or_zero
      Prom.metric_silent_dashboard_actor_fallback ~labels ()
  in
  let fb : Aek.dashboard_actor_fallback =
    { outcome =
        Aek.Outcome_error
          { err = unauthorized_err
          ; err_kind = Aek.Unauthorized
          ; actor_hint = None
          }
    ; token_hash_prefix = "feedface"
    }
  in
  Masc_mcp.Server_auth.record_dashboard_actor_fallback fb;
  let after =
    Prom.metric_value_or_zero
      Prom.metric_silent_dashboard_actor_fallback ~labels ()
  in
  Alcotest.(check (float 0.0))
    "counter +1.0 for outcome=error+err_kind=unauthorized"
    (before +. 1.0)
    after

let suite =
  [ test_case "Outcome_none: byte-equivalent log message" `Quick
      test_outcome_none_log_message_byte_equivalent
  ; test_case "Outcome_none: alert prefix locked" `Quick
      test_outcome_none_log_message_starts_with_alert_prefix
  ; test_case "Outcome_none: no whitespace before em-dash" `Quick
      test_outcome_none_log_message_no_leading_whitespace_after_dash
  ; test_case "Outcome_error+Token_mismatch: remediation tail present" `Quick
      test_outcome_error_token_mismatch_renders_remediation
  ; test_case "Outcome_error+Token_mismatch: byte-equivalent" `Quick
      test_outcome_error_token_mismatch_byte_equivalent
  ; test_case "Outcome_error+other err_kind: no remediation tail" `Quick
      test_outcome_error_non_token_mismatch_no_remediation
  ; test_case "Outcome_none: prometheus labels" `Quick
      test_outcome_none_labels
  ; test_case "Outcome_error: prometheus labels include err_kind" `Quick
      test_outcome_error_labels_include_err_kind
  ; test_case "Outcome_error: label shape stable across err_kind" `Quick
      test_outcome_error_labels_for_every_err_kind
  ; test_case "Outcome_none: counter increments" `Quick
      test_outcome_none_increments_counter
  ; test_case "Outcome_error: counter increments with err_kind label" `Quick
      test_outcome_error_increments_counter_with_err_kind
  ]

let () =
  Alcotest.run "Auth_error_kind_dashboard_fallback"
    [ ("dashboard_actor_fallback", suite) ]
