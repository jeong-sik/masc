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

(* Argument and pre-effect lane failures are refusals. [Effect_unknown]
   remains a runtime failure with unknown effect disposition. Left
   undeclared, a failure reads as effect-outcome-unknown, and a composition
   that ran this tool ends the Keeper's turn over it instead of handing it
   back: "no MSX machine is loaded" after a server restart failed the whole
   request, when the Keeper only needed to restore and go on. *)
let refuse ~class_ ~tool_name ~start_time message =
  Tool_result.make_err ~tool_name ~class_ ~start_time
    ~effect_disposition:Tool_result.Proven_pre_effect message
;;

let reject ~tool_name ~start_time message =
  refuse ~class_:Tool_result.Workflow_rejection ~tool_name ~start_time message
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

(* The calls that move the machine's time declare it. The keeper's input-axis
   repeat guard drops the output fingerprint to catch a clock,
   and five [masc_msx_step {frames: 300}] in a row -- 25 seconds of play --
   have a clock's shape on that axis: identical input, a different result
   every time. Every game turn of one keeper ended in that yield on
   2026-09-14, its reply deferred each time. [Progress] beside the
   observation says the frames were run; a read ([masc_msx_screen]) declares
   nothing, so polling a screen five times still yields. *)
let moved_the_machine = Tool_outcome_declaration.to_metadata Tool_outcome_declaration.Progress

