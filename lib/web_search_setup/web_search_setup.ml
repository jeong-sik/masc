type key =
  | Searxng_url
  | Provider
  | Provider_order
  | Fallbacks
  | Timeout_sec
  | Cache_ttl_sec
[@@deriving enumerate]

type providers = Web_search_provider.t * Web_search_provider.t list

type change =
  | Set_searxng_url of string
  | Set_provider of Web_search_provider.t
  | Set_provider_order of providers
  | Set_fallbacks of providers
  | Set_timeout_sec of int
  | Set_cache_ttl_sec of float
  | Unset of key

type settings =
  { searxng_url : string option
  ; provider : string option
  ; provider_order : string option
  ; fallbacks : string option
  ; timeout_sec : int option
  ; cache_ttl_sec : float option
  }

type observation =
  { revision : string
  ; settings : settings
  ; problems : string list
  }

type error =
  | Configuration_unavailable of string
  | Configuration_changed
  | Conflicting_changes of key
  | Section_invalid of string
  | Table_not_reachable
  | Not_read_back of key
  | Configuration_rejected of string

(* The keeper runtime settings own their table name through the registry rows
   ([web_search.searxng_url] ...); a test holds [key_name] to those rows. *)
let table = "web_search"

let key_name = function
  | Searxng_url -> "searxng_url"
  | Provider -> "provider"
  | Provider_order -> "provider_order"
  | Fallbacks -> "fallbacks"
  | Timeout_sec -> "timeout_sec"
  | Cache_ttl_sec -> "cache_ttl_sec"
;;

let dotted key = table ^ "." ^ key_name key
let toml_key = dotted

let error_message = function
  | Configuration_unavailable detail -> "runtime.toml could not be read: " ^ detail
  | Configuration_changed ->
    "runtime.toml changed since it was read, so nothing was written"
  | Conflicting_changes key ->
    Printf.sprintf
      "%s was given twice, so nothing was written"
      (dotted key)
  | Section_invalid detail ->
    "the web search settings would not load after this change, so nothing was \
     written: " ^ detail
  | Table_not_reachable ->
    "web_search is written as an inline table or as dotted keys at the top of \
     runtime.toml, which this editor does not edit, so nothing was written. \
     Write it as a [web_search] table and run this again"
  | Not_read_back key ->
    Printf.sprintf
      "%s is not read back with the requested value after the edit, so nothing \
       was written: the line editor and the loader disagree about where it is"
      (dotted key)
  | Configuration_rejected detail -> "the commit was refused: " ^ detail
;;

exception Revision_changed
exception Section_refused of string
exception Not_visible of key
exception Unreachable

let change_key = function
  | Set_searxng_url _ -> Searxng_url
  | Set_provider _ -> Provider
  | Set_provider_order _ -> Provider_order
  | Set_fallbacks _ -> Fallbacks
  | Set_timeout_sec _ -> Timeout_sec
  | Set_cache_ttl_sec _ -> Cache_ttl_sec
  | Unset key -> key
;;

let conflicting changes =
  let rec loop seen = function
    | [] -> None
    | change :: rest ->
      let key = change_key change in
      if List.mem key seen then Some key else loop (key :: seen) rest
  in
  loop [] changes
;;

(* Repeats are dropped keeping the first: a list read as an order means its
   first mention, and writing a provider twice would only look like a typo. *)
let providers_csv (first, rest) =
  let unique =
    List.fold_left
      (fun kept provider -> if List.mem provider kept then kept else kept @ [ provider ])
      []
      (first :: rest)
  in
  String.concat "," (List.map Web_search_provider.label unique)
;;

let edit_string contents key value =
  Toml_line_editor.edit_table_scalar
    contents
    ~path:table
    ~key:(key_name key)
    ~value
;;

let apply_change contents = function
  | Set_searxng_url url -> edit_string contents Searxng_url (Some url)
  | Set_provider provider ->
    edit_string contents Provider (Some (Web_search_provider.label provider))
  | Set_provider_order providers ->
    edit_string contents Provider_order (Some (providers_csv providers))
  | Set_fallbacks providers ->
    edit_string contents Fallbacks (Some (providers_csv providers))
  | Set_timeout_sec seconds ->
    Toml_line_editor.edit_table_int
      contents
      ~path:table
      ~key:(key_name Timeout_sec)
      ~value:seconds
  | Set_cache_ttl_sec seconds ->
    Toml_line_editor.edit_table_float
      contents
      ~path:table
      ~key:(key_name Cache_ttl_sec)
      ~value:seconds
  | Unset key -> edit_string contents key None
