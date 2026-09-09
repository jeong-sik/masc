(* Pins Runtime_quota_window: account-scoped provider quota windows consumed
   as a lane-ordering preference (RFC-0370 §3.3). [now] is a parameter
   everywhere, so no time stubbing. *)

module Q = Runtime_quota_window

let reset () = Q.reset_for_testing ()

let provider_scope provider_id = Q.scope_of_credential ~provider_id None

(* scope mapping used by demote tests: "prov.model" ids, unknown for
   ids without a dot — mirrors candidates the driver cannot resolve. *)
let quota_scope_of candidate =
  match String.index_opt candidate '.' with
  | Some i -> Some (provider_scope (String.sub candidate 0 i))
  | None -> None

let test_window_lifecycle () =
  reset ();
  let scope = provider_scope "claude_code" in
  Alcotest.(check (option (float 0.0)))
    "no window recorded"
    None
    (Q.active_until ~scope ~now:100.0);
  Q.note_exhausted ~scope ~resets_at:500.0;
  Alcotest.(check (option (float 0.0)))
    "active before reset"
    (Some 500.0)
    (Q.active_until ~scope ~now:499.9);
  Alcotest.(check (option (float 0.0)))
    "expired at reset"
    None
    (Q.active_until ~scope ~now:500.0);
  Alcotest.(check (option (float 0.0)))
    "expiry pruned the entry (no resurrection at an earlier now)"
    None
    (Q.active_until ~scope ~now:0.0)

let test_later_reset_extends_earlier_is_ignored () =
  reset ();
  let scope = provider_scope "codex_subscription" in
  Q.note_exhausted ~scope ~resets_at:500.0;
  Q.note_exhausted ~scope ~resets_at:900.0;
  Alcotest.(check (option (float 0.0)))
    "later reset extends"
    (Some 900.0)
    (Q.active_until ~scope ~now:100.0);
  Q.note_exhausted ~scope ~resets_at:600.0;
  Alcotest.(check (option (float 0.0)))
    "earlier reset cannot shorten"
    (Some 900.0)
    (Q.active_until ~scope ~now:100.0)

let candidates =
  [ "claude_code.sonnet"; "ollama.qwen"; "claude_code.opus"; "codex.spark" ]

(* An observation is a fact without an end time. Both metered providers this
   fleet reaches 429 without Retry-After (2026-09-06), so a table that only
   records stated windows stays empty while every lane re-dispatches into a
   spent account. *)
let test_an_observation_demotes_and_a_success_clears_it () =
  reset ();
  let scope = provider_scope "ollama_cloud" in
  Alcotest.(check bool) "nothing recorded" false (Q.is_exhausted ~scope ~now:100.0);
  Q.note_observed_exhausted ~scope;
  Alcotest.(check bool) "an observation holds it back" true
    (Q.is_exhausted ~scope ~now:100.0);
  (* No time is claimed, so no time answers when it ends. *)
  Alcotest.(check (option (float 0.0)))
    "an observation names no reset"
    None
    (Q.active_until ~scope ~now:100.0);
  (* And it does not age out: a clock cannot know a quota came back. *)
  Alcotest.(check bool) "time alone does not clear it" true
    (Q.is_exhausted ~scope ~now:1_000_000.0);
  Q.note_succeeded ~scope;
  Alcotest.(check bool) "a call getting through clears it" false
    (Q.is_exhausted ~scope ~now:100.0)
;;

(* The provider's own answer outranks an observation in both directions, and a
   success inside a stated window does not make that window untrue. *)
let test_a_stated_window_outranks_an_observation () =
  reset ();
  let scope = provider_scope "api_z_ai" in
  Q.note_observed_exhausted ~scope;
  Q.note_exhausted ~scope ~resets_at:500.0;
  Alcotest.(check (option (float 0.0)))
    "a stated reset replaces an observation"
    (Some 500.0)
    (Q.active_until ~scope ~now:100.0);
  Q.note_observed_exhausted ~scope;
  Alcotest.(check (option (float 0.0)))
    "an observation does not weaken a stated window"
    (Some 500.0)
    (Q.active_until ~scope ~now:100.0);
  Q.note_succeeded ~scope;
  Alcotest.(check (option (float 0.0)))
    "a success does not end a stated window"
    (Some 500.0)
    (Q.active_until ~scope ~now:100.0);
  Alcotest.(check bool) "and the stated window still expires on time" false
    (Q.is_exhausted ~scope ~now:500.1)
;;

