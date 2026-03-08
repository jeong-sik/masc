(** Prompt Registry - Versioned template storage and management

    This module provides a registry for storing and managing prompt templates
    with versioning, variable extraction, and usage metrics tracking.

    Features:
    - In-memory storage using Hashtbl (fast lookup)
    - Optional file-based persistence (JSON files in prompts directory)
    - Thread-safe operations via Mutex
    - Automatic variable extraction from {{var}} syntax
    - Usage metrics tracking (count, avg score, last used)
    - Version support for A/B testing and rollbacks

    Usage:
    {[
      (* Register a prompt *)
      let entry = {
        id = "code-review-v2";
        template = "Review this code: {{source_code}}";
        version = "2.0";
        variables = ["source_code"];
        metrics = None;
        created_at = Unix.gettimeofday ();
        deprecated = false;
      } in
      Prompt_registry.register entry;

      (* Look up by ID *)
      let prompt = Prompt_registry.get ~id:"code-review-v2" () in

      (* Render with variables *)
      let rendered = Prompt_registry.render ~id:"code-review-v2"
        ~vars:[("source_code", "let x = 1")] () in
    ]}
*)

(** {1 Types} *)

(** Usage metrics for tracking prompt effectiveness *)
type prompt_metrics = {
  usage_count: int;      (** Number of times this prompt has been used *)
  avg_score: float;      (** Average quality score (0.0 - 1.0) *)
  last_used: float;      (** Unix timestamp of last usage *)
} [@@deriving yojson]

(** A single prompt entry in the registry *)
type prompt_entry = {
  id: string;                     (** Unique identifier *)
  template: string;               (** Prompt template with {{var}} placeholders *)
  version: string;                (** Semantic version string *)
  variables: string list;         (** Extracted variable names from template *)
  metrics: prompt_metrics option; (** Optional usage metrics *)
  created_at: float;              (** Unix timestamp of creation *)
  deprecated: bool;               (** Whether this prompt is deprecated *)
} [@@deriving yojson]

(** Registry statistics *)
type registry_stats = {
  total_prompts: int;
  active_prompts: int;
  deprecated_prompts: int;
  most_used: string option;
  avg_usage: float;
}

(** {1 Variable Extraction} *)

(** Extract variable names from a template string.
    Matches {{variable_name}} patterns. *)
let extract_variables template =
  let regex = Str.regexp "{{\\([^}]+\\)}}" in
  let rec find_all start acc =
    try
      let _ = Str.search_forward regex template start in
      let var = Str.matched_group 1 template in
      let next = Str.match_end () in
      find_all next (var :: acc)
    with Not_found -> acc
  in
  let vars = find_all 0 [] in
  (* Remove duplicates and sort alphabetically *)
  List.sort_uniq String.compare vars

(** {1 In-memory Registry Storage} *)

(** In-memory registry storage: (id, version) -> entry *)
let registry : (string, prompt_entry) Hashtbl.t = Hashtbl.create 64

(** Version index: id -> [version list] for quick version lookup *)
let version_index : (string, string list) Hashtbl.t = Hashtbl.create 64

(** Standard mutex for thread-safe operations *)
let registry_mutex = Mutex.create ()

(** Helper for mutex-protected operations *)
let with_mutex f =
  Mutex.lock registry_mutex;
  Common.protect
    ~module_name:"prompt_registry"
    ~finally_label:"Mutex.unlock"
    ~finally:(fun () -> Mutex.unlock registry_mutex)
    f

(** {1 Persistence} *)

(** File-based persistence directory *)
let prompts_dir = ref None

(** Make a storage key from id and version *)
let make_key ~id ~version = Printf.sprintf "%s@%s" id version

(** Parse a storage key back to id and version *)
let _parse_key key =
  match String.split_on_char '@' key with
  | [id; version] -> Some (id, version)
  | _ -> None

(** Initialize the registry with optional file persistence *)
let init ?persist_dir () =
  prompts_dir := persist_dir;
  match persist_dir with
  | Some dir ->
      (* Load existing prompts from directory *)
      if Sys.file_exists dir && Sys.is_directory dir then begin
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then begin
            let path = Filename.concat dir file in
            try
              let content = In_channel.with_open_text path In_channel.input_all in
              let json = Yojson.Safe.from_string content in
              match prompt_entry_of_yojson json with
              | Ok entry ->
                  let key = make_key ~id:entry.id ~version:entry.version in
                  Hashtbl.replace registry key entry;
                  (* Update version index *)
                  let versions = match Hashtbl.find_opt version_index entry.id with
                    | Some vs -> if List.mem entry.version vs then vs else entry.version :: vs
                    | None -> [entry.version]
                  in
                  Hashtbl.replace version_index entry.id versions
              | Error msg ->
                Printf.eprintf "[prompt_registry] Failed to parse %s: %s\n%!" file msg
            with exn ->
              Printf.eprintf "[prompt_registry] Failed to parse %s: %s\n%!" file (Printexc.to_string exn)
          end
        ) files
      end
  | None -> ()

