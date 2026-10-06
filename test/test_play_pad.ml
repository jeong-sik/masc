(* RFC play-link-for-the-shared-machine §2.9: pad buttons, layout files and
   where a layout comes from. *)

open Alcotest
module Pad = Masc.Play_pad

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end
    else Unix.unlink path
  in
  go path

let with_workspace f =
  let dir = Filename.temp_dir "play-pad-" "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_layout ~base_path name contents =
  let dir = Pad.pads_dir ~base_path in
  mkdir_p dir;
  Out_channel.with_open_bin (Filename.concat dir (name ^ ".toml")) (fun oc -> output_string oc contents)

let bound layout =
  List.map
    (fun (button, { Pad.keys; label = _ }) -> Pad.button_to_string button, keys)
    (Pad.bindings layout)

let test_buttons_round_trip () =
  List.iter
    (fun button ->
      check bool (Pad.button_to_string button) true
        (Pad.button_of_string (Pad.button_to_string button) = Ok button))
    Pad.all_buttons;
  check bool "an unknown name is refused" true (Result.is_error (Pad.button_of_string "BTN_Z"));
  check bool "names are exact" true (Result.is_error (Pad.button_of_string "btn_south"))

let refused what contents =
  match Pad.parse contents with
  | Ok _ -> failf "%s: parsed" what
  | Error _ -> ()

