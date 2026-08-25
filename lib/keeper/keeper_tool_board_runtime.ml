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

;;

let without_if_revision = function
  | `Assoc fields ->
    `Assoc (List.filter (fun (key, _) -> key <> "if_revision") fields)
  | other -> other
;;

let snapshot_execution_of_response result response =
  let data = Snapshot_protocol.to_yojson response in
  match response, result.Keeper_tool_execution.disposition with
  | Snapshot_protocol.Unchanged _,
    (Tool_result.Completed _ | Tool_result.Deferred _) ->
    Keeper_tool_execution.deferred_data data
  | Snapshot_protocol.Snapshot _, Tool_result.Completed _ ->
    Keeper_tool_execution.success_data data
  | Snapshot_protocol.Snapshot _, Tool_result.Deferred _ ->
    Keeper_tool_execution.deferred_data data
  | (Snapshot_protocol.Snapshot _ | Snapshot_protocol.Unchanged _),
    Tool_result.Failed _ ->
    result
;;

module For_testing = struct
  let snapshot_execution_of_response = snapshot_execution_of_response
end

let string_arg key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String value) -> Some value
     | _ -> None)
  | _ -> None
;;

let ensure_masc_board_post_args ~author ~source args =
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

let handle_board_name_with_outcome
      ~(meta : keeper_meta)
      ~(board_name : Tool_name.Board_name.t)
      ~(args : Yojson.Safe.t)
  =
  let dispatch tool_name tool_args =
    Keeper_tool_execution.of_tool_result
      (Board_tool_dispatch.handle_tool tool_name tool_args)
  in
  (* PR-S1: the board runtime speaks the domain name type [Board_name.t]
     directly rather than routing through the MASC god-enum. *)
  let dispatch_board (tool : Tool_name.Board_name.t) tool_args =
    dispatch (Tool_name.Board_name.to_string tool) tool_args
  in
  let dispatch_board_list args =
    match Snapshot_protocol.if_revision args with
    | Error message ->
      Keeper_tool_execution.failure
        ~class_:Tool_result.Policy_rejection
        (error_json message)
    | Ok if_revision ->
      let result =
        dispatch_board Tool_name.Board_name.Board_list (without_if_revision args)
      in
      let revision =
        Snapshot_protocol.revision_of_json
          ~namespace:"board"
          (`Assoc
            [ "snapshot", `String result.raw_output
            ; "args", without_if_revision args
            ])
      in
      (match result.disposition with
       | Tool_result.Failed _ -> result
       | Tool_result.Completed _ | Tool_result.Deferred _ ->
         let response =
           Snapshot_protocol.respond
             ~revision
             ~if_revision
             (`String result.raw_output)
         in
         snapshot_execution_of_response result response)
  in
  match board_name with
  | Tool_name.Board_name.Board_post ->
    let author = meta.name in
    let keeper_source = Tool_name.Board_name.to_string board_name in
    Log.Keeper.debug
      "%s called by %s, raw args: %s"
      keeper_source
      author
      (Yojson.Safe.pretty_to_string args);
    let board_args =
      ensure_masc_board_post_args
        ~author
        ~source:keeper_source
        (bind_board_identity
           ~keeper_name:author
           Tool_name.Board_name.Board_post
           args)
    in
    Log.Keeper.debug "board_args: %s" (Yojson.Safe.pretty_to_string board_args);
    let result =
      Board_tool_dispatch.handle_tool
        (Tool_name.Board_name.to_string Tool_name.Board_name.Board_post)
        board_args
    in
    let disposition = Tool_result.string_of_disposition result in
    let msg = Tool_result.message result in
    Log.Keeper.info
      "handle_tool result: disposition=%s msg=%s"
      disposition
      (String_util.utf8_safe ~max_bytes:203 ~suffix:"..." msg |> String_util.to_string);
    Keeper_tool_execution.of_tool_result result
  | Tool_name.Board_name.Board_post_get ->
    (match string_arg "post_id" args with
     | Some pid when String.trim pid <> "" ->
       dispatch_board Tool_name.Board_name.Board_post_get args
     | _ ->
       Keeper_tool_execution.failure
         ~class_:Tool_result.Policy_rejection
         (error_json
            ~fields:[ "reason", `String "missing_post_id" ]
            "masc_board_post_get requires post_id (format: p-xxxx). \
             You sent empty or missing post_id."))
  | Tool_name.Board_name.Board_list -> dispatch_board_list args
  | board_name ->
    dispatch_board
      board_name
      (bind_board_identity ~keeper_name:meta.name board_name args)
;;

let handle_board_tool_with_outcome
      ~(meta : keeper_meta)
      ~(name : string)
      ~(args : Yojson.Safe.t)
  =
  match Tool_name.Board_name.of_string name with
  | Some board_name -> handle_board_name_with_outcome ~meta ~board_name ~args
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json ~fields:[ "tool", `String name ] "unknown_board_tool")
;;

let handle_board_tool ~meta ~name ~args =
  (handle_board_tool_with_outcome ~meta ~name ~args).raw_output
;;
