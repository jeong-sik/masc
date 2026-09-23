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

(* The lane editor and the Fusion editor read one list of seats. A preset
   naming the fixture's lane at each kind of seat: a panel member, the judge
   and a first judge. *)
let first_judge jmodel : Fusion_policy.judge_spec =
  { jmodel
  ; jlabel = ""
  ; jsystem_prompt = "First."
  ; jweb_tools = false
  ; jmax_output_tokens = None
  ; jtimeout_s = None
  }
;;

let seats_on ~route ~panel ~judge ~judges (trio : Fusion_policy.preset) =
  let pick named other = if named then route else other in
  { trio with
    Fusion_policy.panels =
      List.map
        (fun (group : Fusion_policy.panel_group) ->
           { group with
             models = [ pick panel "stub-http.stub-model"; "stub-http.stub-alt" ]
           })
        trio.panels
  ; judge = pick judge "stub-http.stub-model"
  ; judges = [ first_judge (pick judges "stub-http.stub-model"); first_judge "stub-http.stub-alt" ]
  }
;;

let seat_trio path =
  let trio =
    seats_on ~route:"fusion-judge" ~panel:true ~judge:true ~judges:true
      (preset_named path "trio")
  in
  (match apply path (Masc.Fusion_config_edit.Upsert_preset trio) with
   | Ok _ -> ()
   | Error error -> failf "seating trio: %s" (Masc.Fusion_config_edit.error_message error));
  trio
;;

let contains text needle =
  let n = String.length needle and h = String.length text in
  let rec go i = i + n <= h && (String.equal (String.sub text i n) needle || go (i + 1)) in
  go 0
;;

let test_lane_rename_rewrites_fusion_seats () =
  with_config (fun path ->
    let trio = seat_trio path in
    (match
       Runtime.rename_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge"
         ~new_lane_id:"arbiter" ()
     with
     | Ok _ -> ()
     | Error detail -> failf "rename refused: %s" detail);
    check (testable Fusion_policy.pp_preset Fusion_policy.equal_preset)
      "every seat on the lane took the new name"
      (seats_on ~route:"arbiter" ~panel:true ~judge:true ~judges:true trio)
      (preset_named path "trio");
    check bool "no seat names the old lane" false (contains (read path) "\"fusion-judge\"");
    (* The Fusion editor resolves every seat the way a run does, so saving
       trio again proves a run would find the renamed lane. *)
    match apply path (Masc.Fusion_config_edit.Upsert_preset (preset_named path "trio")) with
    | Ok _ -> ()
    | Error error ->
      failf "a renamed seat does not resolve: %s" (Masc.Fusion_config_edit.error_message error))
;;

let test_lane_remove_is_refused_while_a_seat_names_it () =
  with_config (fun path ->
    let _ = seat_trio path in
    let before = read path in
    (match Runtime.remove_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge" () with
     | Ok _ -> fail "a lane a Fusion seat names was removed"
     | Error detail ->
       List.iter
         (fun seat ->
            check bool ("the refusal names " ^ seat) true (contains detail seat))
         [ "[fusion.presets.trio].panel"
         ; "[fusion.presets.trio].judge"
         ; "[fusion.presets.trio].judges"
         ]);
    check string "file untouched" before (read path))
;;

(* A [fusion] that does not load hides its seats, so neither lane writer can
   know which ones name the lane; both refuse rather than guess none do. *)
