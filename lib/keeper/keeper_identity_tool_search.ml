(* The attached-service surface, offered as a listing instead of as schemas.

   A Keeper attached to a work service is handed that service's entire tool
   list. Measured on 2026-08-29 (RFC-attached-service-tool-scoping §1.5-1.6)
   one Keeper's attached list was 145 tools and 142,257 bytes against 57 KB
   of built-in tools, it was charged to all 83 provider requests of a turn,
   and 20% of those tools were called at all that day. Overflow took 412
   turns, 58.5% of every turn failure.

   So the argument schemas are not sent until they are asked for. What is
   sent is this one tool, whose description names every attached tool with a
   one-line summary -- 9.2% of the bytes -- and whose handler puts the real
   tools into the running agent's callable set. The next provider request of
   the same turn carries their schemas, so the model calls them the ordinary
   way.

   Answering with the schema as tool-result text instead would not work:
   [Agent_tools.admit_tool_use_names] drops a [tool_use] whose name is not in
   [agent.tools] before the history sees it, so the call would disappear
   rather than fail. *)

type surface =
  { offered : Keeper_identity_tools.offered_tool list
  ; agent_cell : Agent_core.Agent.t option ref
  }

type entry =
  { name : string
  ; summary : string
  ; tool : Agent_core.Tool.t
  }

let tool_name = "keeper_tool_search"
let names_param = "names"

(* One line per attached tool, and the whole listing rides in this tool's
   description, so every byte here is charged to every provider request of
   the turn. A description longer than this is a paragraph, and a paragraph
   per entry gives back what the listing saves. *)
let summary_max_bytes = 80

(* Cutting mid-sequence would put invalid UTF-8 on the wire, so step back to
   the first byte of the character that straddles the cut. *)
let rec character_start s at =
  if at <= 0
  then 0
  else if Char.code (String.unsafe_get s at) land 0xC0 = 0x80
  then character_start s (at - 1)
  else at
;;

let summary_of description =
  let first_line =
    match String.index_opt description '\n' with
    | Some newline -> String.sub description 0 newline
    | None -> description
  in
  let line = String.trim first_line in
  if String.length line <= summary_max_bytes
  then line
  else String.sub line 0 (character_start line summary_max_bytes) ^ "..."
;;

let preamble =
  Printf.sprintf
    "Make a tool of an attached work service callable. The services this \
     Keeper is attached to offer more tools than one request can carry, so \
     their argument schemas are left out and only their names are listed \
     below. Pass the exact names you need in \"%s\"; each becomes callable \
     from your next message in this same turn. A name below that you have \
     not passed here is not callable -- calling it does nothing at all.\n\n\
     Tools that can be loaded:"
    names_param
;;

let description_of entries =
  String.concat
    "\n"
    (preamble
     :: List.map
          (fun entry -> Printf.sprintf "- %s: %s" entry.name entry.summary)
          entries)
;;

let input_schema =
  `Assoc
    [ "type", `String "object"
    ; ( "properties"
      , `Assoc
          [ ( names_param
            , `Assoc
                [ "type", `String "array"
                ; "items", `Assoc [ "type", `String "string" ]
                ; ( "description"
                  , `String
                      "Exact tool names, copied from the list in this tool's \
                       description." )
                ] )
          ] )
    ; "required", `List [ `String names_param ]
    ]
;;

let refusal message =
  Error
    { Agent_core.Types.message
    ; recoverable = true
    ; error_class = Some Agent_core.Types.Deterministic
    }
;;

let requested_names input =
  let of_item = function
    | `String name -> Ok name
    | other ->
      Error
        (Printf.sprintf
           "\"%s\" must hold strings; found %s"
           names_param
           (Yojson.Safe.to_string other))
  in
  match input with
  | `Assoc fields ->
    (match List.assoc_opt names_param fields with
     | Some (`List items) -> Agent_core.Types.result_all (List.map of_item items)
     | Some other ->
       Error
         (Printf.sprintf
            "\"%s\" must be an array of tool names; found %s"
            names_param
            (Yojson.Safe.to_string other))
     | None -> Error (Printf.sprintf "\"%s\" is required" names_param))
  | other ->
    Error
      (Printf.sprintf
         "arguments must be an object with \"%s\"; found %s"
         names_param
         (Yojson.Safe.to_string other))
;;

let load ~keeper_name ~agent_cell ~entries requested =
  match !agent_cell with
  | None ->
    (* The cell is filled at agent creation, so an empty one here means the
       turn was wired without it and no attached tool can ever be reached.
       Loud rather than an empty answer: the model would read "nothing
       matched" and stop asking. *)
    Log.Keeper.emit
      Log.Error
      ~keeper_name
      ~category:Log.Tool
      ~details:
        (`Assoc
           [ "error_kind", `String "keeper_identity_tool_search_no_agent"
           ; "requested", Json_util.json_string_list requested
           ])
      "Attached tool listing has no running agent to make tools callable";
    Error
      { Agent_core.Types.message =
          "this turn has no agent to make the tool callable in; the attached \
           surface cannot be reached"
      ; recoverable = false
      ; error_class = Some Agent_core.Types.Deterministic
      }
  | Some agent ->
    let found, unknown =
      List.partition_map
        (fun name ->
           match List.find_opt (fun entry -> String.equal entry.name name) entries with
           | Some entry -> Either.Left entry
           | None -> Either.Right name)
        requested
    in
    (match found with
     | [] -> refusal (Printf.sprintf "not in the list: %s" (String.concat ", " unknown))
     | _ :: _ ->
       Agent_core.Agent.extend_tools agent (List.map (fun entry -> entry.tool) found);
       let loaded =
         Printf.sprintf
           "now callable: %s"
           (String.concat ", " (List.map (fun entry -> entry.name) found))
       in
       let content =
         match unknown with
         | [] -> loaded
         | _ :: _ ->
           Printf.sprintf "%s\nnot in the list: %s" loaded (String.concat ", " unknown)
       in
       Ok { Agent_core.Types.content; _meta = None })
;;

let make ~keeper_name ~build { offered; agent_cell } =
  match offered with
  | [] -> None
  | _ :: _ ->
    let entries =
      List.map
        (fun (offer : Keeper_identity_tools.offered_tool) ->
           { name = offer.Keeper_identity_tools.schema.name
           ; summary = summary_of offer.Keeper_identity_tools.schema.description
           ; tool = build offer
           })
        offered
    in
    let schema =
      match
        Agent_core.Types.tool_schema_of_input_schema
          ~name:tool_name
          ~description:(description_of entries)
          ~input_schema
          ()
      with
      | Ok schema -> schema
      | Error reason ->
        (* The schema above is a literal, so this is a defect in it rather
           than anything an operator configured. Failing here beats offering
           the attached surface as a list the model cannot act on. *)
        invalid_arg
          (Printf.sprintf "%s has a malformed argument schema: %s" tool_name reason)
    in
    let handler input =
      match requested_names input with
      | Error message -> refusal message
      | Ok [] ->
        refusal (Printf.sprintf "\"%s\" was empty; name at least one tool" names_param)
      | Ok requested ->
        load ~keeper_name ~agent_cell ~entries (List.sort_uniq String.compare requested)
    in
    Some
      (Agent_core.Tool.of_schema schema (Agent_core.Tool.ignoring_execution_env handler))
;;
