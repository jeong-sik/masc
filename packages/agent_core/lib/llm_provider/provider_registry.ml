(** Extensible provider registry with capability-aware queries.

    @since 0.69.0 *)

type provider_defaults =
  { kind : Provider_config.provider_kind
  ; base_url : string
  ; api_key_env : string
  ; request_path : string
  }

type entry =
  { name : string
  ; defaults : provider_defaults
  ; max_context : int option
  ; capabilities : Capabilities.capabilities
  ; is_available : unit -> bool
  }

type mutex =
  | Stdlib_mu of Mutex.t
  | Eio_mu of Eio.Mutex.t

type t =
  { mu : mutex
  ; entries : (string, entry) Hashtbl.t
  }

let create () = { mu = Eio_mu (Eio.Mutex.create ()); entries = Hashtbl.create 8 }
let create_sync () = { mu = Stdlib_mu (Mutex.create ()); entries = Hashtbl.create 8 }

let with_lock t f =
  match t.mu with
  | Stdlib_mu mu ->
    Mutex.lock mu;
    Fun.protect f ~finally:(fun () -> Mutex.unlock mu)
  | Eio_mu mu -> Eio.Mutex.use_rw ~protect:true mu f
;;

let register' t entry = Hashtbl.replace t.entries entry.name entry
let register t entry = with_lock t (fun () -> register' t entry)
let unregister t name = with_lock t (fun () -> Hashtbl.remove t.entries name)
let find t name = with_lock t (fun () -> Hashtbl.find_opt t.entries name)
let all t = with_lock t (fun () -> Hashtbl.fold (fun _k v acc -> v :: acc) t.entries [])
let available t = all t |> List.filter (fun e -> e.is_available ())
let find_capable t pred = all t |> List.filter (fun e -> pred e.capabilities)

(* ── Default registry ─────────────────────────────────── *)

let has_api_key env_name =
  env_name = ""
  ||
  match Cli_common_env.get env_name with
  | Some value -> String.trim value <> ""
  | None -> false
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

let catalog_auth_available (entry : Provider_catalog.entry) =
  match entry.auth with
  | Provider_catalog.Api_key_env env | Provider_catalog.Setup_token_env env ->
    has_api_key env
  | Provider_catalog.No_auth -> true
;;

let catalog_entry_available = catalog_auth_available

let register_catalog_entry t (entry : Provider_catalog.entry) =
  with_lock t (fun () ->
    let max_context =
      match entry.max_context with
      | Some _ as declared -> declared
      | None -> entry.capabilities.Capabilities.max_context_tokens
    in
    let defaults : provider_defaults =
      { kind = entry.kind
      ; base_url = entry.base_url
      ; api_key_env = entry.api_key_env
      ; request_path = entry.request_path
      }
    in
    if String.trim entry.id = ""
    then invalid_arg "Provider_registry.register_catalog_entry: empty provider id"
    else
      Hashtbl.replace
        t.entries
        entry.id
        { name = entry.id
        ; defaults
        ; max_context
        ; capabilities = entry.capabilities
        ; is_available = (fun () -> catalog_entry_available entry)
        })
;;

let overlay_provider_catalog t =
  match Provider_catalog.global () with
  | None -> ()
  | Some catalog ->
    List.iter (register_catalog_entry t) (Provider_catalog.entries catalog)
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
let refresh_llama_endpoints ~sw ~net ~endpoints =
  match endpoints with
  | [] -> Error No_endpoints_declared
  | _ ->
    let statuses = Discovery.refresh_and_sync ~sw ~net ~endpoints in
    let healthy_endpoints =
      List.filter_map
        (fun (status : Discovery.endpoint_status) ->
           if status.healthy
           then
             Some
               (Discovery.endpoint
                  ~protocol:status.protocol
                  ~capabilities:status.capabilities
                  status.url)
           else None)
        statuses
    in
    (match healthy_endpoints with
     | [] -> Error (No_healthy_endpoints statuses)
     | _ ->
       Atomic.set llama_endpoints_ref (Array.of_list healthy_endpoints);
       Ok statuses)
;;

(** Current active endpoint list (snapshot). *)
let active_llama_endpoints () = Array.to_list (Atomic.get llama_endpoints_ref)

let discovered_max_context () = Discovery.discovered_per_slot_context ()

let discovered_endpoint_max_context (url : string) =
  Discovery.discovered_context_for_url url
;;

let default () =
  (* The default registry uses Stdlib.Mutex because its guarded sections are
     short Hashtbl operations and the returned value still exposes the mutable
     registry API. *)
  let t = create_sync () in
  let capabilities_for_registered_label label =
    match Capabilities.capabilities_for_provider_label label with
    | Some caps -> caps
    | None ->
      invalid_arg
        (Printf.sprintf
           "Provider_registry.default: no capabilities for registered provider %S"
           label)
  in
  let register_model_catalog_provider (entry : Model_catalog.provider_entry) =
    let capability_label =
      Option.value entry.capabilities_base ~default:entry.id
      |> String.lowercase_ascii
      |> String.trim
    in
    let caps = capabilities_for_registered_label capability_label in
    let defaults : provider_defaults =
      { kind = entry.kind
      ; base_url = Model_provider_catalog.resolved_base_url entry
      ; api_key_env = entry.api_key_env
      ; request_path = entry.request_path
      }
    in
    register
      t
      { name = entry.id
      ; defaults
      ; max_context = caps.Capabilities.max_context_tokens
      ; capabilities = caps
      ; is_available = (fun () -> has_api_key defaults.api_key_env)
      }
  in
  (match Model_catalog.global () with
   | None ->
     invalid_arg "Provider_registry.default: embedded provider catalog is unavailable"
   | Some catalog ->
     List.iter register_model_catalog_provider (Model_catalog.provider_entries catalog));
  overlay_provider_catalog t;
  t
;;

let provider_name_of_config (config : Provider_config.t) =
  Provider_config.string_of_provider_kind config.kind
;;
