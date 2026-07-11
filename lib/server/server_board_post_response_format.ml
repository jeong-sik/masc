type t =
  | Nested
  | Flat

type error = Unsupported of string

let default = Nested

let to_wire = function
  | Nested -> "nested"
  | Flat -> "flat"
;;

let supported = [ Nested; Flat ]

let of_query = function
  | None -> Ok default
  | Some supplied ->
    let normalized = String.lowercase_ascii (String.trim supplied) in
    (match
       List.find_opt
         (fun response_format ->
            String.equal normalized (to_wire response_format))
         supported
     with
     | Some response_format -> Ok response_format
     | None -> Error (Unsupported supplied))
;;

let error_json (Unsupported supplied) =
  let supported_formats = List.map to_wire supported in
  `Assoc
    [ ( "error"
      , `String
          (Printf.sprintf
             "format must be one of: %s"
             (String.concat ", " supported_formats)) )
    ; "code", `String "unsupported_board_post_response_format"
    ; "supplied", `String supplied
    ; ( "supported_formats"
      , `List (List.map (fun value -> `String value) supported_formats) )
    ]
;;
