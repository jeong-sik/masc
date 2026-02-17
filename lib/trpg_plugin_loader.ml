(** TRPG Plugin Loader

    Dynamic slot loading and lifecycle management for TRPG engine.
    Manages slot activation, configuration, and event broadcasting.

    @since 2.68.0
*)

open Yojson.Safe.Util

(** {1 Plugin Configuration Types} *)

type plugin_config = {
  mutable enabled_slots : string list;               (* Active slot IDs *)
  slot_configs : (string * Yojson.Safe.t) list;  (* Per-slot config *)
}

let empty_plugin_config : plugin_config = {
  enabled_slots = [];
  slot_configs = [];
}

(** {1 Active Slot State} *)

type active_slot = {
  slot_id : string;
  slot_module : (module Trpg_slot.TRPG_SLOT);
  mutable state : Yojson.Safe.t;
  slot_config : Yojson.Safe.t;  (* Reserved for future use *)
}
[@@@ocaml.warning "-69"]  (* Allow intentionally unused slot_config field *)

(** {1 Loader State} *)

type loader_state = {
  mutable slots : active_slot list;
  mutable config : plugin_config;
  mutex : Eio.Mutex.t;
}

let initial_state : loader_state = {
  slots = [];
  config = empty_plugin_config;
  mutex = Eio.Mutex.create ();
}

(** Global loader state *)
let global_state = initial_state

(** {1 JSON Serialization} *)

let plugin_config_to_yojson { enabled_slots; slot_configs } =
  `Assoc [
    ("enabled_slots", `List (List.map (fun id -> `String id) enabled_slots));
    ("slot_configs", `Assoc (List.map (fun (id, cfg) ->
      (id, cfg)
    ) slot_configs));
  ]

let plugin_config_of_yojson json =
  let enabled_slots =
    match json |> member "enabled_slots" with
    | `List ids -> List.map (function
        | `String id -> id
        | _ -> ""
      ) ids
    | _ -> []
  in
  let slot_configs =
    match json |> member "slot_configs" with
    | `Assoc configs -> configs
    | _ -> []
  in
  Ok { enabled_slots; slot_configs }

(** {1 Config File Loading} *)

let default_config_path = "config/trpg/plugins.json"

let load_config_file ?(path = default_config_path) () =
  try
    let content = Fs_compat.load_file path in
    let json = Yojson.Safe.from_string content in
    match plugin_config_of_yojson json with
    | Ok config -> Ok config
    | Error e -> Error ("Failed to parse plugin config: " ^ e)
  with
  | Sys_error msg -> Error ("Cannot load config file: " ^ msg)

(** {1 Slot Lookup} *)

let find_slot slot_id =
  Trpg_slot.Registry.find ~slot_id

let load_slot_module slot_id =
  match find_slot slot_id with
  | Some module_ -> Ok module_
  | None -> Error (Printf.sprintf "Slot not registered: %s" slot_id)

(** {1 Slot Initialization} *)

let init_slot (module Slot : Trpg_slot.TRPG_SLOT) config =
  try
    let state = Slot.init_state ~config in
    Ok { slot_id = Slot.slot_info.slot_id; slot_module = (module Slot); state; slot_config = config }
  with
  | exn -> Error (Printf.sprintf "Failed to init slot %s: %s"
      Slot.slot_info.slot_id (Printexc.to_string exn))

(** {1 Core Loader Operations} *)

let load ?(config = empty_plugin_config) () =
  Eio.Mutex.use_rw global_state.mutex ~protect:true @@ fun () ->
    let errors = ref [] in
    let loaded_slots = ref [] in

    (* Initialize each enabled slot *)
    List.iter (fun slot_id ->
      let slot_config =
        try List.assoc slot_id config.slot_configs
        with Not_found -> `Assoc []
      in
      match load_slot_module slot_id with
      | Ok (module Slot) ->
          (match init_slot (module Slot) slot_config with
          | Ok slot -> loaded_slots := slot :: !loaded_slots
          | Error e -> errors := e :: !errors)
      | Error e -> errors := e :: !errors
    ) config.enabled_slots;

    global_state.slots <- List.rev !loaded_slots;
    global_state.config <- config;

    if !errors = [] then Ok ()
    else Error (String.concat "\n" (List.rev !errors))

let reload () : (unit, string) result =
  match load_config_file () with
  | Ok config -> load ~config ()
  | Error msg -> Error msg

(** {1 Event Broadcasting} *)

let get_slot slot_id =
  List.find_opt (fun s -> s.slot_id = slot_id) global_state.slots

