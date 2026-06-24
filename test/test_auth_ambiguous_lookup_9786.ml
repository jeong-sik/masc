module Types = Masc_domain

(* test/test_auth_ambiguous_lookup_9786.ml

   #9786 runtime complement + PR-MASC-4: when N>=2 credentials share a
   bearer-token hash, [find_credential_by_token] now performs a full
   credential comparison before treating them as equal.  If the
   credentials differ, the lookup returns [InvalidToken] and emits a
   structured collision event instead of silently routing to the first
   match.  Identical duplicates still count as ambiguous lookups.

   This test pins:
   - Single match -> no counter increment, returns Ok
   - Two distinct credentials with the same hash -> ambiguous lookup
     counter unchanged, collision counter +1, returns Error
   - Repeated lookups accumulate only the collision counter
   - first_match label is the routed agent_name (so operators can
     attribute the wrong serving if the collision guard were disabled). *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun e -> rm_rf (Filename.concat path e));
      Unix.rmdir path)
    else
      Sys.remove path

let with_temp_base f =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-9786-rt-%06x" (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () -> f base)

let write_cred ~base ~agent_name ~token_hash =
  let agents_dir = Filename.concat base ".masc/auth/agents" in
  let rec mkdirs p =
    if Sys.file_exists p then ()
    else begin
      mkdirs (Filename.dirname p);
      try Unix.mkdir p 0o755 with Unix.Unix_error _ -> ()
    end
  in
  mkdirs agents_dir;
  let path = Filename.concat agents_dir (agent_name ^ ".json") in
  let json =
    Printf.sprintf
      "{\"agent_name\":%S,\"token\":%S,\"role\":\"worker\",\"created_at\":\"2026-04-25T00:00:00Z\"}"
      agent_name token_hash
  in
  let oc = open_out path in
  output_string oc json;
  close_out oc

let ambiguous_counter_for ~first_match =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_auth_credential_ambiguous_lookup
    ~labels:[ ("first_match", first_match) ]
    ()

let collision_counter_for ~left_agent ~right_agent =
  Masc.Otel_metric_store.metric_value_or_zero
    Masc.Otel_metric_store.metric_auth_credential_hash_collision
    ~labels:[ ("left_agent", left_agent); ("right_agent", right_agent) ]
    ()

let ambiguous_lookup_total () =
  Masc.Otel_metric_store.metric_total
    Masc.Otel_metric_store.metric_auth_credential_ambiguous_lookup

let collision_lookup_total () =
  Masc.Otel_metric_store.metric_total
    Masc.Otel_metric_store.metric_auth_credential_hash_collision

let first_match_for_hash ~base ~token_hash =
  Masc.Auth.list_credentials base
  |> List.find (fun (cred : Masc_domain.agent_credential) ->
       String.equal cred.token token_hash)
  |> fun cred -> cred.agent_name

let test_metric_names_stable () =
  Alcotest.(check string)
    "ambiguous lookup metric name"
    "masc_auth_credential_ambiguous_lookup_total"
    Masc.Otel_metric_store.metric_auth_credential_ambiguous_lookup;
  Alcotest.(check string)
    "hash collision metric name"
    "masc_auth_credential_hash_collision_total"
    Masc.Otel_metric_store.metric_auth_credential_hash_collision

let test_single_match_no_counter () =
  with_temp_base (fun base ->
    let raw_token = "single_match_raw_token_9786" in
    let hash = Masc.Auth.sha256_hash raw_token in
    write_cred ~base ~agent_name:"keeper-only" ~token_hash:hash;
    let before_ambiguous = ambiguous_counter_for ~first_match:"keeper-only" in
    let before_ambiguous_total = ambiguous_lookup_total () in
    let before_collision_total = collision_lookup_total () in
    let result = Masc.Auth.find_credential_by_token base ~token:raw_token in
    (match result with
     | Ok _ -> ()
     | Error e ->
       Alcotest.fail
         (Printf.sprintf "expected Ok on single match, got Error %s"
            (Masc_domain.show_masc_error e)));
    Alcotest.(check (float 0.0001))
      "no ambiguous counter on single match"
      before_ambiguous
      (ambiguous_counter_for ~first_match:"keeper-only");
    Alcotest.(check (float 0.0001))
      "no hidden ambiguous counter series on single match"
      before_ambiguous_total
      (ambiguous_lookup_total ());
    Alcotest.(check (float 0.0001))
      "no collision counter on single match"
      before_collision_total
      (collision_lookup_total ()))