;;

(* The [web_search.*] keys the loader refuses in this text. Other tables are
   not this module's to judge: an unrelated broken table is the commit's to
   refuse, and it says which. *)
let section_problems text =
  match Keeper_runtime_config.validate_source_text text with
  | Error message -> Error message
  | Ok report ->
    let prefix = table ^ "." in
    let is_refused (issue : Keeper_runtime_config.validation_issue) =
      match issue.severity with
      | Keeper_runtime_config.Error -> String.starts_with ~prefix issue.key
      | Keeper_runtime_config.Warning -> false
    in
    Ok
      (report.Keeper_runtime_config.issues
       |> List.filter is_refused
       |> List.map (fun (issue : Keeper_runtime_config.validation_issue) ->
         Printf.sprintf "%s: %s" issue.key issue.detail))
;;

let read_back doc = function
  | Set_searxng_url url ->
    Option.equal String.equal (Keeper_toml_loader.toml_string_opt doc (dotted Searxng_url)) (Some url)
  | Set_provider provider ->
    Option.equal
      String.equal
      (Keeper_toml_loader.toml_string_opt doc (dotted Provider))
      (Some (Web_search_provider.label provider))
  | Set_provider_order providers ->
    Option.equal
      String.equal
      (Keeper_toml_loader.toml_string_opt doc (dotted Provider_order))
      (Some (providers_csv providers))
  | Set_fallbacks providers ->
    Option.equal
      String.equal
      (Keeper_toml_loader.toml_string_opt doc (dotted Fallbacks))
      (Some (providers_csv providers))
  | Set_timeout_sec seconds ->
    Option.equal Int.equal (Keeper_toml_loader.toml_int_opt doc (dotted Timeout_sec)) (Some seconds)
  | Set_cache_ttl_sec seconds ->
    Option.equal
      Float.equal
      (Keeper_toml_loader.toml_float_opt doc (dotted Cache_ttl_sec))
      (Some seconds)
  | Unset key -> not (List.mem_assoc (dotted key) doc)
;;

let index_substring_from s sub start =
  let s_len = String.length s in
  let sub_len = String.length sub in
  let rec loop i =
    if i + sub_len > s_len
    then None
    else if String.equal (String.sub s i sub_len) sub
    then Some i
    else loop (i + 1)
  in
  loop start
;;

let authority_end value start =
  let len = String.length value in
  let rec loop i =
    if i >= len
    then len
    else (
      match value.[i] with
      | '/' | '?' | '#' -> i
      | _ -> loop (i + 1))
  in
  loop start
;;

let scrub_authority value auth_start =
  let auth_end = authority_end value auth_start in
  if auth_end <= auth_start
  then value
  else (
    match String.rindex_opt (String.sub value auth_start (auth_end - auth_start)) '@' with
    | None -> value
    | Some at_idx ->
      let host_offset = auth_start + at_idx in
      String.concat
        ""
        [ String.sub value 0 auth_start
        ; "[REDACTED]"
        ; String.sub value host_offset (String.length value - host_offset)
        ])
;;

let authority_start value =
  if String.starts_with ~prefix:"//" value
  then 2
  else (
    let first_delim = authority_end value 0 in
    match index_substring_from value "://" 0 with
    | Some scheme_end
      when scheme_end + 1 = first_delim
           && not (String.contains (String.sub value 0 scheme_end) '@') ->
      scheme_end + 3
    | Some _ | None -> 0)
;;

let display_searxng_url value = scrub_authority value (authority_start value)
;;

(* The searxng URL is refused here, not left to the loader. The loader checks a
   value's type and range and not its scheme; the reader
   ([Env_config_runtime.Tools.searxng_base_url]) refuses any scheme but http
   and https and any userinfo each time a search resolves it. A writer that
   passed a typo through would leave a provider that fails on every call and
   reads as configured. A host is required on top of the reader's scheme rule:
   an http URL with none cannot be searched, and is a typo whichever reader
   sees it. *)
