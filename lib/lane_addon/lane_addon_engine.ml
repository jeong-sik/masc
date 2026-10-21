open Lane_addon_types

type mount = { source : string; destination : string }
type lookup = Name of string | Id of string
type image_identity = Docker_image_id of string | Apple_manifest_digest of string
let image_digest = function Docker_image_id value | Apple_manifest_digest value -> value
let image_identity_to_json image =
  let runtime = match image with Docker_image_id _ -> Docker | Apple_manifest_digest _ -> Apple_container in
  `Assoc ["runtime", `String (runtime_to_string runtime); "digest", `String (image_digest image)]
let image_create_reference image ~requested = match image with
  | Docker_image_id id -> id
  | Apple_manifest_digest _ -> requested

(* Every container this host creates carries the worker incarnation that made
   it; a container for persistent state also carries the state owner. *)
let instance_label = "masc.lane.instance"
let state_owner_label = "masc.lane.state.owner"

(* Names the base path of the server that made the container. Several servers
   can share one engine, so a sweep must only ever see its own. *)
let scope_label = "masc.lane.scope"

type held = {
  container_id : string;
  name : string;
  instance : string option;
  state_owner : string option;
}

let ( let* ) = Result.bind
let digest value = Digestif.SHA256.(to_hex (digest_string value))
let owned_name runtime instance_id = match runtime with
  | Docker -> "masc-lane-" ^ digest instance_id
  | Apple_container -> digest instance_id

let valid_id id =
  String.length id = 64 && String.for_all (function
    | '0' .. '9' | 'a' .. 'f' -> true | _ -> false) id

let mount_argument runtime ({ source; destination } : mount) =
  if Filename.is_relative source || Filename.is_relative destination then
    Error "mount source and destination must be absolute"
  else if String.contains source ',' || String.contains destination ',' then
    Error "mount paths cannot contain a comma"
  else if String.contains source '\000' || String.contains destination '\000' then
    Error "mount paths cannot contain NUL"
  else Ok (match runtime with
    | Docker -> Printf.sprintf "type=bind,src=%s,dst=%s,readonly" source destination
    | Apple_container -> Printf.sprintf "type=bind,source=%s,target=%s,readonly" source destination)

let create_arguments package ~name ~instance_id ~state_owner ~scope ~image ~package_mount ~mounts ~state_mounts =
  let common = ["--name"; name; "--label"; instance_label ^ "=" ^ instance_id]
    @ (match state_owner with
       | None -> []
       | Some owner -> ["--label"; state_owner_label ^ "=" ^ owner])
    @ (match scope with
       | None -> []
       | Some scope -> ["--label"; scope_label ^ "=" ^ scope]) in
  let controls = match package.runtime with
    | Docker ->
        let memory = Int64.to_string package.resources.memory_bytes in
        ["container"; "create"; "--pull"; "never"] @ common @
        ["--cpus"; Printf.sprintf "%.9f" package.resources.cpus;
         "--memory"; memory; "--memory-swap"; memory] @
        (match package.resources.pids with
         | Some pids -> ["--pids-limit"; string_of_int pids]
         | None -> []) @
        ["--network"; "none"; "--read-only"; "--cap-drop"; "ALL";
         "--security-opt"; "no-new-privileges"; "--log-driver"; "none"]
    | Apple_container ->
        ["create"] @ common @
        ["--cpus"; string_of_int (int_of_float package.resources.cpus);
         "--memory"; Int64.to_string (Int64.div package.resources.memory_bytes 1_048_576L) ^ "M";
         "--network"; "none"; "--no-dns"; "--read-only"; "--cap-drop"; "ALL"] in
  controls @ ["--interactive"; "--workdir"; "/addon"; "--mount"; package_mount]
  @ mounts @ state_mounts @ ["--"; image] @ package.command

let start_arguments runtime id = match runtime with
  | Docker -> ["container"; "start"; "--attach"; "--interactive"; id]
  | Apple_container -> ["start"; "--attach"; "--interactive"; id]
let inspect_arguments runtime id = match runtime with
  | Docker -> ["container"; "inspect"; id]
  | Apple_container -> ["inspect"; id]
let remove_arguments runtime id = match runtime with
  | Docker -> ["container"; "rm"; "--force"; "--volumes"; id]
  | Apple_container -> ["delete"; "--force"; id]
let list_arguments runtime lookup = match runtime with
  | Docker ->
      let filter = match lookup with Name name -> "name=^/" ^ name ^ "$" | Id id -> "id=" ^ id in
      ["container"; "ls"; "--all"; "--no-trunc"; "--filter"; filter; "--format"; "{{json .ID}}"]
  | Apple_container -> ["list"; "--all"; "--format"; "json"]

let parse raw = try Ok (Yojson.Safe.from_string raw) with Yojson.Json_error detail -> Error detail

let scoped_list_arguments runtime scope = match runtime with
  | Docker ->
      ["container"; "ls"; "--all"; "--no-trunc"; "--filter"; "label=" ^ scope_label ^ "=" ^ scope;
       "--format"; "{{json .ID}}"]
  | Apple_container -> ["list"; "--all"; "--format"; "json"]
let member key = function `Assoc fields -> List.assoc_opt key fields | _ -> None
let rec path keys value = match keys with
  | [] -> Some value
  | key :: rest -> Option.bind (member key value) (path rest)
