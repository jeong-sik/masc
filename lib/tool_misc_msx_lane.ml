(** MSX lane tools (RFC-0439 §3.5; increment §6.1, turn-based only).

    [masc_msx_load] plugs a cartridge into the workspace machine,
    [masc_msx_screen] reads it, [masc_msx_press] and [masc_msx_step] move
    its time, [masc_msx_eject] ends it. The machine is {!Msx_lane}'s: one per
    workspace, in this process, shared by every caller. The observation is
    text first — mode, name table, sprite table — because a keeper without a
    vision runtime cannot read pixels (RFC-0414). *)

open Tool_args

let reject ~tool_name ~start_time message =
  Tool_result.make_err ~tool_name ~class_:Tool_result.Workflow_rejection ~start_time message
;;

let of_lane ~tool_name ~start_time (result : (Msx_lane.observation, Msx_lane.error) result) =
  match result with
  | Ok o ->
    let sprite (s : Msx_lane.sprite) : Yojson.Safe.t =
      `Assoc
        [ ("index", `Int s.index)
        ; ("x", `Int s.x)
        ; ("y", `Int s.y)
        ; ("pattern", `Int s.pattern)
        ; ("color", `Int s.color)
        ]
    in
    Tool_result.make_ok ~tool_name ~start_time
      ~data:
        (`Assoc
           [ ("frame", `Int o.frame)
           ; ("mode", `String o.mode)
           ; ("pc", `String (Printf.sprintf "%04x" o.pc))
           ; ("halted", `Bool o.halted)
           ; ( "cartridge"
             , match o.cartridge with Some c -> `String c | None -> `Null )
           ; ("screen_text", `String o.screen_text)
           ; ("tiles", `List (List.map (fun row -> `String row) o.tiles))
           ; ("sprites", `List (List.map sprite o.sprites))
           ])
      ()
  | Error ((Msx_lane.No_machine | Msx_lane.Invalid_request _) as e) ->
    reject ~tool_name ~start_time (Msx_lane.error_to_string e)
  | Error (Msx_lane.Unreadable _ as e) ->
    Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time
      (Msx_lane.error_to_string e)
;;

let ledger_dir ~base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "msx"
;;

let handle_load ~tool_name ~start_time ~base_path args =
  let roms_dir =
    match String.trim (get_string args "roms_dir" "") with
    | "" -> Option.value ~default:"" (Sys.getenv_opt "MSX_ROMS")
    | dir -> dir
  in
  let cart_path =
    match get_string_opt args "cart" with
    | Some p when String.trim p <> "" -> Some (String.trim p)
    | Some _ | None -> None
  in
  of_lane ~tool_name ~start_time
    (Msx_lane.load ~ledger_dir:(ledger_dir ~base_path) ~roms_dir ~cart_path)
;;

let handle_eject ~tool_name ~start_time _args =
  match Msx_lane.eject () with
  | Ok () ->
    Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [ ("ejected", `Bool true) ]) ()
  | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e)
;;

let handle_screen ~tool_name ~start_time _args =
  of_lane ~tool_name ~start_time (Msx_lane.screen ())
;;

let handle_step ~tool_name ~start_time args =
  of_lane ~tool_name ~start_time (Msx_lane.step ~frames:(get_int args "frames" 60))
;;

let handle_press ~tool_name ~start_time ~who args =
  let names = get_string_list args "keys" in
  let rec parse acc = function
    | [] -> Ok (List.rev acc)
    | n :: rest -> (
      match Msx_lane.key_of_string n with
      | Ok k -> parse (k :: acc) rest
      | Error message -> Error message)
  in
  match parse [] names with
  | Error message -> reject ~tool_name ~start_time message
  | Ok keys ->
    of_lane ~tool_name ~start_time
      (Msx_lane.press ~who ~keys
         ~hold_frames:(get_int args "hold_frames" 5)
         ~step_frames:(get_int args "frames" 30))
;;
