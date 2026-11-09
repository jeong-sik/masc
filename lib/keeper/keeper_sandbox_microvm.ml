(** microVM argv for the [Micro_vm] sandbox profile.

    Every builder here takes the runtime the keeper declared
    ({!Keeper_microvm_backend.t}). Before #32837 the lifecycle surfaces took
    it and the boot, exec, image and listing surfaces did not, so a keeper
    naming [microsandbox] booted under Apple's [container] and was then
    stopped and inspected with [msb] -- two runtimes for one guest, and
    nothing able to reap the one that actually booted.

    One lightweight VM per container through Virtualization.framework, so an
    Apple guest runs its own Linux kernel instead of sharing the host's.
    Measured
    2026-08-28 on macOS 26.6.1 / M3 Max with container CLI 1.3.0: about
    460 MB of host memory per running guest, and the guest reporting
    [Linux <uuid> 6.18.35].

    Cost is per keeper, not per call. Booting a guest takes 1.3-2.4s, but
    #31340 made the guest keeper-lifetime, so a turn pays [container exec]
    at 0.06-0.10s -- under Docker's 0.6-0.9s per-call container start. An
    earlier version of this comment quoted 4.0-4.4s per call: that was
    measured before guests were adopted across turns, and stayed here after
    the number stopped being true.

    This module builds the command and nothing else; [Keeper_turn_sandbox_runtime]
    runs the boot and lifecycle argv, and the remote lane
    ([Keeper_sandbox_remote]) drives the guest's shim over [container exec].
    The guest's working tree is on a Keeper-named volume (RFC-0400), which
    can be shared by same-named Keepers in different workspaces. The host
    playground is never mounted into it. *)

include Keeper_sandbox_microvm_base
include Keeper_sandbox_microvm_network
include Keeper_sandbox_microvm_image_probe
include Keeper_sandbox_microvm_guest_argv
include Keeper_sandbox_microvm_work_volume
include Keeper_sandbox_microvm_shim
include Keeper_sandbox_microvm_volume_probe
include Keeper_sandbox_microvm_volume_claim_scripts
include Keeper_sandbox_microvm_volume_claims
include Keeper_sandbox_microvm_work_root

module Backend = Keeper_microvm_backend
module Kata_vmm = Keeper_microvm_kata_vmm

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