let int64_json = function
  | `Int value -> Some (Int64.of_int value)
  | `Intlit value -> Int64.of_string_opt value
  | _ -> None
let integer keys value = Option.bind (path keys value) int64_json
let one raw =
  let* value = parse raw in
  match value with `List [entry] -> Ok entry | _ -> Error "expected one engine inspection result"

let listed_id runtime lookup raw = match runtime with
  | Docker ->
      if String.trim raw = "" then Ok None else
      let* value = parse raw in
      (match value with
       | `String id when valid_id id -> Ok (Some id)
       | _ -> Error "unexpected container identity")
  | Apple_container ->
      let wanted = match lookup with Name value | Id value -> value in
      let* value = parse raw in
      (match value with
       | `List entries ->
           let* ids = List.fold_left (fun result entry ->
             let* ids = result in
             match member "id" entry, path ["configuration"; "id"] entry with
             | Some (`String id), Some (`String configured) when String.equal id configured -> Ok (id :: ids)
             | _ -> Error "container list has an incomplete identity") (Ok []) entries in
           (match List.filter (String.equal wanted) ids with
            | [] -> Ok None | [id] -> Ok (Some id)
            | _ -> Error "container list has duplicate identities")
       | _ -> Error "expected an Apple container list")

let verify_container runtime ~name ~resources ~image raw =
  let* entry = one raw in
  match runtime, image with
  | Docker, Docker_image_id expected_image ->
      (match member "Id" entry, member "Name" entry, member "HostConfig" entry with
       | Some (`String id), Some (`String actual), Some host
         when valid_id id && String.equal actual ("/" ^ name) ->
           let cpus = Int64.of_float (Float.round (resources.cpus *. 1_000_000_000.)) in
           if integer ["NanoCpus"] host <> Some cpus
              || integer ["Memory"] host <> Some resources.memory_bytes
              || integer ["MemorySwap"] host <> Some resources.memory_bytes
              || integer ["PidsLimit"] host <> Option.map Int64.of_int resources.pids
           then Error "Docker did not apply requested CPU, memory, swap and PID limits"
           else if member "Image" entry <> Some (`String expected_image)
           then Error "Docker container image ID differs from the inspected local image"
           else Ok id
       | _ -> Error "container identity or resource settings are absent")
  | Apple_container, Apple_manifest_digest expected ->
      (match member "id" entry, member "configuration" entry with
       | Some (`String id), Some config when String.equal id name
           && path ["id"] config = Some (`String id) ->
           if integer ["resources"; "cpus"] config <> Some (Int64.of_float resources.cpus)
              || integer ["resources"; "memoryInBytes"] config <> Some resources.memory_bytes
           then Error "Apple container did not apply requested vCPU and memory limits"
           else if path ["readOnly"] config <> Some (`Bool true)
              || path ["networks"] config <> Some (`List [])
              || path ["capAdd"] config <> Some (`List [])
              || path ["capDrop"] config <> Some (`List [`String "ALL"])
              || path ["publishedPorts"] config <> Some (`List [])
              || path ["publishedSockets"] config <> Some (`List [])
           then Error "Apple container did not apply read-only, capability and network isolation"
           else (match path ["image"; "descriptor"; "digest"] config with
             | Some (`String actual) when String.equal actual expected -> Ok id
             | _ -> Error "Apple container image digest differs from the inspected local image")
       | _ -> Error "Apple container identity or resource settings are absent")
  | Docker, Apple_manifest_digest _ | Apple_container, Docker_image_id _ ->
      Error "image identity belongs to a different container runtime"

