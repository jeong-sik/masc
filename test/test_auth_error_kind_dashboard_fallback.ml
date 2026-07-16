(** Typed metric tests for the dashboard actor fallback surface. *)

open Alcotest
module Aek = Auth_error_kind
module Sda = Masc.Silent_dashboard_actor_outcome

let with_eio_runtime f =
  Eio_main.run @@ fun _env -> f ()

let invalid_token_err =
  Masc_domain.Auth (Masc_domain.Auth_error.InvalidToken "stale-token-x")

let unauthorized_err =
  Masc_domain.Auth (Masc_domain.Auth_error.Unauthorized
    { reason = Generic; message = "no perms" })

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
  let labels = Aek.dashboard_actor_fallback_metric_labels fb in
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
  let labels = Aek.dashboard_actor_fallback_metric_labels fb in
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
     otel_metric_store label list shape is stable: ("outcome", "error") +
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
      let labels = Aek.dashboard_actor_fallback_metric_labels fb in
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

(* ----- Side-effect: otel_metric_store counter increments -------------------- *)

let test_outcome_none_increments_counter () =
  let module Metrics = Masc.Otel_metric_store in
  let labels = [ ("outcome", "none") ] in
  let before =
    Metrics.metric_value_or_zero
      Metrics.metric_silent_dashboard_actor_fallback ~labels ()
  in
  (* Drive the helper directly via the same internal entry point as
     server_auth.ml — exercise [Auth_error_kind] then increment via the
     otel_metric_store surface. The helper itself lives in [Server_auth] so we
     call [record_dashboard_actor_fallback] there. *)
  let fb : Aek.dashboard_actor_fallback =
    { outcome = Aek.Outcome_none; token_hash_prefix = "feedface" }
  in
  with_eio_runtime (fun () -> Server_auth.record_dashboard_actor_fallback fb);
  let after =
    Metrics.metric_value_or_zero
      Metrics.metric_silent_dashboard_actor_fallback ~labels ()
  in
  Alcotest.(check (float 0.0))
    "counter +1.0 for outcome=none"
    (before +. 1.0)
    after

let test_outcome_error_increments_counter_with_err_kind () =
  let module Metrics = Masc.Otel_metric_store in
  let labels =
    [ ("outcome", "error"); ("err_kind", "unauthorized") ]
  in
  let before =
    Metrics.metric_value_or_zero
      Metrics.metric_silent_dashboard_actor_fallback ~labels ()
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
  with_eio_runtime (fun () -> Server_auth.record_dashboard_actor_fallback fb);
  let after =
    Metrics.metric_value_or_zero
      Metrics.metric_silent_dashboard_actor_fallback ~labels ()
  in
  Alcotest.(check (float 0.0))
    "counter +1.0 for outcome=error+err_kind=unauthorized"
    (before +. 1.0)
    after

let suite =
  [ test_case "Outcome_none: otel_metric_store labels" `Quick
      test_outcome_none_labels
  ; test_case "Outcome_error: otel_metric_store labels include err_kind" `Quick
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
