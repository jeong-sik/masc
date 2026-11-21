(* A program image the core's loaders cannot place is refused as the caller's
   mistake, before any machine is built. The property test runs the real
   loader beside the check, and two tests show with the loader itself why the
   lane's bounds sit where they do, so a pinned core that moves either turns
   them red. *)

open Alcotest

let who = "image-fixture"
let u16 n = String.init 2 (fun i -> Char.chr ((n lsr (8 * i)) land 0xFF))

(* An MZ image of [size] bytes with the four header fields the loader reads.
   The page count defaults to the file's own length rounded up, so the module
   ends at or after the file. *)
let mz ?(reloc_count = 0) ?(header_paras = 2) ?(reloc_offset = 0x1C) ?pages size =
  let pages = Option.value pages ~default:((size + 511) / 512) in
  let image = Bytes.make size '\000' in
  let put offset field =
    if offset + 2 <= size then Bytes.blit_string (u16 field) 0 image offset 2
  in
  if size >= 2 then Bytes.blit_string "MZ" 0 image 0 2;
  put 0x04 pages;
  put 0x06 reloc_count;
  put 0x08 header_paras;
  put 0x18 reloc_offset;
  Bytes.to_string image
;;

let refused name image =
  match Dos_lane.image_of_bytes ~program_name:"game.exe" image with
  | Error (Dos_lane.Invalid_request _) -> ()
  | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
  | Ok _ -> failf "%s: the image was accepted" name
;;

let accepted name image =
  match Dos_lane.image_of_bytes ~program_name:"game.exe" image with
  | Ok _ -> ()
  | Error error -> failf "%s: %s" name (Dos_lane.error_to_string error)
;;

let test_refusals () =
  refused "an empty image" "";
  refused "a bare MZ signature" "MZ";
  refused "an MZ header one byte short" (String.sub (mz 64) 0 27);
  refused "a header longer than the file" (mz ~header_paras:0x1000 64);
  refused "a relocation table past the end" (mz ~reloc_count:100 64);
  refused "a relocation table that starts past the end" (mz ~reloc_count:1 ~reloc_offset:0xFFFF 64);
  (* The core reads the offset even when there are no entries. *)
  refused "a relocation offset past the end with no entries" (mz ~reloc_offset:0xFFFF 64);
  refused "a module that ends inside its header" (mz ~pages:0 64);
  refused "a file a page or more short of its module" (mz ~pages:3 64);
  refused "a payload past the end of memory"
    (mz (32 + Dos_lane.max_exe_payload_bytes + 1));
  refused "a COM larger than its segment" (String.make (Dos_lane.max_com_bytes + 1) '\x90')
;;

let test_the_bounds_are_accepted () =
  accepted "the largest COM" (String.make Dos_lane.max_com_bytes '\x90');
  accepted "the largest EXE payload" (mz (32 + Dos_lane.max_exe_payload_bytes));
  accepted "a header-only EXE" (mz 32);
  accepted "an EXE whose table fills the file" (mz ~reloc_count:2 ~reloc_offset:56 64);
  accepted "a file less than a page short of its module" (mz ~pages:2 600);
  (* DOS takes "ZM" as an EXE signature, and so does the core. *)
  accepted "a ZM signature" ("ZM" ^ String.sub (mz 64) 2 62);
  accepted "a one-byte COM" "\xc3"
;;

(* Each boundary image goes through the real load, not only the check. *)
let with_lane run =
  let directory = Filename.temp_dir "masc-dos-image-" "" in
  Dos_lane.install_activity_observer (Some (fun () -> Machine_configuration.Enabled));
  let rec remove path =
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
  in
  Fun.protect
    ~finally:(fun () ->
      ignore (Dos_lane.eject ~who ~announce:ignore () : (unit, Dos_lane.error) result);
      Dos_lane.install_activity_observer None;
      remove directory)
    (fun () -> run directory)
;;

let load ?(files = []) directory image =
  Dos_lane.load ~who ~ledger_dir:directory ~saves_dir:(Filename.concat directory "saves")
    ~checkpoint_dir:(Filename.concat directory "checkpoints")
    ~previous_autosave:Dos_lane.Discard_previous_autosave ~program_name:"game.exe" ~program_bytes:image ~files
    ~announce:ignore
