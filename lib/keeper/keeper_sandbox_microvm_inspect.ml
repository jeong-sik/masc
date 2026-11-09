module Backend = Keeper_microvm_backend
open Keeper_sandbox_microvm_base

(** Label value distinguishing a keeper-lifetime guest from turn
    containers. The guest outlives turns, so it carries no turn id. *)
let keeper_vm_container_kind = "keeper-vm"

(** [container inspect] answers JSON; state lives at [.[0].status.state]
    ("running" observed live). A non-zero exit is not parsed here: a missing
    container and a runtime that could not look both exit 1, and
    {!classify_guest_probe_for} settles which from the listing. *)
(* Two runtimes, two shapes, measured 2026-09-03:

     container inspect      [ { "status": { "state": "running" } } ]
     msb inspect --format json
                            { "name": ..., "status": "Running" }

   A list against an object, a nested state against a flat one, lowercase
   against capitalised. Neither parser is written to tolerate the other's
   shape: a shape this code does not know is [Error], never [Ok false]. Read
   as "not running", an unrecognised answer would take a live guest down and
   boot a second one beside it. *)
let running_of_microsandbox_inspect_json raw =
  match Yojson.Safe.from_string raw with
  | `Assoc fields ->
    (match List.assoc_opt "status" fields with
     | Some (`String status) ->
       Ok (String.equal (String.lowercase_ascii status) "running")
     | Some _ | None -> Error "msb inspect: status missing")
  | _ -> Error "msb inspect: unparseable JSON"
  | exception Yojson.Json_error _ -> Error "msb inspect: unparseable JSON"
;;

(* [nerdctl inspect --format "{{json .State.Running}}"] answers the bare
   literal, the same template masc already sends Docker. Anything else is an
   [Error]: a template that stopped resolving prints an empty line, and read
   as "not running" that takes a live guest down. *)
let running_of_nerdctl_state_json raw =
  match String.trim raw with
  | "true" -> Ok true
  | "false" -> Ok false
  | other ->
    Error
      (Printf.sprintf
         "nerdctl inspect: expected the State.Running literal, got %S"
         other)
;;

