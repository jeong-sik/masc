(** MSX lane tools (RFC-0439 §3.5; increment §6.1, turn-based only).

    [masc_msx_load] plugs a game into the workspace machine — a cartridge ROM
    or a raw .dsk floppy image (same [cart] argument; a name ending in .dsk
    goes to the drive, anything else to the slot) — [masc_msx_screen] reads
    the machine, [masc_msx_press] and [masc_msx_step] move its time,
    [masc_msx_eject] ends it. The machine is {!Msx_lane}'s: one per
    workspace, in this process, shared by every caller. The observation is
    text first — mode, name table, sprite table — because a keeper without a
    vision runtime cannot read pixels (RFC-0414). *)

open Tool_args

let reject ~tool_name ~start_time message =
  Tool_result.make_err ~tool_name ~class_:Tool_result.Workflow_rejection ~start_time message
;;

(* Sprites ride an observation only when asked for: keepers play by the
   screen, and the attribute table (32 slots, ~60 bytes each) was dead weight
   in every bitmap-mode observation — 2 calls of peek against 204 screens in
   a day (2026-09-09 system log) showed nobody reads RAM state through it
   either. [~sprites] opts one call in. *)
let observation_fields ?(sprites = false) (o : Msx_lane.observation) =
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
  ; ("disk", match o.disk with Some d -> `String d | None -> `Null)
  ; ("screen_text", `String o.screen_text)
  ; ("screen_view", `String o.screen_view)
  ; ("tiles", `List (List.map (fun row -> `String row) o.tiles))
  ]
  @ (if sprites then [ ("sprites", `List (List.map sprite o.sprites)) ] else [])
;;

let of_lane ?(extra = []) ?sprites ~tool_name ~start_time
    (result : (Msx_lane.observation, Msx_lane.error) result) =
  match result with
  | Ok o ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc (observation_fields ?sprites o @ extra))
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
    (* Through the config floor, so a deployment can name the ROM directory in
       runtime.toml the way it names everything else. [Sys.getenv_opt] reads
       only what the parent process exported. *)
    match Env_config_core.raw_value_opt "MSX_ROMS" with
    | Some dir when dir <> "" -> dir
    | Some _ | None ->
      let dir = bios_dir ~base_path in
      if Sys.file_exists (Filename.concat dir "cbios_main_msx2.rom") then dir else "")
  | dir -> dir
;;

(* A cart is a path that exists, or a name (with or without .rom/.dsk) in
   carts/. A .dsk image resolves the same way and loads into the drive — the
   inventory holds game media, whatever the medium is. *)
let resolve_cart ~base_path name =
  let trimmed = String.trim name in
  if Sys.file_exists trimmed && not (Sys.is_directory trimmed) then Ok trimmed
  else begin
    let dir = carts_dir ~base_path in
    let candidates =
      [ trimmed; trimmed ^ ".rom"; trimmed ^ ".ROM"; trimmed ^ ".dsk"; trimmed ^ ".DSK" ]
    in
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
             "unknown cartridge %S and the inventory %s is empty: put ROM or .dsk images \
              there or pass a path"
             trimmed dir
         | names ->
           Printf.sprintf "unknown cartridge %S; available: %s" trimmed
             (String.concat ", " names))
  end
;;

(* Case-insensitive .dsk — the extension picks the drive over the slot. *)
(* Case-insensitive .dsk — the extension picks the drive over the slot. *)
let is_dsk_path path =
  let lower = String.lowercase_ascii path in
  String.length lower >= 4
  && String.sub lower (String.length lower - 4) 4 = ".dsk"
;;

(* --- 아케이드 중계 --------------------------------------------------------
   누가 무슨 게임을 올리고 꺼내는지를 보드에 남긴다. ledger 에는 모든 엣지가
   기록되지만 아무도 안 읽는다 — 보드가 방송의 채널 목록이다 (RFC-0439 의
   관전 화면과 짝). 보드를 초기화하지 않은 프로세스(테스트, CI)에서는
   포스트가 거부되는데, 그 거부가 게임 로드를 막아서는 안 된다: 진단만
   찍고 간다. *)
let relay_to_board ~author content =
  try
    let result =
      Board_tool_dispatch.handle_tool "masc_board_post"
        (`Assoc
          [ ("title", `String "MSX 아케이드")
          ; ("content", `String content)
          ; ("author", `String author)
          ; ("post_kind", `String "automation")
          ])
    in
    if not (Tool_result.is_success result) then
      Log.MsxLog.warn
        "arcade relay: board post refused, the load itself is unaffected: %s"
        (Tool_result.message result)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | e ->
    Log.MsxLog.warn
      "arcade relay: board post raised, the load itself is unaffected: %s"
      (Printexc.to_string e)
;;

(* The board hears about a change of medium, not about a load: a keeper that
   reloads the disk already in the drive says nothing, and every post is a
   board_signal to the whole fleet. The decision reads only the transition
   the lane captured under its lock, so two loads that serialised there
   announce the medium once between them. A BIOS-only boot announces
   nothing. *)
let arcade_announcement ~agent_name
    ({ Msx_lane.before; after } : Msx_lane.transition) =
  if before = after then None
  else
    match after with
    | None -> None
    | Some medium ->
      let name, kind =
        match medium with
        | Msx_lane.Disk name -> (name, "디스크")
        | Msx_lane.Cartridge name -> (name, "카트리지")
      in
      Some
        (Printf.sprintf
           "%s 님이 %s (%s) 를 아케이드에 올렸습니다 — MSX 화면에서 관전하세요"
           agent_name name kind)
;;

let handle_load ~tool_name ~start_time ~base_path ~agent_name args =
  let roms_dir = resolve_roms_dir ~base_path args in
  let media =
    match get_string_opt args "cart" with
    | Some n when String.trim n <> "" -> Some (resolve_cart ~base_path n)
    | Some _ | None -> None
  in
  (* A rejected boot keeps the previous machine and carries no transition,
     so it has nothing to announce. *)
  let relayed (loaded : (Msx_lane.loaded, Msx_lane.error) result) =
    (match loaded with
     | Ok { Msx_lane.transition; _ } ->
       Option.iter (relay_to_board ~author:agent_name)
         (arcade_announcement ~agent_name transition)
     | Error _ -> ());
    Result.map (fun (l : Msx_lane.loaded) -> l.Msx_lane.observation) loaded
  in
  match media with
  | Some (Error message) -> reject ~tool_name ~start_time message
  | Some (Ok path) when is_dsk_path path ->
    of_lane ~tool_name ~start_time
      (relayed
         (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~roms_dir
            ~cart_path:None ~disk_path:(Some path)))
  | Some (Ok path) ->
    of_lane ~tool_name ~start_time
      (relayed
         (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~roms_dir
            ~cart_path:(Some path) ~disk_path:None))
  | None ->
    (* BIOS only, and the inventory so the next call can name a game. *)
    of_lane ~tool_name ~start_time
      ~extra:
        [ ( "carts_available"
          , `List (List.map (fun n -> `String n) (carts_available ~base_path)) )
        ; ("bios", `Bool (roms_dir <> ""))
        ]
      (relayed
         (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~roms_dir
            ~cart_path:None ~disk_path:None))
;;

let handle_eject ~tool_name ~start_time ~agent_name _args =
  match Msx_lane.eject () with
  | Ok () ->
    relay_to_board ~author:agent_name
      (Printf.sprintf "%s 님이 게임을 꺼냈습니다" agent_name);
    Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [ ("ejected", `Bool true) ]) ()
  | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e)
