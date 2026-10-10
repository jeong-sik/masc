(* RFC play-link-for-the-shared-machine §2.7: an MCP caller of masc_dos_screen
   gets the frame as a PNG image item beside the text observation. A VGA game
   draws its menus as pixels, so the text alone cannot spell them. *)

open Alcotest
module Mcp_eio = Masc.Mcp_server_eio

let () = Mirage_crypto_rng_unix.use_default ()

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let string_member name json =
  match member name json with
  | Some (`String value) -> Some value
  | _ -> None

let hello_com = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
let png_signature = "\x89PNG\r\n\x1a\n"

(* IHDR follows the signature: length(4) "IHDR"(4) width(4) height(4). *)
let ihdr_size png =
  let be32 at =
    (Char.code png.[at] lsl 24) lor (Char.code png.[at + 1] lsl 16)
    lor (Char.code png.[at + 2] lsl 8) lor Char.code png.[at + 3]
  in
  check string "the first chunk is IHDR" "IHDR" (String.sub png 12 4);
  be32 16, be32 20

let eject () = match Dos_lane.eject ~who:"operator" ~announce:ignore () with Ok () | Error _ -> ()

let with_worker f =
  let base_path = Filename.temp_dir "mcp-dos-screen-" "" in
  eject ();
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  Fun.protect
    ~finally:(fun () ->
      eject ();
      Dos_lane.install_activity_observer None;
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run (fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      let clock = Eio.Stdenv.clock env in
      Eio.Time.with_timeout_exn clock 30. (fun () ->
        Eio.Switch.run (fun sw ->
          Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
            ~clock ~mono_clock:(Eio.Stdenv.mono_clock env) (fun () ->
            Masc.Lane_addon_runtime.For_testing.reset ();
            let config = Masc.Workspace.default_config base_path in
            let programs = Filename.concat (Masc.Workspace.masc_dir config) "dos/programs" in
            Fs_compat.mkdir_p programs;
            Out_channel.with_open_bin (Filename.concat programs "game.com")
              (fun channel -> output_string channel hello_com);
            let state = Mcp_eio.For_testing.create_state ~base_path () in
            let screen () = Mcp_eio.handle_request ~clock ~sw state
              {|{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"masc_dos_screen","arguments":{}}}|} in
            let unavailable label =
              let response = screen () in
              let rejected = match member "error" response with
                | Some (`Assoc _) -> true
                | _ -> Option.bind (member "result" response) (member "isError") = Some (`Bool true) in
              check bool label true rejected;
              let content = Option.bind (member "result" response) (member "content") in
              check bool "unavailable tool cannot return a cached image" false
                (match content with Some (`List items) ->
                  List.exists (fun item -> string_member "type" item = Some "image") items
                 | _ -> false) in
            unavailable "screen unavailable before attachment";
            Machine_worker_fixture.with_dos ~clock ~sw ~base_path
              (fun ~invoke ~detach ->
                let load () =
                  match invoke ~principal:(Lane_addon_call_context.Host_actor "operator")
                    ~controller:(Some {Machine_controller_contract.observed_holder=None;
                      release=None;handoff_target=None})
                    ~name:"masc_dos_load" ~arguments:(`Assoc ["program",`String "game.com"]) with
                  | Ok result -> check bool "worker loaded program" false (result.is_error=Some true)
                  | Error detail -> fail detail in
                f ~screen ~load;
                detach ();
                unavailable "screen unavailable after detachment"))))))

let content_of response =
  match Option.bind (member "result" response) (member "content") with
  | Some (`List items) -> items
  | _ -> failf "no content in %s" (Yojson.Safe.to_string response)

let test_the_screen_answer_carries_the_frame () =
  with_worker (fun ~screen ~load ->
    load ();
    let frame_width, frame_height =
      match Dos_lane.capture () with
      | Ok (_, { Dos_lane.width; height; _ }) -> width, height
      | Error e -> fail ("capture: " ^ Dos_lane.error_to_string e)
    in
    let response = screen () in
    match content_of response with
    | [ text; image ] ->
      check (option string) "the observation comes first, as text" (Some "text") (string_member "type" text);
      check (option string) "then an image" (Some "image") (string_member "type" image);
      check (option string) "a PNG" (Some "image/png") (string_member "mimeType" image);
      let png =
        match string_member "data" image with
        | Some data -> Base64.decode_exn data
        | None -> fail "the image has no data"
      in
      check string "with the PNG signature" png_signature (String.sub png 0 (String.length png_signature));
      check (pair int int) "at the frame's size" (frame_width, frame_height) (ihdr_size png);
      let structured = Option.bind (member "result" response) (member "structuredContent") in
      check (option int) "the observation names the image's size in bytes" (Some (String.length png))
        (match Option.bind structured (member "bytes") with
         | Some (`Int bytes) -> Some bytes
         | _ -> None)
    | items -> failf "expected text then image, got %d items" (List.length items))

let test_no_machine_is_text_only () =
  with_worker (fun ~screen ~load:_ ->
    let response = screen () in
    check (option bool) "unloaded worker reports tool failure" (Some true)
      (match Option.bind (member "result" response) (member "isError") with
       | Some (`Bool value) -> Some value | _ -> None);
    let items = content_of response in
    check (list (option string)) "only the refusal's text" [ Some "text" ]
      (List.map (string_member "type") items))

let () =
  run "mcp_dos_screen_image"
    [ ( "screen"
      , [ test_case "the screen answer carries the frame" `Quick test_the_screen_answer_carries_the_frame
        ; test_case "no machine is text only" `Quick test_no_machine_is_text_only
        ] )
    ]
