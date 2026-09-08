(* MSX lane tools (RFC-0439 §6.1) — the five tools through Tool_misc.dispatch.

   The machine boots without ROMs (bus reads 0xFF) so the tests need no game
   image. What they pin: the no-machine refusal, the frame clock, the ledger
   edges with the caller's name, the key vocabulary, the per-call frame cap,
   the read-only classification, and that the descriptors and schemas exist. *)

open Alcotest
open Masc

let dispatch ~base_path ?(agent = "msx-test") name assoc =
  let ctx : Tool_misc.context =
    { config = Workspace.default_config base_path; agent_name = agent; help_schemas = [] }
  in
  match Tool_misc.dispatch ctx ~name ~args:(`Assoc assoc) with
  | Some result -> result
  | None -> fail (name ^ " is not dispatched by the misc tool owner")
;;

let with_workspace f =
  let base_path = Filename.temp_dir "masc-msx-tools-" "" in
  Fun.protect
    ~finally:(fun () ->
      ignore (Msx_lane.eject () : (unit, Msx_lane.error) result);
      Fs_compat.remove_tree base_path)
    (fun () -> f base_path)
;;

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let frame_of result =
  match member "frame" (Tool_result.data result) with
  | Some (`Int n) -> n
  | _ -> fail ("no frame in " ^ Tool_result.message result)
;;

let is_completed result = Tool_result.failure_class result = None

let rejected result =
  Tool_result.failure_class result = Some Tool_result.Workflow_rejection
;;

let test_no_machine () =
  with_workspace @@ fun base_path ->
  ignore (Msx_lane.eject () : (unit, Msx_lane.error) result);
  let r = dispatch ~base_path "masc_msx_screen" [] in
  check bool "screen before load is a workflow rejection" true (rejected r);
  let r = dispatch ~base_path "masc_msx_press" [ ("keys", `List [ `String "space" ]) ] in
  check bool "press before load is a workflow rejection" true (rejected r)
;;

let test_load_and_clock () =
  with_workspace @@ fun base_path ->
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] in
  check bool "load completes without ROMs" true (is_completed r);
  check int "load runs the boot ahead" Msx_lane.boot_frames (frame_of r);
  check bool "mode is named"
    true
    (match member "mode" (Tool_result.data r) with Some (`String _) -> true | _ -> false);
  let r = dispatch ~base_path "masc_msx_step" [ ("frames", `Int 10) ] in
  check int "step moves the clock" (Msx_lane.boot_frames + 10) (frame_of r);
  let r = dispatch ~base_path "masc_msx_screen" [] in
  check int "screen does not move the clock" (Msx_lane.boot_frames + 10) (frame_of r);
  let r = dispatch ~base_path "masc_msx_step" [ ("frames", `Int 301) ] in
  check bool "a step over the cap is refused" true (rejected r);
  let r = dispatch ~base_path "masc_msx_step" [ ("frames", `Int 0) ] in
  check bool "a zero step is refused" true (rejected r);
  let r = dispatch ~base_path "masc_msx_eject" [] in
  check bool "eject completes" true (is_completed r);
  let r = dispatch ~base_path "masc_msx_screen" [] in
  check bool "screen after eject is a workflow rejection" true (rejected r)
;;

