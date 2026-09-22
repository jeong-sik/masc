(* Fusion_config_edit: one typed operation reaches runtime.toml through the
   config lock, or is refused with the file untouched. Each refusal is checked
   against the bytes on disk, not only the returned error. *)

open Alcotest

let fixture =
  {|# operator note above everything
[runtime]
default = "stub-http.stub-model"

[runtime.lanes.fusion-judge]
candidates = ["stub-http.stub-model", "stub-http.stub-alt"]

[providers.stub-http]
display-name = "Stub HTTP"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:9/v1"

[models.stub-model]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[models.stub-alt]
api-name = "gpt-5.4"
max-context = 200000
tools-support = true
streaming = true

[stub-http.stub-model]

[stub-http.stub-alt]

[fusion]
enabled = true
default_preset = "trio"

# the trio note
[fusion.presets.trio]
panel = ["stub-http.stub-model", "stub-http.stub-alt"]
# judge note
judge = "stub-http.stub-model"
panel_system_prompt = "Answer."
judge_system_prompt = "Judge."

[fusion.presets.spare]
panel = ["stub-http.stub-model"]
judge = "stub-http.stub-model"
panel_system_prompt = "Answer."
judge_system_prompt = "Judge."
|}
;;

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))
;;

(* Boot tolerates a runtime whose models the AGENT_CORE catalog does not know;
   a commit does not, and every operation here commits. The fixture's models
   are declared to the catalog so the write reaches the fusion edit rather than
   stopping at the catalog gate. *)
let model_catalog =
  {|
[[models]]
id_prefix = "gpt-5.4"
provider_name = "stub-http"
base = "openai_chat"
max_context_tokens = 200000
supports_tools = true
|}
;;

let write_file path content =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel content)
;;

let with_model_catalog f =
  let previous = Llm_provider.Model_catalog.global () in
  let path = Filename.temp_file "fusion-config-edit-models" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      (match previous with
       | Some catalog -> Llm_provider.Model_catalog.set_global catalog
       | None -> Llm_provider.Model_catalog.clear_global ());
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       write_file path model_catalog;
       match Llm_provider.Model_catalog.load_file path with
       | Error detail -> failf "test AGENT_CORE model catalog must load: %s" detail
       | Ok catalog ->
         Llm_provider.Model_catalog.set_global catalog;
         f ())
;;

let with_config f =
  with_model_catalog @@ fun () ->
  let snapshot = Runtime.For_testing.snapshot () in
  let dir = Filename.temp_dir "fusion-config-edit" "" in
  let path = Filename.concat dir "runtime.toml" in
  write_file path fixture;
  Fun.protect
    ~finally:(fun () -> Runtime.For_testing.restore snapshot)
    (fun () ->
       match Runtime.init_default ~config_path:path with
       | Error detail -> failf "fixture runtime must initialize: %s" detail
       | Ok () -> f path)
;;

let revision path =
  match Runtime.load_config_observation ~runtime_config_path:path () with
  | Ok observation -> Runtime.config_source_revision_to_string observation.source_revision
  | Error detail -> failf "observation: %s" detail
;;

let preset_named path name =
  match Fusion_config.of_toml (Otoml.Parser.from_string (read path)) with
  | Error errors ->
    failf "written config must load: %s"
      (String.concat "; " (List.map Fusion_config.config_error_message errors))
  | Ok policy ->
    (match Fusion_policy.find_preset policy name with
     | Some validated -> Fusion_policy.Validated_preset.preset validated
     | None -> failf "preset %s must exist" name)
;;

let apply path ?expected_revision operation =
  let expected_revision =
    match expected_revision with
    | Some revision -> revision
    | None -> revision path
  in
  Masc.Fusion_config_edit.apply ~runtime_config_path:path ~expected_revision operation
;;

let expect_refusal ~label ~code path operation =
  let before = read path in
  (match apply path operation with
   | Ok _ -> failf "%s: expected a refusal" label
   | Error error ->
     check string (label ^ ": error code") code (Masc.Fusion_config_edit.error_code error));
  check string (label ^ ": file untouched") before (read path)
;;

let test_upsert_writes_a_lane_judge () =
  with_config (fun path ->
    let trio = preset_named path "trio" in
    let edited = { trio with Fusion_policy.judge = "fusion-judge"; min_answered = 2 } in
    let before_revision = revision path in
    (match apply path (Masc.Fusion_config_edit.Upsert_preset edited) with
     | Ok receipt ->
       check bool "the commit names a new revision" false
         (String.equal before_revision
            (Runtime.config_source_revision_to_string
               receipt.Runtime.observation.source_revision))
     | Error error -> failf "upsert refused: %s" (Masc.Fusion_config_edit.error_message error));
    check (testable Fusion_policy.pp_preset Fusion_policy.equal_preset)
      "the preset reads back from disk" edited (preset_named path "trio");
    let text = read path in
    let contains needle =
      let n = String.length needle and h = String.length text in
      let rec go i = i + n <= h && (String.equal (String.sub text i n) needle || go (i + 1)) in
      go 0
    in
    check bool "the note above everything survives" true (contains "# operator note above everything");
    check bool "the judge note survives" true (contains "# judge note"))