;;

(* Prints HI, then polls the keyboard until a key comes. *)
let hello = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"

let test_a_refused_image_leaves_the_running_machine () =
  with_lane (fun directory ->
    (match load directory hello with
     | Ok _ -> ()
     | Error error -> fail (Dos_lane.error_to_string error));
    let before = Dos_lane.capture_with_identity () in
    let count () =
      match Dos_lane.current_publication () with
      | Dos_lane.Stable mark | Dos_lane.Running mark -> mark.Dos_lane.count
      | Dos_lane.No_screen -> fail "no machine is published"
    in
    let count_before = count () in
    List.iter
      (fun (name, image) ->
        match load directory image with
        | Error (Dos_lane.Invalid_request _) -> ()
        | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
        | Ok _ -> failf "%s: the load went through" name)
      [ "a bare MZ signature", "MZ"
      ; "a header longer than the file", mz ~header_paras:0x1000 64
      ; "a COM larger than its segment", String.make (Dos_lane.max_com_bytes + 1) '\x90'
      ];
    check int "the machine was not replaced or counted" count_before (count ());
    match before, Dos_lane.capture_with_identity () with
    | Ok first, Ok second ->
      check string "the same incarnation is running" first.Dos_lane.incarnation
        second.Dos_lane.incarnation
    | _ -> fail "the running machine disappeared")
;;

let test_the_boundary_images_load () =
  with_lane (fun directory ->
    List.iter
      (fun (name, image) ->
        match load directory image with
        | Ok _ -> ()
        | Error error -> failf "%s: %s" name (Dos_lane.error_to_string error)
        | exception exn -> failf "%s raised %s" name (Printexc.to_string exn))
      [ "the largest COM", String.make Dos_lane.max_com_bytes '\xeb'
      ; "the largest EXE payload", mz (32 + Dos_lane.max_exe_payload_bytes)
      ])
;;

(* The kept table is keyed by the name the machine reports, which is the name
   after DOS has cut it to 8.3. Keyed by the name the caller passed, it would
   differ from what [keep_writes] reads back, and a file the guest never
   touched would be written to the saves directory as a change. *)
let test_a_file_cut_to_8_3_is_not_saved_as_a_change () =
  with_lane (fun directory ->
    (match load ~files:[ "LONGFILENAME.TXT", "kept" ] directory hello with
     | Ok _ -> ()
     | Error error -> fail (Dos_lane.error_to_string error));
    (match Dos_lane.step ~who ~steps:1000 ~until_ready:false with
     | Ok _ -> ()
     | Error error -> fail (Dos_lane.error_to_string error));
    let saves = Filename.concat directory "saves" in
    let written = if Sys.file_exists saves then Array.to_list (Sys.readdir saves) else [] in
    check (list string) "an unchanged file is not written to the saves directory" [] written)
;;

(* The core reads a name the way DOS does, so two names can reach one file, and
   a name DOS cannot hold is an error. Each is refused as the caller's mistake
   before any machine is installed. *)
let test_file_names_the_core_cannot_mount_are_refused () =
  with_lane (fun directory ->
    List.iter
      (fun (name, files) ->
        match load ~files directory hello with
        | Error (Dos_lane.Invalid_request _) -> ()
        | Error error -> failf "%s: unexpected %s" name (Dos_lane.error_to_string error)
        | Ok _ -> failf "%s: the load went through" name)
      [ "two names cut to one 8.3 name", [ "LONGFILENAME.TXT", "a"; "LONGFILE.TXT", "b" ]
      ; "a character DOS does not allow in a name", [ "A+B.TXT", "a" ]
      ])
;;

(* The check against the loader, over images built to sit on both sides of
   each bound. The loader's [Invalid_argument] is the only outcome that counts
   as "cannot place it"; any other exception fails the test. *)