;;

(* RAM introspection handlers. Read-only, so no board relay and no agent
   identity: anyone may look, nobody may write (RFC-0439's cheat line).
   Addresses arrive as hex strings ("e000", "0xE000") because that is how
   memory is talked about; decimal parses too. *)
let parse_address s =
  let s = String.lowercase_ascii (String.trim s) in
  let s =
    if String.starts_with ~prefix:"0x" s then String.sub s 2 (String.length s - 2) else s
  in
  int_of_string_opt ("0x" ^ s)
;;

let handle_peek ~tool_name ~start_time args =
  let address =
    match parse_address (get_string args "address" "") with
    | Some a -> a
    | None -> -1
  in
  match Msx_lane.peek ~address ~length:(get_int args "length" 16) with
  | Ok hex ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc [ ("address", `Int address); ("hex", `String hex) ]) ()
  | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e)
;;

let handle_ram_diff ~tool_name ~start_time () =
  match Msx_lane.ram_diff () with
  | Ok (d : Msx_lane.ram_diff) ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc
        [ ( "changes"
          , `List
              (List.map
                 (fun (c : Msx_lane.ram_change) ->
                   `Assoc
                     [ ("address", `Int c.address)
                     ; ("length", `Int c.length)
                     ; ("from", `String c.from_hex)
                     ; ("to", `String c.to_hex)
                     ])
                 d.changes) )
        ; ("truncated", `Bool d.truncated)
        ; ("changed_bytes", `Int d.changed_bytes)
        ]) ()
  | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e)
