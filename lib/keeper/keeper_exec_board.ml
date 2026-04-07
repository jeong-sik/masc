open Keeper_types
open Keeper_exec_shared

let ensure_keeper_board_post_args ~author ~source = function
  | `Assoc fields ->
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
       ; "post_kind", `String "automation"
       ; "meta", `Assoc [ "source", `String source ]
       ]
       @ fields)
  | other -> other
;;

let handle_keeper_board_tool
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    tool_result_or_error (Tool_board.handle_tool tool_name tool_args)
  in
  match name with
  | "keeper_board_post" ->
    let author = meta.name in
    Log.Keeper.debug
      "keeper_board_post called by %s, raw args: %s"
      author
      (Yojson.Safe.to_string args);
    let board_args =
      ensure_keeper_board_post_args
        ~author
        ~source:"keeper_board_post"
        (assoc_override_string "author" author args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.to_string board_args);
    let result = Tool_board.handle_tool "masc_board_post" board_args in
    let ok, msg = result in
    Log.Keeper.info
      "handle_tool result: ok=%b msg=%s"
      ok
      (if String.length msg > 200 then String.sub msg 0 200 ^ "..." else msg);
    tool_result_or_error result
  | "keeper_board_list" -> dispatch "masc_board_list" args
  | "keeper_board_get" -> dispatch "masc_board_get" args
  | "keeper_board_comment" ->
    dispatch "masc_board_comment" (assoc_override_string "author" meta.name args)
  | "keeper_board_vote" ->
    dispatch "masc_board_vote" (assoc_override_string "voter" meta.name args)
  | "keeper_board_stats" -> dispatch "masc_board_stats" args
  | "keeper_board_search" -> dispatch "masc_board_search" args
  | "keeper_board_delete" -> dispatch "masc_board_delete" args
  | "keeper_board_cleanup" -> dispatch "masc_board_cleanup" args
  | other -> error_json ~fields:[ "tool", `String other ] "unknown_board_tool"
;;

