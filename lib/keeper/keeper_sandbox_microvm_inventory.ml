module Backend = Keeper_microvm_backend
module Kata_vmm = Keeper_microvm_kata_vmm
open Keeper_sandbox_microvm_base
open Keeper_sandbox_microvm_work_volume
open Keeper_sandbox_microvm_inspect

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
