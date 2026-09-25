(* DOS lane tools — the lane's tools through Tool_misc.dispatch.

   The machine needs no image from outside: the tests assemble a COM program
   of their own, so CI carries no game. What they pin: the no-machine
   refusal, the inventory listing, that a loaded program's screen text comes
   back readable, that waiting_for_key marks the turn, that a key reaches the
   guest and lands in the ledger under the caller's name, that a key name the
   machine has no key for is refused before anything is pressed, the per-call
   step cap, memory reads, and the read-only classification. *)

open Alcotest
open Masc

let dispatch ~base_path ?(agent = "dos-test") name assoc =
  let ctx : Tool_misc.context =
    { config = Workspace.default_config base_path; agent_name = agent; help_schemas = [] }
  in
  match Tool_misc.dispatch ctx ~name ~args:(`Assoc assoc) with
  | Some result -> result
  | None -> fail (name ^ " is not dispatched by the misc tool owner")
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

let with_workspace f =
  let base_path = Filename.temp_dir "masc-dos-tools-" "" in
  Fun.protect
    ~finally:(fun () ->
      (* The machine is process-global: a test that leaves one loaded would
         hand it to the next one. *)
      eject_held ();
      Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let string_field name result =
  match member name (Tool_result.data result) with
  | Some (`String s) -> s
  | _ -> fail (Printf.sprintf "no %s in %s" name (Tool_result.message result))
;;

let int_field name result =
  match member name (Tool_result.data result) with
  | Some (`Int n) -> n
  | _ -> fail (Printf.sprintf "no %s in %s" name (Tool_result.message result))
;;

let bool_field name result =
  match member name (Tool_result.data result) with
  | Some (`Bool b) -> b
  | _ -> fail (Printf.sprintf "no %s in %s" name (Tool_result.message result))
;;

let is_completed result = Tool_result.failure_class result = None

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

(* A COM image that prints HI, then loops on the BIOS key read until one
   arrives, then terminates. The loop is the real idiom: a blocking read with
   an empty ring returns AX=0 here rather than blocking the whole process, and
   every DOS runtime spins on that. A program that fell straight through would
   exit before anyone could press anything.

   org 0x100: mov ah,9 / mov dx,msg / int 21h
              wait: mov ah,0 / int 16h / or ax,ax / jz wait
              int 20h / "HI$" *)
let hello_com =
  "\xb4\x09\xba\x11\x01\xcd\x21\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20HI$"
;;

(* jmp $ -- a program that never asks the BIOS for a key, so a press runs its
   whole budget instead of settling on the first chunk. *)
let spinner_com = "\xeb\xfe"

(* Poll INT 33h until the left button goes down, print D, then poll until it
   comes back up, print U, and exit. The guest therefore proves both state
   transitions; a ledger entry alone only proves that the host accepted the
   call.

   org 0x100: down: mov ax,3 / int 33h / test bx,1 / jz down
              print 'D'
              up:   mov ax,3 / int 33h / test bx,1 / jnz up
              print 'U' / int 20h *)
let mouse_click_com =
  "\xb8\x03\x00\xcd\x33\xf7\xc3\x01\x00\x74\xf5\xb2\x44\xb4\x02\xcd\x21\
   \xb8\x03\x00\xcd\x33\xf7\xc3\x01\x00\x75\xf5\xb2\x55\xb4\x02\xcd\x21\
   \xcd\x20"
;;

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    mkdir_p (Filename.dirname dir);
    Sys.mkdir dir 0o755
  end
;;

let programs_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos"
  |> fun d -> Filename.concat d "programs"
;;

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)
;;

let install_program ~base_path name contents =
  let dir = programs_dir ~base_path in
  mkdir_p dir;
  write_file (Filename.concat dir name) contents
;;

let load ~base_path name = dispatch ~base_path "masc_dos_load" [ ("program", `String name) ]

(* Setup for the tests that are about what happens after a load. The load's
   own result has its own test. *)
let boot ?(agent = "dos-test") ~base_path name =
  ignore
    (dispatch ~base_path ~agent "masc_dos_load" [ ("program", `String name) ]
      : Tool_result.result)

let test_no_machine () =
  with_workspace (fun base_path ->
    let result = dispatch ~base_path "masc_dos_screen" [] in
    check bool "screen without a machine is refused" false (is_completed result);
    check bool "and says which tool starts one" true
      (contains "masc_dos_load" (Tool_result.message result)))
;;

(* A click needs a machine to land on, like every other input tool: without one
   it is refused and names the tool that starts one. *)
let test_click_without_a_machine_is_refused () =
  with_workspace (fun base_path ->
    let result = dispatch ~base_path "masc_dos_click" [ ("x", `Int 1); ("y", `Int 1) ] in
    check bool "click without a machine is refused" false (is_completed result);
    check bool "and says which tool starts one" true
      (contains "masc_dos_load" (Tool_result.message result)))
;;

let test_inventory_when_unnamed () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let result = dispatch ~base_path "masc_dos_load" [] in
    check bool "listing succeeds" true (is_completed result);
    match member "programs_available" (Tool_result.data result) with
    | Some (`List [ `String name ]) -> check string "the inventory" "hello.com" name
    | _ -> fail "no programs_available")
;;

let test_load_runs_to_the_first_key_request () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let result = load ~base_path "hello.com" in
    check bool "load succeeds" true (is_completed result);
    check string "the program name" "hello.com" (string_field "program" result);
    check bool "its output is on the screen" true
      (contains "HI" (string_field "screen_text" result));
    (* The program is spinning on INT 16h with an empty ring and its screen
       has stopped moving. Both halves are why the load stopped here instead
       of burning its whole budget. *)
    check bool "it settled" true (bool_field "settled" result);
    check bool "it is waiting for a key" true (bool_field "waiting_for_key" result);
    check bool "and has not exited" false (bool_field "exited" result))
;;

(* The load and the screen say which DOS core answered. Two servers built
   from one masc commit can link different cores; a black screen from the
   older one otherwise looks like a game bug. *)
let test_load_and_screen_name_the_core () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let expected = Dos_lane.core_to_yojson Dos_lane.core in
    let core_of name result =
      match member "core" (Tool_result.data result) with
      | Some core -> core
      | None -> fail (Printf.sprintf "%s carries no core: %s" name (Tool_result.message result))
    in
    let loaded = load ~base_path "hello.com" in
    check bool "load succeeds" true (is_completed loaded);
    check string "the load names the linked core"
      (Yojson.Safe.to_string expected) (Yojson.Safe.to_string (core_of "load" loaded));
    let screen = dispatch ~base_path "masc_dos_screen" [] in
    check string "the screen names the linked core"
      (Yojson.Safe.to_string expected) (Yojson.Safe.to_string (core_of "screen" screen));
    check string "the digest is the one the core baked at its build"
      Dos_core_identity.source_digest Dos_lane.core.Dos_lane.source_digest)
;;

(* CI links the core at OCAML_DOS_SHA. This fails when the SHA moved without
   Dos_lane's pinned digest, and locally when the build linked another core
   (an older opam install, a vendored checkout on another branch). *)
