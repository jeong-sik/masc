open Keeper_types
open Keeper_exec_shared

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields
;;

let keeper_board_meta ~source = function
  | `Assoc fields -> `Assoc (assoc_replace "source" (`String source) fields)
  | _ -> `Assoc [ "source", `String source ]
;;

let ensure_keeper_board_post_args ~author ~source = function
  | `Assoc fields ->
    let raw_meta =
      match List.assoc_opt "meta" fields with
      | Some (`Assoc _ as meta) -> meta
      | _ -> `Assoc []
    in
    let fields =
      List.filter (fun (k, _) -> k <> "author" && k <> "post_kind" && k <> "meta") fields
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

let dispatchable_keeper_board_tool_name name =
  match Tool_name.Keeper.of_string name with
  | Some tool when Tool_name.Keeper.is_board tool -> Some tool
  | Some _ | None -> None
;;

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error (Tool_board.handle_tool tool_name tool_args)
  in
  let dispatch_board tool tool_args =
    dispatch (Tool_name.Masc.to_string tool) tool_args
  in
  match dispatchable_keeper_board_tool_name name with
  | Some Tool_name.Keeper.Board_post ->
    let author = meta.name in
    let keeper_source = Tool_name.Keeper.to_string Tool_name.Keeper.Board_post in
    Log.Keeper.debug
      "%s called by %s, raw args: %s"
      keeper_source
      author
      (Yojson.Safe.to_string args);
    let board_args =
      ensure_keeper_board_post_args
        ~author
        ~source:keeper_source
        (assoc_override_string "author" author args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.to_string board_args);
    let result =
      Tool_board.handle_tool
        (Tool_name.Masc.to_string Tool_name.Masc.Board_post)
        board_args
    in
    let ok, msg = result in
    Log.Keeper.info
      "handle_tool result: ok=%b msg=%s"
      ok
      (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." msg |> String_util.to_string);
    tool_result_or_error result
  | Some Tool_name.Keeper.Board_list -> dispatch_board Tool_name.Masc.Board_list args
  | Some Tool_name.Keeper.Board_get -> dispatch_board Tool_name.Masc.Board_get args
  | Some Tool_name.Keeper.Board_comment ->
    dispatch_board
      Tool_name.Masc.Board_comment
      (assoc_override_string "author" meta.name args)
  | Some Tool_name.Keeper.Board_vote ->
    dispatch_board
      Tool_name.Masc.Board_vote
      (assoc_override_string "voter" meta.name args)
  | Some Tool_name.Keeper.Board_comment_vote ->
    dispatch_board
      Tool_name.Masc.Board_comment_vote
      (assoc_override_string "voter" meta.name args)
  | Some Tool_name.Keeper.Board_stats -> dispatch_board Tool_name.Masc.Board_stats args
  | Some Tool_name.Keeper.Board_search -> dispatch_board Tool_name.Masc.Board_search args
  | Some Tool_name.Keeper.Board_delete -> dispatch_board Tool_name.Masc.Board_delete args
  | Some Tool_name.Keeper.Board_cleanup ->
    dispatch_board Tool_name.Masc.Board_cleanup args
  | Some _ | None -> error_json ~fields:[ "tool", `String name ] "unknown_board_tool"
;;