let of_lane ?(extra = []) ?sprites ?metadata ~tool_name ~start_time
    (result : (Msx_lane.observation, Msx_lane.error) result) =
  match result with
  | Ok o ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:(`Assoc (observation_fields ?sprites o @ extra))
      ?metadata
      ()
  | Error ((Msx_lane.Activity_disabled | Msx_lane.Activity_unobserved) as e) ->
    let code = match e with
      | Msx_lane.Activity_disabled -> "activity_disabled"
      | Msx_lane.Activity_unobserved | Msx_lane.No_machine | Msx_lane.Invalid_request _
      | Msx_lane.Effect_unknown _ | Msx_lane.Unreadable _
      | Msx_lane.Dependency_unavailable _ -> "activity_unobserved" in
    reject ~tool_name ~start_time (Msx_lane.error_to_string e)
    |> Tool_result.with_metadata (`Assoc ["io.github.jeong-sik/masc.machine.errorCode", `String code])
  | Error (Msx_lane.No_machine as e) ->
    (* A typed marker: a caller that treats an absent machine as an empty
       observation (the spectator tick) must not read the message text. *)
    reject ~tool_name ~start_time (Msx_lane.error_to_string e)
    |> Tool_result.with_metadata
         (`Assoc ["io.github.jeong-sik/masc.machine.errorCode", `String "no_machine"])
  | Error (Msx_lane.Invalid_request _ as e) ->
    reject ~tool_name ~start_time (Msx_lane.error_to_string e)
  | Error (Msx_lane.Effect_unknown message) ->
    Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
  | Error (Msx_lane.Unreadable _ as e) ->
    refuse ~class_:Tool_result.Runtime_failure ~tool_name ~start_time
      (Msx_lane.error_to_string e)
  | Error (Msx_lane.Dependency_unavailable _ as e) ->
    refuse ~class_:Tool_result.Dependency_unavailable ~tool_name ~start_time
      (Msx_lane.error_to_string e)
;;

(* The lane's files live under <.masc>/msx: the ledger, and the two
   inventories an operator fills by hand — bios/ with the C-BIOS triple and
   carts/ with game images. Names in [cart] resolve in carts/, so a Keeper
   never needs a host path. *)
let msx_dir ~base_path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "msx"
let carts_dir ~base_path = Filename.concat (msx_dir ~base_path) "carts"
let bios_dir ~base_path = Filename.concat (msx_dir ~base_path) "bios"

(* A named checkpoint slot is the file <slot>.json under saves/. *)
let saves_dir ~base_path = Filename.concat (msx_dir ~base_path) "saves"
let slot_file_suffix = ".json"
let slot_path ~base_path slot = Filename.concat (saves_dir ~base_path) (slot ^ slot_file_suffix)

(* The names of the regular files in carts/. A missing directory is an empty
   inventory (a fresh volume has none); a directory that exists and will not
   list is an error, so a caller never reads "unreadable" as "nothing there".
   An entry that cannot be inspected, such as a dangling symlink, is not a
   cartridge and is skipped. *)
let carts_available ~base_path =
  let dir = carts_dir ~base_path in
  let is_regular name =
    match Unix.stat (Filename.concat dir name) with
    | stats -> stats.Unix.st_kind = Unix.S_REG
    | exception Unix.Unix_error _ -> false
  in
  if not (Sys.file_exists dir) then Ok []
  else
    match Sys.readdir dir with
    | exception Sys_error message -> Error message
    | entries ->
      Ok
        (Array.to_list entries
         |> List.filter (fun name -> (not (String.starts_with ~prefix:"." name)) && is_regular name)
         |> List.sort String.compare)
;;

(* Where the C-BIOS directory came from, so the load and the report both
   read the decision instead of comparing a path against "". *)
type bios_source =
  | Argument of string (* the caller's roms_dir *)
  | Env of string (* MSX_ROMS through the config floor *)
  | Inventory of string (* .masc/msx/bios/ holding the main ROM *)
  | None_available (* no source names a BIOS; a load that needs one is refused *)

(* roms_dir argument, then MSX_ROMS, then the bios/ inventory when it holds
   the main ROM, else no source at all. *)
let resolve_roms_dir ~base_path args =
  match String.trim (get_string args "roms_dir" "") with
  | "" -> (
    (* Through the config floor, so a deployment can name the ROM directory in
       runtime.toml the way it names everything else. [Sys.getenv_opt] reads
       only what the parent process exported. *)
    match Env_config_core.raw_value_opt "MSX_ROMS" with
    | Some dir when dir <> "" -> Env dir
    | Some _ | None ->
      let dir = bios_dir ~base_path in
      if Sys.file_exists (Filename.concat dir "cbios_main_msx2.rom") then Inventory dir
      else None_available)
  | dir -> Argument dir
;;

(* The BIOS the source names, read whole: [Absent] only when no source names
   one. A source that names a directory missing a ROM is an error naming the
   file, never a downgrade to no BIOS. *)
let bios_of_source = function
  | Argument dir | Env dir | Inventory dir ->
    Result.map (fun triple -> Msx_lane.Present triple) (Msx_lane.read_bios ~dir)
  | None_available -> Ok Msx_lane.Absent
;;

(* A cart is a name in carts/, with or without .rom/.dsk. It is never a path:
   the worker's filesystem holds more than game media, and a name that cannot
   leave carts/ leaves no traversal to reason about. Only a regular file is a
   cartridge; a directory, or a link that points nowhere, is not. *)
let is_inventory_name name =
  name <> ""
  && (not (String.starts_with ~prefix:"." name))
  && not (String.exists (function '/' | '\000' -> true | _ -> false) name)
;;

let resolve_cart ~base_path name =
  let trimmed = String.trim name in
  if not (is_inventory_name trimmed) then
    Error
      (Printf.sprintf
         "cart %S is not an inventory name: pass a file name from masc_msx_meta \
          include_inventory=true, not a path"
         trimmed)
  else begin
    let dir = carts_dir ~base_path in
    let candidates =
      [ trimmed; trimmed ^ ".rom"; trimmed ^ ".ROM"; trimmed ^ ".dsk"; trimmed ^ ".DSK" ]
    in
    let is_file candidate =
      match Unix.stat (Filename.concat dir candidate) with
      | stats -> stats.Unix.st_kind = Unix.S_REG
      | exception Unix.Unix_error _ -> false
    in
    match List.find_opt is_file candidates with
    | Some c -> Ok (Filename.concat dir c)
    | None ->
      Error
        (match carts_available ~base_path with
         | Ok [] ->
           Printf.sprintf
             "unknown cartridge %S and the inventory %s is empty: an operator puts ROM or \
              .dsk images in the Add-on volume"
             trimmed dir
         | Ok names ->
           Printf.sprintf "unknown cartridge %S; available: %s" trimmed
             (String.concat ", " names)
         | Error message ->
           Printf.sprintf "unknown cartridge %S and the inventory %s cannot be listed: %s"
             trimmed dir message)
  end
;;

(* Case-insensitive .dsk — the extension picks the drive over the slot. *)
(* Case-insensitive .dsk — the extension picks the drive over the slot. *)
let is_dsk_path path =
  let lower = String.lowercase_ascii path in
  String.length lower >= 4
  && String.sub lower (String.length lower - 4) 4 = ".dsk"
;;

(* The board hears about a change of medium, not about a load: a keeper that
   reloads the disk already in the drive says nothing, and every post is a
   board_signal to the whole fleet. The decision reads only the transition
   the lane captured under its lock, so two loads that serialised there
   announce the medium once between them. A bare machine announces
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

let handle_load ?(after_load = fun () -> ()) ~relay ~tool_name
    ~start_time ~base_path ~agent_name args =
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
       (* The machine is already replaced. Publish its Lane activity before the
          Board call, which may yield or be cancelled by the HTTP caller. *)
       after_load ();
       Option.iter (relay ~author:agent_name)
         (arcade_announcement ~agent_name transition)
     | Error _ -> ());
    Result.map (fun (l : Msx_lane.loaded) -> l.Msx_lane.observation) loaded
  in
  (* The lane names the ROMs it lacks; this adds where an operator puts them. *)
  let explain_missing_bios = function
    | Error (Msx_lane.Dependency_unavailable message) ->
      Error (Msx_lane.Dependency_unavailable
        (Printf.sprintf "%s. Pass roms_dir, set MSX_ROMS, or put them in %s" message
           (bios_dir ~base_path)))
    | Ok _ | Error ( Msx_lane.Activity_disabled | Msx_lane.Activity_unobserved
                   | Msx_lane.No_machine | Msx_lane.Invalid_request _
                   | Msx_lane.Effect_unknown _ | Msx_lane.Unreadable _ ) as other -> other
  in
  let boot image =
    match resolve_roms_dir ~base_path args |> bios_of_source with
    | Error e -> of_lane ~tool_name ~start_time (Error e)
    | Ok bios ->
      of_lane ~tool_name ~start_time
        (relayed
           (explain_missing_bios
              (Msx_lane.load ~ledger_dir:(msx_dir ~base_path) ~bios ~image)))
  in
  match media with
  | Some (Error message) -> reject ~tool_name ~start_time message
  | Some (Ok path) when is_dsk_path path -> boot (Msx_lane.Disk_file path)
  | Some (Ok path) -> boot (Msx_lane.Cartridge_file path)
  | None ->
    (* A load replaces the running machine and truncates its input ledger, so
       it never runs without something to load. The inventory is read through
       masc_msx_meta, which changes nothing. *)
    reject ~tool_name ~start_time
      "cart is required: loading replaces the running machine. List the inventory with \
       masc_msx_meta include_inventory=true and pass one of those names."
;;

let handle_eject ~relay ~tool_name ~start_time ~agent_name _args =
  match Msx_lane.eject () with
  | Ok () ->
    relay ~author:agent_name
      (Printf.sprintf "%s 님이 게임을 꺼냈습니다" agent_name);
    Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [ ("ejected", `Bool true) ]) ()
  | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e)
