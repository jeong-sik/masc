type t =
  { limit : int
  ; level_filter : string
  ; applied_level : Log.level
  ; min_level : int
  ; module_filter : string
  ; since_seq : int option
  ; before_seq : int option
  ; category_filter : string option
  ; exclude_category : string list option
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
    let exclude_category =
      match Server_utils.query_param req "exclude_category" with
      | None -> None
      | Some raw ->
        (match
           String.split_on_char ',' raw
           |> List.map String.trim
           |> List.filter (fun s -> s <> "")
         with
         | [] -> None
         | xs -> Some xs)
    in
    Ok
      { limit
      ; level_filter
      ; applied_level
      ; min_level = Log.level_to_int applied_level
      ; module_filter = Option.value ~default:"" (Server_utils.query_param req "module")
      ; since_seq = seq_param req "since_seq"
      ; before_seq = seq_param req "before_seq"
      ; category_filter = Server_utils.query_param req "category"
      ; exclude_category
      }
;;

let read t =
  Log.Ring.recent ~limit:t.limit ~min_level:t.min_level ~module_filter:t.module_filter
    ?since_seq:t.since_seq ?before_seq:t.before_seq ?category_filter:t.category_filter
    ?exclude_category:t.exclude_category ()
;;

let to_json ~config t ~ring_bounds entries =
  Server_dashboard_logs_json.build ~config ~limit:t.limit ~level_filter:t.level_filter
    ~applied_level:t.applied_level ~min_level:t.min_level ~module_filter:t.module_filter
    ~since_seq:t.since_seq ~before_seq:t.before_seq ~category_filter:t.category_filter
    ~exclude_category:t.exclude_category ~ring_bounds entries
;;