(* The pin lives in these two files. Naming them here, as the literals the
   edited-tests selector reads, makes a PR that moves only OCAML_DOS_SHA run
   this suite, so a digest left behind fails that PR and not a later main. *)
let pin_script = "scripts/opam-pin-external-deps.sh"
let pin_lock = "masc.opam.locked"

let test_the_linked_core_is_the_pinned_one () =
  let core = Dos_lane.core in
  if not core.Dos_lane.matches_pin then
    fail
      (Printf.sprintf
         "linked ocaml-dos source digest %s differs from the pinned %s: either this \
          build linked a core other than OCAML_DOS_SHA (%s, %s), or the SHA moved and \
          Dos_lane.pinned_core_source_digest must become %s"
         core.source_digest core.pinned_source_digest pin_script pin_lock
         core.source_digest)
;;

let test_press_reaches_the_guest_and_the_ledger () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~agent:"vincent" ~base_path "hello.com";
    let result =
      dispatch ~base_path ~agent:"vincent" "masc_dos_press"
        [ ("keys", `List [ `String "enter" ]) ]
    in
    check bool "press succeeds" true (is_completed result);
    (* The guest took the key and ran into INT 20h. *)
    check bool "the program finished" true (bool_field "exited" result);
    match Dos_lane.ledger () with
    | [ entry ] ->
      check string "the ledger names the caller" "vincent" entry.Dos_lane.who;
      check string "and the key" "enter" entry.Dos_lane.key_name
    | entries ->
      fail (Printf.sprintf "expected one ledger entry, got %d" (List.length entries)))
;;

(* A click is button down, run, button up, run, in one call, sharing one step
   ceiling. The guest prints D only after INT 33h reports the button down, and
   prints U and exits only after the host clears it, so the screen and the exit
   are what prove both halves reached the guest. The step total is not asked to
   prove that -- how many steps the poll loop burns belongs to ocaml-dos -- it
   only has to stay inside the one ceiling. *)
let test_click_reaches_the_guest_and_the_ledger () =
  with_workspace (fun base_path ->
    install_program ~base_path "mouse.com" mouse_click_com;
    boot ~agent:"vincent" ~base_path "mouse.com";
    let result =
      dispatch ~base_path ~agent:"vincent" "masc_dos_click"
        [ ("x", `Int 1); ("y", `Int 1); ("steps", `Int 1_000) ]
    in
    check bool "click succeeds" true (is_completed result);
    check bool "the guest observed release and exited" true (bool_field "exited" result);
    check bool "the guest observed down and up" true
      (contains "DU" (string_field "screen_text" result));
    check bool "down and up share one ceiling, not two" true
      (int_field "steps_run" result <= 1_000);
    match Dos_lane.ledger () with
    | [ entry ] ->
      check string "the ledger names the caller" "vincent" entry.Dos_lane.who;
      (* The default buttons is 1 (left); the entry names the button that
         went down, not the 0 the up half releases it to. *)
      check string "and the click as mouse(x,y,buttons)" "mouse(1,1,1)"
        entry.Dos_lane.key_name
    | entries ->
      fail (Printf.sprintf "expected one ledger entry, got %d" (List.length entries)))
;;

(* The machine reads a program into guest memory and masc_dos_peek reads guest
   memory back out. A caller-supplied path would therefore be an arbitrary
   host-file read, so only inventory names resolve. *)
let test_only_inventory_names_resolve () =
  with_workspace (fun base_path ->
    let outside = Filename.temp_file "masc-dos-outside-" ".com" in
    Out_channel.with_open_bin outside (fun oc -> output_string oc hello_com);
    Fun.protect
      ~finally:(fun () -> Sys.remove outside)
      (fun () ->
        let by_path = load ~base_path outside in
        check bool "a host path is refused" false (is_completed by_path);
        let climbing = load ~base_path "../../etc/passwd" in
        check bool "and so is climbing out" false (is_completed climbing)))
;;

(* The name is checked for separators and dots, but a symbolic link carries a
   path no name spells. Until the boundary moved onto the resolved path, an
   entry linked at a host file was loaded into guest memory, where
   masc_dos_peek hands it back out 256 bytes at a time. *)
let test_a_link_out_of_the_inventory_is_refused () =
  with_workspace (fun base_path ->
    let outside = Filename.temp_file "masc-dos-secret-" ".com" in
    write_file outside hello_com;
    Fun.protect
      ~finally:(fun () -> Sys.remove outside)
      (fun () ->
        let dir = programs_dir ~base_path in
        mkdir_p dir;
        Unix.symlink outside (Filename.concat dir "secret.com");
        check bool "a linked host file is refused" false
          (is_completed (load ~base_path "secret.com"));
        (* The same link one level down, where the mount list reads it. *)
        let game = Filename.concat dir "game" in
        mkdir_p game;
        write_file (Filename.concat game "game.com") hello_com;
        Unix.symlink outside (Filename.concat game "data.dat");
        check bool "and so is a linked file beside the executable" false
          (is_completed (load ~base_path "game"))))
;;

(* A game directory often holds several programs: 삼국지3 boots KOEI.COM,
   which runs OPEN.EXE and MAIN.EXE beside it, and the setup and editor sit
   there too. The refusal used to ask the caller to name one with no argument
   to name it by. [boot] is that argument; it names a file inside the
   directory, folded the way DOS folds, and nothing else. *)
let test_boot_names_the_program_inside_a_directory () =
  with_workspace (fun base_path ->
    let game = Filename.concat (programs_dir ~base_path) "arcade" in
    mkdir_p game;
    write_file (Filename.concat game "LOADER.COM") hello_com;
    write_file (Filename.concat game "SETUP.COM") spinner_com;
    let unnamed = load ~base_path "arcade" in
    check bool "two programs and no boot is a question" false (is_completed unnamed);
    check bool "the question names the argument" true
      (contains "boot" (Tool_result.message unnamed));
    let booted =
      dispatch ~base_path "masc_dos_load"
        [ ("program", `String "arcade"); ("boot", `String "loader.com") ]
    in
    check bool "boot picks the loader, folded like DOS" true (is_completed booted);
    check string "the loader is what runs" "LOADER.COM" (string_field "program" booted);
    check bool "the loader reaches its first key request" true
      (bool_field "waiting_for_key" booted);
    let missing =
      dispatch ~base_path "masc_dos_load"
        [ ("program", `String "arcade"); ("boot", `String "MAIN.EXE") ]
    in
    check bool "a boot the directory does not hold is refused" false (is_completed missing);
    write_file (Filename.concat game "SAVE.DAT") "not a program";
    let data =
      dispatch ~base_path "masc_dos_load"
        [ ("program", `String "arcade"); ("boot", `String "SAVE.DAT") ]
    in
    check bool "a boot that is not a program is refused" false (is_completed data);
    let climbing =
      dispatch ~base_path "masc_dos_load"
        [ ("program", `String "arcade"); ("boot", `String "../LOADER.COM") ]
    in
    check bool "boot is a file name, not a path" false (is_completed climbing);
    install_program ~base_path "hello.com" hello_com;
    let single =
      dispatch ~base_path "masc_dos_load"
        [ ("program", `String "hello.com"); ("boot", `String "hello.com") ]
    in
    check bool "boot on a single file is refused" false (is_completed single))
;;

(* The step budget is declared per key. Multiplied by a caller-controlled
   number of keys it stopped bounding anything: sixty-four keys at four
   million each is a quarter of a billion instructions run under the
   machine's mutex, with every other keeper waiting. A sequence now spends
   one ceiling and says how far it got. *)
let test_a_sequence_spends_one_ceiling_not_one_per_key () =
  with_workspace (fun base_path ->
    install_program ~base_path "spin.com" spinner_com;
    boot ~base_path "spin.com";
    let result =
      dispatch ~base_path "masc_dos_press"
        [ ("keys", `List [ `String "a"; `String "b" ]); ("steps", `Int 4_000_000) ]
    in
    check bool "the press is accepted" true (is_completed result);
    check bool "the call stops at one budget, not two" true
      (int_field "steps_run" result <= 4_000_000);
    check int "and says how many keys landed" 1 (int_field "keys_pressed" result);
    (* The first key left the program busy, so the second was never put in
       the ring: a key typed into a running loop is eaten by it. *)
    check int "the unsent key is not in the ledger" 1 (List.length (Dos_lane.ledger ())))
;;

(* The ceiling bounds the machine's time, not the call's work: a program that
   has exited runs no instructions, so a sequence of any length would still
   walk every key and write every ledger line. *)
let test_a_sequence_has_a_length () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    check bool "65 keys is refused" false
      (is_completed
         (dispatch ~base_path "masc_dos_press"
            [ ("keys", `List (List.init 65 (fun _ -> `String "a"))) ]));
    check bool "and 257 characters is refused" false
      (is_completed
         (dispatch ~base_path "masc_dos_type"
            [ ("text", `String (String.make 257 'a')) ])))
