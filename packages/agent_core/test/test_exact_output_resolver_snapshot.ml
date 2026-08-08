open Alcotest
open Llm_provider
module EO = Agent_sdk.Exact_output

let _load_resolver_snapshot_contract
  :  io:EO.resolver_io
  -> ?catalog:EO.resolver_catalog_input
  -> unit
  -> (EO.resolver_snapshot, EO.resolver_snapshot_error) result
  =
  EO.load_resolver_snapshot
;;

let _catalog_input_contract : EO.resolver_catalog_input -> unit = function
  | EO.Embedded_default
  | EO.Embedded_with_overlay _
  | EO.Full_replacement _
  | EO.Full_replacement_file _ -> ()
[@@warning "+8"]
;;

let schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc [ "name", `Assoc [ "type", `String "string" ] ]
    ; "required", `List [ `String "name" ]
    ]
;;

let message : Types.message =
  { role = Types.User
  ; content = [ Types.Text "return one object" ]
  ; name = None
  ; tool_call_id = None
  ; metadata = []
  }
;;

let aliases_line = function
  | [] -> ""
  | aliases ->
    Printf.sprintf
      "aliases = [%s]\n"
      (String.concat ", " (List.map (Printf.sprintf "%S") aliases))
;;

let option_line key show = function
  | None -> ""
  | Some value -> Printf.sprintf "%s = %s\n" key (show value)
;;

let toml_float value =
  let rendered = Printf.sprintf "%.17g" value in
  if
    String.contains rendered '.'
    || String.contains rendered 'e'
    || String.contains rendered 'E'
  then rendered
  else rendered ^ ".0"
;;

let target_catalog
      ?(provider = "snapshot-fixture")
      ?(aliases = [])
      ?(kind = "openai_compat")
      ?(base_url = "https://snapshot.example")
      ?base_url_env
      ?(request_path = "/v1/chat/completions")
      ?(api_key_env = "")
      ?default_model
      ?(model = "snapshot-model")
      ?(target = "snapshot-target")
      ?enable_thinking
      ?max_request_body_bytes
      ?connect_timeout_s
      ?body_timeout_s
      ?(json = true)
      ?(structured = false)
      ?(price = 1.0)
      ?(model_extra = "")
      ()
  =
  Printf.sprintf
    "[[providers]]\n\
     id = %S\n\
     %skind = %S\n\
     base_url = %S\n\
     %srequest_path = %S\n\
     api_key_env = %S\n\
     %s\n\
     [[models]]\n\
     id_prefix = %S\n\
     provider_name = %S\n\
     max_context_tokens = 8192\n\
     max_output_tokens = 1024\n\
     supports_response_format_json = %b\n\
     supports_structured_output = %b\n\
     input_per_million = %s\n\
     %s\n\
     [[targets]]\n\
     id = %S\n\
     provider_ref = %S\n\
     model_id = %S\n\
     %s%s%s%s"
    provider
    (aliases_line aliases)
    kind
    base_url
    (option_line "base_url_env" (Printf.sprintf "%S") base_url_env)
    request_path
    api_key_env
    (option_line "default_model" (Printf.sprintf "%S") default_model)
    model
    provider
    json
    structured
    (toml_float price)
    model_extra
    target
    provider
    model
    (option_line "enable_thinking" string_of_bool enable_thinking)
    (option_line "max_request_body_bytes" string_of_int max_request_body_bytes)
    (option_line "connect_timeout_s" toml_float connect_timeout_s)
    (option_line "body_timeout_s" toml_float body_timeout_s)
;;

let snapshot ?(getenv = fun _ -> Ok None) contents =
  let io : EO.resolver_io = { getenv } in
  let overlay : EO.catalog_document =
    { source = "resolver snapshot fixture"; contents }
  in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Ok snapshot -> snapshot
  | Error _ -> fail "snapshot should load"
;;

let admit snapshot id =
  match EO.admit_target_ref snapshot id with
  | Ok admitted -> admitted
  | Error _ -> failf "target ref %S should be admitted" id
;;

let resolve_admitted admitted =
  match EO.resolve_target admitted with
  | Ok target -> target
  | Error _ -> fail "admitted target should resolve"
;;

let resolve snapshot id = resolve_admitted (admit snapshot id)

let ready target =
  let requirement =
    EO.make_output_requirement ~schema ~minimum_guarantee:EO.Json_syntax
  in
  match EO.admit ~target ~messages:[ message ] requirement with
  | Ok ready -> ready
  | Error _ -> fail "exact target should admit"
;;

let attempt ready =
  match EO.start_attempt ready with
  | Ok attempt -> attempt
  | Error (EO.Call_id_generation_failed detail) ->
    failf "exact attempt identity allocation failed: %s" detail
;;

