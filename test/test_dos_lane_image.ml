(* A program image the core's loaders cannot place is refused as the caller's
   mistake, before any machine is built. The property test runs the real
   loader beside the check, so the bounds in Dos_lane cannot drift from the
   pinned core without turning it red. *)

open Alcotest

let who = "image-fixture"
let u16 n = String.init 2 (fun i -> Char.chr ((n lsr (8 * i)) land 0xFF))

(* An MZ image of [size] bytes with the three header fields the loader reads. *)
let mz ?(reloc_count = 0) ?(header_paras = 2) ?(reloc_offset = 0x1C) size =
  let image = Bytes.make size '\000' in
  let put offset field =
    if offset + 2 <= size then Bytes.blit_string (u16 field) 0 image offset 2
  in
  if size >= 2 then Bytes.blit_string "MZ" 0 image 0 2;
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
  refused "a payload past the end of memory"
    (mz (32 + Dos_lane.max_exe_payload_bytes + 1));
  refused "a COM larger than its segment" (String.make (Dos_lane.max_com_bytes + 1) '\x90')
;;

let test_the_bounds_are_accepted () =
  accepted "the largest COM" (String.make Dos_lane.max_com_bytes '\x90');
  accepted "the largest EXE payload" (mz (32 + Dos_lane.max_exe_payload_bytes));
  accepted "a header-only EXE" (mz 32);
  accepted "an EXE whose table fills the file" (mz ~reloc_count:2 ~reloc_offset:56 64);
  (* With no relocation entries the offset is never read. *)
  accepted "a relocation offset past the end with no entries" (mz ~reloc_offset:0xFFFF 64);
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

let load directory image =
  Dos_lane.load ~who ~ledger_dir:directory ~saves_dir:(Filename.concat directory "saves")
    ~checkpoint_dir:(Filename.concat directory "checkpoints")
    ~previous_autosave:Dos_lane.Discard_previous_autosave ~program_name:"game.exe" ~program_bytes:image ~files:[]
    ~announce:ignore
;;

let test_a_refused_image_leaves_the_running_machine () =
  with_lane (fun directory ->
    let hello = "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$" in
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

(* The check against the loader, over images built to sit on both sides of
   each bound. The loader's [Invalid_argument] is the only outcome that counts
   as "cannot place it"; any other exception fails the test. *)
let loader_places image =
  let machine = Dos_machine.create () in
  match
    if String.length image >= 2 && image.[0] = 'M' && image.[1] = 'Z' then
      Dos_machine.load_exe machine image
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
        (* Random bytes under an MZ signature: header fields are noise. *)
        let noise = Bytes.init size (fun _ -> Char.chr (Random.State.int random 256)) in
        if size >= 2 then Bytes.blit_string "MZ" 0 noise 0 2;
        Bytes.to_string noise
      else
        mz
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

(* "ZM" is a DOS executable signature. The core's EXE loader takes MZ only, so
   a ZM file goes to the COM loader and runs its header as code. *)
let test_zm_is_not_loaded_as_a_com () =
  let zm = "ZM" ^ String.make 100 '\x90' in
  check bool "the EXE loader refuses it" true
    (match Dos_machine.load_exe (Dos_machine.create ()) zm with
     | () -> false
     | exception Invalid_argument _ -> true);
  check bool "the lane refuses it, small or large" true
    (Result.is_error (Dos_lane.image_of_bytes ~program_name:"z.exe" zm)
     && Result.is_error
          (Dos_lane.image_of_bytes ~program_name:"z.exe" ("ZM" ^ String.make 100_000 '\x90')));
  check bool "a COM whose second byte is M or whose first is Z alone is not a ZM" true
    (Result.is_ok (Dos_lane.image_of_bytes ~program_name:"c.com" "ZX")
     && Result.is_ok (Dos_lane.image_of_bytes ~program_name:"c.com" "\x90M"))
;;

let test_the_check_agrees_with_the_loader_at_the_memory_edge () =
  List.iter
    (fun delta ->
      let image = mz (32 + Dos_lane.max_exe_payload_bytes + delta) in
      let expected = loader_places image in
      let accepted = Result.is_ok (Dos_lane.image_of_bytes ~program_name:"edge.exe" image) in
      check bool (Printf.sprintf "payload bound %+d" delta) expected accepted)
    [ -2; -1; 0; 1; 2 ];
  (* The COM bound is stricter than the loader (see the test above): what the
     check accepts, the loader must place. *)
  List.iter
    (fun delta ->
      let image = String.make (Dos_lane.max_com_bytes + delta) '\x90' in
      let accepted = Result.is_ok (Dos_lane.image_of_bytes ~program_name:"edge.com" image) in
      if accepted then check bool "an accepted COM is placed" true (loader_places image))
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
        ; test_case "the check agrees with the loader on EXE" `Quick
            test_the_check_agrees_with_the_loader_on_exe
        ; test_case "the COM bound is where the loader starts overwriting the image" `Quick
            test_the_com_bound_is_where_the_loader_starts_overwriting_the_image
        ; test_case "ZM is not loaded as a COM" `Quick test_zm_is_not_loaded_as_a_com
        ; test_case "the check agrees with the loader at the memory edge" `Quick
            test_the_check_agrees_with_the_loader_at_the_memory_edge
        ] )
    ]
;;
