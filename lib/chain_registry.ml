(** Chain Registry - Storage and retrieval for named chains

    This module provides a registry for storing and looking up chains by ID,
    enabling the ChainRef node type to reference previously registered chains.

    Features:
    - In-memory storage using Hashtbl (fast lookup)
    - Optional file-based persistence (JSON files in registry directory)
    - Thread-safe operations via Mutex
    - Support for versioning and metadata

    Usage:
    {[
      (* Register a chain *)
      Chain_registry.register chain;

      (* Look up by ID *)
      let chain = Chain_registry.lookup "my_chain_v1" in

      (* List all registered chains *)
      let all = Chain_registry.list_all () in
    ]}
*)

open Chain_types

(** Registry entry with metadata *)
type registry_entry = {
  chain : chain;
  registered_at : float;  (** Unix timestamp *)
  version : int;          (** Incremented on update *)
  description : string option;
}

(** Registry statistics *)
type registry_stats = {
  total_chains : int;
  total_nodes : int;
  oldest_chain : string option;
  newest_chain : string option;
}

(** In-memory registry storage *)
let registry : (string, registry_entry) Hashtbl.t = Hashtbl.create 64

(** Standard mutex for thread-safe operations *)
let registry_mutex = Mutex.create ()

(** Helper for mutex-protected operations *)
let with_mutex f =
  Mutex.lock registry_mutex;
  Common.protect
    ~module_name:"chain_registry"
    ~finally_label:"Mutex.unlock"
    ~finally:(fun () -> Mutex.unlock registry_mutex)
    f

(** File-based persistence directory *)
let registry_dir = ref None

(** Initialize the registry with optional file persistence *)
let init ?persist_dir () =
  registry_dir := persist_dir;
  match persist_dir with
  | Some dir ->
      (* Load existing chains from directory *)
      if Sys.file_exists dir && Sys.is_directory dir then begin
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then begin
            let path = Filename.concat dir file in
            try
              let content = In_channel.with_open_text path In_channel.input_all in
              let json = Yojson.Safe.from_string content in
              (* Prefer Chain_parser.parse_chain for optional/extended fields. *)
              let parsed =
                match Chain_parser.parse_chain json with
                | Ok chain -> Ok chain
                | Error msg ->
                    (match chain_of_yojson json with
                     | Ok chain -> Ok chain
                     | Error _ -> Error msg)
              in
              (match parsed with
               | Ok chain ->
                   Hashtbl.replace registry chain.id {
                     chain;
                     registered_at = Unix.gettimeofday ();
                     version = 1;
                     description = chain.description;
                   }
               | Error msg ->
                   Printf.eprintf "[chain_registry] Failed to parse %s: %s\n%!" path msg)
            with exn ->
              Printf.eprintf "[chain_registry] Exception loading %s: %s\n%!" path (Printexc.to_string exn)
          end
        ) files
      end
  | None -> ()

(** Register a chain in the registry *)
let register ?(description : string option) (chain : chain) : unit =
  with_mutex (fun () ->
    let version = match Hashtbl.find_opt registry chain.id with
      | Some entry -> entry.version + 1
      | None -> 1
    in
    let entry = {
      chain;
      registered_at = Unix.gettimeofday ();
      version;
      description;
    } in
    Hashtbl.replace registry chain.id entry;

    (* Persist to file if enabled *)
    match !registry_dir with
    | Some dir ->
        let path = Filename.concat dir (chain.id ^ ".json") in
        let json = chain_to_yojson chain in
        Out_channel.with_open_text path (fun oc ->
          Out_channel.output_string oc (Yojson.Safe.pretty_to_string json)
        )
    | None -> ()
  )