let change_problem = function
  | Set_searxng_url url ->
    let uri = Uri.of_string url in
    let has_authority_userinfo = not (String.equal url (display_searxng_url url)) in
    (match
       ( Option.map String.lowercase_ascii (Uri.scheme uri)
       , Uri.host uri
       , Uri.userinfo uri
       , has_authority_userinfo )
     with
     | Some ("http" | "https"), Some host, None, false when not (String.equal host "") ->
       None
     | Some ("http" | "https"), Some host, (Some _ | None), _ when not (String.equal host "") ->
       Some
         (Printf.sprintf
            "%s must not contain userinfo credentials (got %S)"
            (dotted Searxng_url)
            (display_searxng_url url))
     | Some _, _, _, _ | None, _, _, _ ->
       Some
         (Printf.sprintf
            "%s must be an http or https URL with a host (got %S)"
            (dotted Searxng_url)
            (display_searxng_url url)))
  | Set_provider _
  | Set_provider_order _
  | Set_fallbacks _
  | Set_timeout_sec _
  | Set_cache_ttl_sec _
  | Unset _ -> None
;;

(* [web_search] reached by dotted keys at the root, or by an inline table, has no
   header for the line editor to find. It would open a [web_search] header
   beside them, which TOML 1.0 forbids and Otoml accepts for dotted keys, so
   the file would commit and then fail a strict reader. *)
let defined_without_a_header contents =
  match Keeper_toml_loader.parse_toml contents with
  | Error _ -> false (* a syntax error is [section_problems]'s to report *)
  | Ok doc ->
    let prefix = table ^ "." in
    let has_keys =
      List.exists
        (fun (key, _) -> String.equal key table || String.starts_with ~prefix key)
        doc
    in
    let lines, _ = Toml_line_editor.split_lines contents in
    has_keys && not (List.exists (Toml_line_editor.is_table ~path:table) lines)
;;

(* The edited text has to read back as the requested settings before it is
   written. Nothing reads these keys until the server starts, so a value the
   loader refuses, or one the line editor put where the loader does not look,
   would stay quiet until a restart. *)
let checked contents changes =
  (match List.filter_map change_problem changes with
   | [] -> ()
   | problems -> raise (Section_refused (String.concat "; " problems)));
  if defined_without_a_header contents then raise Unreachable;
  let updated = List.fold_left apply_change contents changes in
  match section_problems updated with
  | Error message -> raise (Section_refused message)
  | Ok (_ :: _ as problems) -> raise (Section_refused (String.concat "; " problems))
  | Ok [] ->
    (match Keeper_toml_loader.parse_toml updated with
     | Error message -> raise (Section_refused message)
     | Ok doc ->
       List.iter
         (fun change ->
            if not (read_back doc change) then raise (Not_visible (change_key change)))
         changes;
       updated)
;;

let revision_of (observation : Runtime.config_observation) =
  Runtime.config_source_revision_to_string observation.source_revision
;;

let settings_of_doc doc =
  let string key = Keeper_toml_loader.toml_string_opt doc (dotted key) in
  { searxng_url = string Searxng_url
  ; provider = string Provider
  ; provider_order = string Provider_order
  ; fallbacks = string Fallbacks
  ; timeout_sec = Keeper_toml_loader.toml_int_opt doc (dotted Timeout_sec)
  ; cache_ttl_sec = Keeper_toml_loader.toml_float_opt doc (dotted Cache_ttl_sec)
  }
;;

let observe ~runtime_config_path =
  match Runtime.load_config_observation ~runtime_config_path () with
  | Error detail -> Error (Configuration_unavailable detail)
  | Ok observation ->
    (match Keeper_toml_loader.parse_toml observation.source_text with
     | Error message -> Error (Configuration_unavailable message)
     | Ok doc ->
       (match section_problems observation.source_text with
        | Error message -> Error (Configuration_unavailable message)
        | Ok problems ->
          Ok
            { revision = revision_of observation
            ; settings = settings_of_doc doc
            ; problems
            }))
;;

let apply ~runtime_config_path ~expected_revision changes =
  match conflicting changes with
  | Some key -> Error (Conflicting_changes key)
  | None ->
    (* The revision is checked inside edit_config_text's lock, because
       [observe] read it outside one. *)
    let edit contents =
      let observation = Runtime.config_observation ~path:runtime_config_path contents in
      if not (String.equal (revision_of observation) expected_revision)
      then raise Revision_changed;
      checked contents changes
    in
    (match Runtime.edit_config_text ~runtime_config_path edit with
     (* The revision this write produced, out of the commit itself. A second,
        unlocked read afterwards could answer another writer's revision. *)
     | Ok receipt -> Ok (revision_of receipt.Runtime.observation)
     | Error detail -> Error (Configuration_rejected detail)
     | exception Revision_changed -> Error Configuration_changed
     | exception Section_refused message -> Error (Section_invalid message)
     | exception Unreachable -> Error Table_not_reachable
     | exception Not_visible key -> Error (Not_read_back key))
;;