;;

(* DOS folds filenames, so two entries that differ only in case are one name
   to the guest: one would shadow the other while the observation still listed
   both. Called on the lane rather than through the inventory on purpose --
   this machine's filesystem folds case too, so the two files cannot both
   exist here to be found. *)
let test_two_names_that_differ_only_in_case_are_refused () =
  with_workspace (fun base_path ->
    let announced = ref 0 in
    let result =
      Dos_lane.load ~who:"dos-test"
        ~ledger_dir:(Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos")
        ~saves_dir:(Filename.concat base_path "saves")
        ~checkpoint_dir:(Filename.concat base_path "checkpoints")
        ~program_name:"game.com" ~program_bytes:hello_com
        ~files:[ ("GAME.COM", hello_com); ("DATA.DAT", "upper"); ("data.dat", "lower") ]
        ~announce:(fun () -> incr announced)
    in
    check bool "the load is refused" true (Result.is_error result);
    check int "and nothing was announced" 0 !announced)
;;

(* A game in miniature: if SAVE.DAT opens it prints it, otherwise it writes
   "NEW$" there -- create, write, close -- and waits for a key either way.

   100 mov ax,3D00h / mov dx,fname / int 21h / jc create
   10A mov bx,ax / mov ah,3Fh / mov cx,16 / mov dx,buf / int 21h
   116 mov ah,3Eh / int 21h / mov ah,9 / mov dx,buf / int 21h / jmp wait
   123 create: mov ah,3Ch / xor cx,cx / mov dx,fname / int 21h / mov bx,ax
       mov ah,40h / mov cx,4 / mov dx,msg / int 21h / mov ah,3Eh / int 21h
   13C wait: mov ah,0 / int 16h / or ax,ax / jz wait / int 20h
   146 fname "SAVE.DAT",0   14F msg "NEW$"   153 buf 16 x "$" *)
let saver_com_named fname =
  let word n = String.init 2 (fun i -> Char.chr ((n lsr (8 * i)) land 0xff)) in
  let fname_at = 0x146 in
  let msg_at = fname_at + String.length fname + 1 in
  let buf_at = msg_at + 4 in
  "\xb8\x00\x3d\xba" ^ word fname_at ^ "\xcd\x21\x72\x19"
  ^ "\x89\xc3\xb4\x3f\xb9\x10\x00\xba" ^ word buf_at ^ "\xcd\x21"
  ^ "\xb4\x3e\xcd\x21\xb4\x09\xba" ^ word buf_at ^ "\xcd\x21\xeb\x19"
  ^ "\xb4\x3c\x31\xc9\xba" ^ word fname_at ^ "\xcd\x21\x89\xc3"
  ^ "\xb4\x40\xb9\x04\x00\xba" ^ word msg_at ^ "\xcd\x21\xb4\x3e\xcd\x21"
  ^ "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\xcd\x20"
  ^ fname ^ "\000" ^ "NEW$" ^ String.make 16 '$'
;;

let saver_com = saver_com_named "SAVE.DAT"

let saves_of ~base_path name =
  Filename.concat
    (Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos") "saves")
    name
;;

let install_game ~base_path name files =
  let dir = Filename.concat (programs_dir ~base_path) name in
  mkdir_p dir;
  List.iter (fun (f, contents) -> write_file (Filename.concat dir f) contents) files
;;

let eject () = eject_held ()

(* A game saves by writing a file, and the machine kept what the guest wrote
   only in memory: an eject or a server restart took the campaign with it,
   as the MSX 삼국지2 lane's Keepers found. What the program wrote is now on
   disk after the call that wrote it, and the next load mounts it. *)
let test_a_save_outlives_its_machine () =
  with_workspace (fun base_path ->
    install_game ~base_path "quest" [ ("QUEST.COM", saver_com) ];
    let first = load ~base_path "quest" in
    check bool "the first run boots" true (is_completed first);
    let kept = Filename.concat (saves_of ~base_path "quest") "SAVE.DAT" in
    check bool "the save is on disk after the call that wrote it" true (Sys.file_exists kept);
    check string "with what the program wrote" "NEW$"
      (In_channel.with_open_bin kept In_channel.input_all);
    eject ();
    let second = load ~base_path "quest" in
    check bool "the next machine finds the save and prints it" true
      (contains "NEW" (string_field "screen_text" second)))
;;

(* A save made earlier stands in for the inventory's copy of the same file,
   matched the way DOS matches names. *)
let test_a_save_is_mounted_over_the_inventory_copy () =
  with_workspace (fun base_path ->
    install_game ~base_path "quest" [ ("QUEST.COM", saver_com); ("SAVE.DAT", "OLD$") ];
    let saves = saves_of ~base_path "quest" in
    mkdir_p saves;
    write_file (Filename.concat saves "save.dat") "MINE$";
    let loaded = load ~base_path "quest" in
    let text = string_field "screen_text" loaded in
    check bool "the save wins" true (contains "MINE" text);
    check bool "the inventory copy is not what the guest opened" false (contains "OLD" text))
;;

let unsaved result =
  match member "unsaved" (Tool_result.data result) with
  | Some (`List items) -> List.map (function `String u -> u | _ -> fail "unsaved item") items
  | _ -> fail (Printf.sprintf "no unsaved in %s" (Tool_result.message result))
;;

(* When the save cannot be written the call still returns what the guest did
   -- it moved either way, and an error would be answered by sending the same
   keys again -- and lists the save that did not reach disk. *)
let test_a_save_that_cannot_be_written_is_reported () =
  with_workspace (fun base_path ->
    install_game ~base_path "quest" [ ("QUEST.COM", saver_com) ];
    let saves = saves_of ~base_path "quest" in
    mkdir_p (Filename.dirname saves);
    write_file saves "a file where the save directory would be";
    let loaded = load ~base_path "quest" in
    check bool "the call returns the screen" true (is_completed loaded);
    (match unsaved loaded with
     | [ line ] -> check bool "naming the save" true (contains "SAVE.DAT" line)
     | lines -> fail (Printf.sprintf "expected one unsaved line, got %d" (List.length lines)));
    let next = dispatch ~base_path "masc_dos_screen" [] in
    check bool "the machine is still there" true (is_completed next))
;;

(* DOS takes "/" as a separator, so a guest asked for a save name can create
   "../OUT.DAT". That name never reaches the host: it stays in the machine,
   is reported once, and nothing lands beside the saves directory. *)
let test_a_guest_path_never_reaches_the_host () =
  with_workspace (fun base_path ->
    install_game ~base_path "quest" [ ("QUEST.COM", saver_com_named "../OUT.DAT") ];
    let loaded = load ~base_path "quest" in
    check bool "the call returns" true (is_completed loaded);
    check bool "the path is reported" true
      (List.exists (contains "a path, not a file name") (unsaved loaded));
    let saves = saves_of ~base_path "quest" in
    check bool "nothing beside the saves directory" false
      (Sys.file_exists (Filename.concat (Filename.dirname saves) "OUT.DAT"));
    check bool "nothing in it either" false
      (Sys.file_exists saves && Array.length (Sys.readdir saves) > 0);
    let again = dispatch ~base_path "masc_dos_step" [ ("steps", `Int 1000) ] in
    check (list string) "reported once, not on every call" [] (unsaved again))
;;

let controller result =
  match member "controller" (Tool_result.data result) with
  | Some (`String who) -> Some who
  | Some `Null | None -> None
  | Some _ -> fail "controller is neither a name nor null"
;;

let press_as ~base_path who key =
  dispatch ~base_path ~agent:who "masc_dos_press" [ ("keys", `List [ `String key ]) ]
;;

(* A hotseat game asks each human ruler in turn at one keyboard. Without a
   controller a second Keeper's key lands in whoever's turn is on screen, and
   on the MSX lane Keepers swapped programs and restored slots under each
   other mid-campaign. Whoever loads holds the machine; others are refused
   before anything happens and can still watch. *)
let test_only_the_holder_moves_the_machine () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let loaded = dispatch ~base_path ~agent:"liu-bei" "masc_dos_load" [ ("program", `String "hello.com") ] in
    check (option string) "the loader holds it" (Some "liu-bei") (controller loaded);
    let refused = press_as ~base_path "cao-cao" "a" in
    check bool "another player's key is refused" false (is_completed refused);
    check bool "the refusal names the holder" true
      (contains "liu-bei" (Tool_result.message refused));
    check int "and nothing reached the ledger" 0 (List.length (Dos_lane.ledger ()));
    check bool "watching needs no controller" true
      (is_completed (dispatch ~base_path ~agent:"cao-cao" "masc_dos_screen" []));
    check bool "nor may another player eject it" false
      (is_completed (dispatch ~base_path ~agent:"cao-cao" "masc_dos_eject" []));
    check bool "or load over it" false
      (is_completed
         (dispatch ~base_path ~agent:"cao-cao" "masc_dos_load" [ ("program", `String "hello.com") ])))
;;

let test_pass_hands_the_machine_on () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let not_mine =
      dispatch ~base_path ~agent:"cao-cao" "masc_dos_pass" [ ("to", `String "cao-cao") ]
    in
    check bool "only the holder passes" false (is_completed not_mine);
    let passed =
      dispatch ~base_path ~agent:"dos-test" "masc_dos_pass" [ ("to", `String "cao-cao") ]
    in
    check (option string) "the controller moves" (Some "cao-cao") (controller passed);
    check bool "the new holder plays" true (is_completed (press_as ~base_path "cao-cao" "a"));
    check bool "the old holder no longer does" false
      (is_completed (press_as ~base_path "dos-test" "a")))
;;

(* A freed controller goes to whoever next moves the machine and succeeds; a
   call that is refused for its own arguments takes nothing. *)
let test_a_free_controller_goes_to_the_next_successful_mover () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let freed = dispatch ~base_path ~agent:"dos-test" "masc_dos_pass" [] in
    check (option string) "freed" None (controller freed);
    let typo = press_as ~base_path "sun-quan" "no-such-key" in
    check bool "a bad key is refused" false (is_completed typo);
    let after_typo = dispatch ~base_path "masc_dos_screen" [] in
    check (option string) "and took nothing" None (controller after_typo);
    let moved = press_as ~base_path "sun-quan" "a" in
    check (option string) "the next successful mover holds it" (Some "sun-quan")
      (controller moved))
;;

(* A hotseat game runs for hours, and the Keeper holding the controller can
   stop in that time. It will never pass, so a stopped holder is let go the
   next time a Keeper moves the machine. A finished stop removes the Keeper
   from the registry and keeps its meta, so that is the case pinned here. A
   Keeper that is running, or launching, keeps it, and so does a name that
   is not a Keeper. The check reads Keeper state, so it sits on the Keeper's
   own tool path, not the generic dispatch. *)
let keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ ("name", `String name); ("activation_mode", `String "manual") ])
  with
  | Ok meta -> meta
  | Error error -> fail error
;;

type holder_state =
  | Stopped_and_gone
  | Running
  | Launching
  | Not_a_keeper

let with_holder ~base_path state name f =
  let config = Workspace.default_config base_path in
  let meta = keeper_meta name in
  let store_meta () =
    match Keeper_meta_store.replace_snapshot config meta with
    | Ok () -> ()
    | Error error -> fail error
  in
  (match state with
   | Stopped_and_gone -> store_meta ()
   | Running ->
     store_meta ();
     ignore (Keeper_registry.For_testing.register ~base_path name meta : Keeper_registry.registry_entry)
   | Launching ->
     store_meta ();
     ignore (Keeper_registry.register_offline ~base_path name meta : Keeper_registry.registry_entry)
   | Not_a_keeper -> ());
  Fun.protect
    ~finally:(fun () -> Keeper_registry.For_testing.unregister ~base_path name)
    f
;;

let keeper_press ~base_path who key =
  let execution =
    Keeper_tool_in_process_runtime.handle_masc_misc_with_outcome
      ~config:(Workspace.default_config base_path) ~meta:(keeper_meta who)
      ~name:"masc_dos_press" ~args:(`Assoc [ ("keys", `List [ `String key ]) ])
  in
  match execution.disposition with
  | Tool_result.Failed _ -> false
  | _ -> true
;;

let current_controller () =
  match Dos_lane.screen () with
  | Ok o -> o.Dos_lane.controller
  | Error e -> fail (Dos_lane.error_to_string e)
;;

let test_a_stopped_holders_controller_is_let_go () =
  List.iter
    (fun (state, label, released) ->
      with_workspace (fun base_path ->
        install_program ~base_path "hello.com" hello_com;
        with_holder ~base_path state "cao-cao" (fun () ->
          boot ~agent:"cao-cao" ~base_path "hello.com";
          check bool (label ^ ": the next Keeper moves") released
            (keeper_press ~base_path "liu-bei" "a");
          check (option string) (label ^ ": holder")
            (Some (if released then "liu-bei" else "cao-cao"))
            (current_controller ()))))
    [ (Stopped_and_gone, "a stopped Keeper", true)
    ; (Running, "a running Keeper", false)
    ; (Launching, "a launching Keeper", false)
    ; (Not_a_keeper, "a name that is not a Keeper", false)
    ]
;;

(* A pass to a name no caller can ever have -- "@liu-bei", "liu bei" --
   would leave the machine held by nobody who can move or eject it again. It
   is refused, and the controller stays where it was. *)
let test_a_pass_to_an_impossible_name_is_refused () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    List.iter
      (fun bad ->
        let refused =
          dispatch ~base_path ~agent:"dos-test" "masc_dos_pass" [ ("to", `String bad) ]
        in
        check bool (bad ^ " is refused") false (is_completed refused))
      [ "@liu-bei"; "liu bei"; "\xec\x9c\xa0\xeb\xb9\x84" ];
    check (option string) "the holder still holds it" (Some "dos-test")
      (controller (dispatch ~base_path "masc_dos_screen" [])))
;;

(* lea ax, ax: an instruction the emulator does not implement. The core
   raises instead of misbehaving; the lane turns that into an error the
   caller can read, and keeps the stopped machine loaded. *)
let test_an_unimplemented_instruction_is_an_error () =
  with_workspace (fun base_path ->
    install_program ~base_path "fault.com" "\x8d\xc0";
    let loaded = load ~base_path "fault.com" in
    check bool "the load reports the fault" false (is_completed loaded);
    check bool "and says what happened" true
      (contains "does not implement" (Tool_result.message loaded));
    check bool "the stopped machine stays loaded" true
      (is_completed (dispatch ~base_path "masc_dos_screen" [])))
;;

(* The instructions before a fault still ran and may have repainted the
   screen. The step count in tool responses and ledger positions must include
   them. Three instructions complete here (mov ax,0xb800; mov es,ax;
   mov byte es:[0],'X') before lea ax,ax faults. *)
let test_a_fault_keeps_the_steps_that_ran () =
  with_workspace (fun base_path ->
    install_program ~base_path "paint-then-fault.com"
      "\xb8\x00\xb8\x8e\xc0\x26\xc6\x06\x00\x00\x58\x8d\xc0";
    let loaded = load ~base_path "paint-then-fault.com" in
    check bool "the load reports the fault" false (is_completed loaded);
    match Dos_lane.screen () with
    | Error e -> fail (Dos_lane.error_to_string e)
    | Ok observation ->
      check int "the completed instructions are counted" 3 observation.Dos_lane.steps)
;;

let test_unknown_key_is_refused () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_press"
        [ ("keys", `List [ `String "enter"; `String "hyperspace" ]) ]
    in
    check bool "the call is refused" false (is_completed result);
    (* Refused before anything was pressed: the good key in front of the bad
       one must not reach the ring, or half a sequence lands in the game. *)
    check int "nothing was pressed" 0 (List.length (Dos_lane.ledger ())))
;;

let test_step_cap () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_step"
        [ ("steps", `Int (Dos_lane.max_steps_per_call + 1)) ]
    in
    check bool "over the cap is refused" false (is_completed result);
    check bool "and names the cap" true
      (contains (string_of_int Dos_lane.max_steps_per_call) (Tool_result.message result)))
;;

let test_peek_reads_the_text_page () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    boot ~base_path "hello.com";
    let result =
      dispatch ~base_path "masc_dos_peek" [ ("address", `String "b8000"); ("length", `Int 4) ]
    in
    check bool "peek succeeds" true (is_completed result);
    (* 'H' with the default attribute, then 'I': character and attribute
       alternate in the text page. *)
    check string "the first two cells" "48074907" (string_field "hex" result))
;;

(* Ask the catalog, not the facade. The gate that decides whether a tool call
   counts as a read looks the flag up in Tool_catalog, and Tool_misc writes it
   there when it registers each name -- so a classification that never reaches
   the catalog fails here instead of passing against an internal function. *)
let test_read_only_classification () =
  let read_only name =
    match Tool_catalog.registered_metadata name with
    | None -> fail (name ^ " registered no runtime metadata")
    | Some metadata ->
      (match metadata.Tool_catalog.readonly with
       | Some flag -> flag
       | None -> fail (name ^ " declares no readonly flag"))
  in
  check bool "screen reads" true (read_only "masc_dos_screen");
  check bool "peek reads" true (read_only "masc_dos_peek");
  check bool "load changes the machine" false (read_only "masc_dos_load");
  check bool "press changes the machine" false (read_only "masc_dos_press");
  check bool "click changes the machine" false (read_only "masc_dos_click");
  check bool "step changes the machine" false (read_only "masc_dos_step");
  check bool "save writes a slot" false (read_only "masc_dos_save");
  check bool "restore replaces the machine" false (read_only "masc_dos_restore")
;;

let test_every_tool_is_declared () =
  List.iter
    (fun name ->
      match Tool_schemas_misc.misc_operation_of_tool_name name with
      | None -> fail (name ^ " has no misc operation")
      | Some op ->
        (match Tool_schemas_misc.misc_registered_schema op with
         | Some (schema : Masc_domain.tool_schema) ->
           check string "schema name" name schema.name
         | None -> fail (name ^ " registers no schema")))
    [ "masc_dos_load"; "masc_dos_eject"; "masc_dos_screen"; "masc_dos_step";
      "masc_dos_press"; "masc_dos_click"; "masc_dos_type"; "masc_dos_peek";
      "masc_dos_pass"; "masc_dos_save"; "masc_dos_restore" ]
;;

(* ---------- checkpoints ---------- *)

(* Echoes every key it is given and asks for the next one, forever: a program
   whose screen is the history of its input, so two runs that took the same
   keys from the same state show the same text.

   org 0x100: wait: mov ah,0 / int 16h / or ax,ax / jz wait
              mov dl,al / mov ah,2 / int 21h / jmp wait *)
let echo_com = "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\x88\xc2\xb4\x02\xcd\x21\xeb\xf0"

let save_as ?(agent = "dos-test") ~base_path slot =
  dispatch ~base_path ~agent "masc_dos_save" [ ("slot", `String slot) ]
;;

let restore_as ?(agent = "dos-test") ~base_path slot =
  dispatch ~base_path ~agent "masc_dos_restore" [ ("slot", `String slot) ]
;;

let mark () =
  match Dos_lane.current_publication () with
  | Dos_lane.Stable m | Dos_lane.Running m -> m
  | Dos_lane.No_screen -> fail "no machine is published"
;;

let ledger_keys () = List.map (fun e -> e.Dos_lane.key_name) (Dos_lane.ledger ())

let ledger_file ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos") "ledger.jsonl"
;;

(* The contract the whole feature stands on: load, play, save, eject,
   restore, play on -- and the machine is where it would have been had the
   eject never happened. Screen, step count, CS:IP and ledger all agree. *)
let test_a_restored_machine_plays_on_as_if_never_stopped () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    let play_rest () =
      ignore (press_as ~base_path "dos-test" "b");
      press_as ~base_path "dos-test" "c"
    in
    boot ~base_path "echo.com";
    ignore (press_as ~base_path "dos-test" "a");
    let direct = play_rest () in
    let direct_ledger = ledger_keys () in
    eject ();
    boot ~base_path "echo.com";
    ignore (press_as ~base_path "dos-test" "a");
    let saved = save_as ~base_path "mid" in
    check bool "save succeeds" true (is_completed saved);
    check string "and names its slot" "mid" (string_field "slot" saved);
    eject ();
    let restored = restore_as ~base_path "mid" in
    check bool "restore succeeds with no machine loaded" true (is_completed restored);
    check bool "the saved screen is back" true
      (contains "a" (string_field "screen_text" restored));
    let resumed = play_rest () in
    check string "the same screen" (string_field "screen_text" direct)
      (string_field "screen_text" resumed);
    check int "the same step count" (int_field "steps" direct) (int_field "steps" resumed);
    check string "the same CS:IP" (string_field "cs_ip" direct) (string_field "cs_ip" resumed);
    check (list string) "the same ledger" direct_ledger (ledger_keys ()))
;;

(* Anyone may save -- it moves nothing -- but a restore replaces the machine,
   so it asks what a load asks: the controller free or the caller's. A
   refused restore changes nothing. *)
let test_restore_needs_the_controller () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~agent:"liu-bei" ~base_path "echo.com";
    let watched = save_as ~agent:"cao-cao" ~base_path "watched" in
    check bool "a watcher may save" true (is_completed watched);
    check (option string) "and the holder keeps the controller" (Some "liu-bei")
      (controller watched);
    let before = mark () in
    let refused = restore_as ~agent:"cao-cao" ~base_path "watched" in
    check bool "another player's restore is refused" false (is_completed refused);
    check bool "naming the holder" true (contains "liu-bei" (Tool_result.message refused));
    let after = mark () in
    check string "the machine is the same one" before.Dos_lane.incarnation
      after.Dos_lane.incarnation;
    check int "and did not change" before.Dos_lane.count after.Dos_lane.count;
    ignore (dispatch ~base_path ~agent:"liu-bei" "masc_dos_pass" []);
    let taken = restore_as ~agent:"cao-cao" ~base_path "watched" in
    check bool "with the controller free it restores" true (is_completed taken);
    check (option string) "and the restorer holds it" (Some "cao-cao") (controller taken))
;;

(* A restore is a new history even when it installs the same bytes twice:
   an observer holding the old incarnation must see the machine was
   replaced, and the change count moves. *)
let test_a_restore_is_a_new_incarnation () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~base_path "echo.com";
    ignore (save_as ~base_path "same");
    let loaded = mark () in
    ignore (restore_as ~base_path "same");
    let first = mark () in
    ignore (restore_as ~base_path "same");
    let second = mark () in
    check bool "the restore is not the loaded machine" true
      (loaded.Dos_lane.incarnation <> first.Dos_lane.incarnation);
    check bool "restoring the same slot again is another one" true
      (first.Dos_lane.incarnation <> second.Dos_lane.incarnation);
    check bool "the count rises" true
      (first.Dos_lane.count > loaded.Dos_lane.count
       && second.Dos_lane.count > first.Dos_lane.count))
;;

(* The ledger is the replay record, so a restore puts back the checkpoint's
   ledger -- the keys pressed after the save belong to a history that no
   longer exists -- and the next key continues it, in memory and on disk. *)
let test_the_ledger_continues_from_the_checkpoint () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~base_path "echo.com";
    ignore (press_as ~base_path "dos-test" "a");
    ignore (save_as ~base_path "after-a");
    ignore (press_as ~base_path "dos-test" "x");
    ignore (press_as ~base_path "dos-test" "y");
    ignore (restore_as ~base_path "after-a");
    check (list string) "the checkpoint's ledger" [ "a" ] (ledger_keys ());
    ignore (press_as ~base_path "dos-test" "b");
    check (list string) "continued" [ "a"; "b" ] (ledger_keys ());
    let lines =
      In_channel.with_open_bin (ledger_file ~base_path) In_channel.input_all
      |> String.split_on_char '\n'
      |> List.filter (fun l -> l <> "")
      |> List.map (fun l ->
        match Yojson.Safe.from_string l with
        | `Assoc fields ->
          (match List.assoc_opt "key" fields with Some (`String k) -> k | _ -> fail l)
        | _ -> fail l)
    in
    check (list string) "and the file says the same" [ "a"; "b" ] lines)
;;

(* A restore does not write the saves directory. A game may have saved after
   the checkpoint; putting the older machine back must not put its older
   save file over the newer one. The directory changes again only when the
   guest writes. *)
let test_a_restore_leaves_the_saves_directory () =
  with_workspace (fun base_path ->
    install_game ~base_path "quest" [ ("QUEST.COM", saver_com) ];
    ignore (load ~base_path "quest");
    let kept = Filename.concat (saves_of ~base_path "quest") "SAVE.DAT" in
    check string "the game saved" "NEW$" (In_channel.with_open_bin kept In_channel.input_all);
    ignore (save_as ~base_path "early");
    write_file kept "LATER$";
    let restored = restore_as ~base_path "early" in
    check bool "restored" true (is_completed restored);
    check string "the newer save is still there" "LATER$"
      (In_channel.with_open_bin kept In_channel.input_all);
    ignore (dispatch ~base_path "masc_dos_step" [ ("steps", `Int 10_000) ]);
    check string "and a run that writes nothing leaves it" "LATER$"
      (In_channel.with_open_bin kept In_channel.input_all))
;;

(* What the caller can get wrong is refused before anything changes: a name
   that is not a slot, a slot never saved, a file that is not a DOS
   checkpoint. With no slot the tool lists what there is. *)
let test_restore_refusals_and_listing () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~base_path "echo.com";
    ignore (save_as ~base_path "kept");
    let before = mark () in
    let unchanged name result =
      check bool (name ^ " is refused") false (is_completed result);
      check string (name ^ " changes nothing") before.Dos_lane.incarnation
        (mark ()).Dos_lane.incarnation
    in
    unchanged "a path" (restore_as ~base_path "../kept");
    unchanged "a slot never saved" (restore_as ~base_path "never");
    let dir =
      Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos")
        "checkpoints"
    in
    write_file (Filename.concat dir "junk.ckpt") "not a checkpoint";
    unchanged "a file that is not a checkpoint" (restore_as ~base_path "junk");
    check bool "a save to a path is refused" false
      (is_completed (save_as ~base_path "a/b"));
    let listing = dispatch ~base_path "masc_dos_restore" [] in
    check bool "no slot lists" true (is_completed listing);
    match member "checkpoints" (Tool_result.data listing) with
    | Some (`List rows) ->
      let slots = List.map (fun r -> match member "slot" r with Some (`String s) -> s | _ -> "") rows in
      (* [boot] above ran the guest, so it autosaved too: a third, earlier
         slot alongside the two this test saved itself. *)
      check (list string) "every slot" [ "autosave"; "junk"; "kept" ] slots;
      (match rows with
       | [ _autosave; junk; kept ] ->
         check bool "the broken one says why" true (member "unreadable" junk <> None);
         check bool "the good one names its core" true
           (member "core" kept = Some (`String Dos_core_identity.source_digest))
       | _ -> fail "three rows")
    | _ -> fail "no checkpoints list")
;;

(* ---------- autosave ---------- *)

let autosave_field result =
  match member "autosave" (Tool_result.data result) with
  | Some a -> a
  | None -> fail (Printf.sprintf "no autosave in %s" (Tool_result.message result))
;;

let autosave_saved result = member "saved" (autosave_field result) = Some (`Bool true)

let checkpoints_dir ~base_path =
  Filename.concat (Filename.concat (Common.masc_dir_from_base_path ~base_path) "dos") "checkpoints"
;;

let autosave_file ~base_path = Filename.concat (checkpoints_dir ~base_path) "autosave.ckpt"

let offered_steps result =
  match member "steps" (autosave_field result) with
  | Some (`Int n) -> n
  | _ -> fail (Printf.sprintf "the autosave names no step count in %s" (Tool_result.message result))
;;

let test_autosave_written_after_a_successful_step () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~base_path "echo.com";
    let stepped = dispatch ~base_path "masc_dos_step" [ ("steps", `Int 1_000) ] in
    check bool "the step succeeds" true (is_completed stepped);
    check bool "and reports the autosave as saved" true (autosave_saved stepped);
    let before_steps = int_field "steps" stepped in
    let restored = restore_as ~base_path "autosave" in
    check bool "the autosave slot restores" true (is_completed restored);
    check int "at the same step count" before_steps (int_field "steps" restored))
;;

(* Every tool that moves the guest ends in the one lane tail that autosaves,
   but a tool that stopped calling it would still pass every other test. Each
   case removes the file the boot wrote, so only this call can bring it back. *)
let test_every_tool_that_moves_the_guest_autosaves () =
  let saves name tool args =
    with_workspace (fun base_path ->
      install_program ~base_path "echo.com" echo_com;
      boot ~base_path "echo.com";
      Sys.remove (autosave_file ~base_path);
      let result = dispatch ~base_path tool args in
      check bool (name ^ " succeeds") true (is_completed result);
      check bool (name ^ " reports the autosave as saved") true (autosave_saved result);
      check bool (name ^ " left the file") true (Sys.file_exists (autosave_file ~base_path)))
  in
  saves "step" "masc_dos_step" [ ("steps", `Int 1_000) ];
  saves "press" "masc_dos_press" [ ("keys", `List [ `String "a" ]) ];
  saves "type" "masc_dos_type" [ ("text", `String "a") ];
  saves "click" "masc_dos_click" [ ("x", `Int 1); ("y", `Int 1); ("buttons", `Int 1) ]
;;

(* A call refused before anything ran leaves the previous autosave as it was.
   The boot's file is removed first, so a write by a refused call would show
   up as a file that should not be there, not as an unchanged one. *)
let test_a_refused_call_writes_no_autosave () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~agent:"liu-bei" ~base_path "echo.com";
    Sys.remove (autosave_file ~base_path);
    let writes_nothing name result =
      check bool (name ^ " is refused") false (is_completed result);
      check bool (name ^ " wrote nothing") false (Sys.file_exists (autosave_file ~base_path))
    in
    writes_nothing "another player's press"
      (dispatch ~base_path ~agent:"cao-cao" "masc_dos_press" [ ("keys", `List [ `String "a" ]) ]);
    writes_nothing "the holder's press with no keys"
      (dispatch ~base_path ~agent:"liu-bei" "masc_dos_press" [ ("keys", `List []) ]);
    eject ();
    writes_nothing "a step with no machine" (dispatch ~base_path "masc_dos_step" []))
;;

(* wait: mov ah,0 / int 16h / or ax,ax / jz wait / lea ax,ax: polls for a key
   the way [echo_com] does (INT 16h does not block), then faults. The machine a
   fault leaves faults again on its next step, so it must not replace the
   autosave a Keeper can still resume. *)
let test_a_fault_leaves_the_last_good_autosave () =
  with_workspace (fun base_path ->
    install_program ~base_path "key-then-fault.com" "\xb4\x00\xcd\x16\x09\xc0\x74\xf8\x8d\xc0";
    let booted = load ~base_path "key-then-fault.com" in
    check bool "the load settles on the key wait" true (is_completed booted);
    let steps_at_boot = int_field "steps" booted in
    let faulted =
      dispatch ~base_path "masc_dos_press" [ ("keys", `List [ `String "a" ]) ]
    in
    check bool "the press reaches the fault" false (is_completed faulted);
    check bool "and does not report an autosave of its own" true
      (member "autosave" (Tool_result.data faulted) = None);
    eject ();
    check int "the autosave on file is the one from before the fault" steps_at_boot
      (offered_steps (dispatch ~base_path "masc_dos_screen" [])))
;;

(* A program that has exited has nothing to resume. Its exit step would
   replace the last state a Keeper could pick up mid-game. *)
let test_an_exited_program_does_not_replace_the_autosave () =
  with_workspace (fun base_path ->
    install_program ~base_path "hello.com" hello_com;
    let booted = load ~base_path "hello.com" in
    let steps_at_boot = int_field "steps" booted in
    let pressed = dispatch ~base_path "masc_dos_press" [ ("keys", `List [ `String "a" ]) ] in
    check bool "the press succeeds" true (is_completed pressed);
    check bool "the program exited" true
      (member "exited" (Tool_result.data pressed) = Some (`Bool true));
    check bool "and the answer has no autosave field" true
      (member "autosave" (Tool_result.data pressed) = None);
    eject ();
    check int "the autosave on file is the one from before the exit" steps_at_boot
      (offered_steps (dispatch ~base_path "masc_dos_screen" [])))
;;

let test_no_autosave_offered_when_nothing_ever_ran () =
  with_workspace (fun base_path ->
    let result = dispatch ~base_path "masc_dos_screen" [] in
    check bool "no machine" false (is_completed result);
    check bool "and nothing to offer" true (member "autosave" (Tool_result.data result) = None))
;;

let test_a_failed_autosave_does_not_fail_the_call () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    let checkpoints_dir = checkpoints_dir ~base_path in
    mkdir_p (Filename.dirname checkpoints_dir);
    write_file checkpoints_dir "a file where the checkpoints directory would be";
    let loaded = load ~base_path "echo.com" in
    check bool "the load still succeeds" true (is_completed loaded);
    let autosave = autosave_field loaded in
    check bool "reports the write as failed" true (member "saved" autosave = Some (`Bool false));
    check bool "and says why" true (member "reason" autosave <> None))
;;

let test_no_machine_names_the_autosave_after_an_eject () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~agent:"liu-bei" ~base_path "echo.com";
    eject ();
    let names_it name result =
      check bool (name ^ " is refused: no machine") false (is_completed result);
      check bool (name ^ " points at the autosave") true
        (contains "autosave" (Tool_result.message result));
      let autosave = autosave_field result in
      check bool (name ^ " names the program") true
        (member "program" autosave = Some (`String "echo.com"));
      check bool (name ^ " names who saved it") true
        (member "saved_by" autosave = Some (`String "liu-bei"));
      check bool (name ^ " names how to resume") true
        (match member "resume" autosave with
         | Some (`String s) -> contains "masc_dos_restore" s && contains "autosave" s
         | _ -> false)
    in
    names_it "screen" (dispatch ~base_path "masc_dos_screen" []);
    names_it "peek" (dispatch ~base_path "masc_dos_peek" [ ("address", `String "0") ]))
