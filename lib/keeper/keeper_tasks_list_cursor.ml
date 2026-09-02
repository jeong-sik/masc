type page_key =
  { priority : int
  ; created_at : string
  ; id : string
  }

type filter =
  { status : string option
  ; include_done : bool
  ; projection : string
  }

type t =
  { after : page_key
  ; filter : filter
  }

type error =
  | Cursor_unparseable
  | Cursor_filter_mismatch of
      { cursor : filter
      ; call : filter
      }

let compare_key left right =
  match Int.compare left.priority right.priority with
  | 0 ->
    (match String.compare left.created_at right.created_at with
     | 0 -> String.compare left.id right.id
     | order -> order)
  | order -> order
;;

let filter_to_yojson filter =
  `Assoc
    [ "status", (match filter.status with None -> `Null | Some status -> `String status)
    ; "include_done", `Bool filter.include_done
    ; "projection", `String filter.projection
    ]
;;

let to_yojson cursor =
  `Assoc
    [ ( "after"
      , `Assoc
          [ "priority", `Int cursor.after.priority
          ; "created_at", `String cursor.after.created_at
          ; "id", `String cursor.after.id
          ] )
    ; "filter", filter_to_yojson cursor.filter
    ]
;;

let to_string cursor =
  Base64.encode_string
    ~pad:false
    ~alphabet:Base64.uri_safe_alphabet
    (Yojson.Safe.to_string (to_yojson cursor))
;;

let field name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let filter_of_yojson json =
  match field "status" json, field "include_done" json, field "projection" json with
  | Some status, Some (`Bool include_done), Some (`String projection) ->
    (match status with
     | `Null -> Some { status = None; include_done; projection }
     | `String status -> Some { status = Some status; include_done; projection }
     | _ -> None)
  | _ -> None
;;

let page_key_of_yojson json =
  match field "priority" json, field "created_at" json, field "id" json with
  | Some (`Int priority), Some (`String created_at), Some (`String id) ->
    Some { priority; created_at; id }
  | _ -> None
;;

let filter_equal left right =
  Option.equal String.equal left.status right.status
  && Bool.equal left.include_done right.include_done
  && String.equal left.projection right.projection
;;

let of_string ~call raw =
  let decoded =
    match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet raw with
    | Ok text -> (try Some (Yojson.Safe.from_string text) with Yojson.Json_error _ -> None)
    | Error (`Msg _) -> None
  in
  match decoded with
  | None -> Error Cursor_unparseable
  | Some json ->
    (match
       Option.bind (field "after" json) page_key_of_yojson,
       Option.bind (field "filter" json) filter_of_yojson
     with
     | Some after, Some filter ->
       if filter_equal filter call
       then Ok { after; filter }
       else Error (Cursor_filter_mismatch { cursor = filter; call })
     | _ -> Error Cursor_unparseable)
;;

let error_kind_to_string = function
  | Cursor_unparseable -> "cursor_unparseable"
  | Cursor_filter_mismatch _ -> "cursor_filter_mismatch"
;;

let rejection_json error =
  `Assoc
    ([ "ok", `Bool false
     ; "field", `String "cursor"
     ; "error_kind", `String (error_kind_to_string error)
     ]
     @
     match error with
     | Cursor_unparseable -> []
     | Cursor_filter_mismatch { cursor; call } ->
       [ "cursor_filter", filter_to_yojson cursor; "call_filter", filter_to_yojson call ])
;;
