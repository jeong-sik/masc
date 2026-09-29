open Masc
open Alcotest

let handler_produces_readable_artifact () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let root = Filename.temp_dir "portrait-read-" "" in
  let saved_base = Sys.getenv_opt "MASC_BASE_PATH" in
  let saved_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_BASE_PATH" root;
  Unix.unsetenv "MASC_CONFIG_DIR";
  Config_dir_resolver.reset ();
  Eio.Switch.on_release sw (fun () ->
    (match saved_base with Some value -> Unix.putenv "MASC_BASE_PATH" value | None -> Unix.unsetenv "MASC_BASE_PATH");
    (match saved_config with Some value -> Unix.putenv "MASC_CONFIG_DIR" value | None -> Unix.unsetenv "MASC_CONFIG_DIR");
    Config_dir_resolver.reset ();
    Masc_test_deps.cleanup_test_workspace root);
  let run keeper args = Keeper_portrait_read.handle ~keeper_name:keeper
    ~tool_name:"keeper_portrait_read" ~start_time:(Tool_timing.start ()) ~args in
  List.iter (fun args ->
    match run "portrait-invalid" args with
    | Tool_result.Failed error -> check bool "invalid input is rejected before effect" true
        (error.class_=Tool_result.Policy_rejection)
    | Tool_result.Completed _ | Tool_result.Deferred _ -> fail "invalid portrait input succeeded")
    [`Null; `Assoc ["size",`String "48"]; `Assoc ["size",`Int 0]; `Assoc ["size",`Int 513]];
  let invalid_dir = Multimodal.Vision_artifact_store.frames_dir
    ~dir:(Filename.concat (Config_dir_resolver.keepers_dir ()) "portrait-invalid.vision") in
  check bool "rejected inputs create no artifacts" false (Sys.file_exists invalid_dir);
  let completed keeper =
    match run keeper (`Assoc ["size",`Int 48]) with
    | Tool_result.Completed output -> output.data
    | Tool_result.Deferred _ -> fail "portrait read deferred"
    | Tool_result.Failed error -> fail error.message in
  let first = completed "portrait-alpha" in
  let open Yojson.Safe.Util in
  check string "caller identity owns the result" "portrait-alpha" (first |> member "name" |> to_string);
  check int "requested geometry" 48 (first |> member "width" |> to_int);
  check int "square geometry" 48 (first |> member "height" |> to_int);
  let equipment = first |> member "equipment" |> to_assoc in
  check (list string) "all equipment slots are present" ["base";"face";"hand";"head";"neck"]
    (List.sort String.compare (List.map fst equipment));
  let handle = first |> member "artifact" |> to_string in
  let dir = Multimodal.Vision_artifact_store.frames_dir
    ~dir:(Filename.concat (Config_dir_resolver.keepers_dir ()) "portrait-alpha.vision") in
  let png = match Multimodal.Vision_artifact_store.load ~dir
      (Multimodal.Vision_artifact_store.of_string handle) with
    | Ok bytes -> bytes
    | Error error -> fail (Multimodal.Vision_artifact_store.load_error_to_string error) in
  check string "stored artifact is PNG" "\137PNG\r\n\026\n" (String.sub png 0 8);
  check int "IHDR width" 48 (Int32.to_int (String.get_int32_be png 16));
  check int "IHDR height" 48 (Int32.to_int (String.get_int32_be png 20));
  check int "reported bytes equal stored bytes" (String.length png) (first |> member "bytes" |> to_int);
  let repeated = completed "portrait-alpha" in
  check string "same caller and size retain deterministic image" handle
    (repeated |> member "artifact" |> to_string);
  check bool "same caller retains deterministic equipment" true
    ((first |> member "equipment") = (repeated |> member "equipment"))

let () = run "Keeper portrait read" ["handler", [
  test_case "produces a retrievable deterministic PNG and equipment" `Quick handler_produces_readable_artifact]]
