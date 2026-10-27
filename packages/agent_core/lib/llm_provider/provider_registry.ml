(** Extensible provider registry with capability-aware queries.

    @since 0.69.0 *)

type provider_defaults = Provider_registry_state.provider_defaults =
  { kind : Provider_config.provider_kind
  ; base_url : string
  ; request_path : string
  ; requires_api_key : bool
  }

type entry = Provider_registry_state.entry =
  { name : string
  ; defaults : provider_defaults
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; is_available : unit -> bool
  }

type t = Provider_registry_state.t Atomic.t

let create () = Atomic.make_contended Provider_registry_state.empty

let rec apply t event =
  let current = Atomic.get t in
  let next = Provider_registry_state.apply current event in
  if not (Atomic.compare_and_set t current next) then apply t event
;;

let register t entry = apply t (Provider_registry_state.Register entry)
let unregister t name = apply t (Provider_registry_state.Unregister name)
let find t name = Provider_registry_state.find name (Atomic.get t)
let all t = Provider_registry_state.all (Atomic.get t)
let available t = all t |> List.filter (fun e -> e.is_available ())
let find_capable t pred = all t |> List.filter (fun e -> pred e.capabilities)

(* ── Default registry ─────────────────────────────────── *)

let authentication_available = function
  | Provider_declarations.No_auth | Caller_api_key -> true
  | Api_key_env env | Setup_token_env env ->
    (match Cli_common_env.get env with
     | Some value -> String.trim value <> ""
     | None -> false)
;;

let path_entries ?path () =
  match path with
  | Some value -> Cli_common_env.split_on_char_trim ':' value
  | None ->
    (match Cli_common_env.get "PATH" with
     | Some value -> Cli_common_env.split_on_char_trim ':' value
     | None -> [])
;;

let command_candidates ~name =
  if Filename.check_suffix name ".exe" then [ name ] else [ name; name ^ ".exe" ]
;;

let safe_file_exists path =
  try Sys.file_exists path with
  | Sys_error _ | Unix.Unix_error _ -> false
;;

let safe_is_directory path =
  try Sys.is_directory path with
  | Sys_error _ | Unix.Unix_error _ -> false
;;

let is_runnable_path path = safe_file_exists path && not (safe_is_directory path)

let command_in_path ?path name =
  path_entries ?path ()
  |> List.exists (fun dir ->
    command_candidates ~name
    |> List.exists (fun candidate -> is_runnable_path (Filename.concat dir candidate)))
;;

(** Mutable endpoint list, protected by atomic snapshot swap.
    Updated by [refresh_llama_endpoints]. *)
let llama_endpoints_ref : Discovery.endpoint array Atomic.t = Atomic.make [||]

(** Round-robin counter for distributing calls across endpoints. *)
let llama_rr_counter = Atomic.make 0

(** Pick the next llama endpoint via round-robin.
    Reads the current endpoint snapshot atomically.
    Called by downstream callers when resolving "llama:*" provider. *)
let next_llama_endpoint () =
  let endpoints = Atomic.get llama_endpoints_ref in
  let n = Array.length endpoints in
  if n = 0
  then None
  else (
    let idx = Atomic.fetch_and_add llama_rr_counter 1 mod n in
    Some endpoints.(idx))
;;

(** Peek at the current llama endpoint without advancing the round-robin.
    Used by context resolution to match the endpoint that will serve
    the next request, without side effects. *)
let current_llama_endpoint () =
  let endpoints = Atomic.get llama_endpoints_ref in
  let n = Array.length endpoints in
  if n = 0
  then None
  else (
    let idx = Atomic.get llama_rr_counter mod n in
    Some endpoints.(idx))
;;

type endpoint_refresh_error =
  | No_endpoints_declared
  | No_healthy_endpoints of Discovery.endpoint_status list

(** Refresh from typed endpoint declarations only. Discovery never scans ports
    or invents a fallback declaration. The previous active snapshot is retained
    when no declaration is supplied or every declared endpoint is unhealthy. *)
let refresh_llama_endpoints ?clock ~sw ~net ~endpoints () =
  match endpoints with
  | [] -> Error No_endpoints_declared
  | _ ->
    let statuses = Discovery.refresh_and_sync ?clock ~sw ~net ~endpoints () in
    let healthy_endpoints =
      List.filter_map
        (fun ((declared : Discovery.endpoint), (status : Discovery.endpoint_status)) ->
           if status.healthy
           then
             Some
               (Discovery.endpoint
                  ?discovery_timeout_s:declared.discovery_timeout_s
                  ~protocol:status.protocol
                  ~capabilities:status.capabilities
                  status.url)
           else None)
        (List.combine endpoints statuses)
    in
    (match healthy_endpoints with
     | [] -> Error (No_healthy_endpoints statuses)
     | _ ->
       Atomic.set llama_endpoints_ref (Array.of_list healthy_endpoints);
       Ok statuses)
;;

(** Current active endpoint list (snapshot). *)
let active_llama_endpoints () = Array.to_list (Atomic.get llama_endpoints_ref)

let of_declarations declarations =
  let registry = create () in
  List.iter (fun (entry : Provider_declarations.entry) ->
    register registry
      { name=entry.id;
        defaults={kind=entry.kind;base_url=entry.base_url;request_path=entry.request_path;
          requires_api_key=Provider_declarations.requires_api_key entry.authentication};
        max_context=entry.max_context;capabilities=entry.capabilities;
        is_available=(fun () -> authentication_available entry.authentication) })
    (Provider_declarations.entries declarations);
  registry
;;

let default () = of_declarations (Provider_declarations.current ())
;;

let provider_name_of_config (config : Provider_config.t) =
  Provider_config.string_of_provider_kind config.kind
;;
