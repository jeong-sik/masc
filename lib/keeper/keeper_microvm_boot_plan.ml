type guest_mount =
  | Tmpfs of { destination : string }
  | Host_dir of { source : string; destination : string; read_only : bool }
  | Named_volume of { name : string; destination : string }

type network =
  | Network_none
  | Network_inherit
  | Network_policy of { name : string }

type t =
  { image : string
  ; guest_size : Keeper_microvm_guest_size.t
  ; user : string
  ; working_directory : string
  ; command : string list
  ; mounts : guest_mount list
  ; isolation : Keeper_microvm_backend.guest_constraint list
  ; network : network
  ; environment : (string * string) list
  ; labels : (string * string) list
  }

let label_key = "masc.mcp.boot_plan"
let strings values = `List (List.map (fun value -> `String value) values)
let pairs values =
  `List (List.map (fun (key, value) -> strings [key; value])
    (List.sort compare values))

let mount_json = function
  | Tmpfs {destination} -> `List [`String "tmpfs"; `String destination]
  | Host_dir {source; destination; read_only} ->
    `List [`String "host_dir"; `String source; `String destination; `Bool read_only]
  | Named_volume {name; destination} ->
    `List [`String "named_volume"; `String name; `String destination]

let canonical_mounts mounts =
  List.map (fun mount -> Yojson.Safe.to_string (mount_json mount)) mounts
  |> List.sort String.compare

let digest (plan : t) =
  let network = match plan.network with
    | Network_none -> strings ["none"]
    | Network_inherit -> strings ["inherit"]
    | Network_policy {name} -> strings ["policy"; name]
  in
  let json = `Assoc
    [ "schema", `String "masc.keeper-boot-plan.v2"
    ; "image", `String plan.image
    ; "memory_mib", `Int (Keeper_microvm_guest_size.memory_mib plan.guest_size.memory)
    ; "cpus", `Int (Keeper_microvm_guest_size.cpus_count plan.guest_size.cpus)
    ; "user", `String plan.user
    ; "working_directory", `String plan.working_directory
    ; "command", strings plan.command
    ; "mounts", strings (canonical_mounts plan.mounts)
    ; "isolation", strings (List.map Keeper_microvm_backend.guest_constraint_to_string
        plan.isolation |> List.sort String.compare)
    ; "network", network
    ; "environment", pairs plan.environment
    ; "labels", pairs plan.labels
    ]
  in
  Agent_core_sha256.(digest_string (Yojson.Safe.to_string json) |> to_hex)

let expected_mounts (plan : t) =
  if List.mem Keeper_microvm_backend.Scratch_tmpfs plan.isolation then
    Tmpfs {destination = Keeper_microvm_backend.scratch_guest_root} :: plan.mounts
  else plan.mounts

type invalid_plan =
  | Missing_executable
  | Duplicate_environment_key of string
  | Duplicate_label_key of string
  | Duplicate_mount_destination of string
  | Duplicate_constraint of Keeper_microvm_backend.guest_constraint
  | Invalid_environment_key of string
  | Invalid_label_key of string
  | Reserved_plan_label of string
  | Unexpected_lifecycle_label of string
  | Duplicate_lifecycle_label of string
  | Execution_environment_collision of string

let duplicate_errors error values =
  let rec collect seen = function
    | [] -> []
    | value :: rest ->
      if List.mem value seen then error value :: collect seen rest
      else collect (value :: seen) rest
  in
  collect [] values

let valid_key key =
  key <> "" && not (String.contains key '=' || String.contains key '\000')

let lifecycle_label_keys =
  [ Keeper_sandbox_runtime_setup.sandbox_owner_pid_label_key
  ; Keeper_sandbox_runtime_setup.sandbox_started_at_label_key ]

let admission = function [] -> Ok () | _ :: _ as errors -> Error errors

let plan_errors (plan : t) =
  let environment_keys = List.map fst plan.environment in
  let label_keys = List.map fst plan.labels in
  let destinations = List.map (function
    | Tmpfs {destination} | Host_dir {destination; _}
    | Named_volume {destination; _} -> destination) (expected_mounts plan) in
  (match plan.command with
   | [] | "" :: _ -> [Missing_executable]
   | _ :: _ -> [])
  @ duplicate_errors (fun key -> Duplicate_environment_key key) environment_keys
  @ duplicate_errors (fun key -> Duplicate_label_key key) label_keys
  @ duplicate_errors (fun destination -> Duplicate_mount_destination destination) destinations
  @ duplicate_errors (fun constraint_ -> Duplicate_constraint constraint_) plan.isolation
  @ List.filter_map (fun key -> if valid_key key then None else Some (Invalid_environment_key key)) environment_keys
  @ List.filter_map (fun key -> if valid_key key then None else Some (Invalid_label_key key)) label_keys
  @ List.filter_map (fun key ->
      if key = label_key || List.mem key lifecycle_label_keys
      then Some (Reserved_plan_label key) else None) label_keys

let validate plan = admission (plan_errors plan)

let validate_boot ~plan ~lifecycle_labels ~execution_environment =
  let lifecycle_keys = List.map fst lifecycle_labels in
  admission
    (plan_errors plan
     @ duplicate_errors (fun key -> Duplicate_lifecycle_label key) lifecycle_keys
     @ List.filter_map (fun key ->
         if List.mem key lifecycle_label_keys then None
         else Some (Unexpected_lifecycle_label key)) lifecycle_keys
     @ List.filter_map (fun (key, _) ->
         if List.mem_assoc key plan.environment
         then Some (Execution_environment_collision key) else None) execution_environment)

let invalid_plan_message = function
  | Missing_executable -> "command requires a nonempty executable"
  | Duplicate_environment_key key -> Printf.sprintf "duplicate environment key %S" key
  | Duplicate_label_key key -> Printf.sprintf "duplicate label key %S" key
  | Duplicate_mount_destination destination -> Printf.sprintf "duplicate mount destination %S" destination
  | Duplicate_constraint constraint_ ->
    "duplicate constraint " ^ Keeper_microvm_backend.guest_constraint_to_string constraint_
  | Invalid_environment_key key -> Printf.sprintf "invalid environment key %S" key
  | Invalid_label_key key -> Printf.sprintf "invalid label key %S" key
  | Reserved_plan_label key -> Printf.sprintf "reserved stable-plan label %S" key
  | Unexpected_lifecycle_label key -> Printf.sprintf "unexpected lifecycle label %S" key
  | Duplicate_lifecycle_label key -> Printf.sprintf "duplicate lifecycle label %S" key
  | Execution_environment_collision key -> Printf.sprintf "execution environment collides with stable key %S" key

type facts =
  { plan_label : string option
  ; image : string
  ; image_identity : Keeper_microvm_image_command.identity
  ; cpus : int
  ; memory_bytes : int64
  ; user : string
  ; working_directory : string
  ; command : string list
  ; mounts : guest_mount list
  ; read_only : bool
  ; cap_drop : string list
  ; cap_add : string list
  ; networks : string list
  ; environment : (string * string) list
  ; labels : (string * string) list
  }

type reading = Facts of facts | Unreadable of string
type difference =
  | Plan_label | Image | Resources | User | Working_directory | Command
  | Mounts | Root_filesystem | Capabilities | Network | Environment | Labels
  | Policy_route
  | Identity_snapshot
type refusal =
  | Invalid_requested_plan of invalid_plan list
  | Guest_facts_unreadable of string
  | Image_command_unavailable of string
  | Runtime_reports_other_than_asked of difference list

let difference_label = function
  | Plan_label -> "boot_plan_label"
  | Image -> "image"
  | Resources -> "resources"
  | User -> "user"
  | Working_directory -> "working_directory"
  | Command -> "command"
  | Mounts -> "mounts"
  | Root_filesystem -> "root_filesystem"
  | Capabilities -> "capabilities"
  | Network -> "network"
  | Environment -> "environment"
  | Labels -> "labels"
  | Policy_route -> "policy_route"
  | Identity_snapshot -> "identity_snapshot"

let refusal_message = function
  | Invalid_requested_plan errors ->
    "invalid requested plan: " ^ String.concat "; " (List.map invalid_plan_message errors)
  | Guest_facts_unreadable _ -> "runtime guest facts are unreadable; guest preserved"
  | Image_command_unavailable detail ->
    "runtime image command unavailable; guest preserved: " ^ detail
  | Runtime_reports_other_than_asked differences ->
    Printf.sprintf
      "runtime guest facts disagree with the requested plan (fields: %s); guest preserved"
      (String.concat ", " (List.map difference_label differences))

type assessment =
  | Matches_plan
  | Replace of difference list
  | Refuse of refusal

let contains_pairs expected actual =
  List.for_all (fun (key, value) ->
    List.assoc_opt key actual = Some value) expected

let observed_differences ~image_difference ~command_difference (plan : t) (facts : facts) =
  (* Compare in MiB rather than multiplying the requested size into int64:
     an operator-sized value must not wrap and match a smaller real guest. *)
  let memory_matches = facts.memory_bytes > 0L
    && Int64.rem facts.memory_bytes 1_048_576L = 0L
    && Int64.div facts.memory_bytes 1_048_576L
       = Int64.of_int (Keeper_microvm_guest_size.memory_mib plan.guest_size.memory) in
  let read_only = List.mem Keeper_microvm_backend.Read_only_rootfs plan.isolation in
  let cap_drop = if List.mem Keeper_microvm_backend.Drop_all_capabilities plan.isolation
    then ["ALL"] else [] in
  let networks = match plan.network with
    | Network_none -> []
    | Network_inherit -> ["default"]
    | Network_policy {name} -> [name]
  in
  let different differs field = if differs then Some field else None in
  List.filter_map Fun.id
    [ different image_difference Image
    ; different (Keeper_microvm_guest_size.cpus_count plan.guest_size.cpus <> facts.cpus
        || not memory_matches) Resources
    ; different (plan.user <> facts.user) User
    ; different (plan.working_directory <> facts.working_directory) Working_directory
    ; command_difference
    ; different (canonical_mounts (expected_mounts plan) <> canonical_mounts facts.mounts) Mounts
    ; different (read_only <> facts.read_only) Root_filesystem
    ; different (List.sort String.compare cap_drop <> List.sort String.compare facts.cap_drop
        || facts.cap_add <> []) Capabilities
    ; different (List.sort String.compare networks <> List.sort String.compare facts.networks) Network
    ; different (not (contains_pairs plan.environment facts.environment)) Environment
    ; different (not (contains_pairs plan.labels facts.labels)) Labels
    ]

let differences ~image_command (plan : t) (facts : facts) =
  (* Apple launch overrides the image entrypoint with the plan's executable.
     Keep image binding checks separate from the exact requested runtime argv. *)
  let command_difference = if plan.command = facts.command then None else Some Command in
  let image_difference = Keeper_microvm_image_command.validate_binding image_command
      ~reference:plan.image ~identity:facts.image_identity <> Ok () in
  observed_differences ~image_difference ~command_difference plan facts

type identity_reading = Identity_readable | Identity_unreadable

let assess ~plan ~policy_environment ~identity_reading ~image_command reading =
  match validate plan with
  | Error errors -> Refuse (Invalid_requested_plan errors)
  | Ok () -> match reading with
  | Unreadable detail -> Refuse (Guest_facts_unreadable detail)
  | Facts facts ->
    let image_command = Result.bind image_command (fun command ->
      Keeper_microvm_image_command.validate_binding command ~reference:plan.image ~identity:facts.image_identity
      |> Result.map_error Keeper_microvm_image_command.error_message
      |> Result.map (fun () -> command)) in
    let differences = match image_command with
      | Ok image_command -> differences ~image_command plan facts
      | Error _ -> observed_differences ~image_difference:(plan.image <> facts.image)
          ~command_difference:None plan facts in
    if facts.plan_label <> Some (digest plan) then Replace (Plan_label :: differences)
    else
      let policy_route_holds = match plan.network with
        | Network_none | Network_inherit -> true
        | Network_policy _ ->
          policy_environment <> [] && contains_pairs policy_environment facts.environment
      in
      if not policy_route_holds then Replace [Policy_route]
      else match identity_reading with
        | Identity_unreadable -> Replace [Identity_snapshot]
        | Identity_readable ->
          match image_command with
          | Error detail -> Refuse (Image_command_unavailable detail)
          | Ok _ ->
            match differences with
            | [] -> Matches_plan
            | _ :: _ -> Refuse (Runtime_reports_other_than_asked differences)