let loader_places image =
  let machine = Dos_machine.create () in
  let signed = String.length image >= 2 && List.mem (String.sub image 0 2) [ "MZ"; "ZM" ] in
  match
    if signed then Dos_machine.load_exe machine image
    else Dos_machine.load_com machine image
  with
  | () -> true
  | exception Invalid_argument _ -> false
;;

let test_the_check_agrees_with_the_loader_on_exe () =
  let random = Random.State.make [| 20261017 |] in
  let pick options = List.nth options (Random.State.int random (List.length options)) in
  let checked = ref 0 and refused_count = ref 0 in
  for _ = 1 to 1500 do
    (* No size 0: the loader places an empty image, and the lane refuses it by
       its own rule (test_refusals). *)
    let size = pick [ 2; 20; 27; 28; 29; 31; 32; 33; 64; 200; 1000; 4096 ] in
    let image =
      if Random.State.int random 4 = 0 then
        (* Random bytes under an MZ or ZM signature: header fields are noise. *)
        let noise = Bytes.init size (fun _ -> Char.chr (Random.State.int random 256)) in
        if size >= 2 then Bytes.blit_string (pick [ "MZ"; "ZM" ]) 0 noise 0 2;
        Bytes.to_string noise
      else
        mz
          ?pages:(pick [ None; Some 0; Some 1; Some 2; Some 3; Some 0xFFFF ])
          ~reloc_count:(pick [ 0; 1; 2; 5; 100; 0xFFFF ])
          ~header_paras:(pick [ 0; 1; 2; 3; 4; 0x20; 0x1000; 0xFFFF ])
          ~reloc_offset:(pick [ 0; 0x1C; 0x28; 60; 61; 0x100; 0xFFFF ])
          size
    in
    let expected = loader_places image in
    let accepted = Result.is_ok (Dos_lane.image_of_bytes ~program_name:"fuzz.exe" image) in
    incr checked;
    if not accepted then incr refused_count;
    if accepted <> expected then
      failf "size %d: the loader %s the image and the check %s it" (String.length image)
        (if expected then "places" else "cannot place")
        (if accepted then "accepts" else "refuses")
  done;
  check bool "the sample holds both outcomes" true (!refused_count > 0 && !refused_count < !checked)
;;

(* The reason the COM bound sits where it does, shown with the real loader:
   a COM of 65,278 bytes keeps its last byte, and one byte more loses its
   tail to the return word at PSP:FFFE (linear address 0x1FFFE). The loader
   places both without raising. *)
let test_the_com_bound_is_where_the_loader_starts_overwriting_the_image () =
  let image_start = 0x10100 in
  let last_byte_of length =
    let machine = Dos_machine.create () in
    Dos_machine.load_com machine (String.make length '\x90');
    Dos_machine.mem_read machine (image_start + length - 1)
  in
  check int "the bound is 65,278 bytes" 65_278 Dos_lane.max_com_bytes;
  check int "an image of 65,278 bytes keeps its last byte" 0x90 (last_byte_of 65_278);
  check int "an image of 65,279 bytes has its last byte overwritten" 0x00 (last_byte_of 65_279);
  check bool "so the lane refuses 65,279 and accepts 65,278" true
    (Result.is_ok (Dos_lane.image_of_bytes ~program_name:"a.com" (String.make 65_278 '\x90'))
     && Result.is_error
          (Dos_lane.image_of_bytes ~program_name:"a.com" (String.make 65_279 '\x90')))
;;

(* "ZM" is a DOS executable signature, and the core's loader takes it as an
   EXE. A ZM file goes to the EXE loader, and one whose header the loader
   cannot place is refused like an MZ one. *)
let test_zm_is_loaded_as_an_exe () =
  let zm = "ZM" ^ String.sub (mz 64) 2 62 in
  check bool "the EXE loader places it" true
    (match Dos_machine.load_exe (Dos_machine.create ()) zm with
     | () -> true
     | exception Invalid_argument _ -> false);
  check bool "the lane accepts it, as an EXE" true
    (match Dos_lane.image_of_bytes ~program_name:"z.exe" zm with
     | Ok _ -> true
     | Error _ -> false);
  check bool "a ZM whose header names no module is refused" true
    (Result.is_error (Dos_lane.image_of_bytes ~program_name:"z.exe" ("ZM" ^ String.make 100 '\x90')));
  check bool "a COM whose second byte is M or whose first is Z alone is not a ZM" true
    (Result.is_ok (Dos_lane.image_of_bytes ~program_name:"c.com" "ZX")
     && Result.is_ok (Dos_lane.image_of_bytes ~program_name:"c.com" "\x90M"))