let test_parse () =
  (match Pad.parse {|[BTN_SOUTH]
keys = ["return"]
label = "결정"

[BTN_SELECT]
keys = ["0", "return"]
label = "끝"
|} with
   | Error message -> fail message
   | Ok layout ->
     check (list (pair string (list string))) "bound in button order"
       [ "BTN_SOUTH", [ "return" ]; "BTN_SELECT", [ "0"; "return" ] ]
       (bound layout);
     check bool "an unbound button has no binding" true (Pad.binding layout Pad.Tl = None));
  refused "an unknown button" {|[BTN_Z]
keys = ["return"]
label = "x"
|};
  refused "an unknown field" {|[BTN_SOUTH]
keys = ["return"]
label = "x"
hold = 3
|};
  refused "empty keys" {|[BTN_SOUTH]
keys = []
label = "x"
|};
  refused "keys as a string" {|[BTN_SOUTH]
keys = "return"
label = "x"
|};
  refused "a key the machine has not" {|[BTN_SOUTH]
keys = ["enterr"]
label = "x"
|};
  refused "no label" {|[BTN_SOUTH]
keys = ["return"]
|};
  refused "an empty label" {|[BTN_SOUTH]
keys = ["return"]
label = " "
|};
  refused "a button that is not a table" {|BTN_SOUTH = "return"
|};
  refused "not TOML" {|[BTN_SOUTH|}

let test_load () =
  with_workspace (fun base_path ->
    (match Pad.load ~base_path ~saves_name:"samguk3" with
     | Ok (Some (Pad.Builtin, layout)) ->
       check int "the builtin 삼국지3 layout binds every button" 12 (List.length (Pad.bindings layout));
       let keys button = Option.map (fun { Pad.keys; _ } -> keys) (Pad.binding layout button) in
       (* The battle map's hex cursor moves on digits only; arrow keys, 4 and
          6 do nothing there, and 0 places an officer. *)
       List.iter
         (fun (button, expected, what) -> check (option (list string)) what (Some expected) (keys button))
         [ Pad.Dpad_up, [ "8" ], "up is 8"
         ; Pad.Dpad_down, [ "2" ], "down is 2"
         ; Pad.Dpad_left, [ "7" ], "left is 7, up-left"
         ; Pad.Dpad_right, [ "9" ], "right is 9, up-right"
         ; Pad.Tl, [ "1" ], "the left shoulder is 1, down-left"
         ; Pad.Tr, [ "3" ], "the right shoulder is 3, down-right"
         ; Pad.Select, [ "0" ], "select is 0 alone, which places an officer"
         ; Pad.East, [ "backspace" ], "east deletes a typed digit; esc does nothing in the game"
         ]
     | Ok (Some (Pad.Workspace, _)) -> fail "no workspace file was written"
     | Ok None -> fail "no builtin layout for samguk3"
     | Error message -> fail message);
    check bool "a program with no layout has none" true
      (Pad.load ~base_path ~saves_name:"zzt" = Ok None);
    write_layout ~base_path "samguk3" {|[BTN_SOUTH]
keys = ["space"]
label = "다음"
|};
    (match Pad.load ~base_path ~saves_name:"samguk3" with
     | Ok (Some (Pad.Workspace, layout)) ->
       check (list (pair string (list string))) "the workspace file wins" [ "BTN_SOUTH", [ "space" ] ]
         (bound layout)
     | Ok (Some (Pad.Builtin, _)) | Ok None -> fail "the workspace file was not read"
     | Error message -> fail message);
    write_layout ~base_path "samguk3" {|[BTN_SOUTH]
keys = ["nope"]
label = "x"
|};
    check bool "a broken workspace file is an error, not the builtin" true
      (Result.is_error (Pad.load ~base_path ~saves_name:"samguk3"));
    List.iter
      (fun name ->
        check bool (Printf.sprintf "%S is not a file name here" name) true
          (Result.is_error (Pad.load ~base_path ~saves_name:name)))
      [ ""; "."; ".."; ".hidden"; "../samguk3"; "a/b"; "a\\b"; "C:game" ])

let test_workspace_read_authority () =
  with_workspace (fun base_path ->
    let pads = Pad.pads_dir ~base_path in
    mkdir_p pads;
    let check_refused saves_name =
      match Pad.load ~base_path ~saves_name with
      | Error _ -> ()
      | Ok _ -> failf "%s: an unreadable override was treated as builtin or absent" saves_name
    in
    List.iter (fun name ->
      let path = Filename.concat pads (name ^ ".toml") in
      let entry create remove =
        create ();
        Fun.protect ~finally:remove (fun () -> check_refused name)
      in
      entry (fun () -> Unix.symlink "missing-layout.toml" path) (fun () -> Unix.unlink path);
      entry (fun () -> Unix.symlink (name ^ ".toml") path) (fun () -> Unix.unlink path);
      entry (fun () -> Unix.mkdir path 0o700) (fun () -> Unix.rmdir path);
      (* No writer: accepting a FIFO would block rather than return a layout. *)
      entry (fun () -> Unix.mkfifo path 0o600) (fun () -> Unix.unlink path))
      ["samguk3";"zzt"];
    let contents = "[BTN_SOUTH]\nkeys = [\"space\"]\nlabel = \"override\"\n" in
    let target = Filename.concat base_path "layout-target.toml" in
    Out_channel.with_open_bin target (fun oc -> output_string oc contents);
    let path = Filename.concat pads "samguk3.toml" in
    Unix.symlink target path;
    (match Pad.load ~base_path ~saves_name:"samguk3" with
     | Ok (Some (Pad.Workspace, layout)) ->
       check (list (pair string (list string))) "regular symlink override keeps its keys"
         ["BTN_SOUTH",["space"]] (bound layout)
     | Ok _ -> fail "a readable symlink override fell back"
     | Error detail -> fail detail);
    Unix.unlink path;
    (* A stat error at an ancestor is also not a missing layout. *)
    Unix.rmdir pads;
    Out_channel.with_open_bin pads (fun oc -> output_string oc "not a directory");
    check_refused "samguk3";
    Unix.unlink pads;
    mkdir_p pads;
    (* A non-root process cannot inspect this configured directory. Restore
       access before fixture cleanup; privileged test users bypass permissions. *)
    if Unix.geteuid () <> 0 then
      Fun.protect ~finally:(fun () -> Unix.chmod pads 0o700) (fun () ->
        Unix.chmod pads 0;
        check_refused "samguk3"))

let () =
  run "play-pad"
    [ ( "pad"
      , [ test_case "buttons round-trip and unknown ones are refused" `Quick test_buttons_round_trip
        ; test_case "a layout parses strictly" `Quick test_parse
        ; test_case "workspace file, then builtin, then none" `Quick test_load
        ; test_case "workspace read failures never select builtin or none" `Quick test_workspace_read_authority
        ] )
    ]
