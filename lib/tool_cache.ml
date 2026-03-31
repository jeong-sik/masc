(** Cache Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    6 tools: cache_set, cache_get, cache_delete, cache_list, cache_clear, cache_stats
*)

open Tool_args

(** Tool handler context *)
type context = {
  config: Room.config;
}

(** Tool result type *)
type result = bool * string

(** {1 Individual Handlers} *)

let handle_cache_set ctx args : result =
  let key = get_string args "key" "" in
  let value = get_string args "value" "" in
  let ttl_seconds = get_int_opt args "ttl_seconds" in
  let tags = get_string_list args "tags" in
  match Cache_eio.set ctx.config ~key ~value ?ttl_seconds ~tags () with
  | Ok entry ->
      (true, Yojson.Safe.pretty_to_string (Cache_eio.entry_to_json entry))
  | Error e ->
      (false, Printf.sprintf "❌ Cache set failed: %s" e)

let handle_cache_get ctx args : result =
  let key = get_string args "key" "" in
  match Cache_eio.get ctx.config ~key with
  | Ok (Some entry) ->
      (true, Yojson.Safe.pretty_to_string (`Assoc [
        ("hit", `Bool true);
        ("entry", Cache_eio.entry_to_json entry);
      ]))
  | Ok None ->
      (false, Yojson.Safe.pretty_to_string (`Assoc [
        ("hit", `Bool false);
        ("key", `String key);
        ("error", `String "cache entry not found");
      ]))
  | Error e ->
      (false, Printf.sprintf "❌ Cache get failed: %s" e)

let handle_cache_delete ctx args : result =
  let key = get_string args "key" "" in
  match Cache_eio.delete ctx.config ~key with
  | Ok removed ->
      let json = `Assoc [
        ("removed", `Bool removed);
        ("key", `String key);
      ] in
      (true, Yojson.Safe.pretty_to_string json)
  | Error e ->
      (false, Printf.sprintf "❌ Cache delete failed: %s" e)

let handle_cache_list ctx args : result =
  let tag = get_string_opt args "tag" in
  let entries = Cache_eio.list ctx.config ?tag () in
  let json = `Assoc [
    ("count", `Int (List.length entries));
    ("entries", `List (List.map Cache_eio.entry_to_json entries));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

let handle_cache_clear ctx _args : result =
  match Cache_eio.clear ctx.config with
  | Ok count ->
      (true, Printf.sprintf "Cleared %d cache entries" count)
  | Error e ->
      (false, Printf.sprintf "❌ Cache clear failed: %s" e)

let handle_cache_stats ctx _args : result =
  match Cache_eio.stats ctx.config with
  | Ok (total, expired, size_bytes) ->
      let json = `Assoc [
        ("total_entries", `Int total);
        ("expired_entries", `Int expired);
        ("size_bytes", `Float size_bytes);
        ("size_kb", `Float (size_bytes /. 1024.0));
      ] in
      (true, Yojson.Safe.pretty_to_string json)
  | Error e ->
      (false, Printf.sprintf "❌ Cache stats failed: %s" e)

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_cache_set" -> Some (handle_cache_set ctx args)
  | "masc_cache_get" -> Some (handle_cache_get ctx args)
  | "masc_cache_delete" -> Some (handle_cache_delete ctx args)
  | "masc_cache_list" -> Some (handle_cache_list ctx args)
  | "masc_cache_clear" -> Some (handle_cache_clear ctx args)
  | "masc_cache_stats" -> Some (handle_cache_stats ctx args)
  | _ -> None

let schemas : Types.tool_schema list = [
  (* masc_cache_set *)
  {
    name = "masc_cache_set";
    description = "Store a key-value pair in shared cache with optional TTL and tags for cross-agent data sharing. \
Use when caching file contents, API responses, or expensive computations for reuse by other agents. \
Retrieve with masc_cache_get. Browse entries with masc_cache_list.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key (e.g., 'file:src/main.ts', 'jira:PK-123')");
        ]);
        ("value", `Assoc [
          ("type", `String "string");
          ("description", `String "Value to cache");
        ]);
        ("ttl_seconds", `Assoc [
          ("type", `String "integer");
          ("description", `String "Time-to-live in seconds. Omit for no expiry.");
        ]);
        ("tags", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tags for filtering (e.g., ['file', 'typescript'])");
        ]);
      ]);
      ("required", `List [`String "key"; `String "value"]);
    ];
  };

  (* masc_cache_get *)
  {
    name = "masc_cache_get";
    description = "Retrieve a cached entry by key; returns null if not found or expired. \
Use when you need data previously stored by yourself or another agent via masc_cache_set. \
If miss, check masc_cache_list to verify the key exists or re-populate with masc_cache_set.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to retrieve");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };

  (* masc_cache_delete *)
  {
    name = "masc_cache_delete";
    description = "Remove a specific cache entry by key; no error if key does not exist. \\nUse when invalidating stale data, clearing a specific key, or freeing memory. \\nFind keys first with masc_cache_list. For bulk cleanup, use masc_cache_clear instead.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to delete");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };

  (* masc_cache_list *)
  {
    name = "masc_cache_list";
    description = "List cache entries with keys, TTL remaining, and tags; optionally filter by tag. \\nUse when browsing cached data before cleanup or looking for specific entries across agents. \\nPair with masc_cache_delete for targeted removal or masc_cache_stats for aggregate health.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tag", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by tag (optional)");
        ]);
      ]);
    ];
  };

  (* masc_cache_clear *)
  {
    name = "masc_cache_clear";
    description = "Delete ALL cache entries (destructive, cannot undo). \\nUse only when resetting room state, debugging persistent cache issues, or starting fresh. \\nPrefer masc_cache_delete for targeted cleanup. Check masc_cache_stats before clearing.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* masc_cache_stats *)
  {
    name = "masc_cache_stats";
    description = "Get aggregate cache statistics: total entries, memory size, oldest/newest entry age, hit/miss ratio. \\nUse when monitoring cache health, deciding whether to clear, or debugging performance issues. \\nPair with masc_cache_list for per-entry details, masc_cache_clear for full reset.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_cache
           ~input_schema:s.input_schema
           ()))
    schemas