let generation snapshot =
  EO.resolver_catalog_generation snapshot |> EO.catalog_generation_fingerprint
;;

let evidence snapshot =
  EO.resolver_catalog_evidence snapshot |> EO.catalog_evidence_sha256
;;

let identity target = EO.selected_target_identity target |> EO.target_identity_fingerprint

type frozen_observation =
  { snapshot_generation : string
  ; snapshot_evidence : string
  ; selected_generation : string
  ; selected_evidence : string
  ; selected_identity : string
  ; provenance_generation : string
  ; provenance_evidence : string
  ; provenance_identity : string
  ; receipt_generation : string
  ; receipt_evidence : string
  ; receipt_identity : string
  ; plan_fingerprint : string
  }

let frozen_observation snapshot target =
  let plan = ready target in
  let provenance = EO.plan_provenance plan in
  let receipt = EO.attempt_receipt (attempt plan) in
  { snapshot_generation = generation snapshot
  ; snapshot_evidence = evidence snapshot
  ; selected_generation =
      EO.selected_target_catalog_generation target |> EO.catalog_generation_fingerprint
  ; selected_evidence =
      EO.selected_target_catalog_evidence target |> EO.catalog_evidence_sha256
  ; selected_identity = identity target
  ; provenance_generation =
      EO.plan_provenance_catalog_generation provenance
      |> EO.catalog_generation_fingerprint
  ; provenance_evidence =
      EO.plan_provenance_catalog_evidence provenance |> EO.catalog_evidence_sha256
  ; provenance_identity =
      EO.plan_provenance_target_identity provenance |> EO.target_identity_fingerprint
  ; receipt_generation =
      EO.receipt_catalog_generation receipt |> EO.catalog_generation_fingerprint
  ; receipt_evidence = EO.receipt_catalog_evidence receipt |> EO.catalog_evidence_sha256
  ; receipt_identity =
      EO.receipt_target_identity receipt |> EO.target_identity_fingerprint
  ; plan_fingerprint = EO.plan_fingerprint plan
  }
;;

let check_observation_is_coherent label observation =
  check
    string
    (label ^ " selected generation")
    observation.snapshot_generation
    observation.selected_generation;
  check
    string
    (label ^ " provenance generation")
    observation.snapshot_generation
    observation.provenance_generation;
  check
    string
    (label ^ " receipt generation")
    observation.snapshot_generation
    observation.receipt_generation;
  check
    string
    (label ^ " selected evidence")
    observation.snapshot_evidence
    observation.selected_evidence;
  check
    string
    (label ^ " provenance evidence")
    observation.snapshot_evidence
    observation.provenance_evidence;
  check
    string
    (label ^ " receipt evidence")
    observation.snapshot_evidence
    observation.receipt_evidence;
  check
    string
    (label ^ " provenance identity")
    observation.selected_identity
    observation.provenance_identity;
  check
    string
    (label ^ " receipt identity")
    observation.selected_identity
    observation.receipt_identity
;;

let functional_observation observation =
  ( observation.snapshot_generation
  , observation.selected_generation
  , observation.selected_identity
  , observation.provenance_generation
  , observation.provenance_identity
  , observation.receipt_generation
  , observation.receipt_identity
  , observation.plan_fingerprint )
;;

let string_contains ~haystack ~needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec loop offset =
    offset + needle_length <= haystack_length
    && (String.sub haystack offset needle_length = needle || loop (offset + 1))
  in
  needle_length = 0 || loop 0
;;

let test_target_enable_thinking_is_typed_frozen_functional_identity () =
  let absent = snapshot (target_catalog ()) in
  let disabled = snapshot (target_catalog ~enable_thinking:false ()) in
  let enabled = snapshot (target_catalog ~enable_thinking:true ()) in
  let observations =
    [ "absent", absent, resolve absent "snapshot-target"
    ; "disabled", disabled, resolve disabled "snapshot-target"
    ; "enabled", enabled, resolve enabled "snapshot-target"
    ]
  in
  let pairs =
    [ List.nth observations 0, List.nth observations 1
    ; List.nth observations 0, List.nth observations 2
    ; List.nth observations 1, List.nth observations 2
    ]
  in
  List.iter
    (fun ( (left_label, left_snapshot, left_target)
         , (right_label, right_snapshot, right_target) ) ->
       let label = left_label ^ "/" ^ right_label in
       check
         bool
         (label ^ " changes catalog evidence")
         true
         (evidence left_snapshot <> evidence right_snapshot);
       check
         bool
         (label ^ " changes target identity")
         true
         (identity left_target <> identity right_target);
       check
         bool
         (label ^ " changes catalog generation")
         true
         (generation left_snapshot <> generation right_snapshot))
    pairs;
  let absent_before =
    generation absent, evidence absent, identity (resolve absent "snapshot-target")
  in
  ignore (resolve disabled "snapshot-target" : EO.selected_target);
  ignore (resolve enabled "snapshot-target" : EO.selected_target);
  let absent_after =
    generation absent, evidence absent, identity (resolve absent "snapshot-target")
  in
  check
    bool
    "later target-policy snapshots do not mutate the old snapshot"
    true
    (absent_before = absent_after);
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let overlay : EO.catalog_document =
    { source = "non-boolean target enable_thinking"
    ; contents = target_catalog () ^ "enable_thinking = \"true\"\n"
    }
  in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error (EO.Target_catalog_invalid { detail; _ }) ->
    check
      bool
      "non-boolean target enable_thinking is rejected exactly"
      true
      (string_contains ~haystack:detail ~needle:"non-boolean enable_thinking")
  | Ok _ | Error _ -> fail "non-boolean target enable_thinking must fail closed"
