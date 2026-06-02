open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Agent_tool_shared_runtime

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields
;;

let keeper_board_meta ~source meta =
  match meta with
  | `Assoc fields -> assoc_replace "source" (`String source) fields |> fun f -> `Assoc f
  | _ -> `Assoc [ "source", `String source ]
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

let ensure_keeper_board_post_args ~author ~source = function
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

let agent_board_post_source = "agent_board_post"

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error
      (Tool_board.handle_tool tool_name tool_args)
  in
  (* PR-S1: the board runtime speaks the domain name type [Board_name.t]
     directly rather than routing through the [Tool_name.Masc] god-enum. *)
  let dispatch_board (tool : Tool_name.Board_name.t) tool_args =
    dispatch (Tool_name.Board_name.to_string tool) tool_args
  in
  match name with
  | "keeper_board_post" ->
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
        ~source:agent_board_post_source
        (assoc_override_string "author" author args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.pretty_to_string board_args);
    let result =
      Tool_board.handle_tool
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
  | "keeper_board_list" -> dispatch_board Tool_name.Board_name.Board_list args
  | "keeper_board_get" -> dispatch_board Tool_name.Board_name.Board_get args
  | "keeper_board_comment" ->
    dispatch_board
      Tool_name.Board_name.Board_comment
      (assoc_override_string "author" meta.name args)
  | "keeper_board_vote" ->
    dispatch_board
      Tool_name.Board_name.Board_vote
      (assoc_override_string "voter" meta.name args)
  | "keeper_board_comment_vote" ->
    dispatch_board
      Tool_name.Board_name.Board_comment_vote
      (assoc_override_string "voter" meta.name args)
  | "keeper_board_stats" -> dispatch_board Tool_name.Board_name.Board_stats args
  | "keeper_board_search" -> dispatch_board Tool_name.Board_name.Board_search args
  | "keeper_board_curation_read" ->
    dispatch_board Tool_name.Board_name.Board_curation_read args
  | "keeper_board_curation_submit" ->
    dispatch_board
      Tool_name.Board_name.Board_curation_submit
      (assoc_override_string "submitted_by" meta.name args)
  | "keeper_board_sub_board_create" ->
    dispatch_board Tool_name.Board_name.Board_sub_board_create args
  | "keeper_board_sub_board_list" ->
    dispatch_board Tool_name.Board_name.Board_sub_board_list args
  | "keeper_board_sub_board_get" ->
    dispatch_board Tool_name.Board_name.Board_sub_board_get args
  | "keeper_board_sub_board_update" ->
    dispatch_board Tool_name.Board_name.Board_sub_board_update args
  | "keeper_board_sub_board_delete" ->
    dispatch_board Tool_name.Board_name.Board_sub_board_delete args
  | _ -> error_json ~fields:[ "tool", `String name ] "unknown_board_tool"
;;