;;

(* RAM introspection handlers. Read-only, so no board relay and no agent
   identity: anyone may look, nobody may write (RFC-0439's cheat line).
   Addresses arrive as hex strings ("e000", "0xE000") because that is how
   memory is talked about; digits alone are hex too ({!Msx_lane.Address}).
   They leave in the same notation, four hex digits, so an address read from
   a result goes back into peek unchanged. *)
let handle_peek ~tool_name ~start_time args =
  match Msx_lane.Address.parse (get_string args "address" "") with
  | Error message -> reject ~tool_name ~start_time message
  | Ok address ->
    (match Msx_lane.peek ~address ~length:(get_int args "length" 16) with
     | Ok hex ->
       Tool_result.make_ok ~tool_name ~start_time
         ~data:
           (`Assoc
             [ ("address", `String (Msx_lane.Address.to_hex address)); ("hex", `String hex) ])
         ()
     | Error e -> reject ~tool_name ~start_time (Msx_lane.error_to_string e))
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
                     [ ("address", `String (Msx_lane.Address.to_hex c.address))
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

(* Frames a step runs when the caller names none: one second of machine time. *)
let default_step_frames = Msx_lane.frames_per_second

let handle_step ~tool_name ~start_time args =
  of_lane ~tool_name ~start_time ~metadata:moved_the_machine
    (Msx_lane.step ~frames:(get_int args "frames" default_step_frames))
;;

(* 화면이 안착할 때까지 한 번에 논다 — 키퍼가 step+screen 을 반복하며
   장면 전환을 기다리는 턴을 대신한다. changed=false + stable=true 는
   "이 장면은 키를 기다린다"의 후보 신호다. *)
let handle_step_until_change ~tool_name ~start_time args =
  match
    Msx_lane.step_until_change ~max_frames:(get_int args "max_frames" 300)
  with
  | Ok (observation, r) ->
    (* Frames always run here, so the declaration follows the screen: a run
       that changed it moved the game; one that settled on the same picture
       is the key-wait signal, and a keeper asking five times in a row on a
       key-wait scene declares nothing and is still caught. *)
    of_lane ~tool_name ~start_time
      ?metadata:(if r.Msx_lane.changed then Some moved_the_machine else None)
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
    of_lane ~tool_name ~start_time ~metadata:moved_the_machine
      (Msx_lane.press ~who ~keys
         ~hold_frames:(get_int args "hold_frames" 5)
         ~step_frames:(get_int args "frames" 30)
         ~sequence:(get_bool args "sequence" false))
;;

(* Checkpoints use names within saves/, never caller-provided host paths. *)
let checkpoint_slot args =
  Result.map Machine_checkpoint.slot_to_string
    (Machine_checkpoint.slot_of_arguments ~default:Msx_tool.default_checkpoint_slot args)
;;

let run_checkpoint ~restore ~base_path ~slot =
  let ledger_dir = msx_dir ~base_path in
  let path = slot_path ~base_path slot in
  if restore then Msx_lane.restore ~path ~ledger_dir else Msx_lane.save ~path

(* What a checkpoint call asks for. A save without a slot writes the scratch
   slot, which only ever replaces an earlier scratch save. A restore without
   one must not pick a slot for the caller, because it replaces the machine
   every watcher shows; it lists the slots it could name and restores nothing.
   The arguments are read once here, so the handler cannot list and restore
   from two different readings of them. *)
type checkpoint_call =
  | List_slots
  | Slot of string

let checkpoint_call ~restore = function
  | `Assoc [] when restore -> Ok List_slots
  | (`Assoc _ | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as args ->
    Result.map (fun slot -> Slot slot) (checkpoint_slot args)

(* The slots a restore can name: the regular files under saves/ whose name is
   a valid slot. Reads nothing from the files and touches no machine; a
   slot's contents are masc_msx_checkpoint_info's. A missing directory is an
   empty list (a fresh volume has none); a directory that exists and will not
   list is an error, so "unreadable" is never read as "nothing saved". *)
let saved_slots ~base_path =
  let dir = saves_dir ~base_path in
  let is_regular name =
    match Unix.stat (Filename.concat dir name) with
    | stats -> stats.Unix.st_kind = Unix.S_REG
    | exception Unix.Unix_error _ -> false
  in
  if not (Sys.file_exists dir) then Ok []
  else
    match Sys.readdir dir with
    | exception Sys_error message -> Error message
    | names ->
      Ok
        (Array.to_list names
         |> List.filter_map (fun name ->
              if Filename.check_suffix name slot_file_suffix && is_regular name then
                Result.to_option
                  (Result.map Machine_checkpoint.slot_to_string
                     (Machine_checkpoint.slot_of_string
                        (Filename.chop_suffix name slot_file_suffix)))
              else None)
         |> List.sort String.compare)

let handle_checkpoint_list ~tool_name ~start_time ~base_path =
  match saved_slots ~base_path with
  | Error message ->
    refuse ~class_:Tool_result.Runtime_failure ~tool_name ~start_time
      ("the saved checkpoints cannot be listed: " ^ message)
  | Ok slots ->
    Tool_result.make_ok ~tool_name ~start_time
      ~data:
        (`Assoc
          [ ( "checkpoints"
            , `List (List.map (fun slot -> `Assoc [ ("slot", `String slot) ]) slots) )
          ])
      ()

