module Core = Keeper_agent_core_execution_inventory_core
module Identity = Keeper_agent_core_execution_identity
module Store = Keeper_agent_core_execution_store

type inventory = Core.t

type read_error =
  | Filesystem_unavailable
  | Journal_root_not_directory
  | Journal_root_unreadable

type payload_observation =
  | Payload_missing
  | Payload_valid of string
  | Payload_invalid

let locator_leaf = "recovery-locator.json"
let terminal_leaf = "terminal-disposition.json"
let max_record_length = Int64.of_int (1024 * 1024)

let read_record ~parent ~leaf =
  try
    match Eio.Path.kind ~follow:false Eio.Path.(parent / leaf) with
    | `Not_found -> Payload_missing
    | `Regular_file ->
      let stat = Eio.Path.stat ~follow:false Eio.Path.(parent / leaf) in
      let expected_length = Optint.Int63.to_int64 stat.size in
      (match
         Fs_compat.Capability_exact_read.read
           ~parent
           ~leaf
           ~expected_length
           ~max_length:max_record_length
       with
       | Error _ -> Payload_invalid
       | Ok observation ->
         if
           Fs_compat.Capability_exact_read.observation_settlement_warnings observation
           <> []
         then Payload_invalid
         else
           Payload_valid
             (Fs_compat.Capability_exact_read.observation_bytes observation))
    | `Unknown
    | `Fifo
    | `Character_special
    | `Directory
    | `Block_device
    | `Symbolic_link
    | `Socket -> Payload_invalid
  with
  | Eio.Io _ -> Payload_invalid
;;

let observe_locator ~parent ~operation_id =
  match read_record ~parent ~leaf:locator_leaf with
  | Payload_missing -> Core.Locator_missing
  | Payload_invalid -> Core.Locator_invalid
  | Payload_valid bytes ->
    (match Store.validate_locator_record ~operation_id bytes with
     | Ok () -> Core.Locator_valid
     | Error _ -> Core.Locator_invalid)
;;

let observe_terminal ~parent ~operation_id =
  match read_record ~parent ~leaf:terminal_leaf with
  | Payload_missing -> Core.Terminal_missing
  | Payload_invalid -> Core.Terminal_invalid
  | Payload_valid bytes ->
    (match Store.decode_terminal_record ~operation_id bytes with
     | Ok terminal -> Core.Terminal_valid terminal
     | Error _ -> Core.Terminal_invalid)
;;

let operation_entry ~root operation_id =
  let parent =
    Eio.Path.(root / Identity.operation_id_to_string operation_id)
  in
  try
    match Eio.Path.kind ~follow:false parent with
    | `Directory ->
      let locator = observe_locator ~parent ~operation_id in
      let terminal = observe_terminal ~parent ~operation_id in
      Core.operation_entry operation_id (Core.classify ~locator ~terminal)
    | `Not_found -> Core.operation_entry operation_id (Core.Corrupt Core.Scope_unreadable)
    | `Unknown
    | `Fifo
    | `Character_special
    | `Regular_file
    | `Block_device
    | `Symbolic_link
    | `Socket -> Core.operation_entry operation_id (Core.Corrupt Core.Scope_not_directory)
  with
  | Eio.Io _ -> Core.operation_entry operation_id (Core.Corrupt Core.Scope_unreadable)
;;

let inventory_entry ~root entry_name =
  match Identity.operation_id_of_string entry_name with
  | Ok operation_id -> operation_entry ~root operation_id
  | Error _ -> Core.unrecognized_entry ~entry_name
;;

let read ~base_path =
  match Fs_compat.get_fs_opt () with
  | None -> Error Filesystem_unavailable
  | Some fs ->
    let root_path = Config_dir_resolver.agent_execution_journals_dir ~base_path in
    let root = Eio.Path.(fs / root_path) in
    (try
       match Eio.Path.kind ~follow:false root with
       | `Not_found -> Ok (Core.create [])
       | `Directory ->
         Eio.Path.read_dir root
         |> List.map (inventory_entry ~root)
         |> Core.create
         |> Result.ok
       | `Unknown
       | `Fifo
       | `Character_special
       | `Regular_file
       | `Block_device
       | `Symbolic_link
       | `Socket -> Error Journal_root_not_directory
     with
     | Eio.Io _ -> Error Journal_root_unreadable)
;;

let to_yojson = Core.to_yojson

let read_error_to_string = function
  | Filesystem_unavailable -> "Eio filesystem capability is unavailable"
  | Journal_root_not_directory ->
    "Agent Core execution-journal root is not a directory"
  | Journal_root_unreadable -> "Agent Core execution-journal root is unreadable"
;;
