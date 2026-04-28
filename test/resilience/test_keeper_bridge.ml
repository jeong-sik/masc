(* Cycle 23 / Tier A6 — Resilience.Keeper_bridge tests. *)

module KB = Resilience.Keeper_bridge

(* ─── masc_resilience_enabled ─────────────────────────────────── *)

let with_env key value f =
  let prev = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  let cleanup () =
    match prev with
    | Some v -> Unix.putenv key v
    | None -> Unix.putenv key ""
  in
  Fun.protect ~finally:cleanup f

let test_enabled_when_set_to_one () =
  with_env "MASC_RESILIENCE" (Some "1") @@ fun () ->
  assert (KB.masc_resilience_enabled ())

let test_enabled_when_set_to_true () =
  with_env "MASC_RESILIENCE" (Some "true") @@ fun () ->
  assert (KB.masc_resilience_enabled ())

let test_disabled_when_unset () =
  with_env "MASC_RESILIENCE" (Some "") @@ fun () ->
  assert (not (KB.masc_resilience_enabled ()))

let test_disabled_when_arbitrary_value () =
  with_env "MASC_RESILIENCE" (Some "yes-please") @@ fun () ->
  assert (not (KB.masc_resilience_enabled ()))

(* ─── upsert_resilience_meta ──────────────────────────────────── *)

let test_upsert_into_none () =
  let meta = `Assoc [ ("kind", `String "Transient") ] in
  match KB.upsert_resilience_meta None meta with
  | Some (`Assoc [ ("resilience_meta", payload) ]) ->
      assert (payload = meta)
  | _ -> assert false

let test_upsert_preserves_autonomous_meta () =
  let prev_auto = `Assoc [ ("phase", `String "idle") ] in
  let prev_wc = Some (`Assoc [ ("autonomous_meta", prev_auto) ]) in
  let resil = `Assoc [ ("kind", `String "Transient") ] in
  match KB.upsert_resilience_meta prev_wc resil with
  | Some (`Assoc kv) ->
      let auto = List.assoc_opt "autonomous_meta" kv in
      let resil_back = List.assoc_opt "resilience_meta" kv in
      assert (auto = Some prev_auto);
      assert (resil_back = Some resil)
  | _ -> assert false

let test_upsert_replaces_prior_resilience_meta () =
  let prev_resil = `Assoc [ ("kind", `String "Transient") ] in
  let prev_wc = Some (`Assoc [ ("resilience_meta", prev_resil) ]) in
  let new_resil = `Assoc [ ("kind", `String "Permanent") ] in
  match KB.upsert_resilience_meta prev_wc new_resil with
  | Some (`Assoc kv) ->
      let r = List.assoc_opt "resilience_meta" kv in
      assert (r = Some new_resil);
      (* Single key, no duplicate. *)
      assert (List.length kv = 1)
  | _ -> assert false

(* ─── apply_post_turn_resilience ──────────────────────────────── *)

let witness = KB.running_witness

let test_pipeline_no_op_when_no_error () =
  let prev_wc = Some (`Assoc [ ("autonomous_meta", `String "x") ]) in
  let outcome =
    KB.apply_post_turn_resilience witness ~now:1.0 ~working_context:prev_wc
      ~maybe_error:None ()
  in
  assert (outcome.working_context = prev_wc);
  assert (outcome.resilience_meta = None);
  assert (outcome.audit_envelope_id = None)

let test_pipeline_classifies_transient () =
  let outcome =
    KB.apply_post_turn_resilience witness ~now:2.0 ~working_context:None
      ~maybe_error:(Some "Connection timeout while fetching") ()
  in
  match outcome.resilience_meta with
  | Some (`Assoc kv) ->
      let kind = List.assoc "classified_kind" kv in
      assert (kind = `String "Transient");
      let strat = List.assoc "default_strategy_class" kv in
      assert (strat = `String "Retry")
  | _ -> assert false

let test_pipeline_classifies_permanent_handoff () =
  let outcome =
    KB.apply_post_turn_resilience witness ~now:3.0 ~working_context:None
      ~maybe_error:(Some "completely unknown failure mode") ()
  in
  match outcome.resilience_meta with
  | Some (`Assoc kv) ->
      let kind = List.assoc "classified_kind" kv in
      assert (kind = `String "Permanent");
      let strat = List.assoc "default_strategy_class" kv in
      assert (strat = `String "Handoff")
  | _ -> assert false

let test_pipeline_classifies_resource_token () =
  let outcome =
    KB.apply_post_turn_resilience witness ~now:4.0 ~working_context:None
      ~maybe_error:(Some "token budget exhausted") ()
  in
  match outcome.resilience_meta with
  | Some (`Assoc kv) ->
      let kind = List.assoc "classified_kind" kv in
      (* "token" matches resource phrase, "budget" might also; first
         resource phrase wins per Recovery.classify_string ordering. *)
      assert (kind = `String "ResourceExhausted");
      let strat = List.assoc "default_strategy_class" kv in
      assert (strat = `String "Abort")
  | _ -> assert false

let test_pipeline_upserts_into_working_context () =
  let prev_wc = Some (`Assoc [ ("autonomous_meta", `String "running") ]) in
  let outcome =
    KB.apply_post_turn_resilience witness ~now:5.0 ~working_context:prev_wc
      ~maybe_error:(Some "rate limit hit") ()
  in
  match outcome.working_context with
  | Some (`Assoc kv) ->
      assert (List.assoc_opt "autonomous_meta" kv = Some (`String "running"));
      assert (List.mem_assoc "resilience_meta" kv)
  | _ -> assert false

(* ─── audit envelope wiring ───────────────────────────────────── *)

let test_pipeline_writes_audit_when_store_supplied () =
  let tmp_dir =
    let base = Filename.get_temp_dir_name () in
    let dir = Filename.concat base "test_keeper_bridge_audit" in
    (* Best-effort cleanup; ignore failures. *)
    (try
       if Sys.file_exists dir then begin
         (* Walk + remove — tests may rerun. *)
         let rec rm path =
           if Sys.is_directory path then begin
             Array.iter (fun e -> rm (Filename.concat path e))
               (Sys.readdir path);
             Unix.rmdir path
           end
           else Sys.remove path
         in
         rm dir
       end
     with _ -> ());
    dir
  in
  let store = Shared_audit.Store.create ~base_dir:tmp_dir in
  let outcome =
    KB.apply_post_turn_resilience witness ~audit_store:store ~now:6.0
      ~working_context:None
      ~maybe_error:(Some "rate limit exceeded") ()
  in
  (match outcome.audit_envelope_id with
   | Some _ -> ()
   | None -> assert false);
  let recent = Shared_audit.Store.recent store ~n:1 in
  assert (List.length recent = 1);
  match recent with
  | [ env ] ->
      assert (env.Shared_audit.Envelope.category = "RecoveryAttempted");
      assert (Some env.Shared_audit.Envelope.id = outcome.audit_envelope_id)
  | _ -> assert false

let () =
  test_enabled_when_set_to_one ();
  test_enabled_when_set_to_true ();
  test_disabled_when_unset ();
  test_disabled_when_arbitrary_value ();
  test_upsert_into_none ();
  test_upsert_preserves_autonomous_meta ();
  test_upsert_replaces_prior_resilience_meta ();
  test_pipeline_no_op_when_no_error ();
  test_pipeline_classifies_transient ();
  test_pipeline_classifies_permanent_handoff ();
  test_pipeline_classifies_resource_token ();
  test_pipeline_upserts_into_working_context ();
  test_pipeline_writes_audit_when_store_supplied ();
  print_endline "test_keeper_bridge: all assertions passed"
