(** Tests for {!Dashboard_verification} — Mission detail projection of
    verification requests.

    The projection reads [Verification.list_requests] against
    the explicitly supplied base path. Tests use a throwaway temp dir so
    they stay independent from whatever is sitting in the user's real
    [.masc/verifications/] directory. *)

(* Mirage_crypto_rng is consumed by Verification.generate_id. *)
let () = Mirage_crypto_rng_unix.use_default ()

module V = Masc.Verification
module D = Dashboard_verification
module FD = Keeper_fd_pressure

(* ── Fixture helpers ────────────────────────────────── *)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let snapshot_config_input name =
  Sys.getenv_opt name, Config_boot_overrides.get_opt name

let override_config_input name value =
  match Sys.getenv_opt name with
  | Some _ -> Unix.putenv name value
  | None -> Config_boot_overrides.set name value

let restore_config_input name (prior_env, prior_boot) =
  match prior_env with
  | Some v -> Unix.putenv name v
  | None ->
      (match prior_boot with
       | Some v -> Config_boot_overrides.set name v
       | None -> Config_boot_overrides.clear name)

let restore_process_config_input name (prior_env, prior_boot) =
  (match prior_env with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  match prior_boot with
  | Some v -> Config_boot_overrides.set name v
  | None -> Config_boot_overrides.clear name

(** Create an isolated MASC base_path for the duration of [f].
    Restores [MASC_BASE_PATH] and [MASC_BASE_PATH_INPUT] afterwards so
    subsequent tests in the same binary see the original value. *)
let with_temp_base_path f =
  let dir = Filename.temp_dir "masc_dashboard_verify_test" "" in
  let prior_base = snapshot_config_input "MASC_BASE_PATH" in
  let prior_input = snapshot_config_input "MASC_BASE_PATH_INPUT" in
  override_config_input "MASC_BASE_PATH" dir;
  override_config_input "MASC_BASE_PATH_INPUT" dir;
  let cleanup () =
    restore_config_input "MASC_BASE_PATH" prior_base;
    restore_config_input "MASC_BASE_PATH_INPUT" prior_input;
    rm_rf dir
  in
  Fun.protect ~finally:cleanup (fun () -> f dir)

let test_config_input_override_restores_boot_override () =
  let name = "MASC_TEST_DASHBOARD_VERIFICATION_BOOT_OVERRIDE" in
  let original = snapshot_config_input name in
  Fun.protect ~finally:(fun () -> restore_config_input name original) (fun () ->
    if Option.is_some (Sys.getenv_opt name) then
      Alcotest.fail (Printf.sprintf "%s unexpectedly set in test env" name);
    Config_boot_overrides.set name "before";
    let snapshot = snapshot_config_input name in
    override_config_input name "during";
    Alcotest.(check (option string)) "process env remains unset"
      None (Sys.getenv_opt name);
    Alcotest.(check (option string)) "boot override set"
      (Some "during") (Config_boot_overrides.get_opt name);
    restore_config_input name snapshot;
    Alcotest.(check (option string)) "process env still unset"
      None (Sys.getenv_opt name);
    Alcotest.(check (option string)) "boot override restored"
      (Some "before") (Config_boot_overrides.get_opt name))

(* The submit boundary replaces [submitted_evidence] with the materialized
   snapshot, so fixtures must carry snapshot items rather than the producer's
   raw reference strings. An artifact item projects back to its reference, which
   keeps every caller's expected list unchanged. *)
let evidence_snapshot_item reference =
  `Assoc [
    ("kind", `String "artifact");
    ("reference", `String reference);
    ("content", `String "");
    ("bytes", `Int 0);
    ("truncated", `Bool false);
  ]