;;

let test_inventory_names_the_autosave () =
  with_workspace (fun base_path ->
    install_program ~base_path "echo.com" echo_com;
    boot ~base_path "echo.com";
    eject ();
    let listing = dispatch ~base_path "masc_dos_load" [] in
    check bool "listing succeeds" true (is_completed listing);
    check bool "and names the program it holds" true
      (member "program" (autosave_field listing) = Some (`String "echo.com")))
;;

(* A file that is there but will not read is not "no autosave": the next call
   that runs the guest would replace it without anyone having been told. *)
let test_a_damaged_autosave_is_named_not_hidden () =
  with_workspace (fun base_path ->
    mkdir_p (checkpoints_dir ~base_path);
    write_file (autosave_file ~base_path) "not a checkpoint";
    let screen = dispatch ~base_path "masc_dos_screen" [] in
    check bool "still no machine" false (is_completed screen);
    check bool "the message says the file cannot be read" true
      (contains "cannot read" (Tool_result.message screen));
    check bool "and the data carries the reason" true
      (member "unreadable" (autosave_field screen) <> None);
    let listing = dispatch ~base_path "masc_dos_load" [] in
    check bool "the inventory names it too" true
      (member "unreadable" (autosave_field listing) <> None))
;;

let () =
  run "dos-lane-tools"
    [ ( "tools"
      , [ test_case "no machine" `Quick test_no_machine
        ; test_case "click no machine" `Quick test_click_without_a_machine_is_refused
        ; test_case "inventory" `Quick test_inventory_when_unnamed
        ; test_case "load" `Quick test_load_runs_to_the_first_key_request
        ; test_case "load and screen name the core" `Quick
            test_load_and_screen_name_the_core
        ; test_case "linked core is the pinned one" `Quick
            test_the_linked_core_is_the_pinned_one
        ; test_case "press" `Quick test_press_reaches_the_guest_and_the_ledger
        ; test_case "click reaches the guest" `Quick
            test_click_reaches_the_guest_and_the_ledger
        ; test_case "inventory only" `Quick test_only_inventory_names_resolve
        ; test_case "linked out" `Quick test_a_link_out_of_the_inventory_is_refused
        ; test_case "boot inside a directory" `Quick
            test_boot_names_the_program_inside_a_directory
        ; test_case "one ceiling" `Quick test_a_sequence_spends_one_ceiling_not_one_per_key
        ; test_case "sequence length" `Quick test_a_sequence_has_a_length
        ; test_case "case collision" `Quick test_two_names_that_differ_only_in_case_are_refused
        ; test_case "save outlives machine" `Quick test_a_save_outlives_its_machine
        ; test_case "save over inventory" `Quick
            test_a_save_is_mounted_over_the_inventory_copy
        ; test_case "save not written" `Quick test_a_save_that_cannot_be_written_is_reported
        ; test_case "guest path" `Quick test_a_guest_path_never_reaches_the_host
        ; test_case "holder only" `Quick test_only_the_holder_moves_the_machine
        ; test_case "pass" `Quick test_pass_hands_the_machine_on
        ; test_case "free controller" `Quick
            test_a_free_controller_goes_to_the_next_successful_mover
        ; test_case "pass to an impossible name" `Quick
            test_a_pass_to_an_impossible_name_is_refused
        ; test_case "stopped holder is let go" `Quick
            test_a_stopped_holders_controller_is_let_go
        ; test_case "unimplemented instruction" `Quick
            test_an_unimplemented_instruction_is_an_error
        ; test_case "a fault keeps the steps that ran" `Quick
            test_a_fault_keeps_the_steps_that_ran
        ; test_case "unknown key" `Quick test_unknown_key_is_refused
        ; test_case "step cap" `Quick test_step_cap
        ; test_case "peek" `Quick test_peek_reads_the_text_page
        ; test_case "read-only" `Quick test_read_only_classification
        ; test_case "declared" `Quick test_every_tool_is_declared
        ; test_case "checkpoint round trip" `Quick
            test_a_restored_machine_plays_on_as_if_never_stopped
        ; test_case "restore needs the controller" `Quick test_restore_needs_the_controller
        ; test_case "restore is a new incarnation" `Quick test_a_restore_is_a_new_incarnation
        ; test_case "ledger continues" `Quick test_the_ledger_continues_from_the_checkpoint
        ; test_case "restore leaves saves" `Quick test_a_restore_leaves_the_saves_directory
        ; test_case "restore refusals and listing" `Quick test_restore_refusals_and_listing
        ; test_case "autosave after a step" `Quick test_autosave_written_after_a_successful_step
        ; test_case "every tool that moves the guest autosaves" `Quick
            test_every_tool_that_moves_the_guest_autosaves
        ; test_case "autosave skips a refusal" `Quick test_a_refused_call_writes_no_autosave
        ; test_case "a fault keeps the last good autosave" `Quick
            test_a_fault_leaves_the_last_good_autosave
        ; test_case "an exited program keeps the last autosave" `Quick
            test_an_exited_program_does_not_replace_the_autosave
        ; test_case "no autosave to offer" `Quick test_no_autosave_offered_when_nothing_ever_ran
        ; test_case "a failed autosave still returns the call" `Quick
            test_a_failed_autosave_does_not_fail_the_call
        ; test_case "no machine names the autosave" `Quick
            test_no_machine_names_the_autosave_after_an_eject
        ; test_case "inventory names the autosave" `Quick test_inventory_names_the_autosave
        ; test_case "a damaged autosave is named" `Quick test_a_damaged_autosave_is_named_not_hidden
        ] )
    ]
;;
