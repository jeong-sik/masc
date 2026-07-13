open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields
;;

let keeper_board_meta ~source meta =
  let fields =
    match meta with
    | `Assoc fields -> fields
    | _ -> []
  in
  `Assoc (assoc_replace "source" (`String source) fields)
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

let ensure_keeper_board_post_args ~author ~source args =
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
           && k <> "meta")
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
       ; "meta", keeper_board_meta ~source raw_meta
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
    tool_result_or_error result
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
