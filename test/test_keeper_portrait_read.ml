open Masc

(* task-1830: the read-only portrait tool returns the equipment the name hash
   gives, plus a durable PNG artifact a Keeper can open.

   The tool is read-only: it never stores an equip choice. This test pins the
   two things the task's first stage promises: the reported equipment equals
   [equipment_of_name], and the artifact is a real PNG in the Keeper's vision
   store. *)

module Read = Masc.Keeper_portrait_read
module Look = Keeper_portrait_look
module Store = Multimodal.Vision_artifact_store
module Vision = Masc.Keeper_vision_tool
module Plan = Masc.Keeper_tool_plan

let with_temp_base f =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base = Filename.temp_dir "keeper-portrait-read" "" in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  let previous_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.unsetenv "MASC_CONFIG_DIR";
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw (fun () ->
    (match previous with Some value -> Unix.putenv "MASC_BASE_PATH" value | None -> Unix.unsetenv "MASC_BASE_PATH");
    (match previous_config with Some value -> Unix.putenv "MASC_CONFIG_DIR" value | None -> Unix.unsetenv "MASC_CONFIG_DIR");
    Config_dir_resolver.reset ();
    Masc_test_deps.cleanup_test_workspace base);
  f ()
;;

let field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some value -> value
     | None -> Alcotest.failf "the tool output has no %s" key)
  | other -> Alcotest.failf "the tool output is not an object: %s" (Yojson.Safe.to_string other)
;;

let call ~name ~args =
  Read.handle
    ~base_path:(Sys.getenv "MASC_BASE_PATH")
    ~keeper_name:name
    ~tool_name:"keeper_portrait_read"
    ~start_time:(Tool_timing.start ())
    ~args
;;

let completed_data (result : Tool_result.result) =
  match result with
  | Tool_result.Completed output -> output.data
  | Tool_result.Failed error -> Alcotest.fail error.message
  | Tool_result.Deferred _ -> Alcotest.fail "portrait read deferred"
;;