(** Guests whose owning server is gone.

    A guest is keeper-lifetime, so age says nothing: one running for days
    belongs to a keeper that has been busy for days. What marks a guest as
    abandoned is its [masc.mcp.owner_pid] label naming a process that no
    longer exists -- the server that booted it died without reaching
    shutdown finalization, which is the one path that removes a guest
    (#31413). Each is about 460 MB, so they are worth collecting.

    Owner liveness is a fact rather than a heuristic, which is why this does
    not fall back to a time cutoff when the label is missing or unreadable:
    a guest it cannot account for is left alone and reported, not removed.
    Removing somebody's running guest to tidy up is worse than leaking. *)
type sweep_candidate =
  { container_id : string
  ; keeper_name : string option
  ; owner_pid : int option
  }

let label_of entry key =
  let open Yojson.Safe.Util in
  match entry |> member "configuration" |> member "labels" |> member key with
  | `String value -> Some value
  | _ -> None
;;

let json_string_opt = function
  | `String value -> Some value
  | _ -> None
;;

let container_id_of_entry entry =
  let open Yojson.Safe.Util in
  match entry |> member "id" |> json_string_opt with
  | Some id -> Some id
  | None -> entry |> member "configuration" |> member "id" |> json_string_opt
;;

let live_containers_of_json ~base_path ~keeper_name = function
  | `List entries ->
    let open Yojson.Safe.Util in
    let expected_base_path_hash = Keeper_sandbox_runtime.base_path_hash base_path in
    let expected_keeper_name = Keeper_sandbox_runtime.sanitize_label_value keeper_name in
    let belongs_to_keeper entry =
      String.equal
        (Option.value ~default:""
           (label_of entry Keeper_sandbox_runtime.sandbox_component_label_key))
        Keeper_sandbox_runtime.sandbox_component_label_value
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_base_path_hash_label_key))
           expected_base_path_hash
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_keeper_label_key))
           expected_keeper_name
      && String.equal
           (Option.value ~default:""
              (label_of entry Keeper_sandbox_runtime.sandbox_kind_label_key))
           keeper_vm_container_kind
    in
    let decode entry =
      if not (belongs_to_keeper entry) then Ok None
      else
        match container_id_of_entry entry with
        | None ->
          Error
            (Printf.sprintf "microvm live container for %s is malformed: missing id"
               keeper_name)
        | Some id ->
          try
          let configuration = entry |> member "configuration" in
          let image = configuration |> member "image" |> member "reference" |> to_string in
          let state = entry |> member "status" |> member "state" |> to_string in
          let labels = configuration |> member "labels" in
          let label name = labels |> member name |> json_string_opt in
          let float_label name = Option.bind (label name) float_of_string_opt in
          let int_member name json =
            match json |> member name with
            | `Int value -> Some value
            | _ -> None
          in
          let network =
            match entry |> member "status" |> member "networks" with
            | `List (network :: _) -> Some network
            | `List [] | `Null | _ -> None
          in
          let network_string name =
            Option.bind network (fun row -> row |> member name |> json_string_opt)
          in
          let resources = configuration |> member "resources" in
          let owner_pid =
            Option.bind
              (label Keeper_sandbox_runtime.sandbox_owner_pid_label_key)
              int_of_string_opt
          in
          Ok
            (Some
               ({ id
                ; name = id
                ; image
                ; status = state
                ; running = Some (String.equal state "running")
                ; created_at = configuration |> member "creationDate" |> json_string_opt
                ; keeper_name = label Keeper_sandbox_runtime.sandbox_keeper_label_key
                ; container_kind = label Keeper_sandbox_runtime.sandbox_kind_label_key
                ; network_label = label Keeper_sandbox_runtime.sandbox_network_label_key
                ; owner_pid
                ; started_at = float_label Keeper_sandbox_runtime.sandbox_started_at_label_key
                ; ttl_sec = float_label Keeper_sandbox_runtime.sandbox_ttl_sec_label_key
                ; cpus = int_member "cpus" resources
                ; memory_bytes = int_member "memoryInBytes" resources
                ; hostname = network_string "hostname"
                ; ipv4_address = network_string "ipv4Address"
                ; ipv6_address = network_string "ipv6Address"
                ; gateway = network_string "ipv4Gateway"
                } : Keeper_sandbox_runtime.live_container))
          with Yojson.Safe.Util.Type_error (detail, _) ->
            Error
              (Printf.sprintf "microvm live container for %s is malformed: %s"
                 keeper_name detail)
    in
    List.fold_right
      (fun entry result ->
         match decode entry, result with
         | Error detail, _ | _, Error detail -> Error detail
         | Ok None, Ok containers -> Ok containers
         | Ok (Some container), Ok containers -> Ok (container :: containers))
      entries
      (Ok [])
  | _ -> Error "microvm container list must be a JSON array"
;;

(** How a runtime answers "which guests are here", and whether that answer
    carries the labels the scoping above reads.

    What the sweep needs from a row is not just "which guests" but "whose":
    the base path hash, the keeper name, and the owner pid it decides
    abandonment on. Filtering is not enough -- the pid has to be read back.

    Apple's [container list --all --format json] answers a JSON array whose
    entries nest [configuration.labels], which is where all three live.

    [msb list] documents [--label <LABEL>] (repeatable, AND-matched), so a
    guest can be scoped server-side; what its [--format json] rows carry is
    only created_at, image, name and status, with no label values at all
    (measured 0.6.16, 2026-09-04). The owner pid the sweep needs is therefore
    not in the answer, and msb keeps labels in [inspect] under
    [active_config.labels] -- one call per guest rather than one listing.

    Nerdctl's ListItem exposes LabelsMap to Go templates even though its
    ordinary JSON representation excludes that field. Request an explicit
    flat record, including the runtime identity; do not pretend its status
    prose is Apple's structured running state.
    Source: nerdctl v2.3.5 pkg/cmd/container/list.go:107-125,182-193. *)
type container_listing =
  | Labelled_json_array of string list
  | Nerdctl_labelled_json_lines of string list
  | Listing_not_established of string

let nerdctl_inventory_argv () =
  command_argv_for Backend.Nerdctl_kata
  @ [ "ps"; "-a"; "--no-trunc"; "--format";
      {|{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"status":{{json .Status}},"created_at":{{json .CreatedAt}},"runtime":{{json .Runtime}},"labels":{{json .LabelsMap}}}|} ]
;;

type kata_name_observation =
  | Kata_name_absent
  | Kata_name_expected_runtime
  | Kata_name_other_runtime
  | Kata_name_runtime_unreported
  | Kata_name_unavailable

(* This listing deliberately asks for no labels, images, IDs, logs or guest
   files. A reported runtime is a CLI observation, never proof of ownership. *)
let kata_name_listing_argv () =
  command_argv_for Backend.Nerdctl_kata
  @ [ "ps"; "-a"; "--no-trunc"; "--format";
      {|{"name":{{json .Names}},"runtime":{{json .Runtime}}}|} ]
;;

let kata_name_observation_of_json_lines ~guest_name raw =
  let open Result.Syntax in
  let row line =
    let* json =
      try Ok (Yojson.Safe.from_string line) with Yojson.Json_error _ -> Error ()
    in
    match json with
    | `Assoc fields ->
      let keys = List.map fst fields in
      if List.length keys <> List.length (List.sort_uniq String.compare keys)
      then Error ()
      else
        let* name = match List.assoc_opt "name" fields with
          | Some (`String name) when String.trim name <> "" -> Ok name
          | Some _ | None -> Error () in
        let* runtime = match List.assoc_opt "runtime" fields with
          | None | Some `Null | Some (`String "") -> Ok Kata_name_runtime_unreported
          | Some (`String runtime) ->
            if String.trim runtime = "" then Ok Kata_name_runtime_unreported
            else
              (match Kata_vmm.classify_runtime_id runtime with
               | Ours _ | Default_shim -> Ok Kata_name_expected_runtime
               | Unknown_runtime _ -> Ok Kata_name_other_runtime)
          | Some _ -> Error () in
        Ok (name, runtime)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
      Error ()
  in
  let decode () =
    let* rows =
      String.split_on_char '\n' raw
      |> List.map String.trim
      |> List.filter (fun line -> line <> "")
      |> fun lines -> List.fold_right (fun line acc ->
           let* rows = acc in
           let* current = row line in
           Ok (current :: rows)) lines (Ok [])
    in
    let names = List.map fst rows in
    if List.length names <> List.length (List.sort_uniq String.compare names)
       || String.trim guest_name = ""
    then Error ()
    else Ok (match List.assoc_opt guest_name rows with
      | Some observation -> observation
      | None -> Kata_name_absent)
  in
  match decode () with
  | Ok observation -> observation
  | Error () -> Kata_name_unavailable
;;

let observe_kata_name_with ~run ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec =
  let guest_name =
    Keeper_sandbox_container_name.make
      (Keeper_sandbox_container_name.Micro_vm_persistent
         { base_path; keeper_name; network_mode })
    |> Keeper_sandbox_container_name.to_string in
  if not (Float.is_finite timeout_sec) || timeout_sec <= 0. then Kata_name_unavailable
  else match run ~timeout_sec ~env ~cwd ~argv:(kata_name_listing_argv ()) with
  | Ok (Unix.WEXITED 0, stdout) ->
    kata_name_observation_of_json_lines ~guest_name stdout
  | Ok ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _) | Error () ->
    Kata_name_unavailable
  | exception (Sys_error _ | Unix.Unix_error _ | Eio.Io _) -> Kata_name_unavailable
;;

let observe_kata_name ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec =
  let run ~timeout_sec ~env ~cwd ~argv =
    Fd_accountant.observe ~kind:Fd_accountant.Docker_spawn (fun () ->
      Keeper_microvm_cli_output.read_with_environment ~timeout_sec
        ~stdout_limit:Common.max_process_capture_head_bytes
        ~stderr_limit:Common.max_process_capture_tail_bytes ~env ~cwd ~argv ()
      |> Result.map (fun (status, stdout, _) -> status, stdout)
      |> Result.map_error (fun _ -> ())) in
  observe_kata_name_with ~run ~env ~cwd ~base_path ~keeper_name ~network_mode ~timeout_sec
;;

let container_listing_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container -> Labelled_json_array (apple_container_list_argv ())
  | Backend.Microsandbox ->
    Listing_not_established
      "msb list can be scoped server-side with --label, but its --format \
       json rows report only {created_at, image, name, status} and echo no \
       label values, so the owner pid this sweep decides abandonment on \
       cannot be read back from the listing; msb keeps labels in `inspect` \
       under active_config.labels, one call per guest"
  | Backend.Nerdctl_kata -> Nerdctl_labelled_json_lines (nerdctl_inventory_argv ())
;;

type nerdctl_inventory_entry =
  { nerdctl_id : string
  ; nerdctl_name : string
  ; nerdctl_image : string
  ; nerdctl_status : string
  ; nerdctl_created_at : string
  ; nerdctl_runtime : string
  ; nerdctl_labels : (string * string) list
  }

let nerdctl_inventory_of_json_lines raw =
  let open Result.Syntax in
  let object_fields = function
    | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names = List.length (List.sort_uniq String.compare names)
      then Ok fields else Error "nerdctl inventory contains duplicate fields"
    | _ -> Error "nerdctl inventory row must be an object"
  in
  let required_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) -> Ok value
    | _ -> Error ("nerdctl inventory requires string field " ^ name)
  in
  let decode line =
    let* json =
      try Ok (Yojson.Safe.from_string line)
      with Yojson.Json_error detail -> Error ("invalid nerdctl inventory JSON: " ^ detail)
    in
    let* fields = object_fields json in
    let* nerdctl_id = required_string fields "id" in
    (* --no-trunc returns the complete containerd id: accepting an empty or
       option-shaped id could make a removal target somebody else's guest. *)
    let* () =
      if String.length nerdctl_id = 64
         && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) nerdctl_id
      then Ok () else Error "nerdctl inventory requires a full hexadecimal container id"
    in
    let* nerdctl_name = required_string fields "name" in
    let* nerdctl_image = required_string fields "image" in
    let* nerdctl_status = required_string fields "status" in
    let* nerdctl_created_at = required_string fields "created_at" in
    let* nerdctl_runtime = required_string fields "runtime" in
    let* labels =
      match List.assoc_opt "labels" fields with
      | Some `Null -> Ok [] (* Go marshals a nil map as null; it owns no labels. *)
      | Some value -> object_fields value
      | None -> Error "nerdctl inventory requires labels"
    in
    let* nerdctl_labels =
      List.fold_right (fun (key, value) acc ->
        let* rest = acc in
        match value with
        | `String value -> Ok ((key, value) :: rest)
        | _ -> Error "nerdctl inventory label values must be strings") labels (Ok [])
    in
    Ok { nerdctl_id; nerdctl_name; nerdctl_image; nerdctl_status;
         nerdctl_created_at; nerdctl_runtime; nerdctl_labels }
  in
  let* rows =
    String.split_on_char '\n' raw
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
    |> fun lines -> List.fold_right (fun line acc ->
         let* row = decode line in
         let* rest = acc in
         Ok (row :: rest)) lines (Ok [])
  in
  let ids = List.map (fun row -> row.nerdctl_id) rows in
  if List.length ids = List.length (List.sort_uniq String.compare ids)
  then Ok rows else Error "nerdctl inventory contains duplicate container ids"