(* The safety line. Demotion is ordering, not admission: an observed scope is
   still attempted when it is all a lane has left, so a provider blip cannot
   take a lane out. *)
let test_an_observed_scope_is_demoted_not_excluded () =
  reset ();
  Q.note_observed_exhausted ~scope:(provider_scope "ollama_cloud");
  let candidates = [ "ollama_cloud.glm-5-3"; "deepseek.v4-flash" ] in
  Alcotest.(check (list string))
    "an observed candidate goes to the tail"
    [ "deepseek.v4-flash"; "ollama_cloud.glm-5-3" ]
    (Q.demote_order ~now:100.0 ~quota_scope_of candidates);
  Alcotest.(check (list string))
    "and is still there when it is all there is"
    [ "ollama_cloud.glm-5-3" ]
    (Q.demote_order ~now:100.0 ~quota_scope_of [ "ollama_cloud.glm-5-3" ])
;;

let test_demote_moves_exhausted_provider_to_tail () =
  reset ();
  Q.note_exhausted ~scope:(provider_scope "claude_code") ~resets_at:500.0;
  Alcotest.(check (list string))
    "exhausted provider's candidates keep order at the tail"
    [ "ollama.qwen"; "codex.spark"; "claude_code.sonnet"; "claude_code.opus" ]
    (Q.demote_order ~now:100.0 ~quota_scope_of candidates)

let test_demote_noop_paths () =
  reset ();
  Alcotest.(check (list string))
    "no windows: unchanged"
    candidates
    (Q.demote_order ~now:100.0 ~quota_scope_of candidates);
  Q.note_exhausted ~scope:(provider_scope "claude_code") ~resets_at:500.0;
  Alcotest.(check (list string))
    "window passed: unchanged"
    candidates
    (Q.demote_order ~now:501.0 ~quota_scope_of candidates);
  Q.note_exhausted ~scope:(provider_scope "unrelated_provider") ~resets_at:900.0;
  Alcotest.(check (list string))
    "window on a provider with no candidate: unchanged"
    candidates
    (Q.demote_order ~now:100.0 ~quota_scope_of candidates)

let test_unknown_provider_stays_in_place () =
  reset ();
  Q.note_exhausted ~scope:(provider_scope "claude_code") ~resets_at:500.0;
  Alcotest.(check (list string))
    "unresolvable id is not demoted"
    [ "no-dot-id"; "ollama.qwen"; "claude_code.sonnet" ]
    (Q.demote_order
       ~now:100.0
       ~quota_scope_of
       [ "no-dot-id"; "claude_code.sonnet"; "ollama.qwen" ]
     |> fun reordered ->
     (* stable partition keeps no-dot-id and ollama.qwen in declared order,
        claude_code.sonnet at the tail *)
     reordered)

let test_all_demoted_keeps_declared_order () =
  reset ();
  Q.note_exhausted ~scope:(provider_scope "claude_code") ~resets_at:500.0;
  Alcotest.(check (list string))
    "every candidate demoted: declared order preserved, still attemptable"
    [ "claude_code.sonnet"; "claude_code.opus" ]
    (Q.demote_order
       ~now:100.0
       ~quota_scope_of
       [ "claude_code.sonnet"; "claude_code.opus" ])