let running_of_apple_inspect_json raw =
  let open Result.Syntax in
  let fields name = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields
      else Error ("container inspect: duplicate " ^ name ^ " key")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error ("container inspect: invalid " ^ name)
  in
  match Yojson.Safe.from_string raw with
  | `List [row] ->
    let* row = fields "row" row in
    (match List.assoc_opt "status" row with
     | Some status ->
       let* status = fields "status" status in
       (match List.assoc_opt "state" status with
        | Some (`String "running") -> Ok true
        | Some (`String "stopped") -> Ok false
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Assoc _)
        | None -> Error "container inspect: unknown or missing status.state")
     | None -> Error "container inspect: status missing")
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _
  | `List [] | `List (_ :: _ :: _) -> Error "container inspect: expected exactly one row"
  | exception Yojson.Json_error _ -> Error "container inspect: unparseable JSON"
;;

(* Apple inspect configuration. Unknown metadata is left alone; every
   identity/isolation field below is mandatory and duplicate-free.
   [publishedSockets] and [useInit] were read from 1.6.1, which reports both
   for every guest (docs/evidence/2026-11-03-microvm-request-transport). *)
let apple_guest_facts ~container_name raw =
  let module Plan = Keeper_microvm_boot_plan in
  let open Result.Syntax in
  let ( >>= ) = Result.bind in
  let invalid field = Error ("container inspect: invalid or missing " ^ field) in
  let object_fields field = function
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys = List.length (List.sort_uniq String.compare keys)
      then Ok fields else invalid (field ^ " (duplicate keys)")
    | _ -> invalid field in
  let member field fields = match List.assoc_opt field fields with
    | Some value -> Ok value | None -> invalid field in
  let string field = function `String value -> Ok value | _ -> invalid field in
  let boolean field = function `Bool value -> Ok value | _ -> invalid field in
  let list field parse = function
    | `List values ->
      let* reversed = List.fold_left (fun result value ->
        let* values = result in let* value = parse value in Ok (value :: values))
        (Ok []) values in
      Ok (List.rev reversed)
    | _ -> invalid field in
  let positive_integer field value =
    let parsed = match value with
      | `Int value -> Some (Int64.of_int value)
      | `Intlit value -> Int64.of_string_opt value
      | _ -> None in
    match parsed with Some value when value > 0L -> Ok value | Some _ | None -> invalid field in
  let string_member field fields = member field fields >>= string field in
  let strings_member field fields = member field fields >>= list field (string field) in
  let object_member field fields = member field fields >>= object_fields field in
  let string_pairs field fields =
    let* fields = object_fields field fields in
    List.fold_left (fun result (key, value) ->
      let* pairs = result in let* value = string field value in Ok ((key, value) :: pairs))
      (Ok []) fields in
  let environment value =
    let* entries = list "environment" (string "environment") value in
    let* pairs = List.fold_left (fun result entry ->
      let* pairs = result in
      match String.index_opt entry '=' with
      | None -> invalid "environment entry"
      | Some index ->
        let key = String.sub entry 0 index in
        if key = "" || List.mem_assoc key pairs then invalid "environment name"
        else Ok ((key, String.sub entry (index + 1) (String.length entry - index - 1)) :: pairs))
      (Ok []) entries in
    Ok (List.rev pairs) in
  let mount value =
    let* fields = object_fields "mount" value in
    let* destination = string_member "destination" fields in
    let* source = string_member "source" fields in
    let* options = strings_member "options" fields in
    let* kind = object_member "type" fields in
    match kind with
    | ["tmpfs", `Assoc []] ->
      if options = [] then Ok (Plan.Tmpfs {destination}) else invalid "tmpfs options"
    | ["virtiofs", `Assoc []] ->
      if options = [] || options = ["ro"] then
        Ok (Plan.Host_dir {source; destination; read_only = options = ["ro"]})
      else invalid "virtiofs options"
    | ["volume", detail] ->
      let* detail = object_fields "volume" detail in
      let* name = string_member "name" detail in
      if options = [] then Ok (Plan.Named_volume {name; destination})
      else invalid "volume options"
    | _ -> invalid "mount type" in
  let decode json =
    let* row = match json with `List [row] -> object_fields "row" row | _ -> invalid "row count" in
    let* id = string_member "id" row in
    let* config = object_member "configuration" row in
    let* configured_id = string_member "id" config in
    let* () = if id = container_name && configured_id = container_name then Ok () else invalid "guest identity" in
    let* image_fields = object_member "image" config in
    let* image = string_member "reference" image_fields in
    let* descriptor_digest = object_member "descriptor" image_fields >>= string_member "digest" in
    let* platform = object_member "platform" config in
    let* architecture = string_member "architecture" platform in
    let* os = string_member "os" platform in
    let* variant = match List.assoc_opt "variant" platform with
      | None | Some `Null -> Ok None
      | Some value -> Result.map Option.some (string "platform variant" value) in
    let* () = if descriptor_digest = "" || architecture = "" || os = "" || variant = Some ""
      then invalid "image identity" else Ok () in
    let image_identity : Keeper_microvm_image_command.identity =
      {descriptor_digest; platform={architecture; os; variant}} in
    let* resources = object_member "resources" config in
    let* cpus = member "cpus" resources >>= positive_integer "cpus" in
    let* cpus = if cpus <= Int64.of_int max_int then Ok (Int64.to_int cpus) else invalid "cpus" in
    let* memory_bytes = member "memoryInBytes" resources >>= positive_integer "memoryInBytes" in
    let* init = object_member "initProcess" config in
    let* user = object_member "user" init >>= object_member "raw" >>= string_member "userString" in
    let* working_directory = string_member "workingDirectory" init in
    let* executable = string_member "executable" init in
    let* arguments = strings_member "arguments" init in
    let* mounts = member "mounts" config >>= list "mounts" mount in
    let destinations = List.map (function
      | Plan.Tmpfs {destination} | Plan.Host_dir {destination; _}
      | Plan.Named_volume {destination; _} -> destination) mounts in
    let* () = if List.length destinations = List.length (List.sort_uniq String.compare destinations)
      then Ok () else invalid "duplicate mount destination" in
    let* read_only = member "readOnly" config >>= boolean "readOnly" in
    let* cap_drop = strings_member "capDrop" config in
    let* cap_add = strings_member "capAdd" config in
    let* published_sockets = member "publishedSockets" config >>= list "publishedSockets" (fun value ->
      let* fields = object_fields "published socket" value in
      let* host_path = string_member "hostPath" fields in
      let* guest_path = string_member "containerPath" fields in
      Ok {Plan.host_path; guest_path}) in
    let* use_init = member "useInit" config >>= boolean "useInit" in
    let* networks = member "networks" config >>= list "networks" (fun value ->
      object_fields "network" value >>= string_member "network") in
    let* environment = member "environment" init >>= environment in
    let* labels = member "labels" config >>= string_pairs "labels" in
    Ok {Plan.plan_label = List.assoc_opt Plan.label_key labels; image; image_identity; cpus; memory_bytes;
        user; working_directory; command = executable :: arguments; mounts;
        read_only; cap_drop; cap_add; published_sockets; use_init; networks; environment; labels}
  in
  match Yojson.Safe.from_string raw with
  | json -> (match decode json with Ok facts -> Plan.Facts facts | Error detail -> Plan.Unreadable detail)
  | exception Yojson.Json_error _ -> Plan.Unreadable "container inspect: unparseable JSON"
;;

let running_of_inspect_json_for backend raw =
  match (backend : Backend.t) with
  | Backend.Apple_container -> running_of_apple_inspect_json raw
  | Backend.Microsandbox -> running_of_microsandbox_inspect_json raw
  | Backend.Nerdctl_kata -> running_of_nerdctl_state_json raw
;;

(* [container inspect] answers JSON by default; [msb inspect] answers a
   human table unless asked, so the machine form is requested explicitly. *)
let inspect_argv_for backend ~container_name =
  match (backend : Backend.t) with
  | Backend.Apple_container -> command_argv_for backend @ [ "inspect"; container_name ]
  | Backend.Microsandbox ->
    command_argv_for backend @ [ "inspect"; container_name; "--format"; "json" ]
  (* [nerdctl inspect] documents [--mode=(dockercompat|native)] and states no
     default, so the mode is named. [{{json .State.Running}}] resolves only
     in dockercompat; inherited from an unstated default it would be a
     template that stops resolving the day the default moves, which prints an
     empty line and reads as "not running". Asking for the one field rather
     than the whole document keeps the parse to a literal. *)
  | Backend.Nerdctl_kata ->
    command_argv_for backend
    @ [ "inspect"
      ; "--mode"
      ; "dockercompat"
      ; "--format"
      ; "{{json .State.Running}}"
      ; container_name
      ]
;;

(* [container logs] takes [-n]; [msb logs] rejects [-n] and takes [--tail]
   (measured 0.6.16, 2026-09-04: "unexpected argument '-n' found"), and
   nerdctl documents [-n, --tail]. *)
let logs_tail_argv_for backend ~tail ~container_id =
  match (backend : Backend.t) with
  | Backend.Apple_container ->
    command_argv_for backend @ [ "logs"; "-n"; string_of_int tail; container_id ]
  | Backend.Microsandbox | Backend.Nerdctl_kata ->
    command_argv_for backend @ [ "logs"; "--tail"; string_of_int tail; container_id ]
;;
