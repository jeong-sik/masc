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

let () =
  run "msx tools"
    [ ( "lane"
      , [ test_case "no machine" `Quick test_no_machine
        ; test_case "load, step, screen, eject" `Quick test_load_and_clock
        ; test_case "press writes the ledger" `Quick test_press_ledger
        ; test_case "press validation" `Quick test_press_validation
        ; test_case "key vocabulary" `Quick test_key_vocabulary
        ; test_case "registration" `Quick test_registration
        ; test_case "xspelunker: two presses reach the level card" `Quick
            test_xspelunker_two_presses
        ] )
    ]
;;