;;

let nerdctl_label row name = List.assoc_opt name row.nerdctl_labels

let nerdctl_belongs_to_base ~base_path row =
  let exact name expected = nerdctl_label row name = Some expected in
  (* Ownership runtime predicate widened by [task-2856]: rows started with any
     host-validated Kata-family id (default shim or per-VMM split) are ours;
     before, only the fixed shim id matched.  The component and
     base_path_hash labels below remain the real gates. *)
  (match Kata_vmm.classify_runtime_id row.nerdctl_runtime with
   | Ours _ | Default_shim -> true
   | Unknown_runtime _ -> false)
  && exact Keeper_sandbox_runtime.sandbox_component_label_key
       Keeper_sandbox_runtime.sandbox_component_label_value
  && exact Keeper_sandbox_runtime.sandbox_base_path_hash_label_key
       (Keeper_sandbox_runtime.base_path_hash base_path)
  && exact Keeper_sandbox_runtime.sandbox_kind_label_key keeper_vm_container_kind
;;

let nerdctl_owner_pid row =
  match Option.bind
          (nerdctl_label row Keeper_sandbox_runtime.sandbox_owner_pid_label_key)
          int_of_string_opt with
  | Some pid when pid > 0 -> Some pid
  | Some _ | None -> None
;;

let nerdctl_live_containers_of_json_lines ~base_path ~keeper_name raw =
  let expected_keeper = Keeper_sandbox_runtime.sanitize_label_value keeper_name in
  Result.map (fun rows ->
    List.filter_map (fun row ->
      if not (nerdctl_belongs_to_base ~base_path row)
         || nerdctl_label row Keeper_sandbox_runtime.sandbox_keeper_label_key <> Some expected_keeper
      then None
      else
        let label = nerdctl_label row in
        let float_label key = Option.bind (label key) float_of_string_opt in
        Some ({ id = row.nerdctl_id; name = row.nerdctl_name; image = row.nerdctl_image;
                status = row.nerdctl_status; running = None;
                created_at = Some row.nerdctl_created_at;
                keeper_name = label Keeper_sandbox_runtime.sandbox_keeper_label_key;
                container_kind = label Keeper_sandbox_runtime.sandbox_kind_label_key;
                network_label = label Keeper_sandbox_runtime.sandbox_network_label_key;
                owner_pid = nerdctl_owner_pid row;
                started_at = float_label Keeper_sandbox_runtime.sandbox_started_at_label_key;
                ttl_sec = float_label Keeper_sandbox_runtime.sandbox_ttl_sec_label_key;
                cpus = None; memory_bytes = None; hostname = None;
                ipv4_address = None; ipv6_address = None; gateway = None }
              : Keeper_sandbox_runtime.live_container)) rows)
    (nerdctl_inventory_of_json_lines raw)