(** Load chain JSON files from a directory into the in-memory registry (no persistence).

    This is intended for bootstrapping "preset" chains shipped with the repo
    (e.g. data/chains/*.json) at server startup. *)
let load_from_dir (dir : string) : (int * (string * string) list) =
  if not (Sys.file_exists dir && Sys.is_directory dir) then
    (0, [ (dir, "missing_or_not_a_directory") ])
  else
    let files = Sys.readdir dir in
    let loaded = ref 0 in
    let errors = ref [] in
    Array.iter (fun file ->
      if Filename.check_suffix file ".json" then begin
        let path = Filename.concat dir file in
        try
          let content = In_channel.with_open_text path In_channel.input_all in
          let json = Yojson.Safe.from_string content in
          (* Prefer Chain_parser.parse_chain for optional/extended fields. *)
          let parsed =
            match Chain_parser.parse_chain json with
            | Ok chain -> Ok chain
            | Error msg ->
                (match chain_of_yojson json with
                 | Ok chain -> Ok chain
                 | Error _ -> Error msg)
          in
          match parsed with
          | Ok chain ->
              register chain;
              incr loaded
          | Error msg ->
              errors := (path, msg) :: !errors
        with exn ->
          errors := (path, Printexc.to_string exn) :: !errors
      end
    ) files;
    (!loaded, List.rev !errors)

(** Look up a chain by ID *)
let lookup (id : string) : chain option =
  with_mutex (fun () ->
    match Hashtbl.find_opt registry id with
    | Some entry -> Some entry.chain
    | None -> None
  )

(** Look up a chain by ID, raising Not_found if missing *)
let lookup_exn (id : string) : chain =
  match lookup id with
  | Some chain -> chain
  | None -> raise Not_found

(** Look up with full entry metadata *)
let lookup_entry (id : string) : registry_entry option =
  with_mutex (fun () ->
    Hashtbl.find_opt registry id
  )

(** Check if a chain is registered *)
let exists (id : string) : bool =
  with_mutex (fun () ->
    Hashtbl.mem registry id
  )

(** Unregister a chain by ID *)
let unregister (id : string) : bool =
  with_mutex (fun () ->
    if Hashtbl.mem registry id then begin
      Hashtbl.remove registry id;
      (* Remove file if persistence enabled *)
      (match !registry_dir with
       | Some dir ->
           let path = Filename.concat dir (id ^ ".json") in
           if Sys.file_exists path then Sys.remove path
       | None -> ());
      true
    end else
      false
  )

(** List all registered chain IDs *)
let list_ids () : string list =
  with_mutex (fun () ->
    Hashtbl.fold (fun id _ acc -> id :: acc) registry []
  )

(** List all registered chains *)
let list_all () : chain list =
  with_mutex (fun () ->
    Hashtbl.fold (fun _ entry acc -> entry.chain :: acc) registry []
  )

(** List all entries with metadata *)
let list_entries () : (string * registry_entry) list =
  with_mutex (fun () ->
    Hashtbl.fold (fun id entry acc -> (id, entry) :: acc) registry []
  )

(** Get registry statistics *)
let stats () : registry_stats =
  with_mutex (fun () ->
    let total_chains = Hashtbl.length registry in
    let total_nodes = Hashtbl.fold (fun _ entry acc ->
      acc + List.length entry.chain.nodes
    ) registry 0 in
    let oldest, newest =
      Hashtbl.fold (fun id entry (oldest, newest) ->
        let oldest' = match oldest with
          | None -> Some (id, entry.registered_at)
          | Some (_, t) when entry.registered_at < t -> Some (id, entry.registered_at)
          | _ -> oldest
        in
        let newest' = match newest with
          | None -> Some (id, entry.registered_at)
          | Some (_, t) when entry.registered_at > t -> Some (id, entry.registered_at)
          | _ -> newest
        in
        (oldest', newest')
      ) registry (None, None)
    in
    {
      total_chains;
      total_nodes;
      oldest_chain = Option.map fst oldest;
      newest_chain = Option.map fst newest;
    }
  )

(** Clear all registered chains *)
let clear () : unit =
  with_mutex (fun () ->
    Hashtbl.clear registry;
    (* Clear files if persistence enabled *)
    match !registry_dir with
    | Some dir when Sys.file_exists dir && Sys.is_directory dir ->
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then
            Sys.remove (Filename.concat dir file)
        ) files
    | _ -> ()
  )

(** Count of registered chains *)
let count () : int =
  with_mutex (fun () ->
    Hashtbl.length registry
  )

(** Export registry to JSON *)
let to_json () : Yojson.Safe.t =
  with_mutex (fun () ->
    let chains = Hashtbl.fold (fun id entry acc ->
      let entry_json = `Assoc [
        ("id", `String id);
        ("chain", chain_to_yojson entry.chain);
        ("registered_at", `Float entry.registered_at);
        ("version", `Int entry.version);
        ("description", match entry.description with
          | Some d -> `String d
          | None -> `Null);
      ] in
      entry_json :: acc
    ) registry [] in
    `List chains
  )

(** Import registry from JSON *)
let of_json (json : Yojson.Safe.t) : (int, string) result =
  with_mutex (fun () ->
    try
      let open Yojson.Safe.Util in
      let entries = to_list json in
      let count = ref 0 in
      List.iter (fun entry_json ->
        let chain_json = entry_json |> member "chain" in
        match chain_of_yojson chain_json with
        | Ok chain ->
            let description = entry_json |> member "description" |> to_string_option in
            let version = entry_json |> member "version" |> to_int_option |> Option.value ~default:1 in
            let registered_at = entry_json |> member "registered_at" |> to_float_option
              |> Option.value ~default:(Unix.gettimeofday ()) in
            Hashtbl.replace registry chain.id {
              chain;
              registered_at;
              version;
              description;
            };
            incr count
        | Error msg ->
            Printf.eprintf "[chain_registry] Failed to load entry: %s\n%!" msg
      ) entries;
      Ok !count
    with e ->
      Error (Printexc.to_string e)
  )
