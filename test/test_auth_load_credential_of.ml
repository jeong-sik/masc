(* test/test_auth_load_credential_of.ml

   RFC P2-a unit test for [Auth.load_credential_of].

   Pins the 3 explicit branches that distinguish "credential missing"
   from "credential exists but its owner does not match the dispatcher
   ctx" — the dual-identity surfacing semantic that the removed
   runtime alias fallback used to silently absorb.

   Cases:
   1. resolved_credential_stem = ctx_agent_name, file exists -> Ok
   2. resolved_credential_stem = ctx_agent_name, file missing -> Error Credential_missing
   3. resolved_credential_stem <> ctx_agent_name -> Error Credential_mismatch
      (even when a credential for resolved_credential_stem exists on disk
       — the function rejects rather than falling back) *)

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
      (Printf.sprintf "masc-p2a-loadof-%06x" (Random.bits ()))
  in
  Unix.mkdir base 0o755;
  Fun.protect
    ~finally:(fun () -> rm_rf base)
    (fun () -> f base)

let write_cred ~base ~agent_name ~token_hash =
  (* Write through the production encoder so a credential schema change breaks
     this fixture at compile time instead of at [of_yojson] runtime. The
     hand-written JSON this replaces omitted [id]/[agent_id]/[expires_at], which
     the decoder requires as keys even where the record type defaults them. *)
  let cred : Masc_domain.agent_credential =
    { id = None
    ; agent_id = None
    ; agent_name
    ; token = token_hash
    ; role = Masc_domain.Worker
    ; created_at = "2026-04-26T00:00:00Z"
    ; expires_at = None
    }
  in
  Auth.save_credential base cred

let test_exact_match_load_ok () =
  with_temp_base (fun base ->
    write_cred ~base ~agent_name:"keeper-alpha-agent"
      ~token_hash:"abc123";
    match
      Auth.load_credential_of base
        ~ctx_agent_name:"keeper-alpha-agent"
        ~resolved_credential_stem:"keeper-alpha-agent"
    with
    | Ok cred ->
        assert (cred.agent_name = "keeper-alpha-agent");
        print_endline "PASS: exact match -> Ok cred"
    | Error e ->
        Printf.printf "FAIL: expected Ok, got Error %s\n"
          (Auth.show_load_credential_error e);
        exit 1)

let test_exact_match_missing_returns_credential_missing () =
  with_temp_base (fun base ->
    (* No cred file written *)
    match
      Auth.load_credential_of base
        ~ctx_agent_name:"keeper-ghost-agent"
        ~resolved_credential_stem:"keeper-ghost-agent"
    with
    | Ok _ ->
        print_endline "FAIL: expected Credential_missing, got Ok";
        exit 1
    | Error (Auth.Credential_missing { ctx_agent_name }) ->
        assert (ctx_agent_name = "keeper-ghost-agent");
        print_endline "PASS: missing file -> Credential_missing"
    | Error (Auth.Credential_mismatch _) ->
        print_endline "FAIL: expected Credential_missing, got Credential_mismatch";
        exit 1)

let test_mismatch_rejects_even_when_resolved_stem_exists () =
  (* Dual-identity scenario: bare nickname cred exists on disk, but ctx
     is canonical. load_credential_of must reject rather than fall back. *)
  with_temp_base (fun base ->
    write_cred ~base ~agent_name:"alpha" ~token_hash:"bare-token";
    write_cred ~base ~agent_name:"keeper-alpha-agent"
      ~token_hash:"canonical-token";
    match
      Auth.load_credential_of base
        ~ctx_agent_name:"keeper-alpha-agent"
        ~resolved_credential_stem:"alpha"
    with
    | Ok _ ->
        print_endline "FAIL: expected Credential_mismatch, got Ok (silent fallback)";
        exit 1
    | Error (Auth.Credential_missing _) ->
        print_endline "FAIL: expected Credential_mismatch, got Credential_missing";
        exit 1
    | Error
        (Auth.Credential_mismatch
           { ctx_agent_name; resolved_credential_stem }) ->
        assert (ctx_agent_name = "keeper-alpha-agent");
        assert (resolved_credential_stem = "alpha");
        print_endline
          "PASS: ctx<>stem -> Credential_mismatch (no silent fallback)")

let test_mismatch_rejects_even_when_neither_exists () =
  with_temp_base (fun base ->
    match
      Auth.load_credential_of base
        ~ctx_agent_name:"keeper-a-agent"
        ~resolved_credential_stem:"b"
    with
    | Ok _ ->
        print_endline "FAIL: expected Credential_mismatch";
        exit 1
    | Error (Auth.Credential_missing _) ->
        print_endline "FAIL: ctx<>stem must take mismatch branch even when nothing exists";
        exit 1
    | Error
        (Auth.Credential_mismatch
           { ctx_agent_name; resolved_credential_stem }) ->
        assert (ctx_agent_name = "keeper-a-agent");
        assert (resolved_credential_stem = "b");
        print_endline "PASS: empty filesystem still produces Credential_mismatch")

let () =
  Random.self_init ();
  test_exact_match_load_ok ();
  test_exact_match_missing_returns_credential_missing ();
  test_mismatch_rejects_even_when_resolved_stem_exists ();
  test_mismatch_rejects_even_when_neither_exists ();
  print_endline "All P2-a load_credential_of tests passed"
