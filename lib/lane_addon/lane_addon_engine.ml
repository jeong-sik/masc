open Lane_addon_types

type mount = { source : string; destination : string }
type lookup = Name of string | Id of string

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

let create_arguments package ~name ~instance_id ~image ~package_mount ~mounts ~state_mounts =
  let common = ["--name"; name; "--label"; "masc.lane.instance=" ^ instance_id] in
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

let verify_container runtime ~name ~resources ~image_digest raw =
  let* entry = one raw in
  match runtime with
  | Docker ->
      (match member "Id" entry, member "Name" entry, member "HostConfig" entry with
       | Some (`String id), Some (`String actual), Some host
         when valid_id id && String.equal actual ("/" ^ name) ->
           let cpus = Int64.of_float (Float.round (resources.cpus *. 1_000_000_000.)) in
           if integer ["NanoCpus"] host <> Some cpus
              || integer ["Memory"] host <> Some resources.memory_bytes
              || integer ["MemorySwap"] host <> Some resources.memory_bytes
              || integer ["PidsLimit"] host <> Option.map Int64.of_int resources.pids
           then Error "Docker did not apply requested CPU, memory, swap and PID limits"
           else Ok id
       | _ -> Error "container identity or resource settings are absent")
  | Apple_container ->
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
           else (match image_digest, path ["image"; "descriptor"; "digest"] config with
             | Some expected, Some (`String actual) when String.equal actual expected -> Ok id
             | _ -> Error "Apple container image digest differs from the inspected local image")
       | _ -> Error "Apple container identity or resource settings are absent")

let verify_owner runtime ~instance_id ~name ~id raw =
  let* entry = one raw in
  let actual, actual_name, labels = match runtime with
    | Docker -> member "Id" entry, member "Name" entry, path ["Config"; "Labels"] entry
    | Apple_container -> member "id" entry, path ["configuration"; "id"] entry,
        path ["configuration"; "labels"] entry in
  let name_matches = match name with
    | None -> true
    | Some expected -> actual_name = Some (`String (match runtime with Docker -> "/" ^ expected | Apple_container -> expected)) in
  if actual = Some (`String id) && name_matches
     && (match runtime with Docker -> true | Apple_container -> actual_name = Some (`String id))
     && Option.bind labels (member "masc.lane.instance") = Some (`String instance_id)
  then Ok ()
  else Error "container identity and masc.lane.instance label must match the persisted binding"

let image_arguments runtime image = match runtime with
  | Docker -> ["image"; "inspect"; "--format"; "{{.Id}}"; image]
  | Apple_container -> ["image"; "inspect"; image]
let image_digest runtime raw = match runtime with
  | Docker -> let value = String.trim raw in
      if value = "" then Error "empty image identity" else Ok value
  | Apple_container ->
      let* entry = one raw in
      (match path ["configuration"; "descriptor"; "digest"] entry with
       | Some (`String digest) when String.length digest = 71
          && String.sub digest 0 7 = "sha256:" && valid_id (String.sub digest 7 64) -> Ok digest
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
     && Option.bind labels (member "masc.lane.state.owner") = Some (`String owner)
  then Ok () else Error "persistent state volume belongs to a different owner"
let state_mount runtime name = match runtime with
  | Docker -> "type=volume,src=" ^ name ^ ",dst=/state,volume-nocopy"
  | Apple_container -> "type=volume,source=" ^ name ^ ",target=/state"