let string_field key data =
  match field key data with
  | `String value -> value
  | _ -> Alcotest.failf "%s is not a string" key
;;

let output_validator args =
  let id =
    match Plan.Node_id.make "portrait" with
    | Ok id -> id
    | Error Plan.Node_id.Empty -> Alcotest.fail "empty portrait node id"
  in
  let node =
    Plan.node ~id ~tool_name:"keeper_portrait_read"
      ~input:(Plan.Json_template.literal args) ()
  in
  let plan =
    match Plan.create ~descriptors:(Keeper_tool_descriptor.all_descriptors ()) [ node ] with
    | Ok plan -> plan
    | Error error -> Alcotest.fail (Plan.error_to_string error)
  in
  (match Plan.prepare_inputs plan with
   | Ok _ -> ()
   | Error _ -> Alcotest.fail "the declared tool input rejected a catalog preview");
  fun data ->
    match Plan.validate_output plan ~run_id:(Plan.Run_id.fresh ()) ~node_id:id data with
    | Ok _ -> ()
    | Error _ -> Alcotest.fail "the actual portrait response violated its composable schema"
;;

(* A Keeper discovers the catalog, tries every accessory on its own body and
   reads its starting portrait again. The preview is a real retained PNG;
   browsing does not become a purchase or a persisted equipment choice. *)
let test_browse_and_preview_without_equipping () =
  with_temp_base @@ fun () ->
  let name = "portrait-item-browser" in
  let args = `Assoc [ "size", `Int 48 ] in
  let starting = call ~name ~args |> completed_data in
  output_validator args starting;
  Alcotest.(check string) "default view is explicitly current" "current"
    (string_field "mode" starting);
  Alcotest.(check bool) "default view has no preview item" true
    (field "preview_item" starting = `Null);
  let original_equipment = field "equipment" starting in
  Alcotest.(check bool) "starting view shows the starting equipment" true
    (original_equipment = field "starting_equipment" starting);
  let items =
    match field "catalog" starting with
    | `List items -> items
    | _ -> Alcotest.fail "catalog is not an array"
  in
  let ids = List.map (string_field "id") items in
  Alcotest.(check int) "all nonempty renderer items are discoverable" 18 (List.length ids);
  Alcotest.(check int) "every catalog id is unique" 18
    (List.length (List.sort_uniq String.compare ids));
  List.iter (fun (slot, count) ->
    Alcotest.(check int) (slot ^ " item count") count
      (List.length (List.filter (fun item -> String.equal (string_field "slot" item) slot) items)))
    [ "face", 6; "neck", 3; "head", 3; "hand", 3; "base", 3 ];
  List.iter
    (fun item ->
       let id = string_field "id" item in
       let slot = string_field "slot" item in
       let args = `Assoc [ "size", `Int 48; "preview_item", `String id ] in
       let preview = call ~name ~args |> completed_data in
       output_validator args preview;
       Alcotest.(check string) (id ^ " is a preview") "preview" (string_field "mode" preview);
       Alcotest.(check string) "the chosen id is explicit" id (string_field "preview_item" preview);
       Alcotest.(check bool) "preview retains the starting gear" true
         (field "starting_equipment" preview = original_equipment);
       let shown = field "equipment" preview in
       Alcotest.(check string) "the preview uses the catalog item's slot" id
         (string_field slot shown);
       List.iter (fun other ->
         if not (String.equal slot other) then
           Alcotest.(check bool) (other ^ " is unchanged") true
             (field other shown = field other original_equipment))
         [ "face"; "neck"; "head"; "hand"; "base" ];
       let handle = string_field "artifact" preview in
       (match Store.load ~dir:(Vision.vision_store_dir ~keeper_name:name) (Store.of_string handle) with
        | Error error -> Alcotest.fail (Store.load_error_to_string error)
        | Ok png ->
            Alcotest.(check bool) "the preview artifact is a PNG" true
              (String.length png >= 8 && String.sub png 0 8 = "\137PNG\r\n\026\n"));
       if shown <> original_equipment then
         Alcotest.(check bool) (id ^ " changes the actual image") false
           (field "artifact" preview = field "artifact" starting))
    items;
  let after = call ~name ~args |> completed_data in
  Alcotest.(check bool) "browsing preserves the starting picture" true
    (field "artifact" after = field "artifact" starting);
  Alcotest.(check bool) "browsing persists no equipment choice" true
    (field "equipment" after = original_equipment)
;;

let test_invalid_preview_is_refused_before_artifacts () =
  with_temp_base @@ fun () ->
  let name = "invalid-item-preview" in
  List.iter
    (fun preview_item ->
       match call ~name ~args:(`Assoc [ "preview_item", preview_item ]) with
       | Tool_result.Failed error ->
           Alcotest.(check bool) "invalid item is a policy rejection" true
             (error.class_ = Tool_result.Policy_rejection)
       | Tool_result.Completed _ | Tool_result.Deferred _ ->
           Alcotest.fail "an unknown or empty item was previewed")
    [ `Null; `Int 1; `List []; `String ""; `String "not-an-item"
    ; `String "bare_face"; `String "bare_neck"; `String "bare_head"
    ; `String "empty_hand"; `String "no_dish" ];
  Alcotest.(check bool) "a refused preview creates no artifact store" false
    (Sys.file_exists (Vision.vision_store_dir ~keeper_name:name))
;;

(* The tool reports the equipment the name hash gives, through the same mapping
   the tool uses. A change to either side fails here. *)
let test_equipment_matches_the_name_hash () =
  with_temp_base @@ fun () ->
  List.iter
    (fun name ->
      let result = call ~name ~args:(`Assoc []) in
      let data = completed_data result in
      Alcotest.(check string)
        (name ^ ": the tool reports the name hash's equipment")
        (Yojson.Safe.to_string (Read.equipment_to_json (Look.equipment_of_name name)))
        (Yojson.Safe.to_string (field "equipment" data)))
    [ "won-chik"; "lane-smith"; "jazz-developer"; "simplifyer" ]