let test_lane_edits_refuse_while_fusion_does_not_load () =
  with_config (fun path ->
    let broken =
      let text = read path in
      let marker = "judge_system_prompt = \"Judge.\"\n" in
      let at = String.length text - String.length marker in
      check string "the fixture ends with spare's judge prompt" marker
        (String.sub text at (String.length marker));
      String.sub text 0 at ^ "min_answered = 9\n" ^ marker
    in
    write_file path broken;
    let refused label result =
      match result with
      | Ok _ -> failf "%s went through with [fusion] unreadable" label
      | Error detail ->
        check bool (label ^ " names the cause") true
          (contains detail "[fusion] does not load")
    in
    let cause =
      Fusion_config.config_error_message (Fusion_config.Invalid_min_answered ("spare", 9))
    in
    let refused label result =
      refused label result;
      match result with
      | Ok _ -> ()
      | Error detail ->
        check bool (label ^ " names the load error") true (contains detail cause);
        check bool (label ^ " names the raw endpoint") true
          (contains detail "POST /api/v1/runtime/config/raw")
    in
    refused "remove"
      (Runtime.remove_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge" ());
    refused "rename"
      (Runtime.rename_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge"
         ~new_lane_id:"arbiter" ());
    check string "file untouched" broken (read path))
;;

(* A run trims a seat before it resolves it, so a padded seat names the lane
   too: the rename rewrites it and the remove refuses on it. The refusal is
   the server's own sentence, pinned here word for word. *)
let test_a_padded_seat_names_the_lane () =
  with_config (fun path ->
    let trio = { (preset_named path "trio") with Fusion_policy.judge = " fusion-judge " } in
    (match apply path (Masc.Fusion_config_edit.Upsert_preset trio) with
     | Ok _ -> ()
     | Error error -> failf "seating trio: %s" (Masc.Fusion_config_edit.error_message error));
    check string "the padded seat is on disk" " fusion-judge " (preset_named path "trio").judge;
    (match Runtime.remove_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge" () with
     | Ok _ -> fail "a lane a padded seat names was removed"
     | Error detail ->
       check string "the server's refusal"
         "lane \"fusion-judge\" is in use by [fusion.presets.trio].judge" detail);
    (match
       Runtime.rename_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge"
         ~new_lane_id:"arbiter" ()
     with
     | Ok _ -> ()
     | Error detail -> failf "rename refused: %s" detail);
    check string "the padded seat took the new name" "arbiter" (preset_named path "trio").judge)
;;

(* A preset the Fusion writer cannot address -- here, inline [judges] --
   refuses the rename, and the refusal says a lane rename reached it. *)
let test_an_unaddressable_seat_refuses_the_rename () =
  with_config (fun path ->
    let marker = "judge = \"stub-http.stub-model\"\n" in
    let text = read path in
    (* The first such line is trio's: the fixture writes trio before spare. *)
    let at =
      let n = String.length marker in
      let rec find i =
        if i + n > String.length text then fail "fixture has no trio judge line"
        else if String.equal (String.sub text i n) marker then i
        else find (i + 1)
      in
      find 0
    in
    let seated =
      String.sub text 0 at
      ^ marker
      ^ "judges = [ { model = \"fusion-judge\", system_prompt = \"First.\" } ]\n"
      ^ String.sub text (at + String.length marker)
          (String.length text - at - String.length marker)
    in
    write_file path seated;
    check string "the inline seat loads" "fusion-judge"
      (match (preset_named path "trio").judges with
       | [ judge ] -> judge.jmodel
       | _ -> fail "trio must read one inline first judge");
    (match
       Runtime.rename_runtime_lane ~runtime_config_path:path ~lane_id:"fusion-judge"
         ~new_lane_id:"arbiter" ()
     with
     | Ok _ -> fail "a rename rewrote a preset the writer cannot address"
     | Error detail ->
       check bool "the refusal says the lane rename reached the preset" true
         (contains detail "renaming lane \"fusion-judge\" rewrites a seat of preset trio"));
    check string "file untouched" seated (read path))
;;

(* For each kind of seat alone, the lane references and the Fusion route check
   both see it: the lane check reports that seat, and the Fusion check refuses
   the same route while no lane or runtime declares it. *)
let test_fusion_and_lane_checks_see_the_same_seats () =
  with_config (fun path ->
    let config =
      match Runtime_toml.parse_string (read path) with
      | Ok config -> config
      | Error _ -> fail "fixture must parse"
    in
    List.iter
      (fun (seat, panel, judge, judges) ->
         let label = Fusion_policy.seat_kind_key seat in
         let probe =
           seats_on ~route:"ghost" ~panel ~judge ~judges (preset_named path "trio")
         in
         let validated =
           match Fusion_policy.Validated_preset.of_preset probe with
           | Ok validated -> validated
           | Error _ -> failf "%s probe must validate" label
         in
         let policy : Fusion_policy.t =
           { enabled = true
           ; default_preset = "trio"
           ; staged_judge_group_size = Fusion_policy.default_staged_judge_group_size
           ; presets = [ validated ]
           }
         in
         let on_ghost =
           List.filter_map
             (fun (reference, route) ->
                if String.equal route "ghost" then Some reference else None)
             (Runtime.route_references config policy)
         in
         check bool (label ^ ": the lane check reports the seat") true
           (on_ghost = [ Runtime.Fusion_seat { preset = "trio"; seat } ]);
         match apply path (Masc.Fusion_config_edit.Upsert_preset probe) with
         | Error (Masc.Fusion_config_edit.Route_unresolved { route = "ghost"; _ }) -> ()
         | Error error ->
           failf "%s: unexpected refusal %s" label (Masc.Fusion_config_edit.error_message error)
         | Ok _ -> failf "%s: the Fusion check saved a seat on an unknown route" label)
      [ Fusion_policy.Panel_member, true, false, false
      ; Fusion_policy.Judge, false, true, false
      ; Fusion_policy.First_judge, false, false, true
      ])
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
    ; ( "lane references"
      , [ test_case "a lane rename rewrites the Fusion seats" `Quick
            test_lane_rename_rewrites_fusion_seats
        ; test_case "a lane remove is refused while a seat names it" `Quick
            test_lane_remove_is_refused_while_a_seat_names_it
        ; test_case "a padded seat names the lane" `Quick test_a_padded_seat_names_the_lane
        ; test_case "an unaddressable seat refuses the rename" `Quick
            test_an_unaddressable_seat_refuses_the_rename
        ; test_case "lane edits refuse while [fusion] does not load" `Quick
            test_lane_edits_refuse_while_fusion_does_not_load
        ; test_case "the Fusion and lane checks see the same seats" `Quick
            test_fusion_and_lane_checks_see_the_same_seats
        ] )
    ; ( "json", [ test_case "operation JSON is strict" `Quick test_operation_json_is_strict ] )
    ]
;;