;;

let nerdctl_sweep_candidates_of_json_lines ~base_path ~is_pid_alive raw =
  Result.map (fun rows ->
    List.filter_map (fun row ->
      let keeper_name = nerdctl_label row Keeper_sandbox_runtime.sandbox_keeper_label_key in
      match nerdctl_belongs_to_base ~base_path row, keeper_name, nerdctl_owner_pid row with
      | true, Some name, Some pid when String.trim name <> "" && not (is_pid_alive pid) ->
        Some { container_id = row.nerdctl_id; keeper_name; owner_pid = Some pid }
      | _ -> None) rows)
    (nerdctl_inventory_of_json_lines raw)
;;

(* ── Whether a guest name exists when inspect did not answer ────────── *)

(* Measured 2026-10-21 on container 1.3.1: [container inspect] exits 1 for a
   name that is not there ("container not found") and also exits 1 when the
   apiserver stalls before it can look ("failed to list containers ... XPC
   timeout", 31.5 s). msb 0.6.16 exits 1 for a missing name as well, and a
   timed-out inspect ends on a signal. The exit code cannot tell "absent"
   from "could not ask" (#44676), so the runtime's own listing settles it.

   msb is listed with its plain [msb list --format json]: the sweep cannot
   use those rows because they carry no labels, but they carry the name and
   the status a lookup by name needs. Measured 2026-10-21 on 0.6.16: stopped
   sandboxes are listed without a flag ([--running] and [--stopped] narrow
   it), and a row reads [{created_at, image, name, status}]. *)
let guest_listing_argv_for backend =
  match (backend : Backend.t) with
  | Backend.Apple_container -> apple_container_list_argv ()
  | Backend.Microsandbox -> command_argv_for backend @ [ "list"; "--format"; "json" ]
  | Backend.Nerdctl_kata -> nerdctl_inventory_argv ()
;;

(* What one listing row says about its guest. nerdctl's [ps] Status is
   display text ("Up 5 minutes"), not a state, so its rows report none. *)
type listed_state =
  | Listed_running
  | Listed_stopped
  | Listed_state_unreported

let apple_listing_rows raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("container list returned invalid JSON: " ^ detail)
  | `List entries ->
    List.fold_right
      (fun entry acc ->
         Result.bind acc (fun rows ->
           match entry with
           | `Assoc fields ->
             (match apple_listing_row_id fields with
              | None -> Error "container list has a row without a container id"
              | Some id ->
                let state =
                  match List.assoc_opt "status" fields with
                  | Some (`Assoc status) ->
                    (match List.assoc_opt "state" status with
                     | Some (`String state) ->
                       if String.equal state "running" then Listed_running else Listed_stopped
                     | Some _ | None -> Listed_state_unreported)
                  | Some _ | None -> Listed_state_unreported
                in
                Ok ((id, state) :: rows))
           | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
             Error "container list has a row that is not an object"))
      entries
      (Ok [])
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    Error "container list did not return a JSON array"
;;