;;

let test_exact_target_id_has_no_alias_or_default () =
  let snapshot =
    snapshot
      (target_catalog ~aliases:[ "snapshot-alias" ] ~default_model:"different-default" ())
  in
  ignore (resolve snapshot "snapshot-target" : EO.selected_target);
  List.iter
    (fun id ->
       match EO.admit_target_ref snapshot id with
       | Error (EO.Target_not_in_catalog unknown) -> check string "exact miss" id unknown
       | Ok _ | Error _ -> failf "%S must not alias or default to a target" id)
    [ "snapshot-alias"; "snapshot-fixture"; "different-default" ]
;;

let test_environment_is_consumed_once_and_snapshot_is_immutable () =
  let values =
    ref
      [ "SNAPSHOT_BASE", "https://first.example"
      ; "SNAPSHOT_KEY", "first-secret"
      ; "OLLAMA_CLOUD_API_KEY", "embedded-fixture"
      ]
  in
  let reads = Hashtbl.create 4 in
  let getenv name =
    Hashtbl.replace reads name (1 + Option.value (Hashtbl.find_opt reads name) ~default:0);
    Ok (List.assoc_opt name !values)
  in
  let snapshot =
    snapshot
      ~getenv
      (target_catalog ~base_url_env:"SNAPSHOT_BASE" ~api_key_env:"SNAPSHOT_KEY" ())
  in
  let before = resolve snapshot "snapshot-target" in
  let before_plan_fingerprint = ready before |> EO.plan_fingerprint in
  check int "base URL read once" 1 (Hashtbl.find reads "SNAPSHOT_BASE");
  check int "credential read once" 1 (Hashtbl.find reads "SNAPSHOT_KEY");
  values
  := [ "SNAPSHOT_BASE", "https://rotated.example"
     ; "SNAPSHOT_KEY", "rotated-secret"
     ; "OLLAMA_CLOUD_API_KEY", "rotated-embedded"
     ];
  Fun.protect
    ~finally:(fun () ->
      Model_catalog.clear_global ();
      Provider_catalog.clear_global ())
    (fun () ->
       Model_catalog.set_global Model_catalog.empty;
       Provider_catalog.clear_global ();
       let after = resolve snapshot "snapshot-target" in
       let after_plan_fingerprint = ready after |> EO.plan_fingerprint in
       check
         string
         "frozen request remains unchanged"
         before_plan_fingerprint
         after_plan_fingerprint;
       check string "identity remains frozen" (identity before) (identity after);
       check
         int
         "resolve/admit do not reread URL env"
         1
         (Hashtbl.find reads "SNAPSHOT_BASE");
       check
         int
         "resolve/admit do not reread credential env"
         1
         (Hashtbl.find reads "SNAPSHOT_KEY"))
;;

