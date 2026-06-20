type urgency =
  | Immediate
  | Normal
  | Low

let urgency_rank = function
  | Immediate -> 0
  | Normal -> 1
  | Low -> 2

type post_id = string

type board_stimulus_kind =
  | Post_created
  | Comment_added

type board_stimulus = {
  kind : board_stimulus_kind;
  author : string;
  title : string;
  content : string;
  hearth : string option;
  updated_at : float option;
}

type stimulus_payload =
  | Board_signal of board_stimulus
  | Bootstrap
  | No_progress_recovery
  | Fusion_completed of fusion_completion
      (* RFC-0266: an async [masc_fusion] deliberation finished. Wakes the
         calling keeper so the resolved answer arrives as actionable turn
         input on its next cycle, instead of being discovered passively. *)

and fusion_completion = {
  run_id : string;
  ok : bool;  (* judge synthesized vs denied/sink_failed/aborted. *)
  resolved_answer : string;
  (* judge resolved answer; a failure label when [ok = false]. *)
  board_post_id : string;
  (* correlates to the sink's board evidence post; "" if none was created. *)
}

let fusion_completion_post_id (fc : fusion_completion) =
  if String.equal fc.board_post_id "" then "fusion-run:" ^ fc.run_id
  else fc.board_post_id

type stimulus = {
  post_id : post_id;
  urgency : urgency;
  arrived_at : float;
  payload : stimulus_payload;
}

type t =
  { front : stimulus list
  ; back_rev : stimulus list
  ; length : int
  }

let empty : t = { front = []; back_rev = []; length = 0 }

let length q = q.length

let is_empty q = q.length = 0

let enqueue (queue : t) (s : stimulus) : t =
  { queue with back_rev = s :: queue.back_rev; length = queue.length + 1 }

let to_list (queue : t) : stimulus list =
  match queue.back_rev with
  | [] -> queue.front
  | back_rev -> queue.front @ List.rev back_rev

let of_list (items : stimulus list) : t =
  { front = items; back_rev = []; length = List.length items }

let dequeue (queue : t) : (stimulus * t) option =
  match queue.front with
  | s :: rest -> Some (s, { queue with front = rest; length = queue.length - 1 })
  | [] ->
    (match List.rev queue.back_rev with
     | [] -> None
     | s :: rest -> Some (s, { front = rest; back_rev = []; length = queue.length - 1 }))

let dedup_by_post_id ?(window_seconds = 60.0) (queue : t) : t =
  let within_window a b =
    Float.abs (a.arrived_at -. b.arrived_at) <= window_seconds
  in
  let rec aux acc = function
    | [] -> List.rev acc
    | s :: rest ->
        let later =
          List.filter
            (fun s' -> not (s'.post_id = s.post_id && within_window s s'))
            rest
        in
        aux (s :: acc) later
  in
  of_list (aux [] (to_list queue))

let sort_by_urgency (queue : t) : t =
  queue
  |> to_list
  |> List.stable_sort
       (fun a b -> Int.compare (urgency_rank a.urgency) (urgency_rank b.urgency))
  |> of_list

let payload_kind_label = function
  | Board_signal _ -> "board_signal"
  | Bootstrap -> "bootstrap"
  | No_progress_recovery -> "no_progress_recovery"
  | Fusion_completed _ -> "fusion_completed"

let is_board_signal = function
  | Board_signal _ -> true
  | Bootstrap | No_progress_recovery | Fusion_completed _ -> false

let drain_board_window ?(window_sec = 2.0) (queue : t) : stimulus list * t =
  let now = Unix.gettimeofday () in
  let is_board_in_window s =
    is_board_signal s.payload && Float.abs (now -. s.arrived_at) <= window_sec
  in
  let board, rest = List.partition is_board_in_window (to_list queue) in
  (to_list (sort_by_urgency (of_list board)), of_list rest)

let summary (queue : t) : string =
  Printf.sprintf "%d stimulus%s pending"
    queue.length
    (if queue.length = 1 then "" else "es")

let urgency_to_string = function
  | Immediate -> "immediate"
  | Normal -> "normal"
  | Low -> "low"

let urgency_of_string = function
  | "immediate" -> Ok Immediate
  | "normal" -> Ok Normal
  | "low" -> Ok Low
  | value -> Error (Printf.sprintf "unknown urgency: %s" value)

let board_stimulus_kind_to_string = function
  | Post_created -> "post_created"
  | Comment_added -> "comment_added"

let board_stimulus_kind_of_string = function
  | "post_created" -> Ok Post_created
  | "comment_added" -> Ok Comment_added
  | value -> Error (Printf.sprintf "unknown board stimulus kind: %s" value)

let option_json f = function
  | Some value -> f value
  | None -> `Null

let ( let* ) = Result.bind

let assoc_fields ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (Printf.sprintf "%s must be a JSON object" context)

let required_field ~context name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing required field %s" context name)

let optional_field name fields =
  match List.assoc_opt name fields with
  | Some `Null | None -> None
  | Some value -> Some value

let string_of_json ~context = function
  | `String value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a string" context)

let bool_of_json ~context = function
  | `Bool value -> Ok value
  | _ -> Error (Printf.sprintf "%s must be a boolean" context)

let float_of_json ~context = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (Printf.sprintf "%s must be a number" context)

let optional_string_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = string_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let optional_float_field ~context name fields =
  match optional_field name fields with
  | None -> Ok None
  | Some json ->
    let* value = float_of_json ~context:(context ^ "." ^ name) json in
    Ok (Some value)

let string_field ~context name fields =
  let* json = required_field ~context name fields in
  string_of_json ~context:(context ^ "." ^ name) json

let bool_field ~context name fields =
  let* json = required_field ~context name fields in
  bool_of_json ~context:(context ^ "." ^ name) json

let float_field ~context name fields =
  let* json = required_field ~context name fields in
  float_of_json ~context:(context ^ "." ^ name) json

let payload_to_yojson = function
  | Board_signal board ->
    `Assoc
      [ "kind", `String "board_signal"
      ; "board_kind", `String (board_stimulus_kind_to_string board.kind)
      ; "author", `String board.author
      ; "title", `String board.title
      ; "content", `String board.content
      ; "hearth", option_json (fun value -> `String value) board.hearth
      ; "updated_at_unix", option_json (fun value -> `Float value) board.updated_at
      ]
  | Bootstrap -> `Assoc [ "kind", `String "bootstrap" ]
  | No_progress_recovery -> `Assoc [ "kind", `String "no_progress_recovery" ]
  | Fusion_completed fusion ->
    `Assoc
      [ "kind", `String "fusion_completed"
      ; "run_id", `String fusion.run_id
      ; "ok", `Bool fusion.ok
      ; "resolved_answer", `String fusion.resolved_answer
      ; "board_post_id", `String fusion.board_post_id
      ]