let msb_listing_rows raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error ("msb list returned invalid JSON: " ^ detail)
  | `List entries ->
    List.fold_right
      (fun entry acc ->
         Result.bind acc (fun rows ->
           match entry with
           | `Assoc fields ->
             (match List.assoc_opt "name" fields with
              | Some (`String name) when String.trim name <> "" ->
                let state =
                  match List.assoc_opt "status" fields with
                  | Some (`String status) ->
                    if String.equal (String.lowercase_ascii status) "running"
                    then Listed_running
                    else Listed_stopped
                  | Some _ | None -> Listed_state_unreported
                in
                Ok ((name, state) :: rows)
              | Some _ | None -> Error "msb list has a row without a name")
           | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) ->
             Error "msb list has a row that is not an object"))
      entries
      (Ok [])
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    Error "msb list did not return a JSON array"
;;

let nerdctl_listing_rows raw =
  Result.map
    (List.map (fun row -> row.nerdctl_name, Listed_state_unreported))
    (nerdctl_inventory_of_json_lines raw)
;;

(* Every row is decoded before the name is looked up: a row whose name cannot
   be read might be the guest asked about, so it fails the listing instead of
   being skipped. *)
let listing_rows_for backend raw =
  match (backend : Backend.t) with
  | Backend.Apple_container -> apple_listing_rows raw
  | Backend.Microsandbox -> msb_listing_rows raw
  | Backend.Nerdctl_kata -> nerdctl_listing_rows raw