let test_credential_outcomes_are_frozen_per_target () =
  let contents =
    String.concat
      "\n"
      [ target_catalog
          ~provider:"credential-no-auth-provider"
          ~model:"credential-no-auth-model"
          ~target:"credential-no-auth"
          ()
      ; target_catalog
          ~provider:"credential-available-provider"
          ~api_key_env:"AVAILABLE_FIXTURE_KEY"
          ~model:"credential-available-model"
          ~target:"credential-available"
          ()
      ; target_catalog
          ~provider:"credential-shared-provider"
          ~api_key_env:"AVAILABLE_FIXTURE_KEY"
          ~model:"credential-shared-model"
          ~target:"credential-shared"
          ()
      ; target_catalog
          ~provider:"credential-missing-provider"
          ~api_key_env:"MISSING_FIXTURE_KEY"
          ~model:"credential-missing-model"
          ~target:"credential-missing"
          ()
      ; target_catalog
          ~provider:"credential-invalid-provider"
          ~api_key_env:"INVALID_FIXTURE_KEY"
          ~model:"credential-invalid-model"
          ~target:"credential-invalid"
          ()
      ; target_catalog
          ~provider:"credential-read-failed-provider"
          ~api_key_env:"READ_FAILED_FIXTURE_KEY"
          ~model:"credential-read-failed-model"
          ~target:"credential-read-failed"
          ()
      ]
  in
  let values =
    ref
      [ "AVAILABLE_FIXTURE_KEY", Ok (Some "first-secret")
      ; "MISSING_FIXTURE_KEY", Ok None
      ; "INVALID_FIXTURE_KEY", Ok (Some "secret\r\nX-Leak: yes")
      ; "READ_FAILED_FIXTURE_KEY", Error ()
      ]
  in
  let reads = Hashtbl.create 8 in
  let getenv name =
    Hashtbl.replace reads name (1 + Option.value (Hashtbl.find_opt reads name) ~default:0);
    Option.value (List.assoc_opt name !values) ~default:(Ok None)
  in
  let frozen = snapshot ~getenv contents in
  let no_auth = admit frozen "credential-no-auth" in
  let available = admit frozen "credential-available" in
  let shared_available = admit frozen "credential-shared" in
  let missing = admit frozen "credential-missing" in
  let invalid = admit frozen "credential-invalid" in
  let read_failed = admit frozen "credential-read-failed" in
  ignore (resolve_admitted no_auth : EO.selected_target);
  let available_target = resolve_admitted available in
  ignore (resolve_admitted shared_available : EO.selected_target);
  let expect_missing admitted =
    match EO.resolve_target admitted with
    | Error error ->
      (match EO.target_selection_error_disposition error with
       | EO.Runtime_slot_unavailable -> ()
       | _ -> fail "missing credential must remain a runtime-slot outcome")
    | Ok _ -> fail "missing credential unexpectedly resolved"
  in
  let expect_invalid admitted =
    match EO.resolve_target admitted with
    | Error error ->
      (match EO.target_selection_error_disposition error with
       | EO.Runtime_slot_unavailable -> ()
       | _ -> fail "invalid credential must remain a runtime-slot outcome")
    | Ok _ -> fail "invalid credential unexpectedly resolved"
  in
  let expect_read_failed admitted =
    match EO.resolve_target admitted with
    | Error error ->
      (match EO.target_selection_error_disposition error with
       | EO.Runtime_slot_unavailable -> ()
       | _ -> fail "credential read failure must remain a runtime-slot outcome")
    | Ok _ -> fail "read-failed credential unexpectedly resolved"
  in
  expect_missing missing;
  expect_invalid invalid;
  expect_read_failed read_failed;
  List.iter
    (fun name ->
       check
         int
         (name ^ " observed once while freezing")
         1
         (Option.value (Hashtbl.find_opt reads name) ~default:0))
    [ "AVAILABLE_FIXTURE_KEY"
    ; "MISSING_FIXTURE_KEY"
    ; "INVALID_FIXTURE_KEY"
    ; "READ_FAILED_FIXTURE_KEY"
    ];
  values
  := [ "AVAILABLE_FIXTURE_KEY", Ok (Some "rotated-secret")
     ; "MISSING_FIXTURE_KEY", Ok (Some "now-present")
     ; "INVALID_FIXTURE_KEY", Ok (Some "now-valid")
     ; "READ_FAILED_FIXTURE_KEY", Ok (Some "read-now-works")
     ];
  ignore (resolve_admitted available : EO.selected_target);
  ignore (resolve_admitted shared_available : EO.selected_target);
  expect_missing missing;
  expect_invalid invalid;
  expect_read_failed read_failed;
  List.iter
    (fun name ->
       check
         int
         (name ^ " is not reread while resolving")
         1
         (Option.value (Hashtbl.find_opt reads name) ~default:0))
    [ "AVAILABLE_FIXTURE_KEY"
    ; "MISSING_FIXTURE_KEY"
    ; "INVALID_FIXTURE_KEY"
    ; "READ_FAILED_FIXTURE_KEY"
    ];
  let rotated = snapshot ~getenv contents in
  List.iter
    (fun id -> ignore (resolve rotated id : EO.selected_target))
    [ "credential-no-auth"
    ; "credential-available"
    ; "credential-shared"
    ; "credential-missing"
    ; "credential-invalid"
    ; "credential-read-failed"
    ];
  check
    string
    "credential rotation does not change catalog generation"
    (generation frozen)
    (generation rotated);
  check
    string
    "credential rotation does not change catalog evidence"
    (evidence frozen)
    (evidence rotated);
  check
    string
    "credential rotation does not change target identity"
    (identity available_target)
    (identity (resolve rotated "credential-available"));
  (match EO.admit_target_ref frozen "missing-target" with
   | Error (EO.Target_not_in_catalog "missing-target") -> ()
   | Ok _ | Error _ -> fail "unknown catalog membership must remain typed");
  match EO.admit_target_ref frozen "../invalid-target" with
  | Error (EO.Target_ref_rejected EO.Invalid_target_ref) -> ()
  | Ok _ | Error _ -> fail "target syntax rejection must remain typed"