;;

(* The artifact is a real PNG in the Keeper's vision store, and the reported
   geometry matches the bytes. *)
let test_artifact_is_a_readable_png () =
  with_temp_base @@ fun () ->
  let name = "won-chik" in
  let result = call ~name ~args:(`Assoc [ "size", `Int 96 ]) in
  let data = completed_data result in
  Alcotest.(check string) "the tool names the Keeper" name
    (match field "name" data with `String value -> value | _ -> Alcotest.fail "name is not a string");
  Alcotest.(check string) "the media type is PNG" "image/png"
    (match field "media_type" data with
     | `String value -> value
     | _ -> Alcotest.fail "media_type is not a string");
  Alcotest.(check int) "the reported width is the requested edge" 96
    (match field "width" data with `Int value -> value | _ -> Alcotest.fail "width is not an int");
  Alcotest.(check int) "the reported height is the requested edge" 96
    (match field "height" data with `Int value -> value | _ -> Alcotest.fail "height is not an int");
  let handle =
    match field "artifact" data with
    | `String value -> value
    | _ -> Alcotest.fail "artifact is not a string"
  in
  let bytes =
    match field "bytes" data with `Int value -> value | _ -> Alcotest.fail "bytes is not an int"
  in
  let dir = Vision.vision_store_dir ~keeper_name:name in
  match Store.load ~dir (Store.of_string handle) with
  | Error error ->
    Alcotest.failf "the artifact did not load: %s" (Store.load_error_to_string error)
  | Ok loaded ->
    Alcotest.(check int) "the stored bytes are the reported bytes" bytes (String.length loaded);
    Alcotest.(check bool) "the artifact is a PNG" true
      (String.length loaded >= 8 && String.sub loaded 0 8 = "\137PNG\r\n\026\n");
    Alcotest.(check int) "IHDR width matches the requested edge" 96
      (Int32.to_int (String.get_int32_be loaded 16));
    Alcotest.(check int) "IHDR height matches the requested edge" 96
      (Int32.to_int (String.get_int32_be loaded 20));
    let repeated = call ~name ~args:(`Assoc ["size", `Int 96]) |> completed_data in
    Alcotest.(check bool) "same identity and size retain the image" true
      (field "artifact" repeated = field "artifact" data);
    Alcotest.(check bool) "same identity retains equipment" true
      (field "equipment" repeated = field "equipment" data)
;;

(* A portrait handle can be used in a later turn. Rotate the same Keeper's
   screen cache through a one-entry limit, then reload the exact returned
   handle through the lookup used by keeper_analyze_image. *)