;;

let classify_guest_probe_for backend ~container_name ~inspect ~listing =
  let inspect_status, inspect_output = inspect in
  match inspect_status with
  | Unix.WEXITED 0 ->
    (match running_of_inspect_json_for backend inspect_output with
     | Ok true -> Ok Keeper_sandbox_runtime.Docker_container_running
     | Ok false -> Ok Keeper_sandbox_runtime.Docker_container_stopped
     | Error _ as error -> error)
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ ->
    let unknown reason =
      Error
        (Printf.sprintf
           "microvm_guest_state_unknown: %s inspect %s did not answer (%s): %s; %s"
           (Backend.cli_name backend)
           container_name
           (Keeper_sandbox_exec_failure.status_label inspect_status)
           (Keeper_sandbox_runtime.docker_failure_output_for_log inspect_output)
           reason)
    in
    (match listing with
     | None -> unknown "no listing was taken to confirm the guest is absent"
     | Some (Unix.WEXITED 0, stdout, _stderr) ->
       (match listing_rows_for backend stdout with
        | Error detail -> unknown ("the listing could not be read: " ^ detail)
        | Ok rows ->
          (match List.filter (fun (name, _) -> String.equal name container_name) rows with
           | [] -> Ok Keeper_sandbox_runtime.Docker_container_absent
           | [ (_, Listed_running) ] -> Ok Keeper_sandbox_runtime.Docker_container_running
           | [ (_, Listed_stopped) ] -> Ok Keeper_sandbox_runtime.Docker_container_stopped
           | [ (_, Listed_state_unreported) ] ->
             unknown "the listing shows the guest and does not report its state"
           | _ :: _ :: _ -> unknown "the listing names the guest more than once"))
     | Some (((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr) ->
       unknown
         (Printf.sprintf
            "the listing failed too (%s): %s"
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
;;

let list_live_containers_for_with ~run backend ~base_path ~keeper_name ~timeout_sec =
  let open Result.Syntax in
  if not (Float.is_finite timeout_sec) || timeout_sec <= 0. then
    Error "microvm observation timeout is unavailable"
  else match container_listing_for backend with
  | Listing_not_established reason ->
    Error
      (Printf.sprintf
         "microvm_container_listing_unsupported: %s: %s"
         (Backend.to_string backend)
         reason)
  | (Labelled_json_array argv | Nerdctl_labelled_json_lines argv) as listing ->
    (match run ~timeout_sec argv with
     | Unix.WEXITED 0, stdout, _ ->
       (match listing with
        | Nerdctl_labelled_json_lines _ ->
          let* containers = nerdctl_live_containers_of_json_lines ~base_path ~keeper_name stdout in
          (* ps Status is display prose. Ask the existing typed bool inspect
             for each scoped guest so status does not misreport unknown as idle. *)
          List.fold_right (fun (container : Keeper_sandbox_runtime.live_container) acc ->
            let* rest = acc in
            match run ~timeout_sec (inspect_argv_for backend ~container_name:container.id) with
            | Unix.WEXITED 0, state, _ ->
              let* running = running_of_nerdctl_state_json state in
              Ok ({ container with running = Some running } :: rest)
            | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), out, err ->
              Error (Printf.sprintf "nerdctl inventory state for %s failed (%s): %s"
                       container.id (Keeper_sandbox_exec_failure.status_label status)
                       (output_for_log ~stdout:out ~stderr:err))) containers (Ok [])
        | Labelled_json_array _ ->
          (match Yojson.Safe.from_string stdout with
           | json -> live_containers_of_json ~base_path ~keeper_name json
           | exception Yojson.Json_error detail ->
             Error ("microvm container list returned invalid JSON: " ^ detail))
        | Listing_not_established reason -> Error reason)
     | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), stdout, stderr ->
       Error
         (Printf.sprintf
            "microvm container list failed (%s): %s"
            (Keeper_sandbox_exec_failure.status_label status)
            (output_for_log ~stdout ~stderr)))
;;

let list_live_containers_for ?env ?cwd backend ~base_path ~keeper_name ~timeout_sec =
  let run ~timeout_sec argv = Process_eio.run_argv_with_status_split ~timeout_sec ?env ?cwd argv in
  list_live_containers_for_with ~run backend ~base_path ~keeper_name ~timeout_sec
;;

module Kata_observation_for_testing = struct
  let observe = observe_kata_name_with
  let inventory = list_live_containers_for_with
end

type sweep_outcome =
  { removed : string list
  ; failed : (string * string) list
  }

(* One runtime's share of the sweep. Returns what it did rather than
   raising: a guest that refuses to stop is worth reporting, and is not a
   reason to fail whatever asked for the sweep. A listing that cannot be read
   removes nothing. *)
let sweep_one_backend backend ~base_path ~timeout_sec ~is_pid_alive ~run_argv listing =
  match run_argv ~timeout_sec listing with
  | Unix.WEXITED 0, out ->
    let candidates =
      match nerdctl_sweep_candidates_of_json_lines ~base_path ~is_pid_alive out with
      | Ok candidates -> candidates
      | Error detail ->
        Log.Keeper.warn "nerdctl abandoned guest inventory rejected: %s" detail;
        []
    in
    List.fold_left
      (fun acc candidate ->
        match
          run_argv
            ~timeout_sec
            (delete_force_argv_for backend ~container_name:candidate.container_id)
        with
        | Unix.WEXITED 0, _ -> { acc with removed = candidate.container_id :: acc.removed }
        | (Unix.WEXITED _, detail) | (Unix.WSIGNALED _, detail) | (Unix.WSTOPPED _, detail) ->
          { acc with failed = (candidate.container_id, detail) :: acc.failed })
      { removed = []; failed = [] }
      candidates
  | ((Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _) as status), detail ->
    Log.Keeper.warn "microvm abandoned guest inventory failed backend=%s status=%s: %s"
      (Backend.to_string backend) (Keeper_sandbox_exec_failure.status_label status) detail;
    { removed = []; failed = [] }
;;

(* Apple selection belongs to the complete declaration-aware runtime sweep.
   Only Nerdctl retains process-bound dead-owner adoption and collection. *)
let sweep_abandoned_guests
      ~base_path
      ~command_available
      ~timeout_sec
      ~is_pid_alive
      ~run_argv
  =
  List.filter_map
    (fun backend ->
      if not (command_available (Backend.cli_name backend))
      then None
      else (
        match container_listing_for backend with
        | Listing_not_established _ -> None
        | Labelled_json_array listing | Nerdctl_labelled_json_lines listing ->
          Some
            ( backend
            , sweep_one_backend
                backend
                ~base_path
                ~timeout_sec
                ~is_pid_alive
                ~run_argv
                listing )))
    [Backend.Nerdctl_kata]
;;