let create_pending_request_with_artifacts ~required_artifacts ~base_path ~task_id
    ~worker ~criteria ~evidence =
  let output = `Assoc [
    ("required_artifacts",
     `List (List.map (fun s -> `String s) required_artifacts));
    ("submitted_evidence", `List (List.map evidence_snapshot_item evidence));
    ("task_title", `String (Printf.sprintf "title for %s" task_id));
  ] in
  match V.create_request ~base_path ~task_id ~output ~criteria ~worker () with
  | Ok req -> req
  | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)

let create_pending_request ~base_path ~task_id ~worker ~criteria ~evidence =
  create_pending_request_with_artifacts
    ~required_artifacts:[]
    ~base_path
    ~task_id
    ~worker
    ~criteria
    ~evidence

let member key j = Yojson.Safe.Util.member key j

let test_temp_base_path_overrides_and_restores_env_inputs () =
  let prior_base = snapshot_config_input "MASC_BASE_PATH" in
  let prior_input = snapshot_config_input "MASC_BASE_PATH_INPUT" in
  Fun.protect
    ~finally:(fun () ->
      restore_process_config_input "MASC_BASE_PATH" prior_base;
      restore_process_config_input "MASC_BASE_PATH_INPUT" prior_input)
    (fun () ->
      let original_base =
        Filename.concat (Filename.get_temp_dir_name ())
          "masc-dashboard-verify-original-base"
      in
      let original_input =
        Filename.concat (Filename.get_temp_dir_name ())
          "masc-dashboard-verify-original-input"
      in
      Unix.putenv "MASC_BASE_PATH" original_base;
      Unix.putenv "MASC_BASE_PATH_INPUT" original_input;
      with_temp_base_path (fun base_path ->
        Alcotest.(check (option string)) "base path overridden"
          (Some base_path) (Sys.getenv_opt "MASC_BASE_PATH");
        Alcotest.(check (option string)) "base path input overridden"
          (Some base_path) (Sys.getenv_opt "MASC_BASE_PATH_INPUT");
        let _ =
          create_pending_request ~base_path ~task_id:"task-env-override"
            ~worker:"keeper-alpha" ~criteria:[ "env isolated" ]
            ~evidence:["ref-env"]
        in
        let j = D.requests_json ~base_path () in
        match member "total" j with
        | `Int 1 -> ()
        | `Int n ->
            Alcotest.fail
              (Printf.sprintf "expected temp base_path request, got %d" n)
        | _ -> Alcotest.fail "total not int");
      Alcotest.(check (option string)) "base path restored"
        (Some original_base) (Sys.getenv_opt "MASC_BASE_PATH");
      Alcotest.(check (option string)) "base path input restored"
        (Some original_input) (Sys.getenv_opt "MASC_BASE_PATH_INPUT"))

(* ── Tests ──────────────────────────────────────────── *)

let test_requests_json_shape () =
  with_temp_base_path (fun base_path ->
    let _req = create_pending_request_with_artifacts ~base_path
        ~task_id:"task-shape"
        ~worker:"keeper-alpha"
        ~criteria:[
          "Must reduce FD leak";
          "Must pass integration tests";
        ]
        ~required_artifacts:[
          "artifact://required-report";
          "artifact://required-test-log";
        ]
        ~evidence:["trace://submitted-runtime-proof"] in
    let j = D.requests_json ~base_path () in
    (* Envelope: updated_at, total, requests *)
    (match member "updated_at" j with
     | `String _ -> ()
     | _ -> Alcotest.fail "updated_at should be string");
    (match member "total" j with
     | `Int n ->
         Alcotest.(check int) "total = 1" 1 n
     | _ -> Alcotest.fail "total should be int");
    let reqs = match member "requests" j with
      | `List xs -> xs
      | _ -> Alcotest.fail "requests should be list"
    in
    Alcotest.(check int) "one request" 1 (List.length reqs);
    let r = List.hd reqs in
    (* Required per-request fields *)
    let required_string_fields = [
      "request_id"; "task_id"; "task_title"; "created_at"; "submitted_by";
    ] in
    List.iter (fun key ->
      match member key r with
      | `String _ -> ()
      | _ ->
          Alcotest.fail
            (Printf.sprintf "%s should be string, got %s"
               key (Yojson.Safe.to_string (member key r)))
    ) required_string_fields;
    (* List fields *)
    (match member "completion_contract" r with
     | `List items ->
         Alcotest.(check int) "completion_contract len"
           2 (List.length items);
         List.iter (function
           | `String _ -> ()
           | _ -> Alcotest.fail "contract entry must be string"
         ) items
     | _ -> Alcotest.fail "completion_contract should be list");
    (match member "required_artifacts" r with
     | `List items ->
         Alcotest.(check (list string)) "required artifacts stay distinct"
           ["artifact://required-report"; "artifact://required-test-log"]
           (List.map Yojson.Safe.Util.to_string items);
         Alcotest.(check int) "required_artifacts len"
           2 (List.length items);
         List.iter (function
           | `String _ -> ()
           | _ -> Alcotest.fail "required artifact entry must be string"
         ) items
     | _ -> Alcotest.fail "required_artifacts should be list");
    (match member "submitted_evidence" r with
     | `List items ->
         Alcotest.(check (list string)) "submitted evidence stays distinct"
           ["trace://submitted-runtime-proof"]
           (List.map Yojson.Safe.Util.to_string items)
     | _ -> Alcotest.fail "submitted_evidence should be list");
    Alcotest.(check bool) "valid empty/non-empty evidence has no projection error"
      true (member "evidence_projection_error" r = `Null);
    (match member "submitted_by" r with
     | `String "keeper-alpha" -> ()
     | _ -> Alcotest.fail "submitted_by mismatch");
    (* task_title is pulled from the submit envelope so the UI detail cell
       has a fallback when contract and evidence are empty. *)
    (match member "task_title" r with
     | `String "title for task-shape" -> ()
     | `String s ->
         Alcotest.fail (Printf.sprintf "task_title mismatch: got %S" s)
     | _ -> Alcotest.fail "task_title should be string"))

let test_requests_json_uses_explicit_base_path_not_env () =
  let workspace_base = Filename.temp_dir "masc_dashboard_verify_workspace" "" in
  let env_base = Filename.temp_dir "masc_dashboard_verify_env" "" in
  let prior_base = snapshot_config_input "MASC_BASE_PATH" in
  let prior_input = snapshot_config_input "MASC_BASE_PATH_INPUT" in
  override_config_input "MASC_BASE_PATH" env_base;
  override_config_input "MASC_BASE_PATH_INPUT" env_base;
  Fun.protect
    ~finally:(fun () ->
      restore_config_input "MASC_BASE_PATH" prior_base;
      restore_config_input "MASC_BASE_PATH_INPUT" prior_input;
      rm_rf workspace_base;
      rm_rf env_base)
    (fun () ->
      let _ =
        create_pending_request ~base_path:workspace_base
          ~task_id:"task-workspace"
          ~worker:"keeper-workspace"
          ~criteria:[ "workspace criterion" ]
          ~evidence:["ref-workspace"]
      in
      let _ =
        create_pending_request ~base_path:env_base
          ~task_id:"task-env"
          ~worker:"keeper-env"
          ~criteria:[ "env criterion" ]
          ~evidence:["ref-env"]
      in
      let j = D.requests_json ~base_path:workspace_base () in
      Alcotest.(check int) "explicit base path total"
        1
        (match member "total" j with
         | `Int n -> n
         | _ -> Alcotest.fail "total should be int");
      match member "requests" j with
      | `List [row] ->
          Alcotest.(check string) "workspace task visible"
            "task-workspace"
            (match member "task_id" row with
             | `String value -> value
             | _ -> Alcotest.fail "task_id should be string")
      | _ -> Alcotest.fail "expected one explicit-base request")

let test_task_id_filter () =
  with_temp_base_path (fun base_path ->
    let _ = create_pending_request ~base_path
        ~task_id:"task-A" ~worker:"alpha"
        ~criteria:[ "A criterion" ] ~evidence:["ref-A"] in
    let _ = create_pending_request ~base_path
        ~task_id:"task-A" ~worker:"alpha"
        ~criteria:[ "A criterion 2" ] ~evidence:["ref-A2"] in
    let _ = create_pending_request ~base_path
        ~task_id:"task-B" ~worker:"beta"
        ~criteria:[ "B criterion" ] ~evidence:["ref-B"] in

    (* Unfiltered: all 3 requests *)
    let j_all = D.requests_json ~base_path () in
    (match member "total" j_all with
     | `Int 3 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 3 total, got %d" n)
     | _ -> Alcotest.fail "total not int");

    (* Filter task_id="task-A": exactly 2 requests, all with task_id = task-A *)
    let j_a = D.requests_json ~base_path ~task_id:"task-A" () in
    (match member "total" j_a with
     | `Int 2 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 2 for task-A, got %d" n)
     | _ -> Alcotest.fail "total not int");
    (match member "requests" j_a with
     | `List reqs ->
         List.iter (fun r ->
           match member "task_id" r with
           | `String "task-A" -> ()
           | `String s ->
               Alcotest.fail
                 (Printf.sprintf "expected task-A, got %s" s)
           | _ -> Alcotest.fail "task_id not string"
         ) reqs
     | _ -> Alcotest.fail "requests not list");

    (* Filter task_id="nonexistent": 0 entries *)
    let j_none = D.requests_json ~base_path ~task_id:"task-missing" () in
    (match member "total" j_none with
     | `Int 0 -> ()
     | `Int n ->
         Alcotest.fail (Printf.sprintf "expected 0, got %d" n)
     | _ -> Alcotest.fail "total not int");
    (match member "requests" j_none with
     | `List [] -> ()
     | `List _ -> Alcotest.fail "expected empty list"
     | _ -> Alcotest.fail "requests not list"))

(* [request_kind], [request_summary] and [next_action] were projected here
   until this row was written. Nothing produced them: [submit_request_spec] is
   the only caller of [Verification.create_request] outside tests, and it set
   the three to the literals "normal", "" and "". The only place
   "conflict_triage" appeared in the repository was the reader that matched on
   it, and the only place the other two were non-empty was the test that hand
   built an [output] to feed the reader its own vocabulary back.

   What survives is the field the queue actually reads. *)
let test_requests_json_carries_the_task_title () =
  with_temp_base_path (fun base_path ->
    let output =
      `Assoc [
        ("required_artifacts", `List [`String "artifact://required-A"]);
        ("submitted_evidence", `List [`String "trace://submitted-A"]);
        ("task_title", `String "conflict task");
      ]
    in
    let req =
      match V.create_request ~base_path ~task_id:"task-conflict" ~output
              ~criteria:[ "tests pass" ] ~worker:"keeper-alpha" () with
      | Ok req -> req
      | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)
    in
    let j = D.requests_json ~base_path ~task_id:"task-conflict" () in
    let row =
      match member "requests" j with
      | `List [row] -> row
      | _ -> Alcotest.fail "expected one request row"
    in
    (match member "request_id" row with
     | `String id when id = req.id -> ()
     | _ -> Alcotest.fail "request_id mismatch");
    (match member "task_title" row with
     | `String "conflict task" -> ()
     | _ -> Alcotest.fail "task_title mismatch");
    List.iter
      (fun field ->
        match member field row with
        | `Null -> ()
        | _ ->
          Alcotest.failf "%s is projected again and nothing produces it" field)
      [ "request_kind"; "request_summary"; "next_action" ])

(* Edges the live store does not currently hold but the writer can produce: an
   empty snapshot, an invalid-reference item that carries no reference at all,
   and a kind this module never writes. The first two must project; the third
   must fail the whole array rather than silently drop one item. *)
let test_requests_json_snapshot_projection_edges () =
  let row_for ~task_id items =
    with_temp_base_path (fun base_path ->
      let output =
        `Assoc [
          ("required_artifacts", `List []);
          ("submitted_evidence", `List items);
        ]
      in
      (match V.create_request ~base_path ~task_id ~output ~criteria:[]
               ~worker:"keeper-alpha" () with
       | Ok _ -> ()
       | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e));
      match member "requests" (D.requests_json ~base_path ()) with
      | `List [row] -> row
      | _ -> Alcotest.fail "expected one request")
  in
  let evidence row =
    member "submitted_evidence" row |> Yojson.Safe.Util.to_list
    |> List.map Yojson.Safe.Util.to_string
  in
  let error row =
    match member "evidence_projection_error" row with
    | `String s -> Some s
    | _ -> None
  in
  let empty = row_for ~task_id:"task-empty-evidence" [] in
  Alcotest.(check (list string)) "empty snapshot projects empty" [] (evidence empty);
  Alcotest.(check (option string)) "empty snapshot is not an error" None (error empty);
  let no_ref =
    row_for ~task_id:"task-invalid-reference"
      [ `Assoc [
          ("kind", `String "artifact_unreadable");
          ("reason", `Assoc [("code", `String "invalid_reference")]);
        ] ]
  in
  Alcotest.(check (list string)) "reference-less unreadable still names its reason"
    ["(unreadable: invalid_reference)"] (evidence no_ref);
  let unknown =
    row_for ~task_id:"task-unknown-kind"
      [ `Assoc [("kind", `String "hologram"); ("content", `String "x")] ]
  in
  Alcotest.(check (list string)) "unknown kind projects nothing" [] (evidence unknown);
  Alcotest.(check (option string)) "unknown kind fails the whole array"
    (Some
       ("malformed current-schema field \"submitted_evidence\": "
        ^ "unknown submitted evidence snapshot kind \"hologram\""))
    (error unknown);
  (* The identity surface and the authority-scoped payload route read the same
     persisted bytes. An artifact item carrying a reference but no payload
     metadata is rejected by the payload decoder, so naming it here would tell
     an operator that evidence exists which that route cannot serve. *)
  let artifact_without_payload =
    row_for ~task_id:"task-artifact-missing-payload"
      [ `Assoc [
          ("kind", `String "artifact");
          ("reference", `String "artifact:repos/demo/main.ml");
        ] ]
  in
  Alcotest.(check (list string))
    "artifact missing payload metadata is not named"
    [] (evidence artifact_without_payload);
  Alcotest.(check bool)
    "artifact missing payload metadata fails the array"
    true
    (error artifact_without_payload <> None)

let test_requests_json_surfaces_evidence_projection_error () =
  with_temp_base_path (fun base_path ->
    let output =
      `Assoc [
        ("submitted_evidence", `List [
          `String "trace://must-not-be-partially-projected";
          `Int 7;
        ]);
      ]
    in
    let _req =
      match V.create_request ~base_path ~task_id:"task-malformed-evidence"
              ~output ~criteria:[] ~worker:"keeper-alpha" () with
      | Ok req -> req
      | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)
    in
    let row =
      match member "requests" (D.requests_json ~base_path ()) with
      | `List [row] -> row
      | _ -> Alcotest.fail "expected one malformed evidence request"
    in
    Alcotest.(check (list string)) "missing required artifacts project empty"
      [] (member "required_artifacts" row |> Yojson.Safe.Util.to_list
          |> List.map Yojson.Safe.Util.to_string);
    Alcotest.(check (list string)) "malformed submitted evidence projects empty"
      [] (member "submitted_evidence" row |> Yojson.Safe.Util.to_list
          |> List.map Yojson.Safe.Util.to_string);
    (* The detail comes from this module's snapshot decoder, which the identity
       projection now runs, so it names the offending value rather than only
       its expected shape. *)
    Alcotest.(check string) "missing and malformed fields are distinguished"
      ("missing current-schema field \"required_artifacts\"; "
       ^ "malformed current-schema field \"submitted_evidence\": "
       ^ "submitted evidence snapshot item must be an object, got "
       ^ "\"trace://must-not-be-partially-projected\"")
      (member "evidence_projection_error" row |> Yojson.Safe.Util.to_string))

(* The live store holds 47 artifact, 231 note and 6 unreadable items written by
   the current serializer. Each kind must reach the operator as an identity
   line; an unreadable item must name its failure instead of vanishing. *)
let test_requests_json_projects_every_snapshot_item_kind () =
  with_temp_base_path (fun base_path ->
    let output =
      `Assoc [
        ("required_artifacts", `List []);
        ("submitted_evidence", `List [
          `Assoc [
            ("kind", `String "artifact");
            ("reference", `String "artifact:repos/demo/main.ml");
            ("content", `String "let () = ()");
            ("bytes", `Int 11);
            ("truncated", `Bool false);
          ];
          `Assoc [
            ("kind", `String "note");
            ("content", `String "executor summary");
          ];
          `Assoc [
            ("kind", `String "artifact_unreadable");
            ("reference", `String "artifact:repos/demo/gone.ml");
            ("reason", `Assoc [("code", `String "missing")]);
          ];
        ]);
      ]
    in
    let _req =
      match V.create_request ~base_path ~task_id:"task-snapshot-kinds"
              ~output ~criteria:[] ~worker:"keeper-alpha" () with
      | Ok req -> req
      | Error e -> Alcotest.fail (Printf.sprintf "create_request failed: %s" e)
    in
    let row =
      match member "requests" (D.requests_json ~base_path ()) with
      | `List [row] -> row
      | _ -> Alcotest.fail "expected one snapshot request"
    in
    Alcotest.(check (option string)) "snapshot projects without error"
      None
      (match member "evidence_projection_error" row with
       | `String s -> Some s
       | _ -> None);
    Alcotest.(check (list string)) "every item kind reaches the operator"
      [ "artifact:repos/demo/main.ml"
      ; "note:executor summary"
      ; "artifact:repos/demo/gone.ml (unreadable: missing)"
      ]
      (member "submitted_evidence" row |> Yojson.Safe.Util.to_list
       |> List.map Yojson.Safe.Util.to_string))

(* ── summary_json ───────────────────────────────────── *)

let int_field name j =
  match member name j with
  | `Int n -> n
  | _ -> Alcotest.fail (Printf.sprintf "%s not int" name)

let string_field name j =
  match member name j with
  | `String value -> value
  | _ -> Alcotest.fail (Printf.sprintf "%s not string" name)

(* A stored file the schema cannot read must not take the projection with it.

   This is the shape that reached production: a producer removed on 2026-08-07
   left 171 records whose [criteria] entries are objects rather than strings,
   and the projection raised on the first of them, so /api/v1/dashboard/proof
   answered 500 for five days while 122 readable records sat beside them. The
   fixture writes that exact shape rather than truncated JSON, so the case
   fails if the projection ever goes back to reading the store all-or-nothing. *)
let superseded_criteria_record =
  {|{"id":"vrf-superseded","task_id":"t-superseded","output":null,|}
  ^ {|"criteria":[{"type":"custom","description":"Task scope satisfied"}],|}
  ^ {|"worker":"w","created_at":1.0}|}

let test_projection_survives_an_unreadable_record () =
  with_temp_base_path (fun base_path ->
    let readable =
      create_pending_request ~base_path ~task_id:"t-readable" ~worker:"w"
        ~criteria:[ "criterion" ] ~evidence:[]
    in
    let dir = Filename.concat base_path ".masc/verifications" in
    Fs_compat.save_file
      (Filename.concat dir "vrf-superseded.json")
      superseded_criteria_record;

    let requests = D.requests_json ~base_path () in
    Alcotest.(check int)
      "the readable request is still projected"
      1
      (int_field "total" requests);
    Alcotest.(check int)
      "the unreadable record is counted, not swallowed"
      1
      (int_field "unreadable_total" requests);
    (match member "unreadable" requests with
     | `List [ entry ] ->
       Alcotest.(check bool)
         "the unreadable entry names its file"
         true
         (Astring.String.is_infix ~affix:"vrf-superseded.json"
            (string_field "path" entry));
       Alcotest.(check bool)
         "the unreadable entry carries why it could not be read"
         false
         (String.equal (String.trim (string_field "detail" entry)) "")
     | _ -> Alcotest.fail "unreadable is not a one-element list");

    (* The summary projection reads the same store and must agree. *)
    let summary = D.summary_json ~base_path () in
    Alcotest.(check int) "summary counts the readable request"
      1 (int_field "total" summary);
    Alcotest.(check int) "summary counts the unreadable record"
      1 (int_field "unreadable_total" summary);
    ignore readable)

let test_requests_and_summary_remain_available_after_fd_observation () =
  with_temp_base_path (fun base_path ->
    let _ =
      create_pending_request
        ~base_path
        ~task_id:"task-fd-pressure"
        ~worker:"keeper-alpha"
        ~criteria:[ "verification remains visible under FD pressure" ]
        ~evidence:[ "ref-fd" ]
    in
    FD.reset_for_tests ();
    FD.note_exception
      ~site:"test"
      (Unix.Unix_error (Unix.EMFILE, "open", "verification fixture"));
    Fun.protect
      ~finally:FD.reset_for_tests
      (fun () ->
        let requests = D.requests_json ~base_path () in
        Alcotest.(check int) "request remains visible" 1 (int_field "total" requests);
        Alcotest.(check string)
          "requests expose observation-only mode"
          "observation_only"
          (string_field "mode" requests);
        Alcotest.(check int)
          "requests expose exact process FD observation"
          1
          (int_field "process_fd_exhaustion_observations_total" requests);
        Alcotest.(check bool)
          "requests do not synthesize degraded state"
          true
          (member "degraded" requests = `Null);
        (match member "requests" requests with
         | `List [ _ ] -> ()
         | _ -> Alcotest.fail "request should remain visible during fd pressure");
        let summary = D.summary_json ~base_path () in
        Alcotest.(check int) "summary remains complete" 1 (int_field "total" summary);
        Alcotest.(check int)
          "summary exposes exact process FD observation"
          1
          (int_field "process_fd_exhaustion_observations_total" summary);
        Alcotest.(check bool)
          "summary does not synthesize degraded state"
          true
          (member "degraded" summary = `Null)))

(* ── Registration ───────────────────────────────────── *)

let () =
  Alcotest.run "dashboard_verification" [
    "requests_json", [
      Alcotest.test_case "restores boot override config inputs" `Quick
        test_config_input_override_restores_boot_override;
      Alcotest.test_case "overrides and restores env inputs" `Quick
        test_temp_base_path_overrides_and_restores_env_inputs;
      Alcotest.test_case "shape" `Quick test_requests_json_shape;
      Alcotest.test_case "uses explicit base_path, not env" `Quick
        test_requests_json_uses_explicit_base_path_not_env;
      Alcotest.test_case "task_id filter" `Quick test_task_id_filter;
      Alcotest.test_case "the task title, and nothing that is not produced" `Quick
        test_requests_json_carries_the_task_title;
      Alcotest.test_case "evidence projection errors" `Quick
        test_requests_json_surfaces_evidence_projection_error;
      Alcotest.test_case "projects every snapshot item kind" `Quick
        test_requests_json_projects_every_snapshot_item_kind;
      Alcotest.test_case "snapshot projection edges" `Quick
        test_requests_json_snapshot_projection_edges;
      Alcotest.test_case "fd pressure remains observation-only" `Quick
        test_requests_and_summary_remain_available_after_fd_observation;
      Alcotest.test_case "survives an unreadable record" `Quick
        test_projection_survives_an_unreadable_record;
    ];
    "summary_json", [
      Alcotest.test_case "immutable submission count" `Quick
        (fun () -> with_temp_base_path (fun base_path ->
          let j = D.summary_json ~base_path () in
          Alcotest.(check int) "total" 0 (int_field "total" j)));
    ];
  ]
