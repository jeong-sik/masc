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

let observation_fields (o : Msx_lane.observation) =
  let sprite (s : Msx_lane.sprite) : Yojson.Safe.t =
    `Assoc
      [ ("index", `Int s.index)
      ; ("x", `Int s.x)
      ; ("y", `Int s.y)
      ; ("pattern", `Int s.pattern)
      ; ("color", `Int s.color)
      ]
  in
  [ ("frame", `Int o.frame)
  ; ("mode", `String o.mode)
  ; ("pc", `String (Printf.sprintf "%04x" o.pc))
  ; ("halted", `Bool o.halted)
  ; ("cartridge", match o.cartridge with Some c -> `String c | None -> `Null)
  ; ("screen_text", `String o.screen_text)
  ; ("tiles", `List (List.map (fun row -> `String row) o.tiles))
  ; ("sprites", `List (List.map sprite o.sprites))
  ]
;;

let of_lane ?(extra = []) ~tool_name ~start_time
    (result : (Msx_lane.observation, Msx_lane.error) result) =
  match result with
  | Ok o ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc (observation_fields o @ extra))
      ()
  | Error ((Msx_lane.No_machine | Msx_lane.Invalid_request _) as e) ->
    reject ~tool_name ~start_time (Msx_lane.error_to_string e)
  | Error (Msx_lane.Unreadable _ as e) ->
    Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time
      (Msx_lane.error_to_string e)
;;

(* The lane's files live under <.masc>/msx: the ledger, and the two
   inventories an operator fills by hand — bios/ with the C-BIOS triple and
   carts/ with game images. Names in [cart] resolve in carts/, so a Keeper
   never needs a host path. *)
let msx_dir ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "msx"
let carts_dir ~base_path = Filename.concat (msx_dir ~base_path) "carts"
let bios_dir ~base_path = Filename.concat (msx_dir ~base_path) "bios"

let carts_available ~base_path =
  let dir = carts_dir ~base_path in
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f ->
         (not (String.starts_with ~prefix:"." f))
         && not (Sys.is_directory (Filename.concat dir f)))
    |> List.sort String.compare
  else []
;;

(* roms_dir argument, then MSX_ROMS, then the bios/ inventory when it holds
   the main ROM, else no BIOS at all. *)
let resolve_roms_dir ~base_path args =
  match String.trim (get_string args "roms_dir" "") with
  | "" -> (
    match Sys.getenv_opt "MSX_ROMS" with
    | Some dir when dir <> "" -> dir
    | Some _ | None ->
      let dir = bios_dir ~base_path in
      if Sys.file_exists (Filename.concat dir "cbios_main_msx2.rom") then dir else "")
  | dir -> dir
;;

(* A cart is a path that exists, or a name (with or without .rom) in carts/. *)
let resolve_cart ~base_path name =
  let trimmed = String.trim name in
  if Sys.file_exists trimmed && not (Sys.is_directory trimmed) then Ok trimmed
  else begin
    let dir = carts_dir ~base_path in
    let candidates = [ trimmed; trimmed ^ ".rom"; trimmed ^ ".ROM" ] in
    match
      List.find_opt
        (fun c -> Sys.file_exists (Filename.concat dir c))
        candidates
    with
    | Some c -> Ok (Filename.concat dir c)
    | None ->
      Error
        (match carts_available ~base_path with
         | [] ->
           Printf.sprintf
             "unknown cartridge %S and the inventory %s is empty: put ROM images there or pass a path"
             trimmed dir
         | names ->
           Printf.sprintf "unknown cartridge %S; available: %s" trimmed
             (String.concat ", " names))
  end
;;

let handle_load ~tool_name ~start_time ~base_path args =
  let roms_dir = resolve_roms_dir ~base_path args in
  let cart =
    match get_string_opt args "cart" with
    | Some n when String.trim n <> "" -> Some (resolve_cart ~base_path n)
    | Some _ | None -> None
  in
  match cart with
  | Some (Error message) -> reject ~tool_name ~start_time message
  | Some (Ok path) ->
    of_lane ~tool_name ~start_time
      (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~roms_dir ~cart_path:(Some path))
  | None ->
    (* BIOS only, and the inventory so the next call can name a game. *)
    of_lane ~tool_name ~start_time
      ~extra:
        [ ( "carts_available"
          , `List (List.map (fun n -> `String n) (carts_available ~base_path)) )
        ; ("bios", `Bool (roms_dir <> ""))
        ]
      (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~roms_dir ~cart_path:None)
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
