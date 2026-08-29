let search_tool_name = "keeper_tool_search"

(* A row is worth about this much in the index. edgar's 145-tool surface
   encodes to 13,116 bytes as name plus one line, which is 9.2% of the
   142,257 bytes of schema it stands for; the average row is ~90 bytes and
   the name takes ~30 of them. A service is free to write a paragraph, so
   the line is cut. *)
let summary_max_bytes = 160

type row =
  { name : string
  ; summary : string
  ; tool : Agent_core.Tool.t
  }

type t = { rows : row list }

type surface =
  { always_loaded : Agent_core.Tool.t list
  ; deferred : (Agent_core.Types.tool_schema * Agent_core.Tool.t) list
  }

let first_line text =
  match String.index_opt text '\n' with
  | Some i -> String.sub text 0 i
  | None -> text
;;

let summary_of_description description =
  let line = String.trim (first_line description) in
  (* A description is prose the service wrote. Cutting it on a byte boundary
     splits a multi-byte character and the row stops decoding as UTF-8. *)
  String_util.utf8_prefix ~max_bytes:summary_max_bytes line
;;

let create offered =
  let rows =
    List.map
      (fun ((schema : Agent_core.Types.tool_schema), tool) ->
         { name = schema.name
         ; summary = summary_of_description schema.description
         ; tool
         })
      offered
  in
  { rows }
;;

let is_empty t = t.rows = []
let count t = List.length t.rows

let index_text t =
  t.rows
  |> List.map (fun row ->
    if String.equal row.summary ""
    then row.name
    else Printf.sprintf "%s — %s" row.name row.summary)
  |> String.concat "\n"
;;

let select t ~names =
  let find name =
    match List.find_opt (fun row -> String.equal row.name name) t.rows with
    | Some row -> Ok row.tool
    | None -> Error name
  in
  let rec walk acc = function
    | [] -> Ok (List.rev acc)
    | name :: rest ->
      (match find name with
       | Ok tool -> walk (tool :: acc) rest
       | Error unknown -> Error unknown)
  in
  match names with
  | [] -> Error "name a tool from the index"
  | _ ->
    (match walk [] names with
     | Ok tools -> Ok tools
     | Error unknown ->
       Error
         (Printf.sprintf
            "%s is not in this keeper's tool index; name a tool the index lists"
            unknown))
;;

let names_of_input input =
  match input with
  | `Assoc fields ->
    (match List.assoc_opt "names" fields with
     | Some (`List items) ->
       let rec walk acc = function
         | [] -> Ok (List.rev acc)
         | `String name :: rest ->
           let name = String.trim name in
           if String.equal name ""
           then Error "names carries a blank entry"
           else walk (name :: acc) rest
         | _ :: _ -> Error "names carries an entry that is not a string"
       in
       walk [] items
     | Some `Null | None -> Error "names is required"
     | Some _ -> Error "names must be an array of tool names")
  | _ -> Error "input must be an object"
;;

let schema_json (tool : Agent_core.Tool.t) =
  Agent_core.Tool.schema_to_json tool
;;

let search_tool t ~extend =
  let description =
    Printf.sprintf
      "Return the input schemas for tools this keeper carries but does not \
       send, and make them callable from the next request onward. Name them \
       exactly as the index lists them. A schema returned here is not \
       callable in the same message that asked for it.\n\n\
       Tools in the index:\n\
       %s"
      (index_text t)
  in
  let parameters =
    [ { Agent_core.Types.name = "names"
      ; description = "Exact tool names from the index."
      ; param_type = Agent_core.Types.Array
      ; required = true
      }
    ]
  in
  let handler input : Agent_core.Types.tool_result =
    match names_of_input input with
    | Error message -> Error
        { Agent_core.Types.message
        ; recoverable = true
        ; error_class = Some Agent_core.Types.Deterministic
        }
    | Ok names ->
      (match select t ~names with
       | Error message -> Error
        { Agent_core.Types.message
        ; recoverable = true
        ; error_class = Some Agent_core.Types.Deterministic
        }
       | Ok tools ->
         (match extend tools with
          | Error message ->
            Error
              { Agent_core.Types.message
              ; recoverable = false
              ; error_class = Some Agent_core.Types.Unknown
              }
          | Ok () ->
         let content =
           `Assoc
             [ "loaded", `List (List.map (fun name -> `String name) names)
             ; "schemas", `List (List.map schema_json tools)
             ]
           |> Yojson.Safe.to_string
         in
         Ok { Agent_core.Types.content; _meta = None }))
  in
  Agent_core.Tool.create
    ~name:search_tool_name
    ~description
    ~parameters
    handler
;;