let test_artifact_survives_frame_pressure () =
  with_temp_base @@ fun () ->
  let name = "portrait-retention" in
  let data = call ~name ~args:(`Assoc [ "size", `Int 48 ]) |> completed_data in
  let handle =
    match field "artifact" data with
    | `String value -> Store.of_string value
    | _ -> Alcotest.fail "artifact is not a string"
  in
  let dir = Vision.vision_store_dir ~keeper_name:name in
  let read_portrait () =
    match Store.load ~dir handle with
    | Ok bytes -> bytes
    | Error error -> Alcotest.fail (Store.load_error_to_string error)
  in
  let before = read_portrait () in
  let frames = Vision.frames_dir ~keeper_name:name in
  let capture bytes =
    match Store.store ~auto_prune:true ~max_entries:1 ~dir:frames bytes with
    | Ok frame -> frame
    | Error error -> Alcotest.fail error
  in
  let previous = capture "previous screen frame" in
  let current_bytes = "current screen frame" in
  let current = capture current_bytes in
  (match Store.load ~dir:frames previous with
   | Error (Store.Missing_artifact _) -> ()
   | Error error -> Alcotest.fail (Store.load_error_to_string error)
   | Ok _ -> Alcotest.fail "the frame cache did not rotate");
  (match Store.load ~dir:frames current with
   | Ok bytes -> Alcotest.(check string) "current frame is readable" current_bytes bytes
   | Error error -> Alcotest.fail (Store.load_error_to_string error));
  Alcotest.(check string) "the returned portrait survives frame rotation" before (read_portrait ())
;;

(* A size outside the declared range is refused, not clamped. 16 and 47 are
   inside the renderer's range but below the tool's declared minimum. A size
   refusal names the declared range. *)
let test_size_out_of_range_is_refused () =
  with_temp_base @@ fun () ->
  let declared =
    Printf.sprintf "size must be between %d and %d" Read.minimum_size Read.maximum_size
  in
  List.iter (fun args ->
    match call ~name:"invalid-portrait" ~args with
    | Tool_result.Failed error ->
        Alcotest.(check bool) "invalid input is a policy rejection" true
          (error.class_ = Tool_result.Policy_rejection)
    | Tool_result.Completed _ | Tool_result.Deferred _ ->
        Alcotest.fail "invalid portrait input succeeded")
    [`Null; `Assoc ["size", `String "48"]; `Assoc ["size", `Int 8]; `Assoc ["size", `Int 513]];
  List.iter (fun size ->
    match call ~name:"invalid-portrait" ~args:(`Assoc ["size", `Int size]) with
    | Tool_result.Failed error ->
        Alcotest.(check string) (Printf.sprintf "size %d names the declared range" size)
          declared error.message
    | Tool_result.Completed _ | Tool_result.Deferred _ ->
        Alcotest.failf "size %d is outside the declared range and succeeded" size)
    [ Keeper_portrait_draw.min_size; Read.minimum_size - 1; Read.maximum_size + 1 ];
  let dir = Vision.vision_store_dir ~keeper_name:"invalid-portrait" in
  Alcotest.(check bool) "rejected inputs create no artifacts" false (Sys.file_exists dir)
;;

(* The tool file states the size bounds and default as literals; this module
   owns them. A change to either side fails here. *)
let test_declared_size_matches_the_handler () =
  let schema = Tool_schemas_misc_toml.portrait_read in
  let field key =
    match schema.Masc_domain.input_schema with
    | `Assoc fields ->
      (match List.assoc_opt "properties" fields with
       | Some (`Assoc props) ->
         (match List.assoc_opt "size" props with
          | Some (`Assoc p) ->
            (match List.assoc_opt key p with
             | Some (`Int v) -> v
             | _ -> Alcotest.failf "size.%s is absent or not an integer" key)
          | _ -> Alcotest.fail "size is absent")
       | _ -> Alcotest.fail "no properties")
    | _ -> Alcotest.fail "input_schema is not an object"
  in
  Alcotest.(check int) "size minimum" Read.minimum_size (field "minimum");
  Alcotest.(check int) "size maximum" Read.maximum_size (field "maximum");
  Alcotest.(check int) "size default" Read.default_size (field "default")
;;

let () =
  Alcotest.run
    "keeper_portrait_read"
    [ ( "read-only portrait"
      , [ Alcotest.test_case "equipment matches the name hash" `Quick
            test_equipment_matches_the_name_hash
        ; Alcotest.test_case "browse and preview without equipping" `Quick
            test_browse_and_preview_without_equipping
        ; Alcotest.test_case "invalid preview is refused before artifacts" `Quick
            test_invalid_preview_is_refused_before_artifacts
        ; Alcotest.test_case "artifact is a readable PNG" `Quick test_artifact_is_a_readable_png
        ; Alcotest.test_case "artifact survives frame pressure" `Quick test_artifact_survives_frame_pressure
        ; Alcotest.test_case "size out of range is refused" `Quick test_size_out_of_range_is_refused
        ; Alcotest.test_case "declared size matches the handler" `Quick
            test_declared_size_matches_the_handler
        ] )
    ]
;;
