(** See [lsp_questions.mli]. *)

type question =
  | References
  | Definition
  | Hover

let question_of_string = function
  | "references" -> Some References
  | "definition" -> Some Definition
  | "hover" -> Some Hover
  | _ -> None
;;

let string_of_question = function
  | References -> "references"
  | Definition -> "definition"
  | Hover -> "hover"
;;

(* A language server with no index answers [References] with the occurrences
   it can see, which is the ones in the file it was given -- one where the
   truth was three, measured (#30504). A short list reads like an answer, so
   the caller is refused before the question is asked.

   Here rather than in each surface: the Keeper tool and the REST question
   route already share the position arithmetic in [Lsp_position] so they
   cannot disagree about where a name sits. They should not be able to
   disagree about whether an answer is worth asking for either. *)
let reference_index_ready ~question ~language ~project_root =
  match question with
  | Definition | Hover -> Ok ()
  | References ->
    (match Lsp_reference_index.check ~language ~project_root with
     | Lsp_reference_index.Present -> Ok ()
     | Lsp_reference_index.Missing { build_command; searched } ->
       Error
         (Printf.sprintf
            "references needs the project's reference index and none is under %s. Run: %s \
             -- until then the answer would name only the occurrences in this one file, \
             which is not the same as there being only one."
            searched
            build_command))
;;

let method_of_question = function
  | References -> "textDocument/references"
  | Definition -> "textDocument/definition"
  | Hover -> "textDocument/hover"
;;

type location =
  { path : string
  ; line : int
  ; character : int
  }

type answer =
  | Locations of location list
  | Hover_text of string option

type error =
  | Server of Lsp_workspace_pool.error
  | Unreadable_file of
      { path : string
      ; reason : string
      }
  | Unparsed_answer of
      { method_ : string
      ; reason : string
      }

let pp_error fmt = function
  | Server err -> Lsp_workspace_pool.pp_error fmt err
  | Unreadable_file { path; reason } -> Fmt.pf fmt "cannot read %s: %s" path reason
  | Unparsed_answer { method_; reason } ->
    Fmt.pf fmt "unreadable answer to %s: %s" method_ reason
;;

let field obj name = List.assoc_opt name obj

let int_field obj name =
  match field obj name with
  | Some (`Int n) -> Some n
  | Some _ | None -> None
;;

(* A [Range]'s start. The end is where the symbol stops on that line, which
   tells a caller nothing it did not already ask for. *)
let start_of_range = function
  | `Assoc range ->
    (match field range "start" with
     | Some (`Assoc start) ->
       (match int_field start "line", int_field start "character" with
        | Some line, Some character -> Some (line, character)
        | (Some _ | None), (Some _ | None) -> None)
     | Some _ | None -> None)
  | _ -> None
;;

(* [Location] and [LocationLink] are both answers to [textDocument/definition];
   which one arrives is the server's choice, so both are read here. *)
let uri_and_range obj =
  match field obj "uri", field obj "range" with
  | Some (`String uri), Some range -> Some (uri, range)
  | (Some _ | None), (Some _ | None) ->
    let target_range =
      match field obj "targetSelectionRange" with
      | Some range -> Some range
      | None -> field obj "targetRange"
    in
    (match field obj "targetUri", target_range with
     | Some (`String uri), Some range -> Some (uri, range)
     | (Some _ | None), (Some _ | None) -> None)
;;

let location_of_json = function
  | `Assoc obj ->
    (match uri_and_range obj with
     | Some (uri, range) ->
       (match start_of_range range with
        | Some (line, character) ->
          Ok { path = Lsp_uri.path_of_file_uri uri; line; character }
        | None -> Error "range without a start position")
     | None -> Error "neither uri+range nor targetUri+targetRange")
  | _ -> Error "not an object"
;;

let locations_of_json json =
  let collect items =
    List.fold_left
      (fun acc item ->
        match acc, location_of_json item with
        | Error _, _ -> acc
        | Ok locations, Ok location -> Ok (location :: locations)
        | Ok _, Error reason -> Error reason)
      (Ok [])
      items
    |> Result.map List.rev
  in
  match json with
  | `Null -> Ok []
  | `List items -> collect items
  | `Assoc _ -> Result.map (fun location -> [ location ]) (location_of_json json)
  | _ -> Error "not a location, a list of locations, or null"
;;

(* [contents] is [MarkupContent], [MarkedString], or a list of the latter. Every
   shape carries its text in [value] except the bare string. *)
let rec markup_text = function
  | `String text -> Ok text
  | `Assoc obj ->
    (match field obj "value" with
     | Some (`String text) -> Ok text
     | Some _ | None -> Error "hover contents without a string value")
  | `List items ->
    List.fold_left
      (fun acc item ->
        match acc, markup_text item with
        | Error _, _ -> acc
        | Ok texts, Ok text -> Ok (text :: texts)
        | Ok _, Error reason -> Error reason)
      (Ok [])
      items
    |> Result.map (fun texts -> String.concat "\n\n" (List.rev texts))
  | _ -> Error "hover contents is not markup"
;;

let hover_of_json = function
  | `Null -> Ok None
  | `Assoc obj ->
    (match field obj "contents" with
     | Some (`Null) | None -> Ok None
     | Some contents -> Result.map Option.some (markup_text contents))
  | _ -> Error "not a hover or null"
;;

let answer_of_json question json =
  match question with
  | References | Definition ->
    Result.map (fun locations -> Locations locations) (locations_of_json json)
  | Hover -> Result.map (fun text -> Hover_text text) (hover_of_json json)
;;

let read_file path =
  try Ok (In_channel.with_open_bin path In_channel.input_all) with
  | Sys_error reason -> Error reason
;;

let text_document_id uri = `Assoc [ "uri", `String uri ]