(* The completion travels with the observation: the checkpoint's server-side
   receipt settles from these fields, and only the worker that ran the
   checkpoint knows its change mark. *)
let handle_checkpoint ~restore ~tool_name ~start_time ~base_path args =
  match checkpoint_call ~restore args with
  | Error message -> reject ~tool_name ~start_time message
  | Ok List_slots -> handle_checkpoint_list ~tool_name ~start_time ~base_path
  | Ok (Slot slot) ->
    match run_checkpoint ~restore ~base_path ~slot with
    | Ok (completed : Msx_lane.checkpoint_effect) ->
      Tool_result.make_ok ~tool_name ~start_time
        ~data:(`Assoc (observation_fields completed.observation
               @ [ "slot", `String slot
                 ; "change_count", `Int completed.mark.Msx_lane.count
                 ; "incarnation", `String completed.mark.Msx_lane.incarnation
                 ; "checkpoint_sha256", `String completed.checkpoint_sha256 ]))
        ()
    | Error e ->
      of_lane ~tool_name ~start_time ~extra:["slot", `String slot] (Error e)
;;

(* masc_msx_meta — which core this server linked, as [Msx_lane.core] reports
   it. Read-only: reads one module constant, moves nothing. *)
let handle_meta ?inventory_base_path ~tool_name ~start_time () =
  let inventory = match inventory_base_path with
    | None -> Ok []
    | Some base_path ->
        Result.map (fun carts ->
          let loaded, cartridge, disk = match Msx_lane.frame () with
            | None -> false, `Null, `Null
            | Some frame -> true,
                (match frame.Msx_lane.cartridge with None -> `Null | Some name -> `String name),
                (match frame.disk with None -> `Null | Some name -> `String name) in
          ["inventory", `Assoc [
            "carts", `List (List.map (fun name -> `String name) carts);
            "loaded", `Bool loaded; "cartridge", cartridge; "disk", disk]])
          (carts_available ~base_path) in
  match inventory with
  | Error message ->
      refuse ~class_:Tool_result.Runtime_failure ~tool_name ~start_time
        ("cartridge inventory cannot be listed: " ^ message)
  | Ok inventory ->
      Tool_result.make_ok ~tool_name ~start_time
        ~data:(`Assoc (["core", Msx_lane.core_to_yojson Msx_lane.core] @ inventory))
        ()
;;

(* masc_msx_checkpoint_info — what a saved slot holds, without restoring it.
   A restore replaces the machine every watcher shows, so asking about a slot
   must not be a restore in disguise. *)
let handle_checkpoint_info ~tool_name ~start_time ~base_path args =
  match checkpoint_slot args with
  | Error message -> reject ~tool_name ~start_time message
  | Ok slot ->
    let path = slot_path ~base_path slot in
    match Msx_lane.checkpoint_info ~path with
    | Ok info ->
      Tool_result.make_ok ~tool_name ~start_time
        ~data:
          (`Assoc
            ([ ("slot", `String slot)
             ; ("exists", `Bool info.exists)
             ; ("version", `Int info.version)
             ; ( "saved_at_unix"
               , match info.saved_at_unix with Some t -> `Float t | None -> `Null )
             ; ( "mtime_utc"
               , match info.mtime_utc with Some t -> `String t | None -> `Null )
             ; ("core_sha", match info.core_sha with Some s -> `String s | None -> `Null)
             ; ( "core_matches_current"
               , match info.core_sha with
                 | Some sha -> `Bool (String.equal sha Msx_lane.core.source_digest)
                 | None -> `Null )
             ; ( "cartridge"
               , match info.cartridge with Some c -> `String c | None -> `Null )
             ; ("disk", match info.disk with Some d -> `String d | None -> `Null)
             ; ("ledger_entries", `Int info.ledger_entries)
             ; ("byte_length", `Int info.byte_length)
             ; ("sha256", `String info.sha256)
             ]))
        ()
    | Error ((Msx_lane.Invalid_request _ | Msx_lane.No_machine | Msx_lane.Activity_disabled | Msx_lane.Activity_unobserved
             | Msx_lane.Dependency_unavailable _) as e) ->
      reject ~tool_name ~start_time (Msx_lane.error_to_string e)
    | Error (Msx_lane.Effect_unknown message) ->
      Tool_result.make_err ~tool_name ~class_:Tool_result.Runtime_failure ~start_time message
    | Error (Msx_lane.Unreadable _ as e) ->
      refuse ~class_:Tool_result.Runtime_failure ~tool_name ~start_time
        (Msx_lane.error_to_string e)
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
      let backup_path = slot_path ~base_path backup_slot in
      of_lane ~tool_name ~start_time ~extra:["backup_slot", `String backup_slot]
        (Msx_lane.change_disk ~path ~backup_path))
;;

let handle_export_disk ~tool_name ~start_time ~base_path args =
  match args with
  | `Assoc ["filename", `String filename] ->
    let catalog =
      try Ok (carts_dir ~base_path:(Unix.realpath base_path))
      with Unix.Unix_error (error, fn, arg) ->
        Error (Msx_lane.Unreadable
          (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message error))) in
    let result = Result.bind catalog (fun catalog_dir ->
      Msx_lane.export_disk ~catalog_dir ~filename) in
    (match result with
     | Ok (receipt : Msx_lane.disk_export) ->
       Tool_result.make_ok ~tool_name ~start_time ~data:(`Assoc [
         "filename", `String receipt.filename;
         "byte_length", `Int receipt.byte_length;
         "sha256", `String receipt.sha256;
         "source_disk", (match receipt.source_disk with None -> `Null | Some name -> `String name);
         "frame", `Int receipt.frame]) ()
     | Error error -> of_lane ~tool_name ~start_time (Error error))
  | _ -> reject ~tool_name ~start_time "filename must name one new catalog .dsk image"
;;

(* The worker parses a call's tool name once with [Msx_tool.of_name]. *)
let dispatch ~relay ~base_path ~agent ~(tool : Msx_tool.t) ~arguments =
  let module T = Msx_tool in
  let tool_name = T.name tool and start_time = Tool_timing.start () in
  match tool with
  | T.Load -> handle_load ~relay ~tool_name ~start_time ~base_path ~agent_name:agent arguments
  | T.Eject -> handle_eject ~relay ~tool_name ~start_time ~agent_name:agent arguments
  | T.Save -> handle_checkpoint ~restore:false ~tool_name ~start_time ~base_path arguments
  | T.Restore -> handle_checkpoint ~restore:true ~tool_name ~start_time ~base_path arguments
  | T.Export_disk -> handle_export_disk ~tool_name ~start_time ~base_path arguments
  | T.Change_disk -> handle_change_disk ~tool_name ~start_time ~base_path arguments
  | T.Meta -> handle_meta ~tool_name ~start_time
      ?inventory_base_path:(if get_bool arguments "include_inventory" false then Some base_path else None) ()
  | T.Checkpoint_info -> handle_checkpoint_info ~tool_name ~start_time ~base_path arguments
  | T.Press -> handle_press ~tool_name ~start_time ~who:agent arguments
  | T.Step -> handle_step ~tool_name ~start_time arguments
  | T.Step_until_change -> handle_step_until_change ~tool_name ~start_time arguments
  | T.Peek -> handle_peek ~tool_name ~start_time arguments
  | T.Ram_diff -> handle_ram_diff ~tool_name ~start_time ()
  | T.Screen -> handle_screen ~tool_name ~start_time arguments
