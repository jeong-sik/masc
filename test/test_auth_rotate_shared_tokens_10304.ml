module Types = Masc_domain

(** #10304 — pin the shared-token rotation contract.

    #9786 shipped detection only ([Auth.audit_token_uniqueness] +
    boot-time WARN + Prometheus counter).  #10304 reports the
    detection fires again in production: 14 agents shared one token
    (3 distinct [token_hash_prefix] in one day).  The WARN message
    instructs operators to "rotate via Auth.create_token" but no
    automatic prevention exists — every server restart that
    bootstraps the shared-credential state stays vulnerable.

    [Auth.rotate_shared_tokens] is the prevention building block:
    given the live credential store, regenerate every credential
    in a shared-token group with its own unique raw token,
    persisting each through [save_raw_token_credential].  The
    function is intentionally side-effecting and idempotent:

    1. No shared groups → returns the empty list (no writes).
    2. One shared group of N agents → returns one outcome whose
       [rotated_agents] has N successful entries; calling the
       function a second time returns [] because the audit no
       longer sees duplicates.
    3. Per-agent role is preserved — the rotation must not
       silently demote an Admin to a Worker or vice-versa.
    4. Two simultaneous shared groups land as two outcomes,
       sorted by [token_hash_prefix] for stable log diffs. *)

open Alcotest
open Masc_mcp

(* [generate_token] inside [Auth.create_token] / [rotate_shared_tokens]
   pulls from Mirage_crypto_rng — needs an explicit unix init in
   tests (mirrors test_a2a_e2e, test_verification, etc.). *)
let () = Mirage_crypto_rng_unix.use_default ()

(* --- harness ------------------------------------------------------ *)

let temp_dir () =
  let path = Filename.temp_file "auth_rotate_shared_10304_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_base f =
  let dir = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let seed_shared_credential base_path ~agent_name ~role ~raw_token =
  match
    Auth.save_raw_token_credential base_path ~agent_name ~role ~raw_token
  with
  | Ok cred -> cred
  | Error e -> failf "seed credential failed: %s" (Masc_domain.masc_error_to_string e)

let outcome_names_of (o : Auth.rotation_outcome) =
  List.map fst o.rotated_agents

let outcome_results_of (o : Auth.rotation_outcome) =
  List.map snd o.rotated_agents

let credential_token base_path agent_name =
  match Auth.load_credential base_path agent_name with
  | Some cred -> cred.token
  | None -> failf "credential missing: %s" agent_name

let credential_role base_path agent_name =
  match Auth.load_credential base_path agent_name with
  | Some cred -> cred.role
  | None -> failf "credential missing: %s" agent_name

let raw_token_file base_path agent_name =
  Filename.concat (Auth.auth_dir base_path) (agent_name ^ ".token")

let raw_token_value base_path agent_name =
  let path = raw_token_file base_path agent_name in
  if Sys.file_exists path then
    In_channel.with_open_bin path (fun ic ->
        String.trim (In_channel.input_all ic))
  else
    failf "raw token file missing: %s" path

(* --- 1. clean store -> empty rotation --------------------------- *)

let test_no_shared_returns_empty () =
  with_temp_base @@ fun base ->
  ignore
    (seed_shared_credential base ~agent_name:"alice" ~role:Masc_domain.Worker
       ~raw_token:"alice-unique-token");
  ignore
    (seed_shared_credential base ~agent_name:"bob" ~role:Masc_domain.Worker
       ~raw_token:"bob-unique-token");
  let outcomes = Auth.rotate_shared_tokens base in
  check int "no shared groups, no rotation"
    0 (List.length outcomes);
  (* Audit confirms nothing to fix. *)
  check int "audit also reports clean"
    0 (List.length (Auth.audit_token_uniqueness base))

(* --- 2. shared group of 3 -> all rotated to unique tokens ------- *)

let test_shared_group_rotates_to_unique () =
  with_temp_base @@ fun base ->
  let shared = "shared-bearer-token-abc" in
  ignore
    (seed_shared_credential base ~agent_name:"keeper-a"
       ~role:Masc_domain.Worker ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"keeper-b"
       ~role:Masc_domain.Worker ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"keeper-c"
       ~role:Masc_domain.Worker ~raw_token:shared);
  (* Audit before rotation: one group of 3. *)
  let groups_before = Auth.audit_token_uniqueness base in
  check int "audit sees 1 group before rotation"
    1 (List.length groups_before);
  (* Rotate. *)
  let outcomes = Auth.rotate_shared_tokens base in
  check int "rotation reports 1 outcome"
    1 (List.length outcomes);
  let outcome = List.hd outcomes in
  check (list string)
    "rotation visits all 3 agents in sorted order"
    [ "keeper-a"; "keeper-b"; "keeper-c" ]
    (outcome_names_of outcome);
  let all_ok =
    outcome_results_of outcome
    |> List.for_all (function Ok () -> true | Error _ -> false)
  in
  check bool "all 3 rotations succeeded" true all_ok;
  (* Tokens are now distinct. *)
  let tokens =
    [ "keeper-a"; "keeper-b"; "keeper-c" ]
    |> List.map (credential_token base)
  in
  check int "3 distinct token hashes after rotation"
    3
    (List.sort_uniq String.compare tokens |> List.length);
  [ "keeper-a"; "keeper-b"; "keeper-c" ]
  |> List.iter (fun agent_name ->
         let raw_token = raw_token_value base agent_name in
         check string
           (agent_name ^ " raw token file hashes to rotated credential")
           (credential_token base agent_name)
           (Auth.sha256_hash raw_token);
         match Auth.verify_token base ~agent_name ~token:raw_token with
         | Ok cred ->
             check string (agent_name ^ " raw token verifies")
               agent_name cred.agent_name
         | Error e ->
             failf "%s raw token should verify after rotation: %s"
               agent_name (Masc_domain.masc_error_to_string e));
  (* Audit is empty after rotation. *)
  check int "audit is clean after rotation"
    0 (List.length (Auth.audit_token_uniqueness base))