let position_params ~uri ~line ~character ~question =
  let base =
    [ "textDocument", text_document_id uri
    ; "position", `Assoc [ "line", `Int line; "character", `Int character ]
    ]
  in
  match question with
  | References ->
    (* Without the declaration a caller that asked "where is this used" has to
       ask "where does it come from" as a second question to see the whole
       set. *)
    `Assoc (base @ [ "context", `Assoc [ "includeDeclaration", `Bool true ] ])
  | Definition | Hover -> `Assoc base
;;

let ask pool ~language ~workspace_root ~path ~line ~character ~question =
  match read_file path with
  | Error reason -> Error (Unreadable_file { path; reason })
  | Ok text ->
    let uri = Lsp_uri.file_uri_of_path path in
    let method_ = method_of_question question in
    let open_params =
      `Assoc
        [ ( "textDocument"
          , `Assoc
              [ "uri", `String uri
              ; "languageId", `String (Lsp_process_manager.lang_id_of_language language)
              ; "version", `Int 1
              ; "text", `String text
              ] )
        ]
    in
    (match
       Lsp_workspace_pool.notify
         pool
         ~language
         ~workspace_root
         ~method_:"textDocument/didOpen"
         ~params:open_params
     with
     | Error err -> Error (Server err)
     | Ok () ->
       let answer =
         Lsp_workspace_pool.ask
           pool
           ~language
           ~workspace_root
           ~method_
           ~params:(position_params ~uri ~line ~character ~question)
       in
       (* Closed whatever the answer was: the pool holds the server past this
          call, and a document left open shadows the file on disk for every
          later question. *)
       let (_ : (unit, Lsp_workspace_pool.error) result) =
         Lsp_workspace_pool.notify
           pool
           ~language
           ~workspace_root
           ~method_:"textDocument/didClose"
           ~params:(`Assoc [ "textDocument", text_document_id uri ])
       in
       (match answer with
        | Error err -> Error (Server err)
        | Ok json ->
          (match answer_of_json question json with
           | Ok answer -> Ok answer
           | Error reason -> Error (Unparsed_answer { method_; reason }))))
;;