let test_press_ledger () =
  with_workspace @@ fun base_path ->
  ignore (dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] : Tool_result.result);
  let r =
    dispatch ~base_path ~agent:"keeper-a" "masc_msx_press"
      [ ("keys", `List [ `String "space"; `String "right" ])
      ; ("hold_frames", `Int 2)
      ; ("frames", `Int 4)
      ]
  in
  check bool "press completes" true (is_completed r);
  check int "press advances the whole frames count" (Msx_lane.boot_frames + 4) (frame_of r);
  let entries = Msx_lane.ledger () in
  check int "two keys make four edges" 4 (List.length entries);
  let down = List.filter (fun (e : Msx_lane.entry) -> e.down) entries in
  let up = List.filter (fun (e : Msx_lane.entry) -> not e.down) entries in
  check (list int) "downs at the press frame"
    [ Msx_lane.boot_frames; Msx_lane.boot_frames ]
    (List.map (fun (e : Msx_lane.entry) -> e.at_frame) down);
  check (list int) "ups after the hold"
    [ Msx_lane.boot_frames + 2; Msx_lane.boot_frames + 2 ]
    (List.map (fun (e : Msx_lane.entry) -> e.at_frame) up);
  check (list string) "the caller's name is on every edge"
    [ "keeper-a"; "keeper-a"; "keeper-a"; "keeper-a" ]
    (List.map (fun (e : Msx_lane.entry) -> e.who) entries);
  check (list string) "canonical key spelling"
    [ "space"; "right" ]
    (List.map (fun (e : Msx_lane.entry) -> e.key_name) down);
  (* The ledger file mirrors the entries, one JSON object a line. *)
  let path = Filename.concat (Filename.concat (Filename.concat base_path ".masc") "msx") "ledger.jsonl" in
  let lines = In_channel.with_open_bin path In_channel.input_all |> String.split_on_char '\n' |> List.filter (( <> ) "") in
  check int "ledger file has one line per edge" 4 (List.length lines);
  (match Yojson.Safe.from_string (List.hd lines) with
   | `Assoc fields ->
     check (option string) "first line is a down edge" (Some "down")
       (match List.assoc_opt "edge" fields with Some (`String s) -> Some s | _ -> None)
   | _ -> fail "ledger line is not an object");
  (* A new load starts a new ledger. *)
  ignore (dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] : Tool_result.result);
  check int "reload empties the ledger" 0 (List.length (Msx_lane.ledger ()))
;;

let test_press_validation () =
  with_workspace @@ fun base_path ->
  ignore (dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] : Tool_result.result);
  let before = frame_of (dispatch ~base_path "masc_msx_screen" []) in
  let r = dispatch ~base_path "masc_msx_press" [ ("keys", `List [ `String "banana" ]) ] in
  check bool "an unknown key name is refused" true (rejected r);
  let r = dispatch ~base_path "masc_msx_press" [ ("keys", `List [ `String "f9" ]) ] in
  check bool "f9 has no matrix place and is refused" true (rejected r);
  let r = dispatch ~base_path "masc_msx_press" [ ("keys", `List []) ] in
  check bool "no keys is refused" true (rejected r);
  let r =
    dispatch ~base_path "masc_msx_press"
      [ ("keys", `List [ `String "space" ]); ("hold_frames", `Int 10); ("frames", `Int 5) ]
  in
  check bool "hold longer than frames is refused" true (rejected r);
  check int "refusals do not move the clock" before
    (frame_of (dispatch ~base_path "masc_msx_screen" []));
  check int "refusals write no ledger edge" 0 (List.length (Msx_lane.ledger ()));
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "/nonexistent/roms") ] in
  check (option string) "a missing BIOS directory is a runtime failure"
    (Some Tool_result.Runtime_failure |> Option.map Tool_result.tool_failure_class_to_string)
    (Option.map Tool_result.tool_failure_class_to_string (Tool_result.failure_class r))
;;

let test_inventory () =
  with_workspace @@ fun base_path ->
  let carts = Filename.concat (Filename.concat (Filename.concat base_path ".masc") "msx") "carts" in
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] in
  check bool "load without cart completes" true (is_completed r);
  check (option (list string)) "empty inventory is an empty list" (Some [])
    (match member "carts_available" (Tool_result.data r) with
     | Some (`List l) -> Some (List.filter_map (function `String s -> Some s | _ -> None) l)
     | _ -> None);
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "hero") ] in
  check bool "an unknown name is refused" true (rejected r);
  (* Two images in the inventory: a 16KB one named with .rom, a 32KB one without. *)
  List.iter (fun d -> if not (Sys.file_exists d) then Sys.mkdir d 0o755)
    [ Filename.concat base_path ".masc"; Filename.dirname carts; carts ];
  Out_channel.with_open_bin (Filename.concat carts "hero.rom") (fun oc ->
    output_string oc (String.make 0x4000 '\000'));
  Out_channel.with_open_bin (Filename.concat carts "big") (fun oc ->
    output_string oc (String.make 0x8000 '\000'));
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] in
  check (option (list string)) "inventory lists both, sorted" (Some [ "big"; "hero.rom" ])
    (match member "carts_available" (Tool_result.data r) with
     | Some (`List l) -> Some (List.filter_map (function `String s -> Some s | _ -> None) l)
     | _ -> None);
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "hero") ] in
  check bool "a name without .rom resolves" true (is_completed r);
  check (option string) "the cartridge is named by its file" (Some "hero.rom")
    (match member "cartridge" (Tool_result.data r) with Some (`String s) -> Some s | _ -> None);
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "big") ] in
  check bool "an exact inventory name resolves" true (is_completed r);
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "nope") ] in
  check bool "an unknown name is still refused" true (rejected r);
  check bool "the refusal names the inventory" true
    (let m = Tool_result.message r in
     let has needle = let ln = String.length needle and lm = String.length m in
       let rec go i = i + ln <= lm && (String.sub m i ln = needle || go (i + 1)) in go 0 in
     has "hero.rom" && has "big")
;;

(* A .dsk image resolves in the same inventory and lands in the drive: the
   observation names it under "disk" with no cartridge (the interface ROM the
   core rides in the slot takes it), and a ROM-less load still completes —
   the image is synthetic, no BIOS is around to boot it. *)
let test_disk_load () =
  with_workspace @@ fun base_path ->
  let carts = Filename.concat (Filename.concat (Filename.concat base_path ".masc") "msx") "carts" in
  List.iter (fun d -> if not (Sys.file_exists d) then Sys.mkdir d 0o755)
    [ Filename.concat base_path ".masc"; Filename.dirname carts; carts ];
  Out_channel.with_open_bin (Filename.concat carts "war.dsk") (fun oc ->
    output_string oc (String.make (720 * 1024) '\xf9'));
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "war") ] in
  check bool "a name ending in .dsk resolves and loads" true (is_completed r);
  check (option string) "the disk is named under disk" (Some "war.dsk")
    (match member "disk" (Tool_result.data r) with Some (`String s) -> Some s | _ -> None);
  check (option string) "no cartridge is claimed while a disk runs" None
    (match member "cartridge" (Tool_result.data r) with Some (`String s) -> Some s | _ -> None);
  let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String ""); ("cart", `String "war.dsk") ] in
  check bool "the full file name resolves too" true (is_completed r)