(* A blank label names nobody, the same as an absent one. It is read as absent
   here so that a record naming the holder never carries a blank, which the
   record's own decoder refuses. *)
let label_value labels key = match Option.bind labels (member key) with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (if String.trim value = "" then None else Some value)
  | Some _ -> Error ("label " ^ key ^ " is not text")

let held_of_inspect runtime raw =
  let* entry = one raw in
  match runtime with
  | Docker ->
      (match member "Id" entry, member "Name" entry with
       | Some (`String id), Some (`String name)
         when valid_id id && String.length name > 1 && name.[0] = '/' ->
           let labels = path ["Config"; "Labels"] entry in
           let* instance = label_value labels instance_label in
           let* state_owner = label_value labels state_owner_label in
           Ok { container_id = id; name = String.sub name 1 (String.length name - 1);
                instance; state_owner }
       | _ -> Error "container identity or name is absent")
  | Apple_container ->
      (match member "id" entry, path ["configuration"; "id"] entry with
       | Some (`String id), Some (`String configured) when String.equal id configured ->
           let labels = path ["configuration"; "labels"] entry in
           let* instance = label_value labels instance_label in
           let* state_owner = label_value labels state_owner_label in
           Ok { container_id = id; name = id; instance; state_owner }
       | _ -> Error "container identity or name is absent")

(* Docker lists one JSON string per line and filters by label itself. The
   Apple runtime lists every container, so the label is filtered here. *)
let listed_scoped_ids runtime ~scope raw = match runtime with
  | Docker ->
      let lines = String.split_on_char '\n' raw |> List.filter (fun line -> String.trim line <> "") in
      List.fold_left (fun result line ->
        let* ids = result in
        let* value = parse line in
        match value with
        | `String id when valid_id id -> Ok (id :: ids)
        | _ -> Error "unexpected container identity") (Ok []) lines
      |> Result.map List.rev
  | Apple_container ->
      let* value = parse raw in
      (match value with
       | `List entries ->
           List.fold_left (fun result entry ->
             let* ids = result in
             match member "id" entry, path ["configuration"; "id"] entry with
             | Some (`String id), Some (`String configured) when String.equal id configured ->
                 let* labelled = label_value (path ["configuration"; "labels"] entry) scope_label in
                 Ok (if labelled = Some scope then id :: ids else ids)
             | _ -> Error "container list has an incomplete identity") (Ok []) entries
           |> Result.map List.rev
       | _ -> Error "expected an Apple container list")

(* The identity command is the same structural probe for reachability: it
   either exits 0 with an identity or it does not. Neither outcome is read out
   of an error message. *)
let info_arguments runtime = match runtime with
  | Docker -> ["info"; "--format"; "{{.ID}}"]
  | Apple_container -> ["system"; "status"; "--format"; "json"]

let max_engine_identity_bytes = 256

let engine_of_info runtime raw : (Lane_addon_lifecycle.engine, Lane_addon_lifecycle.engine_fault) result =
  let unreadable detail = Error (Lane_addon_lifecycle.Identity_unreadable detail) in
  match runtime with
  | Docker ->
      let id = String.trim raw in
      if id = "" then unreadable "engine reported no ID"
      else if String.length id > max_engine_identity_bytes then unreadable "engine ID is too long"
      else if String.exists (fun c -> Char.code c <= 32 || Char.code c = 127) id then
        unreadable "engine ID contains whitespace or control characters"
      else Ok (Lane_addon_lifecycle.Docker_engine id)
  | Apple_container ->
      (match parse raw with
       | Error detail -> unreadable detail
       | Ok value ->
           (match member "status" value, member "appRoot" value with
            | Some (`String "running"), Some (`String root)
              when String.trim root <> "" && not (Filename.is_relative root) ->
                Ok (Lane_addon_lifecycle.Apple_app_root root)
            | Some (`String "running"), _ -> unreadable "Apple container service reported no application root"
            | Some (`String status), _ ->
                Error (Lane_addon_lifecycle.Unreachable ("Apple container service status is " ^ status))
            | _, _ -> unreadable "Apple container service reported no status"))

let image_arguments runtime image = match runtime with
  | Docker -> ["image"; "inspect"; "--format"; "{{.Id}}"; image]
  | Apple_container -> ["image"; "inspect"; image]
let image_of_inspect runtime raw =
  let sha256 value = String.length value = 71
    && String.sub value 0 7 = "sha256:" && valid_id (String.sub value 7 64) in
  match runtime with
  | Docker -> let value = String.trim raw in
      if sha256 value then Ok (Docker_image_id value)
      else Error "local Docker image has no SHA-256 image ID"
  | Apple_container ->
      let* entry = one raw in
      (match path ["configuration"; "descriptor"; "digest"] entry with
       | Some (`String digest) when sha256 digest -> Ok (Apple_manifest_digest digest)
       | _ -> Error "local Apple image has no SHA-256 descriptor")

let volume_list_arguments runtime name = match runtime with
  | Docker -> ["volume"; "ls"; "--filter"; "name=^" ^ name ^ "$"; "--format"; "{{json .Name}}"]
  | Apple_container -> ["volume"; "list"; "--format"; "json"]
let listed_volume runtime ~name raw = match runtime with
  | Docker -> if String.trim raw = "" then Ok false else
      let* value = parse raw in
      (match value with `String actual when String.equal actual name -> Ok true
       | _ -> Error "ambiguous persistent state volume identity")
  | Apple_container ->
      let* value = parse raw in
      (match value with
       | `List entries ->
           let* names = List.fold_left (fun result entry ->
             let* names = result in
             match member "id" entry, path ["configuration"; "name"] entry with
             | Some (`String name), Some (`String configured) when String.equal name configured -> Ok (name :: names)
             | _ -> Error "volume list has an incomplete identity") (Ok []) entries in
           (match List.filter (String.equal name) names with
            | [] -> Ok false | [_] -> Ok true | _ -> Error "ambiguous persistent state volume identity")
       | _ -> Error "expected an Apple volume list")
let verify_volume runtime ~name ~owner raw =
  let* entry = one raw in
  let actual, labels = match runtime with
    | Docker -> member "Name" entry, member "Labels" entry
    | Apple_container -> member "id" entry, path ["configuration"; "labels"] entry in
  if actual = Some (`String name)
     && (match runtime with Docker -> true | Apple_container -> path ["configuration"; "name"] entry = Some (`String name))
     && Option.bind labels (member state_owner_label) = Some (`String owner)
  then Ok () else Error "persistent state volume belongs to a different owner"
let state_mount runtime name = match runtime with
  | Docker -> "type=volume,src=" ^ name ^ ",dst=/state,volume-nocopy"
  | Apple_container -> "type=volume,source=" ^ name ^ ",target=/state"
