(** Keeper_exec_tools_search — tool search, tool call recording, and
    mutating-side-effect detection extracted from [Keeper_exec_tools]
    (640 LoC).  Tool execution dispatch remains in the parent.
    @since Keeper 500-line decomposition *)

open Keeper_types
open Keeper_exec_shared
include Keeper_tool_registry
include Keeper_tool_policy

let has_mutating_side_effect_with_input ~(tool_name : string) ~(input : Yojson.Safe.t)
  : bool
  =
  match Tool_name.of_string tool_name with
  | Some (Keeper Shell) ->
    let op =
      match input with
      | `Assoc fields ->
        (match List.assoc_opt "op" fields with
         | Some (`String value) -> Some (String.lowercase_ascii (String.trim value))
         | _ -> None)
      | _ -> None
    in
    (match op with
     | Some op when List.mem op Keeper_shell_op.valid_strings ->
       not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
     | Some _ | None -> false)
  | _ -> not (Keeper_tool_registry.is_read_only_with_input ~tool_name ~input)
;;

type keeper_tool_call_recorder =
  tool_name:string -> success:bool -> duration_ms:int -> unit

let default_keeper_tool_call_recorder ~tool_name:_ ~success:_ ~duration_ms:_ = ()
let keeper_tool_call_recorder_mutex = Stdlib.Mutex.create ()
let keeper_tool_call_recorder = ref default_keeper_tool_call_recorder

let set_on_keeper_tool_call (f : keeper_tool_call_recorder) =
  Stdlib.Mutex.protect keeper_tool_call_recorder_mutex (fun () ->
    keeper_tool_call_recorder := f)
;;

let record_keeper_tool_call ~tool_name ~success ~duration_ms =
  let f =
    Stdlib.Mutex.protect keeper_tool_call_recorder_mutex (fun () ->
      !keeper_tool_call_recorder)
  in
  f ~tool_name ~success ~duration_ms
;;

let search_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> c
  | _ when Char.code c > 127 -> c
  | _ -> ' '
;;

let normalize_search_text text = String.lowercase_ascii (String.map search_char text)


let search_terms query =
  normalize_search_text query
  |> String.split_on_char ' '
  |> List.map String.trim
  |> List.filter (fun term -> term <> "")
  |> List.sort_uniq String.compare
;;

let dedupe_tool_search_schemas schemas =
  let seen = Hashtbl.create (List.length schemas) in
  List.filter
    (fun (schema : Masc_domain.tool_schema) ->
       if Hashtbl.mem seen schema.name
       then false
       else (
         Hashtbl.replace seen schema.name ();
         true))
    schemas
;;

let default_tool_search_schemas () =
  Tool_shard.all_keeper_tool_schemas @ [ keeper_tool_search_schema ]
  |> List.filter (fun (schema : Masc_domain.tool_schema) ->
    not (is_keeper_denied schema.name))
  |> dedupe_tool_search_schemas
;;

let score_tool_schema terms (schema : Masc_domain.tool_schema) =
  let help = Tool_help_registry.entry_of_schema schema in
  let name_text = normalize_search_text schema.name in
  let search_text =
    normalize_search_text
      (String.concat
         " "
         [ schema.name
         ; schema.description
         ; help.Tool_help_registry.when_to_use
         ; Yojson.Safe.to_string schema.input_schema
         ])
  in
  List.fold_left
    (fun score term ->
       if String_util.contains_substring name_text term
       then score +. 2.0
       else if String_util.contains_substring search_text term
       then score +. 1.0
       else score)
    0.0
    terms
;;

let default_tool_search_fn ~query ~max_results =
  let terms = search_terms query in
  let schemas = default_tool_search_schemas () in
  let hits =
    schemas
    |> List.filter_map (fun schema ->
      let score = score_tool_schema terms schema in
      if Float.compare score 0.0 <= 0 then None else Some (schema, score))
    |> List.sort (fun (left_schema, left_score) (right_schema, right_score) ->
      let by_score = compare right_score left_score in
      if by_score <> 0
      then by_score
      else String.compare left_schema.Masc_domain.name right_schema.name)
  in
  let rec take n xs =
    if n <= 0
    then []
    else (
      match xs with
      | [] -> []
      | x :: rest -> x :: take (n - 1) rest)
  in
  let selected = take max_results hits in
  let result_json (schema, score) =
    let help = Tool_help_registry.entry_of_schema schema in
    `Assoc
      [ "name", `String schema.Masc_domain.name
      ; "score", `Float score
      ; "description", `String help.short_description
      ; "when_to_use", `String help.when_to_use
      ; "input_schema", schema.input_schema
      ; "already_visible", `Bool false
      ]
  in
  let results = List.map result_json selected in
  let hint =
    if results = []
    then
      "No tools match this static fallback query. In normal keeper turns, the \
       session-scoped BM25 index provides richer policy-aware search."
    else
      "Static fallback results from keeper schemas. Normal keeper turns use the richer \
       session-scoped BM25 index."
  in
  `Assoc
    [ "ok", `Bool true
    ; "query", `String query
    ; "results", `List results
    ; "result_count", `Int (List.length results)
    ; ( "diagnostics"
      , `Assoc
          [ "source", `String "static_schema_fallback"
          ; "candidate_count", `Int (List.length schemas)
          ] )
    ; "hint", `String hint
    ]
;;

type tool_searcher = query:string -> max_results:int -> Yojson.Safe.t

let default_tool_searcher = default_tool_search_fn
let tool_searcher_mutex = Stdlib.Mutex.create ()
let tool_searcher = ref default_tool_searcher

let set_tool_search_fn (f : tool_searcher) =
  Stdlib.Mutex.protect tool_searcher_mutex (fun () -> tool_searcher := f)
;;

let search_tools ~query ~max_results =
  let f = Stdlib.Mutex.protect tool_searcher_mutex (fun () -> !tool_searcher) in
  f ~query ~max_results
;;