;;

let test_rejected_disk_preserves_machine () =
  with_workspace @@ fun base_path ->
  let loaded = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] in
  check bool "initial machine load completes" true (is_completed loaded);
  let pressed = dispatch ~base_path "masc_msx_press"
    [ ("keys", `List [ `String "space" ]); ("hold_frames", `Int 2); ("frames", `Int 4) ]
  in
  check bool "initial input completes" true (is_completed pressed);
  let before = dispatch ~base_path "masc_msx_screen" [] |> frame_of in
  let ledger_dir = Filename.concat (Filename.concat base_path ".masc") "msx" in
  let ledger_path = Filename.concat ledger_dir "ledger.jsonl" in
  let ledger_before = In_channel.with_open_bin ledger_path In_channel.input_all in
  check bool "input ledger contains prior progress" true (ledger_before <> "");
  let check_preserved () =
    check int "rejected disk preserves current frame" before
      (dispatch ~base_path "masc_msx_screen" [] |> frame_of);
    check string "rejected disk does not truncate input ledger" ledger_before
      (In_channel.with_open_bin ledger_path In_channel.input_all)
  in
  List.iter (fun size ->
    let disk_path = Filename.concat base_path (Printf.sprintf "short-%d.dsk" size) in
    Out_channel.with_open_bin disk_path (fun oc -> output_string oc (String.make size '\000'));
    (match Msx_lane.load ~ledger_dir ~roms_dir:"" ~cart_path:None ~disk_path:(Some disk_path) with
     | Error (Msx_lane.Invalid_request _) -> ()
     | Error e -> fail (Msx_lane.error_to_string e)
     | Ok _ -> fail "unreadable boot sector must reject load");
    check_preserved ()
  ) [0; 511];
  let failed_load = dispatch ~base_path "masc_msx_load"
    [ ("roms_dir", `String ""); ("cart", `String (Filename.concat base_path "short-0.dsk")) ]
  in
  check bool "public load reports disk boot rejection" true (rejected failed_load);
  check_preserved ()
;;

(* With a BIOS and a real .dsk on this host, the boot chain runs: the load
   itself carries the warm-up replay (disk_boot_frames + boot_frames), then
   the machine keeps stepping and the clock advances frame by frame. CI has no
   ROM images (they are not in the repository), so without MSX_ROMS and
   MSX_DISK this case records that it did not run instead of pretending to. *)