(* Quota is credential-account-owned: two provider rows sharing one
   credential share one scope, so exhausting either demotes both
   (PR #28202 review P2). *)
let test_shared_credential_scope_demotes_siblings () =
  reset ();
  let scope_of = function
    (* two rows, one account *)
    | "ollama_cloud.qwen" | "ollama_cloud_native.qwen" ->
      Some
        (Q.scope_of_credential
           ~provider_id:"ignored"
           (Some (Runtime_schema.Env "OLLAMA_CLOUD_API_KEY")))
    | "claude_code.sonnet" ->
      Some
        (Q.scope_of_credential
           ~provider_id:"ignored"
           (Some (Runtime_schema.Env "ANTHROPIC_KEY")))
    | _ -> None
  in
  Q.note_exhausted
    ~scope:
      (Q.scope_of_credential
         ~provider_id:"ollama_cloud"
         (Some (Runtime_schema.Env "OLLAMA_CLOUD_API_KEY")))
    ~resets_at:500.0;
  Alcotest.(check (list string))
    "both rows on the exhausted account move to the tail"
    [ "claude_code.sonnet"; "ollama_cloud.qwen"; "ollama_cloud_native.qwen" ]
    (Q.demote_order
       ~now:100.0
       ~quota_scope_of:scope_of
       [ "ollama_cloud.qwen"; "claude_code.sonnet"; "ollama_cloud_native.qwen" ])

let test_scope_kinds_do_not_collide () =
  reset ();
  let env_scope =
    Q.scope_of_credential
      ~provider_id:"ignored"
      (Some (Runtime_schema.Env "TOKEN"))
  in
  let provider_row_scope = provider_scope "env:TOKEN" in
  Q.note_exhausted ~scope:env_scope ~resets_at:500.0;
  Alcotest.(check (option (float 0.0)))
    "an env reference cannot collide with a provider row that resembles it"
    None
    (Q.active_until ~scope:provider_row_scope ~now:100.0)

let test_registry_default_credential_is_shared_scope () =
  let credential provider_id =
    Runtime_adapter.effective_credential_reference ~provider_id None
  in
  let glm_scope =
    Q.scope_of_credential ~provider_id:"glm" (credential "glm")
  in
  let image_scope =
    Q.scope_of_credential ~provider_id:"zai-image" (credential "zai-image")
  in
  reset ();
  Q.note_exhausted ~scope:glm_scope ~resets_at:500.0;
  Alcotest.(check bool)
    "registry rows sharing ZAI_API_KEY share a quota window"
    true
    (Option.is_some (Q.active_until ~scope:image_scope ~now:100.0))

let with_env_values bindings f =
  let previous =
    List.map (fun (key, _) -> key, Sys.getenv_opt key) bindings
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun (key, value) ->
           Unix.putenv key (Option.value ~default:"" value))
        previous)
    (fun () ->
       List.iter (fun (key, value) -> Unix.putenv key value) bindings;
       f ())
;;

let test_selected_environment_alias_owns_scope () =
  with_env_values
    [ "OLLAMA_CLOUD_API_KEY", ""; "OLLAMA_API_KEY", "legacy-test-key" ]
    (fun () ->
       let selected =
         Runtime_adapter.effective_credential_reference
           ~provider_id:"ollama_cloud"
           (Some (Runtime_schema.Env "OLLAMA_CLOUD_API_KEY"))
       in
       let selected_scope =
         Q.scope_of_credential ~provider_id:"ollama_cloud" selected
       in
       let legacy_scope =
         Q.scope_of_credential
           ~provider_id:"ollama_cloud"
           (Some (Runtime_schema.Env "OLLAMA_API_KEY"))
       in
       reset ();
       Q.note_exhausted ~scope:selected_scope ~resets_at:500.0;
       Alcotest.(check bool)
         "the environment alias that supplied the key shares the window"
         true
         (Option.is_some (Q.active_until ~scope:legacy_scope ~now:100.0)))

let () =
  Alcotest.run
    "runtime_quota_window"
    [ ( "window"
      , [ Alcotest.test_case "lifecycle" `Quick test_window_lifecycle
        ; Alcotest.test_case
            "later reset extends, earlier ignored"
            `Quick
            test_later_reset_extends_earlier_is_ignored
        ] )
    ; ( "demote"
      , [ Alcotest.test_case
            "exhausted provider to tail"
            `Quick
            test_demote_moves_exhausted_provider_to_tail
        ; Alcotest.test_case "no-op paths" `Quick test_demote_noop_paths
        ; Alcotest.test_case
            "unknown provider stays"
            `Quick
            test_unknown_provider_stays_in_place
        ; Alcotest.test_case
            "all demoted keeps order"
            `Quick
            test_all_demoted_keeps_declared_order
        ; Alcotest.test_case
            "shared credential demotes siblings"
            `Quick
            test_shared_credential_scope_demotes_siblings
        ; Alcotest.test_case
            "an observation demotes and a success clears it"
            `Quick
            test_an_observation_demotes_and_a_success_clears_it
        ; Alcotest.test_case
            "a stated window outranks an observation"
            `Quick
            test_a_stated_window_outranks_an_observation
        ; Alcotest.test_case
            "an observed scope is demoted, not excluded"
            `Quick
            test_an_observed_scope_is_demoted_not_excluded
        ] )
    ; ( "scope"
      , [ Alcotest.test_case
            "scope kinds do not collide"
            `Quick
            test_scope_kinds_do_not_collide
        ; Alcotest.test_case
            "registry default credential shares scope"
            `Quick
            test_registry_default_credential_is_shared_scope
        ; Alcotest.test_case
            "selected environment alias owns scope"
            `Quick
            test_selected_environment_alias_owns_scope
        ] )
    ]
