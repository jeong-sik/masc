(** Mcp_server_eio_tool_profile — Tool profile, schema, annotations, and pagination

    Extracted from mcp_server_eio.ml.
    Handles tool listing, profile filtering, annotations, pagination cursors,
    and tool JSON serialization for the MCP protocol.
*)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

let instruction key =
  let value = Prompt_registry.get_prompt key in
  if String.trim value = "" then invalid_arg ("missing required MCP prompt: " ^ key)
  else value

let operator_remote_instructions () = instruction Prompt_names.mcp_operator_remote

let managed_agent_instructions () = instruction Prompt_names.mcp_managed_agent

let managed_agent_passthrough_tool_names =
  Tool_catalog_surfaces.spawned_agent_surface_tools

(* O(1) membership view of [managed_agent_passthrough_tool_names].
   Used by [tool_schemas_for_profile Managed_agent] to filter
   ~150 visible schemas per request — replaces a per-schema
   [List.mem] scan over ~20 passthrough names. *)
let managed_agent_passthrough_tool_set : (string, unit) Hashtbl.t =
  let tbl =
    Hashtbl.create (List.length managed_agent_passthrough_tool_names)
  in
  List.iter
    (fun name -> Hashtbl.replace tbl name ())
    managed_agent_passthrough_tool_names;
  tbl

module StringSet = Set_util.StringSet

let default_instructions () = instruction Prompt_names.mcp_full

let tool_schemas_for_profile ?(include_hidden = false)
    _state profile =
  let schemas =
    match profile with
    | Full ->
        let show_all = include_hidden in
        let all =
          Config.visible_tool_schemas ~include_hidden:show_all ()
        in
        let full_profile_tools =
          List.filter
            (fun (schema : Masc_domain.tool_schema) ->
              Tool_catalog.allow_direct_call schema.name
              && (show_all || Tool_catalog.is_public_mcp schema.name))
            all
        in
        full_profile_tools
    | Managed_agent ->
        let passthrough =
          Config.visible_tool_schemas ~include_hidden:true ()
          |> List.filter (fun (schema : Masc_domain.tool_schema) ->
                 Hashtbl.mem managed_agent_passthrough_tool_set schema.name
                 && Option.is_none
                      (Agent_core_tool_contract.agent_core_binding_by_name schema.name)
                 && Tool_catalog.is_visible ~include_hidden:true schema.name)
        in
        Agent_core_tool_contract.agent_core_tool_schemas @ passthrough
    | Operator_remote -> Tool_operator.remote_schemas ()
  in
  Config.validate_schemas schemas;
  schemas

let tool_allowed_in_profile state profile tool_name =
  match profile with
  | Full ->
      (* Equivalent to [List.mem tool_name (names from
         visible_tool_schemas ~include_hidden:true)]: that helper
         composes raw schemas → canonicalize → filter is_visible. The name set is
         exactly { n | n ∈ raw_all_tool_schemas.names ∧ is_visible n }.
         Two O(1) checks replace ~150 schema canonicalizations + a
         List.mem per dispatch. *)
      Config.is_raw_tool_name tool_name
      && Tool_catalog.is_visible ~include_hidden:true tool_name
      && Tool_catalog.allow_direct_call tool_name
  | Managed_agent ->
      Option.is_some (Agent_core_tool_contract.agent_core_binding_by_name tool_name)
      || (tool_schemas_for_profile state Managed_agent
          |> List.exists (fun (schema : Masc_domain.tool_schema) ->
                 String.equal schema.name tool_name))
  | Operator_remote -> List.mem tool_name (Tool_operator.remote_tool_names ())