let apply_event_to_slot active_slot event =
  let (module Slot) = active_slot.slot_module in
  let _slot_config = active_slot.slot_config in
  try
    let new_state = Slot.apply_event ~state:active_slot.state ~event in
    active_slot.state <- new_state;
    Ok new_state
  with
  | exn -> Error (Printf.sprintf "Slot %s event failed: %s"
      active_slot.slot_id (Printexc.to_string exn))

let broadcast_event ~event =
  Eio.Mutex.use_rw global_state.mutex ~protect:true @@ fun () ->
  let results = ref [] in
  List.iter (fun slot ->
    match apply_event_to_slot slot event with
    | Ok new_state -> results := (slot.slot_id, new_state) :: !results
    | Error e ->
        (* Log error but continue processing other slots *)
        Format.eprintf "Plugin loader: %s@." e;
        results := (slot.slot_id, `Null) :: !results
  ) global_state.slots;
  List.rev !results

(** {1 State Queries} *)

let get_states () =
  Eio.Mutex.use_ro global_state.mutex @@ fun () ->
  List.map (fun slot ->
    let (module Slot) = slot.slot_module in
    let derived = Slot.derive_state ~state:slot.state in
    (slot.slot_id, derived)
  ) global_state.slots

let get_slot_state ~slot_id =
  Eio.Mutex.use_ro global_state.mutex @@ fun () ->
  match get_slot slot_id with
  | Some slot ->
      let (module Slot) = slot.slot_module in
      Ok (Slot.derive_state ~state:slot.state)
  | None -> Error (Printf.sprintf "Slot not active: %s" slot_id)

(** {1 Slot Management} *)

let list_active_slots () =
  Eio.Mutex.use_ro global_state.mutex @@ fun () ->
  List.map (fun slot ->
    let (module Slot) = slot.slot_module in
    Slot.slot_info
  ) global_state.slots

let list_available_slots () =
  Trpg_slot.Registry.list_all ()

let enable_slot ~slot_id ?config () =
  Eio.Mutex.use_rw global_state.mutex ~protect:true @@ fun () ->
  (* Check if already active *)
  if List.exists (fun s -> s.slot_id = slot_id) global_state.slots then
    Error (Printf.sprintf "Slot already active: %s" slot_id)
  else
    match load_slot_module slot_id with
    | Ok (module Slot) ->
        let cfg = match config with
          | Some c -> c
          | None -> `Assoc []
        in
        (match init_slot (module Slot) cfg with
        | Ok active_slot ->
            global_state.slots <- active_slot :: global_state.slots;
            global_state.config.enabled_slots <-
              slot_id :: global_state.config.enabled_slots;
            Ok ()
        | Error e -> Error e)
    | Error e -> Error e

let disable_slot ~slot_id =
  Eio.Mutex.use_rw global_state.mutex ~protect:true @@ fun () ->
  let rec remove = function
    | [] -> []
    | s :: rest when s.slot_id = slot_id ->
        global_state.config.enabled_slots <-
          List.filter ((<>) slot_id) global_state.config.enabled_slots;
        rest
    | s :: rest -> s :: remove rest
  in
  global_state.slots <- remove global_state.slots;
  Ok ()

(** {1 Configuration Persistence} *)

let save_config ?(path = default_config_path) () =
  Eio.Mutex.use_ro global_state.mutex @@ fun () ->
  let json = plugin_config_to_yojson global_state.config in
  let content = Yojson.Safe.to_string json in
  try
    Fs_compat.save_file path content;
    Ok ()
  with
  | Sys_error msg -> Error (Printf.sprintf "Failed to save config: %s" msg)

(** {1 Validation} *)

let validate_config ~config =
  let errors = ref [] in
  List.iter (fun slot_id ->
    match find_slot slot_id with
    | None -> errors := Printf.sprintf "Unknown slot: %s" slot_id :: !errors
    | Some _ -> ()
  ) config.enabled_slots;
  if !errors = [] then Ok ()
  else Error (String.concat ", " (List.rev !errors))

let () =
  (* Auto-load from default config path on startup *)
  match load_config_file () with
  | Ok config ->
      (match load ~config () with
      | Ok () -> ()
      | Error e ->
          Format.eprintf "Plugin loader auto-load failed: %s@." e;
          Format.eprintf "Starting with no active slots.@.")
  | Error e ->
      Format.eprintf "Plugin loader: %s@." e;
      Format.eprintf "Starting with no active slots.@."