;;

(* The reason the EXE bound sits where it does, shown with the real loader.
   Addresses run modulo 1MB, so the loader places a module of any length and
   the bytes past the end of memory land on address 0. The last byte of a
   module of [max_exe_payload_bytes] sits on the last address; one byte more
   sits on address 0. *)
let test_the_exe_bound_is_where_the_loader_starts_wrapping () =
  let address_zero_after length =
    let image = Bytes.of_string (mz (32 + length)) in
    Bytes.set image (Bytes.length image - 1) '\xAB';
    let machine = Dos_machine.create () in
    let before = Dos_machine.mem_read machine 0 in
    Dos_machine.load_exe machine (Bytes.to_string image);
    before, Dos_machine.mem_read machine 0
  in
  let before, at_bound = address_zero_after Dos_lane.max_exe_payload_bytes in
  let _, past_bound = address_zero_after (Dos_lane.max_exe_payload_bytes + 1) in
  check bool "address 0 does not hold the marker to begin with" true (before <> 0xAB);
  check int "a module of the largest size leaves address 0 alone" before at_bound;
  check int "one byte more wraps onto address 0" 0xAB past_bound;
  check bool "so the lane accepts the first and refuses the second" true
    (Result.is_ok
       (Dos_lane.image_of_bytes ~program_name:"a.exe" (mz (32 + Dos_lane.max_exe_payload_bytes)))
     && Result.is_error
          (Dos_lane.image_of_bytes ~program_name:"a.exe"
             (mz (32 + Dos_lane.max_exe_payload_bytes + 1))))
;;

(* What the lane accepts the loader must place. The COM bound is stricter than
   the loader (see the COM test above), and so is the EXE bound. *)
let test_what_the_lane_accepts_the_loader_places () =
  List.iter
    (fun delta ->
      let exe = mz (32 + Dos_lane.max_exe_payload_bytes + delta) in
      let com = String.make (Dos_lane.max_com_bytes + delta) '\x90' in
      List.iter
        (fun (name, image) ->
          if Result.is_ok (Dos_lane.image_of_bytes ~program_name:name image) then
            check bool (Printf.sprintf "an accepted %s at %+d is placed" name delta) true
              (loader_places image))
        [ "exe", exe; "com", com ])
    [ -2; -1; 0; 1; 2 ]
;;

let () =
  run "DOS program images"
    [ ( "image_of_bytes"
      , [ test_case "refusals" `Quick test_refusals
        ; test_case "the bounds are accepted" `Quick test_the_bounds_are_accepted
        ; test_case "a refused image leaves the running machine" `Quick
            test_a_refused_image_leaves_the_running_machine
        ; test_case "the boundary images load" `Quick test_the_boundary_images_load
        ; test_case "a file cut to 8.3 is not saved as a change" `Quick
            test_a_file_cut_to_8_3_is_not_saved_as_a_change
        ; test_case "file names the core cannot mount are refused" `Quick
            test_file_names_the_core_cannot_mount_are_refused
        ; test_case "the check agrees with the loader on EXE" `Quick
            test_the_check_agrees_with_the_loader_on_exe
        ; test_case "the COM bound is where the loader starts overwriting the image" `Quick
            test_the_com_bound_is_where_the_loader_starts_overwriting_the_image
        ; test_case "ZM is loaded as an EXE" `Quick test_zm_is_loaded_as_an_exe
        ; test_case "the EXE bound is where the loader starts wrapping" `Quick
            test_the_exe_bound_is_where_the_loader_starts_wrapping
        ; test_case "what the lane accepts the loader places" `Quick
            test_what_the_lane_accepts_the_loader_places
        ] )
    ]
;;