;;

let handle_screen ~tool_name ~start_time args =
  of_lane ~tool_name ~start_time
    ~sprites:(get_bool args "sprites" false)
    (Msx_lane.screen ())
;;

let handle_step ~tool_name ~start_time args =
  of_lane ~tool_name ~start_time (Msx_lane.step ~frames:(get_int args "frames" 60))
;;

(* 화면이 안착할 때까지 한 번에 논다 — 키퍼가 step+screen 을 반복하며
   장면 전환을 기다리는 턴을 대신한다. changed=false + stable=true 는
   "이 장면은 키를 기다린다"의 후보 신호다. *)
let handle_step_until_change ~tool_name ~start_time args =
  match
    Msx_lane.step_until_change ~max_frames:(get_int args "max_frames" 300)
  with
  | Ok (observation, r) ->
    of_lane ~tool_name ~start_time
      ~extra:
        [ ("frames_run", `Int r.Msx_lane.frames_run)
        ; ("changed", `Bool r.changed)
        ; ("stable", `Bool r.stable)
        ]
      (Ok observation)
  | Error e -> of_lane ~tool_name ~start_time (Error e)
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
         ~step_frames:(get_int args "frames" 30)
         ~sequence:(get_bool args "sequence" false))
;;

(* Checkpoints use names within saves/, never caller-provided host paths. *)
let checkpoint_slot args =
  let slot = match args with
    | `Assoc fields when List.for_all (fun (name, _) -> name = "slot") fields -> (
      match List.filter (fun (name, _) -> name = "slot") fields with
      | [] -> Ok "quick"
      | [(_, `String value)] -> Ok value
      | _ -> Error "slot must be one string")
    | _ -> Error "checkpoint arguments must be an object" in
  match slot with
  | Error _ as e -> e
  | Ok slot ->
    if String.length slot < 1 || String.length slot > 64
       || not (String.for_all (function
          | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '-' -> true | _ -> false) slot)
    then Error "slot must be 1..64 letters, digits, underscores or hyphens"
    else Ok slot
;;

let handle_checkpoint ~restore ~tool_name ~start_time ~base_path args =
  match checkpoint_slot args with
  | Error message -> reject ~tool_name ~start_time message
  | Ok slot ->
    let ledger_dir = msx_dir ~base_path in
    let path = Filename.concat (Filename.concat ledger_dir "saves") (slot ^ ".json") in
    let result = if restore then Msx_lane.restore ~path ~ledger_dir else Msx_lane.save ~path in
    of_lane ~tool_name ~start_time ~extra:["slot", `String slot] result
;;

let handle_change_disk ~tool_name ~start_time ~base_path args =
  let request = match args with
    | `Assoc ["disk", `String disk] when disk <> "" -> Ok disk
    | _ -> Error "disk must name one .dsk image" in
  match request with
  | Error message -> reject ~tool_name ~start_time message
  | Ok disk -> (
    match resolve_cart ~base_path disk with
    | Error message -> reject ~tool_name ~start_time message
    | Ok path when not (is_dsk_path path) -> reject ~tool_name ~start_time "disk must be a .dsk image"
    | Ok path ->
      let backup_slot = "before-disk-change" in
      let backup_path = Filename.concat (Filename.concat (msx_dir ~base_path) "saves") (backup_slot ^ ".json") in
      of_lane ~tool_name ~start_time ~extra:["backup_slot", `String backup_slot]
        (Msx_lane.change_disk ~path ~backup_path))
;;
