(** RFC-0058: Declarative capability profile (v2).

    Replaces the closed variant with config-driven profile lookup via
    {!Cascade_capability_schema}.  Profiles are string-named; capability
    requirements live in the schema registry.

    Migration note: callers that previously used [profile] variant values
    now use string profile names directly.  [catalog_entry] stores
    [required_capability_profile] as [string option]. *)

let profile_to_string name = name

let profile_of_string name =
  if Cascade_capability_schema.is_known_profile name then Some name else None

let all_profiles =
  Cascade_capability_schema.all_profile_names

let provider_satisfies_profile name (caps : Provider_tool_support.capabilities) =
  match Cascade_capability_schema.resolve_profile name with
  | Some spec ->
      Cascade_capability_schema.provider_satisfies_required
        caps
        spec.required_capabilities
  | None -> false

(* === RFC-0058 Phase 1: TOML-declared profiles ====================== *)

type requirement = Required | Optional

type required_capabilities = {
  inline_tools : requirement;
  inline_tool_choice : requirement;
  runtime_mcp_tools : requirement;
  runtime_tool_events : requirement;
  runtime_mcp_http_headers : requirement;
}

type declared_profile = {
  required_capabilities_list : string list;
  provider_filter : string option;
}

module Profile_registry : sig
  val register : string -> declared_profile -> unit
  val find : string -> declared_profile option
  val all_declared : unit -> (string * declared_profile) list
  val clear : unit -> unit
end = struct
  let tbl : (string, declared_profile) Hashtbl.t = Hashtbl.create 8
  let register = Hashtbl.replace tbl
  let find = Hashtbl.find_opt tbl
  let all_declared () = Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  let clear () = Hashtbl.clear tbl
end

let known_capability_fields =
  [ "inline_tools"; "inline_tool_choice"; "runtime_mcp_tools";
    "runtime_tool_events"; "runtime_mcp_http_headers" ]

let required_capabilities_of_string_list names =
  let is_required name = List.mem name names in
  let req name = if is_required name then Required else Optional in
  { inline_tools = req "inline_tools";
    inline_tool_choice = req "inline_tool_choice";
    runtime_mcp_tools = req "runtime_mcp_tools";
    runtime_tool_events = req "runtime_tool_events";
    runtime_mcp_http_headers = req "runtime_mcp_http_headers" }

let register_declared_profiles_from_json json =
  match json with
  | `Assoc fields ->
      let rec loop = function
        | [] -> Ok ()
        | (name, profile_json) :: rest ->
            (match profile_json with
             | `Assoc profile_fields ->
                 let caps_ref = ref [] in
                 let filter_ref = ref None in
                 let rec parse_fields = function
                   | [] -> Ok ()
                   | (key, value) :: frest ->
                       (match key with
                        | "required_capabilities" ->
                            (match value with
                             | `List items ->
                                 let strings =
                                   List.map (function
                                     | `String s -> s
                                     | _ -> "")
                                     items
                                   |> List.filter (fun s -> s <> "")
                                 in
                                 caps_ref := strings;
                                 parse_fields frest
                             | _ ->
                                 Error
                                   (Printf.sprintf
                                      "profiles.%s.required_capabilities: \
                                       expected array"
                                      name))
                        | "provider_filter" ->
                            (match value with
                             | `String s -> filter_ref := Some s;
                                 parse_fields frest
                             | _ ->
                                 Error
                                   (Printf.sprintf
                                      "profiles.%s.provider_filter: \
                                       expected string"
                                      name))
                        | _ ->
                            parse_fields frest)
                 in
                 (match parse_fields profile_fields with
                  | Error _ as err -> err
                  | Ok () ->
                      Profile_registry.register name
                        { required_capabilities_list = !caps_ref;
                          provider_filter = !filter_ref };
                      loop rest)
             | _ -> loop rest)
      in
      loop fields
  | _ -> Ok ()

let resolve_required_capabilities name =
  match Cascade_capability_schema.resolve_profile name with
  | Some spec ->
      Some (required_capabilities_of_string_list spec.required_capabilities)
  | None ->
      (match Profile_registry.find name with
       | Some dp ->
           Some (required_capabilities_of_string_list
                   dp.required_capabilities_list)
       | None -> None)

let resolve_provider_filter name =
  match Profile_registry.find name with
  | Some dp -> dp.provider_filter
  | None -> None

let declared_profile_names () =
  Profile_registry.all_declared ()
  |> List.map (fun (name, _) -> name)
  |> List.sort compare

let satisfies req has =
  match req with Optional -> true | Required -> has

let provider_satisfies_named_profile name (caps : Provider_tool_support.capabilities) =
  match resolve_required_capabilities name with
  | None -> false
  | Some req ->
      satisfies req.inline_tools caps.supports_inline_tools
      && satisfies req.inline_tool_choice caps.supports_inline_tool_choice
      && satisfies req.runtime_mcp_tools caps.supports_runtime_mcp_tools
      && satisfies req.runtime_tool_events caps.supports_runtime_tool_events
      && satisfies req.runtime_mcp_http_headers caps.supports_runtime_mcp_http_headers

let safe_lane_cascade_name = "__safe_lane"

let is_system_cascade_name name =
  String.length name >= 2 && String.sub name 0 2 = "__"