let payload_of_yojson json =
  let context = "stimulus.payload" in
  let* fields = assoc_fields ~context json in
  let* kind = string_field ~context "kind" fields in
  match kind with
  | "board_signal" ->
    let* board_kind = string_field ~context "board_kind" fields in
    let* kind = board_stimulus_kind_of_string board_kind in
    let* author = string_field ~context "author" fields in
    let* title = string_field ~context "title" fields in
    let* content = string_field ~context "content" fields in
    let* hearth = optional_string_field ~context "hearth" fields in
    let* updated_at = optional_float_field ~context "updated_at_unix" fields in
    Ok (Board_signal { kind; author; title; content; hearth; updated_at })
  | "bootstrap" -> Ok Bootstrap
  | "no_progress_recovery" -> Ok No_progress_recovery
  | "fusion_completed" ->
    let* run_id = string_field ~context "run_id" fields in
    let* ok = bool_field ~context "ok" fields in
    let* resolved_answer = string_field ~context "resolved_answer" fields in
    let* board_post_id = string_field ~context "board_post_id" fields in
    Ok (Fusion_completed { run_id; ok; resolved_answer; board_post_id })
  | value -> Error (Printf.sprintf "unknown stimulus payload kind: %s" value)

let stimulus_to_yojson (stimulus : stimulus) =
  `Assoc
    [ "post_id", `String stimulus.post_id
    ; "urgency", `String (urgency_to_string stimulus.urgency)
    ; "arrived_at_unix", `Float stimulus.arrived_at
    ; "payload", payload_to_yojson stimulus.payload
    ]

let stimulus_of_yojson json =
  let context = "stimulus" in
  let* fields = assoc_fields ~context json in
  let* post_id = string_field ~context "post_id" fields in
  let* urgency_s = string_field ~context "urgency" fields in
  let* urgency = urgency_of_string urgency_s in
  let* arrived_at = float_field ~context "arrived_at_unix" fields in
  let* payload_json = required_field ~context "payload" fields in
  let* payload = payload_of_yojson payload_json in
  Ok { post_id; urgency; arrived_at; payload }

let schema = "keeper.event_queue.v1"

let queue_to_yojson queue =
  `Assoc
    [ "schema", `String schema
    ; "length", `Int (length queue)
    ; "items", `List (List.map stimulus_to_yojson (to_list queue))
    ]

let list_of_json ~context f = function
  | `List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* parsed = f item in
        loop (parsed :: acc) rest
    in
    loop [] items
  | _ -> Error (Printf.sprintf "%s must be a JSON list" context)

let queue_of_yojson json =
  let context = "keeper event queue snapshot" in
  let* fields = assoc_fields ~context json in
  let* schema_value = string_field ~context "schema" fields in
  if not (String.equal schema_value schema)
  then Error (Printf.sprintf "unsupported keeper event queue schema: %s" schema_value)
  else (
    let* items_json = required_field ~context "items" fields in
    let* items = list_of_json ~context:"keeper event queue snapshot.items" stimulus_of_yojson items_json in
    Ok (of_list items))
