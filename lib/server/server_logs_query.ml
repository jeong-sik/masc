type t =
  { limit : int
  ; level_filter : string
  ; applied_level : Log.level
  ; min_level : int
  ; module_filter : string
  ; since_seq : int option
  ; before_seq : int option
  ; categories : Log.category_selector list option
  ; exclude_categories : Log.category_selector list option
  }

let default_limit = 200
let max_limit = 3000

let seq_param req key =
  match Server_utils.query_param req key with
  | None -> None
  | Some _ ->
    let seq = Server_utils.int_query_param req key ~default:(-1) in
    if seq < 0 then None else Some seq
;;

let category_selectors_param req key =
  match Server_utils.query_param req key with
  | None -> Ok None
  | Some raw ->
    let rec read acc = function
      | [] -> Ok (match List.rev acc with [] -> None | selectors -> Some selectors)
      | name :: rest ->
        (match Log.category_selector_of_string_opt name with
         | Some selector -> read (selector :: acc) rest
         | None -> Error name)
    in
    raw
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun name -> name <> "")
    |> read []
;;

let invalid_category_json ~param name =
  `Assoc
    [ "error", `String "invalid_log_category"
    ; "message", `String "each name must be a log category or uncategorized"
    ; "param", `String param
    ; "value", `String name
    ]
;;

let of_request req =
  let limit =
    Server_utils.int_query_param req "limit" ~default:default_limit |> max 1 |> min max_limit
  in
  let level_filter =
    match Server_utils.query_param req "level" with
    | Some v -> v
    | None -> "DEBUG"
  in
  match Log.level_of_string_opt level_filter with
  | None ->
    Error
      (`Assoc
        [ "error", `String "invalid_log_level"
        ; "message", `String "level must be one of debug, info, warn, warning, error"
        ; "level", `String level_filter
        ])
  | Some applied_level ->
    (match
       ( category_selectors_param req "category"
       , category_selectors_param req "exclude_category" )
     with
     | Error name, _ -> Error (invalid_category_json ~param:"category" name)
     | Ok _, Error name -> Error (invalid_category_json ~param:"exclude_category" name)
     | Ok categories, Ok exclude_categories ->
       Ok
         { limit
         ; level_filter
         ; applied_level
         ; min_level = Log.level_to_int applied_level
         ; module_filter = Option.value ~default:"" (Server_utils.query_param req "module")
         ; since_seq = seq_param req "since_seq"
         ; before_seq = seq_param req "before_seq"
         ; categories
         ; exclude_categories
         })
;;

let read t =
  Log.Ring.recent ~limit:t.limit ~min_level:t.min_level ~module_filter:t.module_filter
    ?since_seq:t.since_seq ?before_seq:t.before_seq ?categories:t.categories
    ?exclude_categories:t.exclude_categories ()
;;

let to_json ~config t ~ring_bounds entries =
  Server_dashboard_logs_json.build ~config ~limit:t.limit ~level_filter:t.level_filter
    ~applied_level:t.applied_level ~min_level:t.min_level ~module_filter:t.module_filter
    ~since_seq:t.since_seq ~before_seq:t.before_seq ~categories:t.categories
    ~exclude_categories:t.exclude_categories ~ring_bounds entries
;;