;;

let with_temp_catalog contents f =
  let path = Filename.temp_file "exact-output-full-replacement-" ".toml" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
       Out_channel.with_open_bin path (fun channel ->
         Out_channel.output_string channel contents);
       f path)
;;

let replacement_snapshot contents =
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let document : EO.catalog_document =
    { source = "in-memory full replacement"; contents }
  in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Full_replacement document) () with
  | Ok snapshot -> snapshot
  | Error _ -> fail "full replacement snapshot should load"
;;

let test_full_replacement_path_is_frozen_and_suppresses_embedded () =
  let first_contents =
    target_catalog
      ~provider:"replacement-a-provider"
      ~base_url:"https://replacement-a.example"
      ~model:"replacement-a-model"
      ~target:"replacement-a-target"
      ()
  in
  let second_contents =
    target_catalog
      ~provider:"replacement-b-provider"
      ~base_url:"https://replacement-b.example"
      ~model:"replacement-b-model"
      ~target:"replacement-b-target"
      ()
  in
  with_temp_catalog first_contents
  @@ fun path ->
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let load () =
    match EO.load_resolver_snapshot ~io ~catalog:(EO.Full_replacement_file path) () with
    | Ok snapshot -> snapshot
    | Error _ -> fail "full replacement path should load"
  in
  let first_snapshot = load () in
  let first_handle = admit first_snapshot "replacement-a-target" in
  let first_expected =
    frozen_observation first_snapshot (resolve_admitted first_handle)
  in
  Out_channel.with_open_bin path (fun channel ->
    Out_channel.output_string channel second_contents);
  check
    bool
    "first handle remains coherent after source overwrite"
    true
    (first_expected = frozen_observation first_snapshot (resolve_admitted first_handle));
  let second_snapshot = load () in
  let second_handle = admit second_snapshot "replacement-b-target" in
  let second_expected =
    frozen_observation second_snapshot (resolve_admitted second_handle)
  in
  Sys.remove path;
  check
    bool
    "first handle remains coherent after source deletion"
    true
    (first_expected = frozen_observation first_snapshot (resolve_admitted first_handle));
  check
    bool
    "second handle remains coherent after source deletion"
    true
    (second_expected = frozen_observation second_snapshot (resolve_admitted second_handle));
  check
    bool
    "separately loaded file snapshots remain distinct"
    true
    (first_expected <> second_expected);
  let expect_absent snapshot id =
    match EO.admit_target_ref snapshot id with
    | Error (EO.Target_not_in_catalog actual) -> check string "exact absence" id actual
    | Ok _ | Error _ -> failf "%S must not belong to this frozen snapshot" id
  in
  expect_absent first_snapshot "replacement-b-target";
  expect_absent second_snapshot "replacement-a-target";
  expect_absent first_snapshot "ollama-cloud-minimax-m3-json";
  expect_absent second_snapshot "ollama-cloud-minimax-m3-json"
;;

let test_invalid_full_replacement_inputs_fail_without_fallback () =
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let invalid : EO.catalog_document =
    { source = "invalid full replacement"; contents = "[[providers]" }
  in
  (match EO.load_resolver_snapshot ~io ~catalog:(EO.Full_replacement invalid) () with
   | Error (EO.Catalog_parse_failed { source = EO.Full_replacement_catalog; _ }) -> ()
   | Ok _ | Error _ -> fail "invalid replacement must not fall back to embedded");
  let missing_path = Filename.temp_file "missing-exact-output-catalog-" ".toml" in
  Sys.remove missing_path;
  match
    EO.load_resolver_snapshot ~io ~catalog:(EO.Full_replacement_file missing_path) ()
  with
  | Error (EO.Catalog_read_failed { path; _ }) ->
    check string "missing replacement path is preserved" missing_path path
  | Ok _ | Error _ -> fail "missing replacement file must fail without fallback"
;;

let test_credential_rotation_is_not_functional_identity () =
  let contents = target_catalog ~api_key_env:"ROTATING_FIXTURE_KEY" () in
  let load credential =
    snapshot
      ~getenv:(fun name ->
        Ok
          (if String.equal name "ROTATING_FIXTURE_KEY"
           then Some credential
           else if String.equal name "OLLAMA_CLOUD_API_KEY"
           then Some "embedded-fixture"
           else None))
      contents
  in
  let first = load "first-secret" in
  let second = load "second-secret" in
  let first_target = resolve first "snapshot-target" in
  let second_target = resolve second "snapshot-target" in
  check
    string
    "secret rotation leaves generation stable"
    (generation first)
    (generation second);
  check
    string
    "secret rotation leaves target identity stable"
    (identity first_target)
    (identity second_target);
  check
    string
    "secret rotation leaves public plan fingerprint stable"
    (ready first_target |> EO.plan_fingerprint)
    (ready second_target |> EO.plan_fingerprint)
