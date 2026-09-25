(* The spectator's read of GET /api/v1/lane-addons/live (#38733). Each of
   the three states decodes to its own constructor, a body that is none of
   them is an error, and [advance] decides what a read does to the drawn
   picture: an unchanged answer at the drawn mark changes nothing. *)

open Alcotest
module Live = Masc_tui_machine_live

let pixels width height = String.make (width * height * 3) '\042'

let screen ?(format = "rgb8") ?(width = 4) ?(height = 3) ?rgb () =
  let rgb = match rgb with Some rgb -> rgb | None -> pixels width height in
  "screen",
  `Assoc [ "format", `String format; "width", `Int width; "height", `Int height;
           "rgb_base64", `String (Base64.encode_string rgb) ]

let marked ?(kind = "dos_capture") ?(count = 7) ?(incarnation = "inc-1") state =
  [ "source_kind", `String kind; "state", `String state;
    "change_count", `Int count; "incarnation", `String incarnation ]

let dos_changed ?count ?incarnation ?(screen = screen ()) ?(extra = []) () =
  `Assoc (marked ?count ?incarnation "changed" @ extra @ [ screen ])

let msx_changed ?(frame = [ "frame_number", `Int 88 ]) () =
  `Assoc (marked ~kind:"msx_capture" "changed" @ frame @ [ screen () ])

let answer =
  testable
    (fun fmt -> function
      | Live.No_machine -> Format.pp_print_string fmt "No_machine"
      | Live.Unchanged m -> Format.fprintf fmt "Unchanged %d/%s" m.count m.incarnation
      | Live.Picture p ->
          Format.fprintf fmt "Picture %dx%d at %d/%s" p.width p.height p.mark.count
            p.mark.incarnation)
    ( = )

let decoded source json =
  match Live.decode source json with
  | Ok answer -> answer
  | Error detail -> failf "expected an answer, got %s" detail

let refused source json =
  match Live.decode source json with
  | Ok _ -> failf "a malformed answer decoded: %s" (Yojson.Safe.to_string json)
  | Error _ -> ()

let test_no_machine () =
  check answer "state no_machine" Live.No_machine
    (decoded Live.Dos (`Assoc [ "source_kind", `String "dos_capture";
                                "state", `String "no_machine" ]))

let test_unchanged () =
  check answer "unchanged carries its mark"
    (Live.Unchanged { count = 41; incarnation = "inc-1" })
    (decoded Live.Dos (`Assoc (marked ~count:41 "unchanged")))

let test_dos_picture () =
  match decoded Live.Dos (dos_changed ()) with
  | Live.Picture p ->
      check int "width" 4 p.width;
      check int "height" 3 p.height;
      check int "count" 7 p.mark.count;
      check string "incarnation" "inc-1" p.mark.incarnation;
      check string "pixels" (pixels 4 3) p.rgb;
      check bool "DOS reports no machine time" true (p.time = Live.Untimed)
  | Live.No_machine | Live.Unchanged _ -> fail "a picture decoded as something else"

let test_msx_picture () =
  match decoded Live.Msx (msx_changed ()) with
  | Live.Picture p -> check bool "MSX carries its frame number" true (p.time = Live.Frame 88)
  | Live.No_machine | Live.Unchanged _ -> fail "a picture decoded as something else"

let test_malformed () =
  List.iter (refused Live.Dos)
    [ `Null; `List []; `Assoc [];
      `Assoc [ "source_kind", `String "dos_capture" ];
      `Assoc [ "source_kind", `String "dos_capture"; "state", `String "loading" ];
      (* another machine's answer *)
      `Assoc [ "source_kind", `String "msx_capture"; "state", `String "no_machine" ];
      `Assoc [ "state", `String "no_machine" ];
      `Assoc (marked "unchanged" @ [ "state", `String "unchanged" ]);
      `Assoc [ "source_kind", `String "dos_capture"; "state", `String "unchanged";
               "change_count", `Int 3 ];
      `Assoc (marked ~count:(-1) "unchanged");
      `Assoc (marked ~incarnation:"" "unchanged");
      `Assoc [ "source_kind", `String "dos_capture"; "state", `String "unchanged";
               "change_count", `String "3"; "incarnation", `String "i" ];
      `Assoc (marked "changed");
      dos_changed ~screen:(screen ~format:"rgba8" ()) ();
      dos_changed ~screen:(screen ~width:0 ()) ();
      dos_changed ~screen:(screen ~rgb:(pixels 4 2) ()) ();
      dos_changed ~screen:("screen", `String "AAAA") ();
      dos_changed ~extra:[ "frame_number", `Int 3 ] ();
      `Assoc (marked "changed" @ [ "screen", `Assoc [ "format", `String "rgb8";
        "width", `Int 1; "height", `Int 1; "rgb_base64", `String "!!!" ] ]) ];
  refused Live.Msx (msx_changed ~frame:[] ());
  refused Live.Msx (msx_changed ~frame:[ "frame_number", `Int (-1) ] ());
  refused Live.Msx (dos_changed ())

let test_path () =
  check string "without since" "/api/v1/lane-addons/live?source_kind=dos_capture"
    (Live.path Live.Dos ~since:None);
  check string "since and incarnation go together"
    "/api/v1/lane-addons/live?source_kind=msx_capture&since=12&incarnation=0190-ab"
    (Live.path Live.Msx ~since:(Some { count = 12; incarnation = "0190-ab" }));
  check string "an incarnation cannot add a parameter"
    "/api/v1/lane-addons/live?source_kind=dos_capture&since=1&incarnation=a%26since%3D2"
    (Live.path Live.Dos ~since:(Some { count = 1; incarnation = "a&since=2" }))

let a_picture ?(incarnation = "inc-1") count =
  match decoded Live.Dos (dos_changed ~count ~incarnation ()) with
  | Live.Picture p -> p
  | Live.No_machine | Live.Unchanged _ -> fail "fixture is not a picture"

let mark_of = function
  | Some (Live.Showing p) -> Some (p.mark.count, p.mark.incarnation)
  | Some (Live.Unread | Live.Not_loaded | Live.Failed _) | None -> None

let is_failed = function
  | Some (Live.Failed _) -> true
  | Some (Live.Unread | Live.Not_loaded | Live.Showing _) | None -> false

let test_since () =
  let mark = testable (fun fmt (m : Live.mark) -> Format.fprintf fmt "%d/%s" m.count m.incarnation) ( = ) in
  check (option mark) "nothing drawn asks without since" None (Live.since Live.Unread);
  check (option mark) "no machine asks without since" None (Live.since Live.Not_loaded);
  check (option mark) "a failure asks without since" None (Live.since (Live.Failed "x"));
  check (option mark) "a drawn picture asks at its mark"
    (Some { count = 7; incarnation = "inc-1" })
    (Live.since (Live.Showing (a_picture 7)))

let test_advance () =
  let drawn = Live.Showing (a_picture 7) in
  check bool "unchanged at the drawn mark redraws nothing" true
    (Live.advance drawn (Ok (Live.Unchanged { count = 7; incarnation = "inc-1" })) = None);
  check bool "unchanged at another count is an error" true
    (is_failed (Live.advance drawn (Ok (Live.Unchanged { count = 6; incarnation = "inc-1" }))));
  check bool "unchanged at another incarnation is an error" true
    (is_failed (Live.advance drawn (Ok (Live.Unchanged { count = 7; incarnation = "inc-2" }))));
  check bool "unchanged with nothing drawn is an error" true
    (is_failed (Live.advance Live.Unread (Ok (Live.Unchanged { count = 7; incarnation = "inc-1" }))));
  check (option (pair int string)) "a new picture replaces the drawn one" (Some (8, "inc-1"))
    (mark_of (Live.advance drawn (Ok (Live.Picture (a_picture 8)))));
  check (option (pair int string)) "the same count on a new machine is a new picture"
    (Some (7, "inc-2"))
    (mark_of (Live.advance drawn (Ok (Live.Picture (a_picture ~incarnation:"inc-2" 7)))));
  check bool "no machine clears the picture" true
    (Live.advance drawn (Ok Live.No_machine) = Some Live.Not_loaded);
  check bool "no machine again redraws nothing" true
    (Live.advance Live.Not_loaded (Ok Live.No_machine) = None);
  check bool "an error is drawn as an error, not as the old picture" true
    (Live.advance drawn (Error "HTTP 401") = Some (Live.Failed "HTTP 401"))

let () =
  run "tui_machine_live"
    [ ( "decode",
        [ test_case "no machine" `Quick test_no_machine;
          test_case "unchanged" `Quick test_unchanged;
          test_case "DOS picture" `Quick test_dos_picture;
          test_case "MSX picture" `Quick test_msx_picture;
          test_case "malformed answers are refused" `Quick test_malformed;
          test_case "path" `Quick test_path ] );
      ( "view",
        [ test_case "since" `Quick test_since;
          test_case "advance" `Quick test_advance ] ) ]
