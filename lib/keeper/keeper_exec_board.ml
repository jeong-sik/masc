open Keeper_types
open Keeper_exec_shared

let assoc_replace key value fields =
  (key, value) :: List.filter (fun (name, _) -> name <> key) fields

let keeper_board_meta ~source = function
  | `Assoc fields -> `Assoc (assoc_replace "source" (`String source) fields)
  | _ -> `Assoc [ "source", `String source ]

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
       ; "post_kind", `String
           (Board_core_classify.post_kind_to_string Board_types.Automation_post)
       ; "meta", keeper_board_meta ~source raw_meta
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
      (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." msg |> String_util.to_string);
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
