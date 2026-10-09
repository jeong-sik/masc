(* Attached worker observation and PNG reach the Keeper multimodal result
   without advancing the machine. Detach revokes even a frozen tool handle. *)

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

(* Ejects whatever machine is there, as whoever holds it: the machine is
   process-global and one test must not hand it to the next. *)
let eject_held () =
  let who =
    match Dos_lane.screen () with
    | Ok { Dos_lane.controller = Some holder; _ } -> holder
    | Ok _ | Error _ -> "test-cleanup"
  in
  ignore (Dos_lane.eject ~who ~announce:ignore () : (unit, Dos_lane.error) result)
;;

let test_keeper_screen_carries_the_frame () =
  let base_path = Filename.temp_dir "dos-vision-" "" in
  let unwrap = function Ok value -> value | Error detail -> fail detail in
  let config = Workspace.default_config base_path in
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect ~finally:(fun () ->
    eject_held ();
    Dos_lane.install_activity_observer None;
    Fs_compat.remove_tree base_path) (fun () ->
    Eio_main.run (fun env ->
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 30. (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
            ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
            Lane_addon_runtime.For_testing.reset ();
            let keeper_name = "dos-player" in
            let exports () = (Keeper_lane_addon_runtime.snapshot ~config ~keeper_name).exports in
            check int "no machine tool before attachment" 0 (List.length (exports ()));
            let programs = Filename.concat (Workspace.masc_dir config) "dos/programs" in
            Fs_compat.mkdir_p programs;
            Out_channel.with_open_bin (Filename.concat programs "hello.com")
              (fun channel -> output_string channel hello_com);
            Machine_worker_fixture.with_dos ~clock:(Eio.Stdenv.clock env) ~sw ~base_path
              (fun ~invoke ~detach ->
                let export = List.find (fun (export : Lane_addon_tool_export.t) ->
                  export.tool.name="masc_dos_screen") (exports ()) in
                let screen () = Keeper_lane_addon_runtime.call ~config ~keeper_name ~export ~arguments:(`Assoc []) in
                let empty = screen () in
                check bool "unloaded worker fails at Keeper boundary" true
                  (match empty.disposition with Tool_result.Failed _ -> true | _ -> false);
                check bool "worker's no-machine refusal retains its pre-effect proof" true
                  (empty.failure_effect_disposition=Tool_result.Proven_pre_effect);
                let loaded = unwrap (invoke ~principal:(Lane_addon_call_context.Keeper keeper_name)
                  ~controller:(Some {Machine_controller_contract.observed_holder=None;release=None;handoff_target=None})
                  ~name:"masc_dos_load" ~arguments:(`Assoc ["program",`String "hello.com"])) in
                check bool "worker loads the synthetic program" false (loaded.is_error=Some true);
                let before,frame = match Dos_lane.capture () with
                  | Ok value -> value | Error error -> fail (Dos_lane.error_to_string error) in
                let result = screen () in
                check bool "Keeper receives a completed dynamic tool result" true
                  (match result.disposition with Tool_result.Completed () -> true | _ -> false);
                let data = match result.data with Some value -> value | None -> fail "no structured tool result" in
                let json = Yojson.Safe.Util.member "structuredContent" data in
                let open Yojson.Safe.Util in
                check string "media type" "image/png" (json |> member "media_type" |> to_string);
                check int "width is the captured frame's" frame.width (json |> member "width" |> to_int);
                check int "height is the captured frame's" frame.height (json |> member "height" |> to_int);
                check bool "text observation survives the dynamic boundary" true
                  (String.length (json |> member "screen_text" |> to_string) > 0);
                let png = match result.content_blocks with
                  | Some blocks ->
                      (match List.find_map (function
                        | Llm_provider.Types.Image {data;media_type="image/png";source_type=Base64} ->
                            Some (Base64.decode_exn data)
                        | _ -> None) blocks with
                       | Some png -> png | None -> fail "Keeper result lost PNG image block")
                  | None -> fail "Keeper result lost multimodal content" in
                check string "a PNG" "\x89PNG\r\n\x1a\n" (String.sub png 0 8);
                check string "IHDR first" "IHDR" (String.sub png 12 4);
                check int "PNG width" frame.width (be32 png 16);
                check int "PNG height" frame.height (be32 png 20);
                (match Dos_lane.screen () with
                 | Ok after -> check int "reading moved no time" before.steps after.steps
                 | Error _ -> fail "machine gone");
                check int "reading pressed nothing" 0 (List.length (Dos_lane.ledger ()));
                detach ();
                check int "detachment removes Keeper discovery" 0 (List.length (exports ()));
                let stale = screen () in
                check bool "frozen tool handle is refused before effect after detach" true
                  (match stale.disposition with Tool_result.Failed _ ->
                    stale.failure_effect_disposition=Tool_result.Proven_pre_effect | _ -> false);
                check bool "detached call cannot replay a stale image" true (stale.content_blocks=None)))))))
;;

let () =
  run "DOS vision"
    [ ( "Keeper"
      , [ test_case "attached worker image crosses Keeper boundary without input" `Quick
            test_keeper_screen_carries_the_frame
        ] )
    ]
;;
