(* test/test_auth_ambiguous_lookup_9786.ml

   #9786 runtime complement: when N>=2 credentials share a
   bearer-token hash, [find_credential_by_token] silently routes
   to [List.find]'s first match.  The boot-time audit
   ([audit_token_uniqueness] + masc_auth_credential_token_duplicate_total)
   detects the duplicate once at startup, but operators have no
   per-request signal — a stale audit warning vs. an actively
   wrong-agent-serving keeper looks identical.

   This counter
   (masc_auth_credential_ambiguous_lookup_total{first_match=...})
   fires every time the lookup encounters N>=2 matches, so an
   alert can use rate(...) to distinguish the two cases.

   This test pins:
   - Single match → no counter increment
   - Two creds with same hash → counter increments by 1, returns
     the first credential (legacy behavior preserved)
   - first_match label is the routed agent_name (so operators
     can attribute the wrong serving) *)

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
      "{\"agent_name\":%S,\"token\":%S,\"role\":\"agent\",\"created_at\":\"2026-04-25T00:00:00Z\"}"
      agent_name token_hash
  in
  let oc = open_out path in
  output_string oc json;
  close_out oc

let counter_for ~first_match =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_auth_credential_ambiguous_lookup
    ~labels:[ ("first_match", first_match) ]
    ()

let test_metric_name_stable () =
  Alcotest.(check string)
    "canonical metric name"
    "masc_auth_credential_ambiguous_lookup_total"
    Masc_mcp.Prometheus.metric_auth_credential_ambiguous_lookup

let test_single_match_no_counter () =
  with_temp_base (fun base ->
    let raw_token = "single_match_raw_token_9786" in
    let hash = Masc_mcp.Auth.sha256_hash raw_token in
    write_cred ~base ~agent_name:"keeper-only" ~token_hash:hash;
    let before = counter_for ~first_match:"keeper-only" in
    let _ =
      Masc_mcp.Auth.find_credential_by_token base ~token:raw_token
    in
    Alcotest.(check (float 0.0001))
      "no counter on single match"
      before
      (counter_for ~first_match:"keeper-only"))

let test_duplicate_hash_increments_counter () =
  with_temp_base (fun base ->
    let raw_token = "duplicate_raw_token_9786" in
    let hash = Masc_mcp.Auth.sha256_hash raw_token in
    (* Two credentials hashing to the same token — exactly the
       2026-04-23 audit shape (codex-mcp-client + keeper-name). *)
    write_cred ~base ~agent_name:"alpha-keeper" ~token_hash:hash;
    write_cred ~base ~agent_name:"zeta-keeper"  ~token_hash:hash;
    (* alpha-keeper sorts before zeta — list_credentials reads
       directory entries in lexicographic order, so List.find
       routes to alpha-keeper. *)
    let before_alpha = counter_for ~first_match:"alpha-keeper" in
    let before_zeta  = counter_for ~first_match:"zeta-keeper" in
    let result =
      Masc_mcp.Auth.find_credential_by_token base ~token:raw_token
    in
    (match result with
     | Ok cred ->
         Alcotest.(check string)
           "first match returned (legacy preserved)"
           "alpha-keeper"
           cred.agent_name
     | Error _ ->
         Alcotest.fail "expected Ok on ambiguous lookup");
    Alcotest.(check (float 0.0001))
      "alpha-keeper counter +1"
      (before_alpha +. 1.0)
      (counter_for ~first_match:"alpha-keeper");
    Alcotest.(check (float 0.0001))
      "zeta-keeper counter unchanged (it was not the routed match)"
      before_zeta
      (counter_for ~first_match:"zeta-keeper"))

let test_repeated_lookups_accumulate () =
  with_temp_base (fun base ->
    let raw_token = "repeat_raw_token_9786" in
    let hash = Masc_mcp.Auth.sha256_hash raw_token in
    write_cred ~base ~agent_name:"repeat-a" ~token_hash:hash;
    write_cred ~base ~agent_name:"repeat-b" ~token_hash:hash;
    let before = counter_for ~first_match:"repeat-a" in
    for _ = 1 to 3 do
      let _ =
        Masc_mcp.Auth.find_credential_by_token base ~token:raw_token
      in
      ()
    done;
    Alcotest.(check (float 0.0001))
      "+3 over 3 lookups"
      (before +. 3.0)
      (counter_for ~first_match:"repeat-a"))

let () =
  Random.self_init ();
  Alcotest.run "auth_ambiguous_lookup_9786" [
    "metric", [
      Alcotest.test_case "canonical name stable" `Quick
        test_metric_name_stable;
    ];
    "lookup", [
      Alcotest.test_case "single match → no counter" `Quick
        test_single_match_no_counter;
      Alcotest.test_case "duplicate hash → counter +1, first match returned"
        `Quick
        test_duplicate_hash_increments_counter;
      Alcotest.test_case "repeated lookups accumulate" `Quick
        test_repeated_lookups_accumulate;
    ];
  ]