;;

let test_pricing_and_formatting_are_nonfunctional () =
  let first_contents = target_catalog ~price:1.0 () in
  let second_contents = target_catalog ~price:999999.0 () in
  let formatted_contents = "# formatting-only overlay\n\n" ^ first_contents ^ "\n" in
  let first = snapshot first_contents in
  let second = snapshot second_contents in
  let formatted = snapshot formatted_contents in
  let first_target = resolve first "snapshot-target" in
  let second_target = resolve second "snapshot-target" in
  let formatted_target = resolve formatted "snapshot-target" in
  check
    string
    "pricing leaves generation unchanged"
    (generation first)
    (generation second);
  check
    string
    "pricing leaves identity unchanged"
    (identity first_target)
    (identity second_target);
  check
    string
    "pricing leaves plan fingerprint unchanged"
    (ready first_target |> EO.plan_fingerprint)
    (ready second_target |> EO.plan_fingerprint);
  check bool "pricing remains auditable evidence" true (evidence first <> evidence second);
  check
    string
    "TOML formatting leaves generation unchanged"
    (generation first)
    (generation formatted);
  check
    string
    "TOML formatting leaves identity unchanged"
    (identity first_target)
    (identity formatted_target);
  check
    bool
    "TOML formatting preserves canonical evidence"
    true
    (evidence first = evidence formatted)
;;

let test_supported_models_order_is_canonical () =
  let first =
    snapshot
      (target_catalog
         ~model_extra:"supported_models = [\"snapshot-model\", \"secondary-model\"]\n"
         ())
  in
  let reordered =
    snapshot
      (target_catalog
         ~model_extra:"supported_models = [\"secondary-model\", \"snapshot-model\"]\n"
         ())
  in
  let changed =
    snapshot
      (target_catalog
         ~model_extra:"supported_models = [\"snapshot-model\", \"different-model\"]\n"
         ())
  in
  check
    string
    "supported_models order leaves generation unchanged"
    (generation first)
    (generation reordered);
  check
    string
    "supported_models order leaves canonical evidence unchanged"
    (evidence first)
    (evidence reordered);
  check
    bool
    "supported_models value changes canonical evidence"
    true
    (evidence first <> evidence changed)
;;

let test_every_functional_projection_field_changes_generation () =
  let base = snapshot (target_catalog ()) in
  let variants =
    [ "base URL", target_catalog ~base_url:"https://other.example" ()
    ; "request path", target_catalog ~request_path:"/v1/other" ()
    ; "request body limit", target_catalog ~max_request_body_bytes:4096 ()
    ; "connect timeout", target_catalog ~connect_timeout_s:3.5 ()
    ; "body timeout", target_catalog ~body_timeout_s:9.5 ()
    ; "capability", target_catalog ~structured:true ()
    ; ( "document capability"
      , target_catalog ~model_extra:"supports_document_input = true\n" () )
    ; "audio capability", target_catalog ~model_extra:"supports_audio_input = true\n" ()
    ; ( "supported models"
      , target_catalog ~model_extra:"supported_models = [\"snapshot-model\"]\n" () )
    ; "codec", target_catalog ~kind:"ollama" ~request_path:"/api/chat" ()
    ]
  in
  List.iter
    (fun (label, contents) ->
       let changed = snapshot contents in
       check
         bool
         (label ^ " changes functional generation")
         true
         (generation base <> generation changed))
    variants;
  let endpoint_changed = snapshot (target_catalog ~base_url:"https://other.example" ()) in
  check
    bool
    "functional target change reaches plan fingerprint"
    true
    (ready (resolve base "snapshot-target")
     |> EO.plan_fingerprint
     <> (ready (resolve endpoint_changed "snapshot-target") |> EO.plan_fingerprint))
;;

let test_one_fresh_handle_is_immutably_shareable_across_domains () =
  let snapshot = snapshot (target_catalog ~base_url:"https://shared.example" ()) in
  let handle = admit snapshot "snapshot-target" in
  let first_domain =
    Domain.spawn (fun () -> frozen_observation snapshot (resolve_admitted handle))
  in
  let second_domain =
    Domain.spawn (fun () -> frozen_observation snapshot (resolve_admitted handle))
  in
  let first_observation = Domain.join first_domain in
  let second_observation = Domain.join second_domain in
  check_observation_is_coherent "shared handle first Domain" first_observation;
  check_observation_is_coherent "shared handle second Domain" second_observation;
  check
    bool
    "one freshly admitted handle yields identical immutable Domain observations"
    true
    (first_observation = second_observation)
;;