;;

(* The dashboard sends the whole preset on every save, so saving one it did not
   change must not reformat the operator's file. *)
let test_unchanged_upsert_leaves_the_file () =
  with_config (fun path ->
    let before = read path in
    (match apply path (Masc.Fusion_config_edit.Upsert_preset (preset_named path "trio")) with
     | Ok _ -> ()
     | Error error ->
       failf "unchanged upsert refused: %s" (Masc.Fusion_config_edit.error_message error));
    check string "runtime.toml is byte-identical" before (read path))
;;

let test_stale_revision_is_refused () =
  with_config (fun path ->
    let trio = preset_named path "trio" in
    let before = read path in
    (match
       apply path ~expected_revision:"not-the-revision-on-disk"
         (Masc.Fusion_config_edit.Upsert_preset { trio with Fusion_policy.judge = "fusion-judge" })
     with
     | Error Masc.Fusion_config_edit.Configuration_changed -> ()
     | Error error -> failf "unexpected error: %s" (Masc.Fusion_config_edit.error_message error)
     | Ok _ -> fail "a stale revision must not write");
    check string "file untouched" before (read path))
;;

let test_unknown_route_is_refused () =
  with_config (fun path ->
    let trio = preset_named path "trio" in
    expect_refusal ~label:"unknown judge route" ~code:"route_unresolved" path
      (Masc.Fusion_config_edit.Upsert_preset
         { trio with Fusion_policy.judge = "nope.not-configured" }))
;;

let test_invalid_preset_is_refused () =
  with_config (fun path ->
    let trio = preset_named path "trio" in
    expect_refusal ~label:"quorum above seats" ~code:"preset_invalid" path
      (Masc.Fusion_config_edit.Upsert_preset { trio with Fusion_policy.min_answered = 3 });
    expect_refusal ~label:"padded name" ~code:"name_invalid" path
      (Masc.Fusion_config_edit.Upsert_preset { trio with Fusion_policy.name = " trio" }))
;;

let test_deleting_the_default_is_refused () =
  with_config (fun path ->
    expect_refusal ~label:"delete default" ~code:"default_preset_deleted" path
      (Masc.Fusion_config_edit.Delete_preset "trio");
    match apply path (Masc.Fusion_config_edit.Delete_preset "spare") with
    | Ok _ -> ()
    | Error error -> failf "deleting a non-default preset: %s" (Masc.Fusion_config_edit.error_message error))
;;

let test_rename_follows_the_default () =
  with_config (fun path ->
    (match
       apply path (Masc.Fusion_config_edit.Rename_preset { from = "trio"; target = "duo" })
     with
     | Ok _ -> ()
     | Error error -> failf "rename refused: %s" (Masc.Fusion_config_edit.error_message error));
    let duo = preset_named path "duo" in
    check string "renamed preset keeps its judge" "stub-http.stub-model" duo.judge;
    match Fusion_config.of_toml (Otoml.Parser.from_string (read path)) with
    | Ok policy -> check string "default follows" "duo" policy.Fusion_policy.default_preset
    | Error _ -> fail "renamed config must load")
;;

let test_operation_json_is_strict () =
  let refuses label json =
    match Masc.Fusion_config_edit.operation_of_yojson json with
    | Error _ -> ()
    | Ok _ -> failf "%s must be refused" label
  in
  refuses "unknown kind" (`Assoc [ "kind", `String "drop_everything" ]);
  refuses "unknown key" (`Assoc [ "kind", `String "delete_preset"; "name", `String "a"; "force", `Bool true ]);
  refuses "missing key" (`Assoc [ "kind", `String "rename_preset"; "from", `String "a" ]);
  refuses "wrong type"
    (`Assoc
       [ "kind", `String "set_settings"
       ; "enabled", `String "true"
       ; "default_preset", `String "trio"
       ; "staged_judge_group_size", `Int 3
       ]);
  match
    Masc.Fusion_config_edit.operation_of_yojson
      (`Assoc [ "kind", `String "rename_preset"; "from", `String "a"; "to", `String "b" ])
  with
  | Ok (Masc.Fusion_config_edit.Rename_preset { from = "a"; target = "b" }) -> ()
  | Ok _ | Error _ -> fail "a well-formed rename decodes"
;;

let () =
  run
    "fusion config edit"
    [ ( "apply"
      , [ test_case "upsert writes a lane judge" `Quick test_upsert_writes_a_lane_judge
        ; test_case "unchanged upsert leaves the file" `Quick
            test_unchanged_upsert_leaves_the_file
        ; test_case "stale revision is refused" `Quick test_stale_revision_is_refused
        ; test_case "unknown route is refused" `Quick test_unknown_route_is_refused
        ; test_case "invalid preset is refused" `Quick test_invalid_preset_is_refused
        ; test_case "deleting the default is refused" `Quick test_deleting_the_default_is_refused
        ; test_case "rename follows the default" `Quick test_rename_follows_the_default
        ] )
    ; ( "json", [ test_case "operation JSON is strict" `Quick test_operation_json_is_strict ] )
    ]
;;