let test_duplicate_hash_rejects_collision () =
  with_temp_base (fun base ->
    let raw_token = "duplicate_raw_token_9786" in
    let hash = Masc.Auth.sha256_hash raw_token in
    (* Two credentials hashing to the same token but with different
       agent_name fields: a collision, not merely an ambiguous lookup. *)
    write_cred ~base ~agent_name:"alpha-keeper" ~token_hash:hash;
    write_cred ~base ~agent_name:"zeta-keeper" ~token_hash:hash;
    let first_match = first_match_for_hash ~base ~token_hash:hash in
    let other_match =
      if String.equal first_match "alpha-keeper" then "zeta-keeper" else "alpha-keeper"
    in
    let before_ambiguous_first = ambiguous_counter_for ~first_match in
    let before_ambiguous_other = ambiguous_counter_for ~first_match:other_match in
    let before_collision = collision_counter_for ~left_agent:first_match ~right_agent:other_match in
    let before_collision_total = collision_lookup_total () in
    let result = Masc.Auth.find_credential_by_token base ~token:raw_token in
    (match result with
     | Ok cred ->
       Alcotest.fail
         (Printf.sprintf
            "expected Error on hash collision, got Ok for %s"
            cred.agent_name)
     | Error _ -> ());
    Alcotest.(check (float 0.0001))
      "ambiguous lookup counter unchanged on collision"
      before_ambiguous_first
      (ambiguous_counter_for ~first_match);
    Alcotest.(check (float 0.0001))
      "non-routed ambiguous counter unchanged"
      before_ambiguous_other
      (ambiguous_counter_for ~first_match:other_match);
    Alcotest.(check (float 0.0001))
      "collision counter +1"
      (before_collision +. 1.0)
      (collision_counter_for ~left_agent:first_match ~right_agent:other_match);
    Alcotest.(check (float 0.0001))
      "collision total +1"
      (before_collision_total +. 1.0)
      (collision_lookup_total ()))

let test_repeated_lookups_accumulate () =
  with_temp_base (fun base ->
    let raw_token = "repeat_raw_token_9786" in
    let hash = Masc.Auth.sha256_hash raw_token in
    write_cred ~base ~agent_name:"repeat-a" ~token_hash:hash;
    write_cred ~base ~agent_name:"repeat-b" ~token_hash:hash;
    let first_match = first_match_for_hash ~base ~token_hash:hash in
    let other_match =
      if String.equal first_match "repeat-a" then "repeat-b" else "repeat-a"
    in
    let before_ambiguous = ambiguous_counter_for ~first_match in
    let before_collision = collision_counter_for ~left_agent:first_match ~right_agent:other_match in
    for _ = 1 to 3 do
      let (_ : (Masc_domain.agent_credential, Masc_domain.masc_error) result) =
        Masc.Auth.find_credential_by_token base ~token:raw_token
      in
      ()
    done;
    Alcotest.(check (float 0.0001))
      "ambiguous lookup counter unchanged over 3 calls"
      before_ambiguous
      (ambiguous_counter_for ~first_match);
    Alcotest.(check (float 0.0001))
      "+3 collisions over 3 calls"
      (before_collision +. 3.0)
      (collision_counter_for ~left_agent:first_match ~right_agent:other_match))

let () =
  Random.self_init ();
  Alcotest.run "auth_ambiguous_lookup_9786" [
    "metric", [
      Alcotest.test_case "canonical names stable" `Quick
        test_metric_names_stable;
    ];
    "lookup", [
      Alcotest.test_case "single match -> no counter" `Quick
        test_single_match_no_counter;
      Alcotest.test_case "duplicate hash -> collision error and counters"
        `Quick
        test_duplicate_hash_rejects_collision;
      Alcotest.test_case "repeated lookups accumulate" `Quick
        test_repeated_lookups_accumulate;
    ];
  ]