let tool_annotations_for_profile _profile tool_name =
  let read_only =
    Keeper_tool_descriptor_resolution.capability_has Tool_capability.Read_only tool_name
  in
  let idempotent =
    Keeper_tool_descriptor_resolution.capability_has Tool_capability.Idempotent tool_name
  in
  let fields =
    [ ("readOnlyHint", `Bool read_only) ]
    @ (if idempotent then [ ("idempotentHint", `Bool true) ] else [])
  in
  if fields = [] then None else Some (`Assoc fields)

let metadata_key_present key fields =
  List.exists (fun (existing, _) -> String.equal existing key) fields
;;

let add_metadata_field_if_absent key value fields =
  if metadata_key_present key fields then fields else fields @ [ key, value ]
;;

let descriptor_metadata_fields tool_name fields =
  match Keeper_tool_descriptor_resolution.descriptor_for_tool_name tool_name with
  | None -> fields
  | Some descriptor ->
    fields
    |> add_metadata_field_if_absent "descriptorId" (`String descriptor.id)
    |> add_metadata_field_if_absent "descriptorPublicName" (`String descriptor.public_name)
    |> add_metadata_field_if_absent
         "descriptorCanonicalName"
         (`String descriptor.internal_name)
    |> add_metadata_field_if_absent
         "descriptorExecutor"
         (`String (Keeper_tool_descriptor.executor_to_string descriptor.executor))
    |> add_metadata_field_if_absent
         "descriptorBackend"
         (`String (Keeper_tool_descriptor.backend_to_string descriptor.backend))
    |> add_metadata_field_if_absent
         "descriptorSandbox"
         (`String (Keeper_tool_descriptor.sandbox_to_string descriptor.sandbox))
;;

let label_words_from_identifier ident =
  ident
  |> String.split_on_char '_'
  |> List.filter (fun chunk -> chunk <> "")
  |> List.map (fun word ->
         if String.length word = 0 then word
         else
           String.uppercase_ascii (String.sub word 0 1)
           ^ String.lowercase_ascii
               (String.sub word 1 (String.length word - 1)))

(** Human-readable tool titles now live in each tool's own
    [config/tools/<name>.toml] as the optional [title] key (RFC
    prompts-and-tool-definitions-outside-ocaml §2.2). One parse of the
    embedded tool tree, on first ask — the same idiom as
    [Tool_loading_declarations]: the files are crunched into the binary, so a
    second parse would read the same bytes to the same answer. A file that
    does not parse raises rather than answering "no title": a misplaced
    declaration and no declaration are the same answer at every call site. *)
let declared_title_table : (string, string) Hashtbl.t Lazy.t =
  lazy
    (let table = Hashtbl.create 256 in
     List.iter
       (fun path ->
          match Filename.dirname path, Filename.extension path with
          | "tools", ".toml" ->
            let name = Filename.remove_extension (Filename.basename path) in
            (match Embedded_config.read path with
             | None -> ()
             | Some contents ->
               (match Tool_definition_toml.load ~name ~contents with
                | Error message ->
                  failwith (Printf.sprintf "tool titles: %s: %s" path message)
                | Ok loaded ->
                  (match loaded.Tool_definition_toml.title with
                   | Some title -> Hashtbl.replace table name title
                   | None -> ())))
          | _, _ -> ())
       Embedded_config.file_list;
     table)

(* Three titled tools have no [config/tools] file to carry the key:
   masc_operator_snapshot, masc_operator_digest and masc_operator_action each
   declare two descriptions in OCaml, one per surface (see
   [Operator_tool_toml]). Their [custom_tool_titles] entries were exactly what
   the mechanical fallback below derives from the name, so the fallback covers
   them byte-identically. *)
let tool_title_of_name name =
  match Hashtbl.find_opt (Lazy.force declared_title_table) name with
  | Some title -> title
  | None ->
    let trimmed =
      if String.length name > 5 && String.starts_with ~prefix:"masc_" name then
        String.sub name 5 (String.length name - 5)
      else
        name
    in
    String.concat " " (label_words_from_identifier trimmed)

let maybe_assoc_field name = function
  | Some value -> [ (name, value) ]
  | None -> []

let tool_output_schema_field _ =
  (* Public MCP tools still return text-first envelopes and only some handlers
     opportunistically emit structuredContent. Advertising outputSchema before
     structuredContent is guaranteed breaks strict clients such as Anthropic/FastMCP,
     which reject the tool result as malformed. Keep outputSchema disabled until
     the call path can produce typed payloads from the handler itself. *)
  None

let tool_json_for_profile ?usage_summary profile (schema : Masc_domain.tool_schema) =
  let metadata_fields =
    Tool_catalog.metadata_to_fields schema.name
    |> descriptor_metadata_fields schema.name
  in
  let usage_fields =
    match usage_summary with
    | Some summary -> Telemetry_eio.tool_usage_fields summary schema.name
    | None -> []
  in
  (* Catalog and usage fields used to sit beside [name] and [inputSchema].
     [Tool] defines no index signature, so a strict client is entitled to
     reject them there and a later spec field could take one of the names. *)
  let meta_fields =
    Mcp_server.(meta_field ~key:tool_catalog_meta_key metadata_fields)
    @ Mcp_server.(meta_field ~key:tool_usage_meta_key usage_fields)
  in
  let base =
    [
      ("name", `String schema.name);
      ("title", `String (tool_title_of_name schema.name));
      ("description", `String schema.description);
      ("inputSchema", schema.input_schema);
    ]
    @ maybe_assoc_field "outputSchema" (tool_output_schema_field schema.name)
    @ maybe_assoc_field "annotations" (tool_annotations_for_profile profile schema.name)
    @ (if meta_fields = [] then [] else [ ("_meta", `Assoc meta_fields) ])
  in
  `Assoc base

(** {1 Pagination} *)

type cursor_params = { cursor : string option }

type tools_list_params = {
  names : string list option;
  include_hidden : bool;
  include_usage : bool;
  cursor : string option;
}

open Result.Syntax

let strict_assoc_params params =
  match params with
  | None -> Ok []
  | Some (`Assoc fields) -> Ok fields
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: expected object (received %s)"
           (Json_util.kind_name other))

let cursor_param payload =
  match Json_util.assoc_member_opt "cursor" payload with
  | None -> Ok None
  | Some (`String value) ->
      let trimmed = String.trim value in
      if trimmed = "" then
        Error "Invalid params: cursor must not be empty"
      else
        Ok (Some trimmed)
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: cursor must be a string (received %s)"
           (Json_util.kind_name other))

let bool_param payload key =
  match Json_util.assoc_member_opt key payload with
  | None -> Ok false
  | Some (`Bool value) -> Ok value
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: %s must be a boolean (received %s)"
           key (Json_util.kind_name other))

let validate_optional_meta payload =
  match Json_util.assoc_member_opt "_meta" payload with
  | None
  | Some (`Assoc _) -> Ok ()
  | Some other ->
      Error
        (Printf.sprintf "Invalid params: _meta must be an object (received %s)"
           (Json_util.kind_name other))

let requested_tool_list_params params =
  let* fields = strict_assoc_params params in
  let allowed =
    [ "_meta"; "names"; "include_hidden"; "include_usage"; "cursor" ]
  in
  let unknown =
    fields
    |> List.filter_map (fun (key, _value) ->
           if List.mem key allowed then None else Some key)
  in
  if unknown <> [] then
    Error
      (Printf.sprintf "Invalid params: unsupported field(s): %s"
         (String.concat ", " unknown))
  else
    let payload = `Assoc fields in
    let* () = validate_optional_meta payload in
    let* names =
      match Json_util.assoc_member_opt "names" payload with
      | None -> Ok None
      | Some (`List items) ->
          items
          |> List.fold_left
               (fun acc item ->
                 match (acc, item) with
                 | Error _ as err, _ -> err
                 | Ok names, `String value -> Ok (value :: names)
                 | Ok _, bad ->
                     Error
                       (Printf.sprintf
                          "Invalid params: names must be an array of strings \
                           (received %s element)"
                          (Json_util.kind_name bad)))
               (Ok [])
          |> Result.map (fun names -> Some (List.rev names))
      | Some other ->
          Error
            (Printf.sprintf
               "Invalid params: names must be an array of strings (received %s)"
               (Json_util.kind_name other))
    in
    let* cursor = cursor_param payload in
    let* include_hidden = bool_param payload "include_hidden" in
    let* include_usage = bool_param payload "include_usage" in
    Ok
      {
        names;
        include_hidden;
        include_usage;
        cursor;
      }

let parse_cursor_only_params params =
  let* fields = strict_assoc_params params in
  let allowed = [ "_meta"; "cursor" ] in
  let unknown =
    fields
    |> List.filter_map (fun (key, _value) ->
           if List.mem key allowed then None else Some key)
  in
  if unknown <> [] then
    Error
      (Printf.sprintf "Invalid params: unsupported field(s): %s"
         (String.concat ", " unknown))
  else
    let payload = `Assoc fields in
    let* () = validate_optional_meta payload in
    match Json_util.assoc_member_opt "cursor" payload with
    | None -> Ok { cursor = None }
    | Some (`String cursor) -> Ok { cursor = Some cursor }
    | Some other ->
        Error
          (Printf.sprintf
             "Invalid params: cursor must be a string (received %s)"
             (Json_util.kind_name other))

let list_page_size () = Env_config.Tools.list_page_size ()

let encode_cursor ~kind offset =
  Base64.encode_string (Printf.sprintf "%s:%d" kind offset)

let decode_cursor ~kind cursor =
  match Base64.decode cursor with
  | Ok decoded ->
      let prefix = kind ^ ":" in
      let prefix_len = String.length prefix in
      if String.starts_with decoded ~prefix
      then
        int_of_string_opt
          (String.sub decoded prefix_len (String.length decoded - prefix_len))
      else
        None
  | Error _ -> None

let page_items_with_cursor ~kind items cursor =
  let page_size = list_page_size () in
  let offset =
    match cursor with
    | None -> Ok 0
    | Some encoded -> (
        match decode_cursor ~kind encoded with
        | Some value when value >= 0 -> Ok value
        | Some value ->
            Error
              (Printf.sprintf
                 "Invalid params: cursor decoded to negative offset %d \
                  (kind=%S, encoded=%S)"
                 value kind encoded)
        | None ->
            (* [decode_cursor] returns [None] for three different
               failure modes (base64 decode failed / kind-prefix
               mismatch / int_of_string_opt failed).  Promoting it to
               [(int, string) result] is a separate change because it
               is the second [decode_cursor] in the tree (the other
               lives in [graphql_api]) and the [int option] contract
               is exercised by both. *)
            Error
              (Printf.sprintf
                 "Invalid params: cursor %S could not be decoded \
                  (expected base64-encoded \"%s:<non-negative int>\")"
                 encoded kind))
  in
  let rec drop n xs =
    match (n, xs) with
    | 0, rest -> rest
    | _, [] -> []
    | n, _ :: rest -> drop (n - 1) rest
  in
  let rec take n xs =
    match (n, xs) with
    | 0, _ | _, [] -> []
    | n, x :: rest -> x :: take (n - 1) rest
  in
  let count = List.length items in
  let* offset = offset in
  let offset = min offset count in
  let page = items |> drop offset |> take page_size in
  let next_offset = offset + List.length page in
  let next_cursor =
    if next_offset < count then Some (encode_cursor ~kind next_offset) else None
  in
  Ok (page, next_cursor)