let test_old_and_new_whole_tuples_never_mix_across_domains_and_fibers () =
  let old_snapshot = snapshot (target_catalog ~base_url:"https://old.example" ()) in
  let new_snapshot = snapshot (target_catalog ~base_url:"https://new.example" ()) in
  let old_handle = admit old_snapshot "snapshot-target" in
  let new_handle = admit new_snapshot "snapshot-target" in
  let expected_old = frozen_observation old_snapshot (resolve_admitted old_handle) in
  let expected_new = frozen_observation new_snapshot (resolve_admitted new_handle) in
  let old_domain =
    Domain.spawn (fun () -> frozen_observation old_snapshot (resolve_admitted old_handle))
  in
  let new_domain =
    Domain.spawn (fun () -> frozen_observation new_snapshot (resolve_admitted new_handle))
  in
  let old_domain_observation = Domain.join old_domain in
  let new_domain_observation = Domain.join new_domain in
  check
    bool
    "immutable handle A crosses a Domain without rebinding"
    true
    (old_domain_observation = expected_old);
  check
    bool
    "immutable handle B crosses a Domain without rebinding"
    true
    (new_domain_observation = expected_new);
  check
    bool
    "cross-Domain handles preserve distinct whole tuples"
    true
    (old_domain_observation <> new_domain_observation);
  let observe snapshot admitted signal_arrived gate =
    let target = resolve_admitted admitted in
    Eio.Promise.resolve signal_arrived ();
    Eio.Promise.await gate;
    frozen_observation snapshot target
  in
  let old_observation, new_observation =
    Fun.protect ~finally:(fun () ->
      Model_catalog.clear_global ();
      Provider_catalog.clear_global ())
    @@ fun () ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let old_arrived, signal_old_arrived = Eio.Promise.create () in
    let new_arrived, signal_new_arrived = Eio.Promise.create () in
    let gate, open_gate = Eio.Promise.create () in
    let old_result, resolve_old_result = Eio.Promise.create () in
    let new_result, resolve_new_result = Eio.Promise.create () in
    Eio.Fiber.fork ~sw (fun () ->
      observe old_snapshot old_handle signal_old_arrived gate
      |> Eio.Promise.resolve resolve_old_result);
    Eio.Fiber.fork ~sw (fun () ->
      observe new_snapshot new_handle signal_new_arrived gate
      |> Eio.Promise.resolve resolve_new_result);
    Eio.Promise.await old_arrived;
    Eio.Promise.await new_arrived;
    Model_catalog.set_global Model_catalog.empty;
    Provider_catalog.clear_global ();
    Eio.Promise.resolve open_gate ();
    Eio.Promise.await old_result, Eio.Promise.await new_result
  in
  check_observation_is_coherent "concurrent old" old_observation;
  check_observation_is_coherent "concurrent new" new_observation;
  check
    bool
    "old selected/provenance/receipt tuple is exactly snapshot A"
    true
    (old_observation = expected_old);
  check
    bool
    "new selected/provenance/receipt tuple is exactly snapshot B"
    true
    (new_observation = expected_new);
  check bool "A and B whole tuples differ" true (old_observation <> new_observation)
;;

let expect_endpoint_error label expected_cause contents =
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let overlay : EO.catalog_document = { source = label; contents } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error (EO.Target_endpoint_invalid { cause; _ }) ->
    check bool (label ^ " exact typed cause") true (cause = expected_cause)
  | Error _ -> fail (label ^ " returned the wrong resolver error class")
  | Ok _ -> fail (label ^ " must fail closed")
;;

