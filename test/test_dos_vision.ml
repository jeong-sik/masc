(* masc_dos_screen at the Keeper boundary: the observation plus a PNG of the
   same frame in that Keeper's vision store, with no time moved and no key
   recorded. The PNG encoder has its own round-trip test (test_msx_vision);
   here the question is that the DOS frame reaches the store with its own
   geometry and nothing else moves. *)

open Alcotest
open Masc

(* Prints HI and loops on INT 16h until a key arrives: a text-mode program
   that settles on its first request. *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
;;

let be32 s i =
  (Char.code s.[i] lsl 24) lor (Char.code s.[i + 1] lsl 16)
  lor (Char.code s.[i + 2] lsl 8) lor Char.code s.[i + 3]
;;

let test_keeper_screen_carries_the_frame () =
  let base = Filename.temp_dir "dos-vision-" "" in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base;
  Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      ignore (Dos_lane.eject ~announce:ignore () : (unit, Dos_lane.error) result);
      Unix.putenv "MASC_BASE_PATH" (Option.value ~default:"" previous);
      Config_dir_resolver.reset ();
      Fs_compat.remove_tree base)
    (fun () ->
      let config = Workspace.default_config base in
      let meta =
        match Masc_test_deps.meta_of_json_fixture (`Assoc [ ("name", `String "dos-player") ]) with
        | Ok meta -> meta
        | Error e -> fail e
      in
      let screen () =
        Keeper_tool_in_process_runtime.handle_masc_misc_with_outcome ~config ~meta
          ~name:"masc_dos_screen" ~args:(`Assoc [])
      in
      ignore (Dos_lane.eject ~announce:ignore () : (unit, Dos_lane.error) result);
      check bool "no machine fails" true
        (match (screen ()).disposition with Tool_result.Failed _ -> true | _ -> false);
      (match
         Dos_lane.load ~ledger_dir:(Filename.concat base "dos")
           ~saves_dir:(Filename.concat base "saves") ~program_name:"HELLO.COM"
           ~program_bytes:hello_com ~files:[] ~announce:ignore
       with
       | Ok _ -> ()
       | Error e -> fail (Dos_lane.error_to_string e));
      let before, frame =
        match Dos_lane.capture () with Ok v -> v | Error _ -> fail "no capture"
      in
      let result = screen () in
      let json = match result.data with Some d -> d | None -> fail result.raw_output in
      let open Yojson.Safe.Util in
      let handle = json |> member "artifact" |> to_string in
      check string "media type" "image/png" (json |> member "media_type" |> to_string);
      check int "width is the frame's" frame.width (json |> member "width" |> to_int);
      check int "height is the frame's" frame.height (json |> member "height" |> to_int);
      check bool "the text still rides along" true
        (String.length (json |> member "screen_text" |> to_string) > 0);
      let dir = Keeper_vision_tool.vision_store_dir ~keeper_name:meta.name in
      let png =
        match
          Multimodal.Vision_artifact_store.load ~dir
            (Multimodal.Vision_artifact_store.of_string handle)
        with
        | Ok bytes -> bytes
        | Error e -> fail (Multimodal.Vision_artifact_store.load_error_to_string e)
      in
      check string "a PNG" "\x89PNG\r\n\x1a\n" (String.sub png 0 8);
      check string "IHDR first" "IHDR" (String.sub png 12 4);
      check int "PNG width" frame.width (be32 png 16);
      check int "PNG height" frame.height (be32 png 20);
      (match Dos_lane.screen () with
       | Ok after -> check int "reading moved no time" before.steps after.steps
       | Error _ -> fail "machine gone");
      check int "reading pressed nothing" 0 (List.length (Dos_lane.ledger ()));
      let other = Keeper_vision_tool.vision_store_dir ~keeper_name:"another-player" in
      check bool "not stored for another Keeper" false
        (Sys.file_exists (Filename.concat other handle)))
;;

let () =
  run "DOS vision"
    [ ( "Keeper"
      , [ test_case "screen yields an owned image without input" `Quick
            test_keeper_screen_carries_the_frame
        ] )
    ]
;;