(** {1 Registration and Lookup} *)

(** Register a prompt entry in the registry.
    Automatically extracts variables if not provided. *)
let register (entry : prompt_entry) : unit =
  with_mutex (fun () ->
    (* Auto-extract variables if empty *)
    let entry =
      if entry.variables = [] then
        { entry with variables = extract_variables entry.template }
      else entry
    in
    let key = make_key ~id:entry.id ~version:entry.version in
    Hashtbl.replace registry key entry;

    (* Update version index *)
    let versions = match Hashtbl.find_opt version_index entry.id with
      | Some vs -> if List.mem entry.version vs then vs else entry.version :: vs
      | None -> [entry.version]
    in
    Hashtbl.replace version_index entry.id versions;

    (* Persist to file if enabled *)
    match !prompts_dir with
    | Some dir ->
        if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
        let filename = Printf.sprintf "%s_%s.json" entry.id entry.version in
        let path = Filename.concat dir filename in
        let json = prompt_entry_to_yojson entry in
        Out_channel.with_open_text path (fun oc ->
          Out_channel.output_string oc (Yojson.Safe.pretty_to_string json)
        )
    | None -> ()
  )

(** Get a prompt entry by ID and optional version.
    If version is not specified, returns the latest non-deprecated version. *)
let get ~id ?version () : prompt_entry option =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        Hashtbl.find_opt registry key
    | None ->
        (* Find latest non-deprecated version *)
        match Hashtbl.find_opt version_index id with
        | None -> None
        | Some versions ->
            (* Sort versions descending and find first non-deprecated *)
            let sorted = List.sort (fun a b -> String.compare b a) versions in
            List.find_map (fun v ->
              let key = make_key ~id ~version:v in
              match Hashtbl.find_opt registry key with
              | Some entry when not entry.deprecated -> Some entry
              | _ -> None
            ) sorted
  )

(** Get all versions of a prompt by ID *)
let get_versions ~id () : prompt_entry list =
  with_mutex (fun () ->
    match Hashtbl.find_opt version_index id with
    | None -> []
    | Some versions ->
        List.filter_map (fun v ->
          let key = make_key ~id ~version:v in
          Hashtbl.find_opt registry key
        ) versions
  )

(** List all registered prompt entries *)
let list_all () : prompt_entry list =
  with_mutex (fun () ->
    Hashtbl.fold (fun _ entry acc -> entry :: acc) registry []
  )

(** List all prompt IDs (unique, without versions) *)
let list_ids () : string list =
  with_mutex (fun () ->
    Hashtbl.fold (fun id _ acc -> id :: acc) version_index []
  )

(** Check if a prompt exists *)
let exists ~id ?version () : bool =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        Hashtbl.mem registry key
    | None ->
        Hashtbl.mem version_index id
  )

(** Unregister a prompt entry *)
let unregister ~id ?version () : bool =
  with_mutex (fun () ->
    match version with
    | Some v ->
        let key = make_key ~id ~version:v in
        if Hashtbl.mem registry key then begin
          Hashtbl.remove registry key;
          (* Update version index *)
          (match Hashtbl.find_opt version_index id with
           | Some vs ->
               let new_vs = List.filter (fun ver -> ver <> v) vs in
               if new_vs = [] then Hashtbl.remove version_index id
               else Hashtbl.replace version_index id new_vs
           | None -> ());
          (* Remove file if persistence enabled *)
          (match !prompts_dir with
           | Some dir ->
               let filename = Printf.sprintf "%s_%s.json" id v in
               let path = Filename.concat dir filename in
               if Sys.file_exists path then Sys.remove path
           | None -> ());
          true
        end else false
    | None ->
        (* Remove all versions *)
        match Hashtbl.find_opt version_index id with
        | None -> false
        | Some versions ->
            List.iter (fun v ->
              let key = make_key ~id ~version:v in
              Hashtbl.remove registry key;
              (match !prompts_dir with
               | Some dir ->
                   let filename = Printf.sprintf "%s_%s.json" id v in
                   let path = Filename.concat dir filename in
                   if Sys.file_exists path then Sys.remove path
               | None -> ())
            ) versions;
            Hashtbl.remove version_index id;
            true
  )

(** Mark a prompt as deprecated *)
let deprecate ~id ~version () : bool =
  with_mutex (fun () ->
    let key = make_key ~id ~version in
    match Hashtbl.find_opt registry key with
    | Some entry ->
        let updated = { entry with deprecated = true } in
        Hashtbl.replace registry key updated;
        true
    | None -> false
  )

(** {1 Metrics} *)