let test_endpoint_error_cause_table () =
  let cases =
    [ "malformed URL", EO.Malformed_base_url, target_catalog ~base_url:"not-a-url" ()
    ; ( "URL control"
      , EO.Malformed_base_url
      , target_catalog ~base_url:"https://snapshot.example\r\nX-Secret: hidden" () )
    ; ( "URL userinfo"
      , EO.Base_url_userinfo_not_allowed
      , target_catalog ~base_url:"https://user:secret@snapshot.example" () )
    ; ( "URL query"
      , EO.Base_url_query_not_allowed
      , target_catalog ~base_url:"https://snapshot.example?token=secret" () )
    ; ( "URL fragment"
      , EO.Base_url_fragment_not_allowed
      , target_catalog ~base_url:"https://snapshot.example#secret" () )
    ; ( "path dot traversal"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1/../secret" () )
    ; ( "path encoded traversal"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1/%2e%2e/secret" () )
    ; ( "path backslash"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1\\secret" () )
    ; ( "path repeated slash"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1//chat" () )
    ; ( "path query"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1/chat?secret=1" () )
    ; ( "path fragment"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1/chat#secret" () )
    ; ( "path control"
      , EO.Invalid_request_path
      , target_catalog ~request_path:"/v1/chat\r\nX-Secret: hidden" () )
    ; ( "Gemini slash segment"
      , EO.Invalid_gemini_model_path
      , target_catalog ~kind:"gemini" ~request_path:"" ~model:"bad/model" () )
    ; ( "Gemini encoded segment"
      , EO.Invalid_gemini_model_path
      , target_catalog ~kind:"gemini" ~request_path:"" ~model:"bad%2Fmodel" () )
    ]
  in
  List.iter
    (fun (label, cause, contents) -> expect_endpoint_error label cause contents)
    cases
;;

let test_caller_headers_fail_closed () =
  let header_secret = "must-not-appear-in-diagnostic" in
  let contents =
    target_catalog () ^ Printf.sprintf "headers = [\"Authorization: %s\"]\n" header_secret
  in
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let overlay : EO.catalog_document = { source = "caller header"; contents } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error (EO.Target_catalog_invalid { detail; _ }) ->
    check
      bool
      "rejected caller-header diagnostic omits its value"
      false
      (string_contains ~haystack:detail ~needle:header_secret)
  | Error _ -> fail "caller target headers returned the wrong resolver error class"
  | Ok _ -> fail "caller target headers must be rejected"
;;

let expect_collision_error label expected contents =
  let io : EO.resolver_io = { getenv = (fun _ -> Ok None) } in
  let overlay : EO.catalog_document = { source = label; contents } in
  match EO.load_resolver_snapshot ~io ~catalog:(EO.Embedded_with_overlay overlay) () with
  | Error (EO.Catalog_collision collision) ->
    check bool (label ^ " exact collision") true (collision = expected)
  | Error _ -> fail (label ^ " returned the wrong resolver error class")
  | Ok _ -> fail (label ^ " must fail closed")
;;

let test_collision_and_input_hardening () =
  expect_collision_error
    "alias shadow"
    EO.Provider_alias_shadow
    (target_catalog ~provider:"attacker" ~aliases:[ "ollama_cloud" ] ());
  let duplicate_target =
    target_catalog ~provider:"case-provider" ~model:"case-model" ~target:"case-target" ()
    ^ "\n\
       [[targets]]\n\
       id = \"CASE-TARGET\"\n\
       provider_ref = \"case-provider\"\n\
       model_id = \"case-model\"\n"
  in
  expect_collision_error
    "target case shadow"
    EO.Duplicate_target_identity
    duplicate_target;
  let hardening_snapshot = snapshot (target_catalog ()) in
  List.iter
    (fun malicious ->
       match EO.admit_target_ref hardening_snapshot malicious with
       | Error (EO.Target_ref_rejected EO.Invalid_target_ref) -> ()
       | Ok _ | Error _ ->
         failf "malicious target ref %S must have the exact typed rejection" malicious)
    [ "../target"; "target?key=secret"; "target\nheader"; "target/child" ]
;;

let () =
  run
    "exact-output-resolver-snapshot"
    [ ( "resolver"
      , [ test_case "exact id only" `Quick test_exact_target_id_has_no_alias_or_default
        ; test_case
            "environment consumed once"
            `Quick
            test_environment_is_consumed_once_and_snapshot_is_immutable
        ; test_case
            "credential outcomes frozen per target"
            `Quick
            test_credential_outcomes_are_frozen_per_target
        ; test_case
            "full replacement path suppresses embedded"
            `Quick
            test_full_replacement_path_is_frozen_and_suppresses_embedded
        ; test_case
            "invalid full replacement has no fallback"
            `Quick
            test_invalid_full_replacement_inputs_fail_without_fallback
        ; test_case
            "credential rotation is nonfunctional"
            `Quick
            test_credential_rotation_is_not_functional_identity
        ; test_case
            "pricing and formatting nonfunctional"
            `Quick
            test_pricing_and_formatting_are_nonfunctional
        ; test_case
            "supported_models canonical order"
            `Quick
            test_supported_models_order_is_canonical
        ; test_case
            "functional projection sensitivity"
            `Quick
            test_every_functional_projection_field_changes_generation
        ; test_case
            "target thinking policy is typed and frozen"
            `Quick
            test_target_enable_thinking_is_typed_frozen_functional_identity
        ; test_case
            "one fresh handle is immutable across Domains"
            `Quick
            test_one_fresh_handle_is_immutably_shareable_across_domains
        ; test_case
            "old/new whole-tuple Domain and fiber separation"
            `Quick
            test_old_and_new_whole_tuples_never_mix_across_domains_and_fibers
        ; test_case "endpoint exact-cause table" `Quick test_endpoint_error_cause_table
        ; test_case "caller headers rejected" `Quick test_caller_headers_fail_closed
        ; test_case
            "collision and input hardening"
            `Quick
            test_collision_and_input_hardening
        ] )
    ]
;;
