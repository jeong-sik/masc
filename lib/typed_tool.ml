(** Type-safe constructors for canonical tools.

    @since 0.120.0 *)

let execute_typed ~parse ~handler ~encode json =
  match parse json with
  | Error message -> Error { Types.message; recoverable = true; error_class = None }
  | Ok input ->
    (match handler input with
     | Error message -> Error { Types.message; recoverable = false; error_class = None }
     | Ok output ->
       let content = output |> encode |> Yojson.Safe.to_string in
       Ok { Types.content; _meta = None })
;;

let create ~name ~description ~params ~parse ~handler ~encode ?descriptor ?strict () =
  Tool.create
    ?descriptor
    ?strict
    ~name
    ~description
    ~parameters:params
    (execute_typed ~parse ~handler ~encode)
;;

let create_with_context
      ~name
      ~description
      ~params
      ~parse
      ~handler
      ~encode
      ?descriptor
      ?strict
      ()
  =
  Tool.of_schema
    ?descriptor
    (Types.tool_schema_of_params ?strict ~name ~description ~parameters:params ())
    (Tool.requiring_context (fun context ->
       execute_typed ~parse ~handler:(handler context) ~encode))
;;
