open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields
;;

let keeper_board_meta ?quantitative_evidence ~source meta =
  let fields =
    match meta with
    | `Assoc fields -> fields
    | _ -> []
  in
  let fields = assoc_replace "source" (`String source) fields in
  let fields =
    match quantitative_evidence with
    | Some evidence -> assoc_replace "quantitative_evidence" evidence fields
    | None -> fields
  in
  `Assoc fields
;;

let assoc_value_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None
;;

let string_arg key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let nonempty_string_field key fields =
  match List.assoc_opt key fields with
  | Some (`String value) when String.trim value <> "" -> Some value
  | _ -> None
;;

let quantitative_evidence_arg = function
  | `Assoc fields ->
    (match List.assoc_opt "quantitative_evidence" fields with
     | Some (`Assoc evidence_fields as evidence)
       when Option.is_some (nonempty_string_field "command" evidence_fields)
            && List.mem_assoc "actual_count" evidence_fields -> Some evidence
     | _ -> None)
  | _ -> None
;;

let has_line_anchor s =
  let len = String.length s in
  let rec loop i =
    i + 1 < len
    && ((Char.equal s.[i] 'L' && Char.code s.[i + 1] >= 48 && Char.code s.[i + 1] <= 57)
        || loop (i + 1))
  in
  loop 0
;;

let has_digit s =
  String.exists (fun ch -> Char.code ch >= 48 && Char.code ch <= 57) s
;;

let has_inline_quantitative_evidence s =
  let lower = String.lowercase_ascii s in
  String_util.contains_substring lower "command:"
  && String_util.contains_substring lower "output:"
;;

let needs_quantitative_evidence content =
  has_line_anchor content && has_digit content && not (has_inline_quantitative_evidence content)
;;

let missing_quantitative_evidence_error =
  "keeper_board_post rejected: quantitative code claims with line/count references require quantitative_evidence metadata or inline rg/grep evidence"
;;

let ensure_keeper_board_post_args ~author ~source args =
  let quantitative_evidence = quantitative_evidence_arg args in
  match args with
  | `Assoc fields ->
    let raw_meta =
      match List.assoc_opt "meta" fields with
      | Some (`Assoc _ as meta) -> meta
      | _ -> `Assoc []
    in
    let fields =
      List.filter
        (fun (k, _) ->
           k <> "author"
           && k <> "post_kind"
           && k <> "meta"
           && k <> "quantitative_evidence")
        fields
    in
    let has_hearth =
      List.exists
        (fun (k, v) ->
           k = "hearth"
           &&
           match v with
           | `String s -> String.trim s <> ""
           | _ -> false)
        fields
    in
    let fields =
      if has_hearth
      then fields
      else ("hearth", `String author) :: List.filter (fun (k, _) -> k <> "hearth") fields
    in
    `Assoc
      ([ "author", `String author
         (* Variant SSOT: bind the literal to the Variant constructor so a
          rename of [Automation_post] forces this site to update too.
          Same pattern family as #8354 / #8392. *)
       ; ( "post_kind"
         , `String (Board_core_classify.post_kind_to_string Board_types.Automation_post) )
       ; "meta", keeper_board_meta ?quantitative_evidence ~source raw_meta
       ]
       @ fields)
  | other -> other
;;

let bind_board_identity ~keeper_name board_name args =
  List.fold_left
    (fun args field -> assoc_override_string field keeper_name args)
    args
    (Board_tool_registry.identity_fields_for_board_name board_name)
;;

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error
      (Board_tool.handle_tool tool_name tool_args)
  in
  (* PR-S1: the board runtime speaks the domain name type [Board_name.t]
     directly rather than routing through the MASC god-enum. *)
  let dispatch_board (tool : Tool_name.Board_name.t) tool_args =
    dispatch (Tool_name.Board_name.to_string tool) tool_args
  in
  match Keeper_tool_name.of_string name with
  | Some Keeper_tool_name.Board_post ->
    let author = meta.name in
    let keeper_source = name in
    let content =
      match string_arg "content" args with
      | Some value -> value
      | None ->
        (match string_arg "body" args with
         | Some value -> value
         | None -> "")
    in
    if needs_quantitative_evidence content && Option.is_none (quantitative_evidence_arg args)
    then
      error_json
        ~fields:[ "reason", `String "missing_quantitative_evidence" ]
        missing_quantitative_evidence_error
    else (
    Log.Keeper.debug
      "%s called by %s, raw args: %s"
      keeper_source
      author
      (Yojson.Safe.pretty_to_string args);
    let board_args =
      ensure_keeper_board_post_args
        ~author
        ~source:keeper_source
        (bind_board_identity
           ~keeper_name:author
           Tool_name.Board_name.Board_post
           args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.pretty_to_string board_args);
    let result =
      Board_tool.handle_tool
        (Tool_name.Board_name.to_string Tool_name.Board_name.Board_post)
        board_args
    in
    let ok = Tool_result.is_success result in
    let msg = Tool_result.message result in
    Log.Keeper.info
      "handle_tool result: ok=%b msg=%s"
      ok
      (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." msg |> String_util.to_string);
    tool_result_or_error result)
  | Some Keeper_tool_name.Board_post_get ->
    (match string_arg "post_id" args with
     | Some pid when String.trim pid <> "" ->
       dispatch_board Tool_name.Board_name.Board_post_get args
     | _ ->
       error_json
         ~fields:[ "reason", `String "missing_post_id"
                 ; "recovery", `String "call keeper_board_list or keeper_board_search first" ]
         "keeper_board_post_get requires post_id (format: p-xxxx). \
          You sent empty or missing post_id. Call keeper_board_list \
          or keeper_board_search first to discover available post IDs, \
          then retry with the post_id you want to read.")
  | Some keeper_tool ->
    (match Keeper_tool_name.masc_board_name_of_keeper_tool keeper_tool with
     | Some board_name ->
       dispatch_board
         board_name
         (bind_board_identity ~keeper_name:meta.name board_name args)
     | None -> error_json ~fields:[ "tool", `String name ] "unknown_board_tool")
  | None -> error_json ~fields:[ "tool", `String name ] "unknown_board_tool"
;;