(** Update usage metrics after a prompt is used *)
let update_metrics ~id ~version ~score () : unit =
  with_mutex (fun () ->
    let key = make_key ~id ~version in
    match Hashtbl.find_opt registry key with
    | Some entry ->
        let now = Unix.gettimeofday () in
        let new_metrics = match entry.metrics with
          | None ->
              { usage_count = 1; avg_score = score; last_used = now }
          | Some m ->
              let new_count = m.usage_count + 1 in
              let new_avg = (m.avg_score *. float_of_int m.usage_count +. score)
                            /. float_of_int new_count in
              { usage_count = new_count; avg_score = new_avg; last_used = now }
        in
        let updated = { entry with metrics = Some new_metrics } in
        Hashtbl.replace registry key updated;
        (* Persist updated metrics if enabled *)
        (match !prompts_dir with
         | Some dir ->
             let filename = Printf.sprintf "%s_%s.json" id version in
             let path = Filename.concat dir filename in
             let json = prompt_entry_to_yojson updated in
             Out_channel.with_open_text path (fun oc ->
               Out_channel.output_string oc (Yojson.Safe.pretty_to_string json)
             )
         | None -> ())
    | None -> ()
  )

(** {1 Template Rendering} *)

(** Render a prompt template with the given variables *)
let render_template ~template ~vars () : (string, string) result =
  try
    let result = ref template in
    List.iter (fun (name, value) ->
      let pattern = Printf.sprintf "{{%s}}" name in
      result := Str.global_replace (Str.regexp_string pattern) value !result
    ) vars;
    (* Check for unresolved variables anywhere in the result *)
    let regex = Str.regexp "{{[^}]+}}" in
    let has_unresolved =
      try ignore (Str.search_forward regex !result 0); true
      with Not_found -> false
    in
    if has_unresolved then
      Error "Unresolved variables in template"
    else
      Ok !result
  with e ->
    Error (Printf.sprintf "Render error: %s" (Printexc.to_string e))

(** Render a registered prompt by ID with the given variables *)
let render ~id ?version ~vars () : (string, string) result =
  match get ~id ?version () with
  | None -> Error (Printf.sprintf "Prompt '%s' not found" id)
  | Some entry -> render_template ~template:entry.template ~vars ()

(** {1 Statistics} *)

(** Get registry statistics *)
let stats () : registry_stats =
  with_mutex (fun () ->
    let all_entries = Hashtbl.fold (fun _ entry acc -> entry :: acc) registry [] in
    let total = List.length all_entries in
    let active = List.length (List.filter (fun e -> not e.deprecated) all_entries) in
    let deprecated = total - active in

    let most_used =
      List.fold_left (fun acc entry ->
        match entry.metrics with
        | None -> acc
        | Some m ->
            match acc with
            | None -> Some (entry.id, m.usage_count)
            | Some (_, count) when m.usage_count > count -> Some (entry.id, m.usage_count)
            | _ -> acc
      ) None all_entries
      |> Option.map fst
    in

    let total_usage =
      List.fold_left (fun acc entry ->
        match entry.metrics with
        | None -> acc
        | Some m -> acc + m.usage_count
      ) 0 all_entries
    in
    let avg_usage = if total > 0 then float_of_int total_usage /. float_of_int total else 0.0 in

    { total_prompts = total;
      active_prompts = active;
      deprecated_prompts = deprecated;
      most_used;
      avg_usage }
  )

(** {1 Utility Functions} *)

(** Clear all registered prompts *)
let clear () : unit =
  with_mutex (fun () ->
    Hashtbl.clear registry;
    Hashtbl.clear version_index;
    (* Clear files if persistence enabled *)
    match !prompts_dir with
    | Some dir when Sys.file_exists dir && Sys.is_directory dir ->
        let files = Sys.readdir dir in
        Array.iter (fun file ->
          if Filename.check_suffix file ".json" then
            Sys.remove (Filename.concat dir file)
        ) files
    | _ -> ()
  )

(** Count of registered prompts (all versions) *)
let count () : int =
  with_mutex (fun () -> Hashtbl.length registry)

(** Count of unique prompt IDs *)
let count_unique () : int =
  with_mutex (fun () -> Hashtbl.length version_index)

(** Export registry to JSON *)
let to_json () : Yojson.Safe.t =
  with_mutex (fun () ->
    let entries = Hashtbl.fold (fun _ entry acc ->
      prompt_entry_to_yojson entry :: acc
    ) registry [] in
    `List entries
  )

(** Import registry from JSON *)
let of_json (json : Yojson.Safe.t) : (int, string) result =
  try
    let open Yojson.Safe.Util in
    let entries = to_list json in
    let count = ref 0 in
    List.iter (fun entry_json ->
      match prompt_entry_of_yojson entry_json with
      | Ok entry ->
          register entry;
          incr count
      | Error _ -> ()  (* Skip invalid entries *)
    ) entries;
    Ok !count
  with e ->
    Error (Printexc.to_string e)