(* --- 3. role preserved across rotation -------------------------- *)

let test_rotation_preserves_role () =
  with_temp_base @@ fun base ->
  let shared = "role-mix-shared-token" in
  ignore
    (seed_shared_credential base ~agent_name:"admin-keeper"
       ~role:Masc_domain.Admin ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"worker-keeper"
       ~role:Masc_domain.Worker ~raw_token:shared);
  let _ = Auth.rotate_shared_tokens base in
  check string "admin keeper kept Admin role"
    "admin"
    (Masc_domain.agent_role_to_string (credential_role base "admin-keeper"));
  check string "worker keeper kept Worker role"
    "worker"
    (Masc_domain.agent_role_to_string (credential_role base "worker-keeper"))

(* --- 4. multiple shared groups -> stable order ------------------ *)

let test_two_shared_groups_sorted_by_prefix () =
  with_temp_base @@ fun base ->
  let token_alpha = "alpha-shared-token-zzz" in
  let token_beta = "beta-shared-token-yyy" in
  ignore
    (seed_shared_credential base ~agent_name:"a1" ~role:Masc_domain.Worker
       ~raw_token:token_alpha);
  ignore
    (seed_shared_credential base ~agent_name:"a2" ~role:Masc_domain.Worker
       ~raw_token:token_alpha);
  ignore
    (seed_shared_credential base ~agent_name:"b1" ~role:Masc_domain.Worker
       ~raw_token:token_beta);
  ignore
    (seed_shared_credential base ~agent_name:"b2" ~role:Masc_domain.Worker
       ~raw_token:token_beta);
  let outcomes = Auth.rotate_shared_tokens base in
  check int "two outcome groups"
    2 (List.length outcomes);
  let prefixes =
    List.map (fun (o : Auth.rotation_outcome) -> o.token_hash_prefix) outcomes
  in
  let sorted_prefixes = List.sort String.compare prefixes in
  check (list string) "outcomes sorted by token_hash_prefix"
    sorted_prefixes prefixes

(* --- 5. idempotent: second call after rotation = no-op --------- *)

let test_idempotent_after_rotation () =
  with_temp_base @@ fun base ->
  let shared = "second-pass-token" in
  ignore
    (seed_shared_credential base ~agent_name:"x"
       ~role:Masc_domain.Worker ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"y"
       ~role:Masc_domain.Worker ~raw_token:shared);
  let _ = Auth.rotate_shared_tokens base in
  let second_outcomes = Auth.rotate_shared_tokens base in
  check int "second rotation finds nothing to rotate"
    0 (List.length second_outcomes)

(* --- 6. scoped rotation leaves non-target agents alone ---------- *)

let test_scoped_rotation_only_rotates_selected_agents () =
  with_temp_base @@ fun base ->
  let shared = "scoped-shared-token" in
  ignore
    (seed_shared_credential base ~agent_name:"keeper-a"
       ~role:Masc_domain.Worker ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"keeper-b"
       ~role:Masc_domain.Worker ~raw_token:shared);
  ignore
    (seed_shared_credential base ~agent_name:"admin"
       ~role:Masc_domain.Admin ~raw_token:shared);
  let outcomes =
    Auth.rotate_shared_tokens_for_agents base
      ~agent_names:[ "keeper-a"; "keeper-b" ]
  in
  check int "one scoped outcome" 1 (List.length outcomes);
  let outcome = List.hd outcomes in
  check (list string) "only selected keepers rotated"
    [ "keeper-a"; "keeper-b" ]
    (outcome_names_of outcome);
  check string "admin kept old shared token hash"
    (Auth.sha256_hash shared) (credential_token base "admin");
  let keeper_tokens =
    [ "keeper-a"; "keeper-b" ] |> List.map (credential_token base)
  in
  check int "selected keepers now unique"
    2 (List.sort_uniq String.compare keeper_tokens |> List.length);
  check bool "keeper-a no longer shares with admin" false
    (String.equal (credential_token base "keeper-a")
       (credential_token base "admin"));
  check bool "keeper-b no longer shares with admin" false
    (String.equal (credential_token base "keeper-b")
       (credential_token base "admin"))

let () =
  run "auth_rotate_shared_tokens_10304"
    [
      ( "clean-store",
        [
          test_case "no shared -> empty rotation" `Quick
            test_no_shared_returns_empty;
        ] );
      ( "rotation",
        [
          test_case "shared group rotates to unique" `Quick
            test_shared_group_rotates_to_unique;
          test_case "role preserved across rotation" `Quick
            test_rotation_preserves_role;
        ] );
      ( "ordering",
        [
          test_case "two groups sorted by prefix" `Quick
            test_two_shared_groups_sorted_by_prefix;
        ] );
      ( "idempotency",
        [
          test_case "second call is a no-op" `Quick
            test_idempotent_after_rotation;
        ] );
      ( "scoped",
        [
          test_case "selected agents rotate without admin blast radius" `Quick
            test_scoped_rotation_only_rotates_selected_agents;
        ] );
    ]