let test_disk_boot_smoke () =
  match Sys.getenv_opt "MSX_ROMS", Sys.getenv_opt "MSX_DISK" with
  | Some roms, Some disk when roms <> "" && disk <> "" ->
    with_workspace @@ fun base_path ->
    let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String roms); ("cart", `String disk) ] in
    check bool "load with a BIOS and a disk completes" true (is_completed r);
    check int "the load clock carries the warm-up replay"
      (Msx_lane.disk_boot_frames + Msx_lane.boot_frames) (frame_of r);
    let r = dispatch ~base_path "masc_msx_step" [ ("frames", `Int 300) ] in
    check bool "the machine steps past the boot" true (is_completed r);
    check int "the clock is replay plus boot plus the step"
      (Msx_lane.disk_boot_frames + Msx_lane.boot_frames + 300) (frame_of r);
    (* HALT is a normal VSync wait mid-boot, not a fault — the smoke's claim
       is that the chain keeps observing a named mode. *)
    check bool "a display mode is named" true
      (match member "mode" (Tool_result.data r) with Some (`String m) -> String.length m > 0 | _ -> false)
  | _ -> Printf.printf "not run: MSX_ROMS and MSX_DISK are unset on this host\n%!"
;;

let test_key_vocabulary () =
  let named =
    [ "up"; "down"; "left"; "right"; "space"; "esc"; "return"; "trigger_a"; "trigger_b"; "f1"; "f5"; "a"; "M"; "7" ]
  in
  List.iter
    (fun n ->
      check bool ("key " ^ n ^ " parses") true (Result.is_ok (Msx_lane.key_of_string n)))
    named;
  List.iter
    (fun n ->
      check bool ("key " ^ n ^ " is refused") true (Result.is_error (Msx_lane.key_of_string n)))
    [ ""; "f6"; "shift"; "banana"; "ab" ];
  List.iter
    (fun n ->
      match Msx_lane.key_of_string n with
      | Ok k -> check string ("round trip " ^ n) n (Msx_lane.key_to_string k)
      | Error m -> fail m)
    [ "up"; "down"; "left"; "right"; "space"; "esc"; "return"; "trigger_a"; "trigger_b"; "f3"; "m" ]
;;

let test_registration () =
  List.iter
    (fun (operation, name, readonly) ->
      (match Tool_schemas_misc.misc_registered_schema operation with
       | Some (schema : Masc_domain.tool_schema) -> check string "schema name" name schema.name
       | None -> fail (name ^ " has no registered schema"));
      match Keeper_tool_descriptor.descriptors_for_internal name with
      | [ d ] ->
        check string (name ^ " runtime handler") "tool_masc_misc_dispatch"
          (Keeper_tool_descriptor.runtime_handler_to_string d.runtime_handler);
        check bool (name ^ " descriptor readonly") readonly
          (d.policy.readonly_hint = Some true)
      | [] -> fail ("missing descriptor for " ^ name)
      | _ -> fail ("duplicate descriptor for " ^ name))
    [ (Tool_schemas_misc.Misc_msx_load, "masc_msx_load", false)
    ; (Tool_schemas_misc.Misc_msx_eject, "masc_msx_eject", false)
    ; (Tool_schemas_misc.Misc_msx_screen, "masc_msx_screen", true)
    ; (Tool_schemas_misc.Misc_msx_press, "masc_msx_press", false)
    ; (Tool_schemas_misc.Misc_msx_step, "masc_msx_step", false)
    ]
;;

(* RFC-0439 §5.3, through the tool path: with a BIOS and XSpelunker on this
   host, two Space presses take the game from "BRAIN GAMES PRESENTS" to the
   LEVEL 1-1 card, and each press changes what the name table shows. CI has
   no ROM images (they are not in the repository), so without MSX_ROMS and
   MSX_CART this case records that it did not run instead of pretending to. *)
let test_xspelunker_two_presses () =
  match Sys.getenv_opt "MSX_ROMS", Sys.getenv_opt "MSX_CART" with
  | Some roms, Some cart when roms <> "" && cart <> "" ->
    with_workspace @@ fun base_path ->
    let r = dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String roms); ("cart", `String cart) ] in
    check bool "load with ROMs completes" true (is_completed r);
    let nonzero_tiles result =
      match member "tiles" (Tool_result.data result) with
      | Some (`List rows) ->
        List.fold_left
          (fun acc row ->
            match row with
            | `String s ->
              let n = ref 0 in
              String.iteri (fun i c -> if i mod 2 = 0 && c <> '.' then incr n) s;
              acc + !n
            | _ -> acc)
          0 rows
      | _ -> 0
    in
    (* Boot logo, fade, cartridge init: the first screen waits at ~330. *)
    let r = dispatch ~base_path "masc_msx_step" [ ("frames", `Int 300) ] in
    let presents = nonzero_tiles r in
    let r =
      dispatch ~base_path ~agent:"keeper-a" "masc_msx_press"
        [ ("keys", `List [ `String "space" ]); ("hold_frames", `Int 5); ("frames", `Int 90) ]
    in
    let title = nonzero_tiles r in
    check bool "the title screen shows more tiles than the presents card" true (title > presents);
    let r =
      dispatch ~base_path ~agent:"keeper-a" "masc_msx_press"
        [ ("keys", `List [ `String "space" ]); ("hold_frames", `Int 5); ("frames", `Int 200) ]
    in
    let level = nonzero_tiles r in
    check bool "the level card differs from the title" true (level <> title);
    check string "still GRAPHIC2" "GRAPHIC2"
      (match member "mode" (Tool_result.data r) with Some (`String m) -> m | _ -> "");
    check int "four edges in the ledger" 4 (List.length (Msx_lane.ledger ()))
  | _ ->
    Printf.printf "not run: MSX_ROMS and MSX_CART are unset on this host\n%!"
;;

(* RFC-0439 §3.1: the workspace has one shared [Msx.t], so two keepers drive it
   together. Each press advances the same clock and appends to the same ledger
   under its own caller name — that is the workspace's co-play. keeper-b picks
   up the frame keeper-a left, a third caller reads that same clock, and the
   ledger names both in the order their edges happened. No ROM is needed; the
   point is the one machine and the two names, not any game. *)
let test_two_keepers_share_one_machine () =
  with_workspace @@ fun base_path ->
  ignore (dispatch ~base_path "masc_msx_load" [ ("roms_dir", `String "") ] : Tool_result.result);
  let press who key =
    dispatch ~base_path ~agent:who "masc_msx_press"
      [ ("keys", `List [ `String key ]); ("hold_frames", `Int 2); ("frames", `Int 4) ]
  in
  let r_a = press "keeper-a" "right" in
  check bool "keeper-a's press completes" true (is_completed r_a);
  check int "keeper-a advances the shared clock" (Msx_lane.boot_frames + 4) (frame_of r_a);
  let r_b = press "keeper-b" "left" in
  check bool "keeper-b's press completes" true (is_completed r_b);
  check int "keeper-b advances the same clock further" (Msx_lane.boot_frames + 8) (frame_of r_b);
  let r_screen = dispatch ~base_path ~agent:"keeper-c" "masc_msx_screen" [] in
  check int "a third caller reads the shared clock, not its own"
    (Msx_lane.boot_frames + 8) (frame_of r_screen);
  let entries = Msx_lane.ledger () in
  check int "both presses land in one ledger" 4 (List.length entries);
  check (list string) "the ledger names both keepers"
    [ "keeper-a"; "keeper-b" ]
    (List.sort_uniq compare (List.map (fun (e : Msx_lane.entry) -> e.who) entries));
  let downs = List.filter (fun (e : Msx_lane.entry) -> e.down) entries in
  check (list string) "keeper-a's edge precedes keeper-b's on the shared timeline"
    [ "keeper-a"; "keeper-b" ]
    (List.map (fun (e : Msx_lane.entry) -> e.who) downs)
;;

let () =
  run "msx tools"
    [ ( "lane"
      , [ test_case "no machine" `Quick test_no_machine
        ; test_case "load, step, screen, eject" `Quick test_load_and_clock
        ; test_case "press writes the ledger" `Quick test_press_ledger
        ; test_case "press validation" `Quick test_press_validation
        ; test_case "cartridge inventory" `Quick test_inventory
        ; test_case "disk image loads into the drive" `Quick test_disk_load
        ; test_case "failed disk boot preserves machine and ledger" `Quick test_rejected_disk_preserves_machine
        ; test_case "disk boot smoke (host ROMs)" `Quick test_disk_boot_smoke
        ; test_case "key vocabulary" `Quick test_key_vocabulary
        ; test_case "registration" `Quick test_registration
        ; test_case "xspelunker: two presses reach the level card" `Quick
            test_xspelunker_two_presses
        ; test_case "two keepers share one machine" `Quick
            test_two_keepers_share_one_machine
        ] )
    ]
;;
