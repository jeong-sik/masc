module Event_map = Map.Make (String)

let schema = "board.signal_outbox.v2"

type recipient =
  | Keeper_lane of string
  | Target_identity of {
      identity : string;
      keeper_name : string option;
    }

let non_empty_identity context value =
  match String.trim value with
  | "" -> Error (context ^ " must be non-empty")
  | canonical when String.equal canonical value -> Ok canonical
  | _ -> Error (context ^ " must not have surrounding whitespace")
;;

let keeper_lane name =
  Result.map (fun name -> Keeper_lane name) (non_empty_identity "Keeper lane" name)
;;

let target_identity identity =
  Result.map
    (fun identity -> Target_identity { identity; keeper_name = None })
    (non_empty_identity "Board target identity" identity)
;;

type phase =
  | Prepared of Board_signal_command.t
  | Committed of {
      mutation : Board_signal_command.t;
      recipients : recipient list option;
      settled_recipients : recipient list;
    }
  | Delivered of {
      mutation : Board_signal_command.t;
      recipients : recipient list;
      at : float;
    }

type entry = {
  event_id : string;
  order : int;
  phase : phase;
}

let path () = Board_paths.signal_outbox_path ()

let exact_fields ~context expected fields =
  let field_names = List.map fst fields in
  let actual = List.sort_uniq String.compare field_names in
  let expected = List.sort_uniq String.compare expected in
  if List.length field_names <> List.length actual
  then Error (Printf.sprintf "%s contains duplicate fields" context)
  else if actual = expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields mismatch expected=[%s] actual=[%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let required_string ~context name fields =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal value "") -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a non-empty string" context name)
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let required_command ~context fields =
  match List.assoc_opt "payload" fields with
  | Some payload -> Board_signal_command.of_yojson payload
  | None -> Error (context ^ " missing payload")
;;

let required_finite_float ~context name fields =
  let value =
    match List.assoc_opt name fields with
    | Some (`Float value) -> Ok value
    | Some (`Int value) -> Ok (Float.of_int value)
    | Some _ -> Error (Printf.sprintf "%s.%s must be a number" context name)
    | None -> Error (Printf.sprintf "%s missing %s" context name)
  in
  Result.bind value (fun value ->
    if Float.is_finite value
    then Ok value
    else Error (Printf.sprintf "%s.%s must be finite" context name))
;;

let recipient_key = function
  | Keeper_lane name -> "keeper\000" ^ name
  | Target_identity { identity; keeper_name = _ } -> "target\000" ^ identity
;;

let compare_recipient left right = String.compare (recipient_key left) (recipient_key right)
let canonical_recipients recipients = List.sort_uniq compare_recipient recipients

let recipient_to_yojson = function
  | Keeper_lane name ->
    `Assoc [ "kind", `String "keeper_lane"; "name", `String name ]
  | Target_identity { identity; keeper_name } ->
    `Assoc
      [ "kind", `String "target_identity"
      ; "identity", `String identity
      ; ( "keeper_name"
        , match keeper_name with
          | None -> `Null
          | Some name -> `String name )
      ]
;;

let recipient_of_yojson = function
  | `Assoc fields ->
    let context = "Board signal recipient" in
    let ( let* ) = Result.bind in
    let* kind = required_string ~context "kind" fields in
    (match kind with
     | "keeper_lane" ->
       let* () = exact_fields ~context [ "kind"; "name" ] fields in
       let* name = required_string ~context "name" fields in
       keeper_lane name
     | "target_identity" ->
       let* () =
         exact_fields ~context [ "kind"; "identity"; "keeper_name" ] fields
       in
       let* identity = required_string ~context "identity" fields in
       let* identity = non_empty_identity "Board target identity" identity in
       let* keeper_name =
         match List.assoc_opt "keeper_name" fields with
         | Some `Null -> Ok None
         | Some (`String name) ->
           Result.map
             (fun name -> Some name)
             (non_empty_identity "Resolved Keeper lane" name)
         | Some _ -> Error (context ^ ".keeper_name must be a string or null")
         | None -> Error (context ^ " missing keeper_name")
       in
       Ok (Target_identity { identity; keeper_name })
     | unknown -> Error (Printf.sprintf "%s.kind is unknown: %S" context unknown))
  | _ -> Error "Board signal recipient must be an object"
;;

let required_recipient_list ~context name fields =
  match List.assoc_opt name fields with
  | Some (`List values) ->
    let rec collect acc = function
      | [] -> Ok (List.rev acc)
      | value :: rest ->
        Result.bind (recipient_of_yojson value) (fun recipient ->
          collect (recipient :: acc) rest)
    in
    collect [] values
  | Some _ -> Error (Printf.sprintf "%s.%s must be an array" context name)
  | None -> Error (Printf.sprintf "%s missing %s" context name)
;;

let apply_row ~order index json =
  let context = "board signal outbox row" in
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* row_schema = required_string ~context "schema" fields in
    if not (String.equal row_schema schema)
    then Error (Printf.sprintf "%s has unsupported schema %S" context row_schema)
    else
      let* event_id = required_string ~context "event_id" fields in
      let* phase_name = required_string ~context "phase" fields in
      let prior = Event_map.find_opt event_id index in
      (match phase_name with
       | "prepared" ->
         let* () = exact_fields ~context [ "schema"; "event_id"; "phase"; "payload" ] fields in
         let* command = required_command ~context fields in
         (match prior with
          | None ->
            Ok (Event_map.add event_id { event_id; order; phase = Prepared command } index)
          | Some _ -> Error (Printf.sprintf "duplicate prepare event_id=%s" event_id))
       | "committed" ->
         let* () = exact_fields ~context [ "schema"; "event_id"; "phase" ] fields in
         (match prior with
          | Some ({ phase = Prepared mutation; _ } as prepared) ->
            Ok
              (Event_map.add
                 event_id
                 { prepared with
                   phase =
                     Committed
                       { mutation; recipients = None; settled_recipients = [] }
                 }
                 index)
          | Some _ | None ->
            Error (Printf.sprintf "commit without prepared event_id=%s" event_id))
       | "delivery_planned" ->
         let* () =
           exact_fields
             ~context
             [ "schema"; "event_id"; "phase"; "recipients" ]
             fields
         in
         let* recipients = required_recipient_list ~context "recipients" fields in
         let contains_resolved_target =
           List.exists
             (function
               | Target_identity { keeper_name = Some _; _ } -> true
               | Keeper_lane _ | Target_identity { keeper_name = None; _ } -> false)
             recipients
         in
         if recipients <> canonical_recipients recipients
         then Error (Printf.sprintf "non-canonical recipient plan event_id=%s" event_id)
         else if contains_resolved_target
         then Error (Printf.sprintf "recipient plan contains resolved target event_id=%s" event_id)
         else
           (match prior with
            | Some
                ({ phase =
                     Committed
                       { mutation; recipients = None; settled_recipients = [] }
                 ; _
                 } as committed) ->
              Ok
                (Event_map.add
                   event_id
                   { committed with
                     phase =
                       Committed
                         { mutation
                         ; recipients = Some recipients
                         ; settled_recipients = []
                         }
                   }
                   index)
            | Some _ | None ->
              Error
                (Printf.sprintf
                   "recipient plan without unplanned commit event_id=%s"
                   event_id))
       | "target_resolved" ->
         let* () =
           exact_fields
             ~context
             [ "schema"; "event_id"; "phase"; "identity"; "keeper_name" ]
             fields
         in
         let* identity = required_string ~context "identity" fields in
         let* identity = non_empty_identity "Board target identity" identity in
         let* keeper_name = required_string ~context "keeper_name" fields in
         let* keeper_name = non_empty_identity "Resolved Keeper lane" keeper_name in
         (match prior with
          | Some
              ({ phase =
                   Committed
                     { mutation; recipients = Some recipients; settled_recipients }
               ; _
               } as committed) ->
            let rejected =
              List.exists
                (function
                  | Target_identity
                      { identity = rejected_identity; keeper_name = None } ->
                    String.equal rejected_identity identity
                  | Keeper_lane _
                  | Target_identity { keeper_name = Some _; _ } -> false)
                settled_recipients
            in
            let matching =
              List.filter
                (function
                  | Target_identity { identity = planned; _ } ->
                    String.equal planned identity
                  | Keeper_lane _ -> false)
                recipients
            in
            if rejected
            then
              Error
                (Printf.sprintf
                   "target resolution after terminal rejection event_id=%s identity=%s"
                   event_id
                   identity)
            else
            (match matching with
             | [ Target_identity { keeper_name = None; _ } ] ->
               let recipients =
                 List.map
                   (function
                     | Target_identity { identity = planned; keeper_name = None }
                       when String.equal planned identity ->
                       Target_identity { identity; keeper_name = Some keeper_name }
                     | recipient -> recipient)
                   recipients
               in
               Ok
                 (Event_map.add
                    event_id
                    { committed with
                      phase =
                        Committed
                          { mutation; recipients = Some recipients; settled_recipients }
                    }
                    index)
             | [ Target_identity { keeper_name = Some _; _ } ] ->
               Error (Printf.sprintf "duplicate target resolution event_id=%s identity=%s" event_id identity)
             | [] | _ ->
               Error (Printf.sprintf "resolution for unplanned target event_id=%s identity=%s" event_id identity))
          | Some _ | None ->
            Error (Printf.sprintf "target resolution without plan event_id=%s" event_id))
       | ("recipient_rejected" | "recipient_settled") as terminal_phase ->
         let* () =
           exact_fields
             ~context
             [ "schema"; "event_id"; "phase"; "recipient" ]
             fields
         in
         let* recipient_json =
           match List.assoc_opt "recipient" fields with
           | Some value -> Ok value
           | None -> Error (context ^ " missing recipient")
         in
         let* recipient = recipient_of_yojson recipient_json in
         let phase_matches_recipient =
           match terminal_phase, recipient with
           | "recipient_rejected", Target_identity { keeper_name = None; _ } -> true
           | ( "recipient_settled"
             , (Keeper_lane _ | Target_identity { keeper_name = Some _; _ }) ) -> true
           | _ -> false
         in
         let* () =
           if phase_matches_recipient
           then Ok ()
           else Error (terminal_phase ^ " has incompatible recipient state")
         in
         (match prior with
          | Some
              ({ phase =
                   Committed
                     { mutation; recipients = Some recipients; settled_recipients }
               ; _
               } as committed) ->
            if not (List.exists (( = ) recipient) recipients)
            then
              Error
                (Printf.sprintf
                   "settlement for unplanned recipient event_id=%s recipient=%s"
                   event_id
                   (Yojson.Safe.to_string (recipient_to_yojson recipient)))
            else if List.exists (( = ) recipient) settled_recipients
            then
              Error
                (Printf.sprintf
                   "duplicate recipient settlement event_id=%s recipient=%s"
                   event_id
                   (Yojson.Safe.to_string (recipient_to_yojson recipient)))
            else
              Ok
                (Event_map.add
                   event_id
                   { committed with
                     phase =
                       Committed
                         { mutation
                         ; recipients = Some recipients
                         ; settled_recipients =
                             List.sort_uniq compare_recipient
                               (recipient :: settled_recipients)
                         }
                   }
                   index)
          | Some _ | None ->
            Error
              (Printf.sprintf
                 "recipient settlement without plan event_id=%s"
                 event_id))
       | "delivered" ->
         let* () = exact_fields ~context [ "schema"; "event_id"; "phase"; "at" ] fields in
         let* at = required_finite_float ~context "at" fields in
         (match prior with
          | Some
              ({ phase =
                   Committed { mutation; recipients; settled_recipients }
               ; _
               } as committed) ->
            (match recipients with
            | Some planned when planned = settled_recipients ->
              Ok
                (Event_map.add
                   event_id
                   { committed with
                     phase = Delivered { mutation; recipients = planned; at }
                   }
                   index)
            | None | Some _ ->
              Error
                (Printf.sprintf
                   "delivery with unsettled recipients event_id=%s"
                   event_id))
          | Some _ | None ->
            Error (Printf.sprintf "delivery without committed event_id=%s" event_id))
       | unknown -> Error (Printf.sprintf "unknown outbox phase %S" unknown))
  | _ -> Error (context ^ " must be an object")
;;

let parse_bytes bytes =
  let lines_result =
    if String.equal bytes ""
    then Ok []
    else
      match List.rev (String.split_on_char '\n' bytes) with
      | "" :: reversed_lines ->
        let lines = List.rev reversed_lines in
        (match List.find_index (String.equal "") lines with
         | None -> Ok lines
         | Some index -> Error (Printf.sprintf "line %d: blank JSONL row" (index + 1)))
      | _ -> Error "board signal outbox is not newline-terminated"
  in
  let rec loop line_number index = function
    | [] -> Ok index
    | line :: rest ->
      (match Yojson.Safe.from_string line with
       | json ->
         (match apply_row ~order:line_number index json with
          | Ok next -> loop (line_number + 1) next rest
          | Error detail -> Error (Printf.sprintf "line %d: %s" line_number detail))
       | exception Yojson.Json_error detail ->
         Error (Printf.sprintf "line %d: invalid JSON: %s" line_number detail))
  in
  Result.bind lines_result (loop 1 Event_map.empty)
;;

let load_snapshot expected_path =
  match
    Fs_compat.read_private_jsonl_durable_locked_result expected_path ~after:None
  with
  | Error error -> Error (Fs_compat.private_jsonl_transaction_error_to_string error)
  | Ok snapshot ->
    Result.map (fun entries -> snapshot, entries) (parse_bytes snapshot.bytes)
;;

let row_to_suffix row = Yojson.Safe.to_string row ^ "\n"

type transition_decision =
  | Append
  | Unchanged

let transition ~make_row ~decide =
  match
    Fs_compat.transact_private_jsonl_durable_locked_result (path ()) (fun existing ->
      match Result.bind (parse_bytes existing) decide with
      | Error _ as error -> error
      | Ok Append -> Ok (Some (row_to_suffix (make_row ())), ())
      | Ok Unchanged -> Ok (None, ()))
  with
  | Ok result -> result
  | Error error -> Error (Fs_compat.private_jsonl_transaction_error_to_string error)
;;

let validate_event_id event_id =
  if String.equal event_id ""
  then Error "board signal outbox event_id must be non-empty"
  else Ok ()
;;

let command_equal left right =
  Yojson.Safe.equal
    (Board_signal_command.to_yojson left)
    (Board_signal_command.to_yojson right)
;;

let prepare ~event_id ~command =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let payload = Board_signal_command.to_yojson command in
  transition
    ~make_row:(fun () ->
        `Assoc
          [ "schema", `String schema
          ; "event_id", `String event_id
          ; "phase", `String "prepared"
          ; "payload", payload
          ])
    ~decide:(fun current ->
        match Event_map.find_opt event_id current with
        | None -> Ok Append
        | Some { phase = Prepared existing; _ }
        | Some { phase = Committed { mutation = existing; _ }; _ }
        | Some { phase = Delivered { mutation = existing; _ }; _ }
          when command_equal existing command -> Ok Unchanged
        | Some _ ->
          Error (Printf.sprintf "prepare payload conflict event_id=%s" event_id))
;;

let commit ~event_id =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  transition
    ~make_row:(fun () ->
      `Assoc
        [ "schema", `String schema
        ; "event_id", `String event_id
        ; "phase", `String "committed"
        ])
    ~decide:(fun current ->
      match Event_map.find_opt event_id current with
      | Some { phase = Prepared _; _ } -> Ok Append
      | Some { phase = Committed _; _ } | Some { phase = Delivered _; _ } ->
        Ok Unchanged
      | None -> Error (Printf.sprintf "commit without prepared event_id=%s" event_id))
;;

type recipient_progress =
  | Recipients_unplanned
  | Recipients_pending of recipient list
  | Recipients_settled

let plan_recipients ~event_id ~recipients =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* () =
    if
      List.exists
        (function
          | Target_identity { keeper_name = Some _; _ } -> true
          | Keeper_lane _ | Target_identity { keeper_name = None; _ } -> false)
        recipients
    then Error "Board recipient plan cannot contain an already resolved target"
    else Ok ()
  in
  let recipients = canonical_recipients recipients in
  transition
    ~make_row:(fun () ->
      `Assoc
        [ "schema", `String schema
        ; "event_id", `String event_id
        ; "phase", `String "delivery_planned"
        ; "recipients", `List (List.map recipient_to_yojson recipients)
        ])
    ~decide:(fun current ->
      match Event_map.find_opt event_id current with
      | Some
          { phase = Committed { recipients = None; settled_recipients = []; _ }; _ }
        -> Ok Append
      | Some
          { phase =
              Committed
                { recipients = Some existing; settled_recipients = _; _ }
          ; _
          }
        when existing = recipients -> Ok Unchanged
      | Some { phase = Committed _; _ } ->
        Error (Printf.sprintf "recipient plan conflict event_id=%s" event_id)
      | Some { phase = Prepared _; _ } | Some { phase = Delivered _; _ } | None ->
        Error (Printf.sprintf "recipient plan without committed event_id=%s" event_id))
;;

let recipient_progress ~event_id =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* _, index = load_snapshot (path ()) in
  let current =
    Event_map.bindings index
    |> List.map snd
    |> List.sort (fun left right -> Int.compare left.order right.order)
  in
  match List.find_opt (fun entry -> String.equal entry.event_id event_id) current with
  | Some { phase = Committed { recipients = None; _ }; _ } -> Ok Recipients_unplanned
  | Some
      { phase =
          Committed
            { recipients = Some recipients; settled_recipients; _ }
      ; _
      } ->
    let pending =
      List.filter
        (fun recipient ->
           not (List.exists (( = ) recipient) settled_recipients))
        recipients
    in
    if pending = [] then Ok Recipients_settled else Ok (Recipients_pending pending)
  | Some { phase = Delivered _; _ } -> Ok Recipients_settled
  | Some { phase = Prepared _; _ } | None ->
    Error (Printf.sprintf "recipient progress without committed event_id=%s" event_id)
;;

let resolve_target ~event_id ~identity ~keeper_name =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* identity = non_empty_identity "Board target identity" identity in
  let* keeper_name = non_empty_identity "Resolved Keeper lane" keeper_name in
  let* () =
    transition
      ~make_row:(fun () ->
        `Assoc
          [ "schema", `String schema
          ; "event_id", `String event_id
          ; "phase", `String "target_resolved"
          ; "identity", `String identity
          ; "keeper_name", `String keeper_name
          ])
      ~decide:(fun current ->
        match Event_map.find_opt event_id current with
        | Some
            { phase =
                Committed
                  { recipients = Some recipients; settled_recipients; _ }
            ; _
            } ->
          let rejected =
            List.exists
              (function
                | Target_identity
                    { identity = rejected_identity; keeper_name = None } ->
                  String.equal rejected_identity identity
                | Keeper_lane _
                | Target_identity { keeper_name = Some _; _ } -> false)
              settled_recipients
          in
          if rejected
          then
            Error
              (Printf.sprintf
                 "target resolution after terminal rejection event_id=%s identity=%s"
                 event_id
                 identity)
          else
          (match
             List.find_opt
               (function
                 | Target_identity { identity = planned; _ } ->
                   String.equal planned identity
                 | Keeper_lane _ -> false)
               recipients
           with
           | Some (Target_identity { keeper_name = None; _ }) -> Ok Append
           | Some (Target_identity { keeper_name = Some existing; _ })
             when String.equal existing keeper_name -> Ok Unchanged
           | Some (Target_identity { keeper_name = Some existing; _ }) ->
             Error
               (Printf.sprintf
                  "target binding conflict event_id=%s identity=%s existing=%s requested=%s"
                  event_id
                  identity
                  existing
                  keeper_name)
           | Some (Keeper_lane _) | None ->
             Error
               (Printf.sprintf
                  "resolution for unplanned target event_id=%s identity=%s"
                  event_id
                  identity))
        | Some _ | None ->
          Error (Printf.sprintf "target resolution without plan event_id=%s" event_id))
  in
  let* _, index = load_snapshot (path ()) in
  let current = Event_map.bindings index |> List.map snd in
  match
    List.find_opt (fun entry -> String.equal entry.event_id event_id) current
  with
  | Some { phase = Committed { recipients = Some recipients; _ }; _ }
  | Some { phase = Delivered { recipients; _ }; _ } ->
    (match
       List.find_opt
         (function
           | Target_identity { identity = planned; keeper_name = Some _ } ->
             String.equal planned identity
           | Keeper_lane _ | Target_identity { keeper_name = None; _ } -> false)
         recipients
     with
     | Some recipient -> Ok recipient
     | None -> Error (Printf.sprintf "resolved target is absent event_id=%s identity=%s" event_id identity))
  | Some _ | None ->
    Error (Printf.sprintf "resolved target event is absent event_id=%s" event_id)
;;

let settle_recipient ~event_id ~recipient =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* () =
    match recipient with
    | Target_identity { keeper_name = None; _ } ->
      Error "An unresolved Board target cannot be settled as delivered"
    | Keeper_lane _ | Target_identity { keeper_name = Some _; _ } -> Ok ()
  in
  transition
    ~make_row:(fun () ->
      `Assoc
        [ "schema", `String schema
        ; "event_id", `String event_id
        ; "phase", `String "recipient_settled"
        ; "recipient", recipient_to_yojson recipient
        ])
    ~decide:(fun current ->
      match Event_map.find_opt event_id current with
      | Some
          { phase =
              Committed
                { recipients = Some recipients; settled_recipients; _ }
          ; _
          } ->
        if not (List.exists (( = ) recipient) recipients)
        then
          Error
            (Printf.sprintf
               "settlement for unplanned recipient event_id=%s recipient=%s"
               event_id
               (Yojson.Safe.to_string (recipient_to_yojson recipient)))
        else if List.exists (( = ) recipient) settled_recipients
        then Ok Unchanged
        else Ok Append
      | Some { phase = Delivered { recipients; _ }; _ }
        when List.exists (( = ) recipient) recipients -> Ok Unchanged
      | Some { phase = Delivered _; _ } ->
        Error (Printf.sprintf "settlement does not belong to delivered event_id=%s" event_id)
      | Some { phase = Prepared _; _ }
      | Some { phase = Committed { recipients = None; _ }; _ }
      | None ->
        Error (Printf.sprintf "recipient settlement without plan event_id=%s" event_id))
;;

let reject_target ~event_id ~identity =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* identity = non_empty_identity "Board target identity" identity in
  let recipient = Target_identity { identity; keeper_name = None } in
  transition
    ~make_row:(fun () ->
      `Assoc
        [ "schema", `String schema
        ; "event_id", `String event_id
        ; "phase", `String "recipient_rejected"
        ; "recipient", recipient_to_yojson recipient
        ])
    ~decide:(fun current ->
      match Event_map.find_opt event_id current with
      | Some
          { phase =
              Committed
                { recipients = Some recipients; settled_recipients; _ }
          ; _
          } ->
        if not (List.exists (( = ) recipient) recipients)
        then
          Error
            (Printf.sprintf
               "rejection for unplanned target event_id=%s identity=%s"
               event_id
               identity)
        else if List.exists (( = ) recipient) settled_recipients
        then Ok Unchanged
        else Ok Append
      | Some { phase = Delivered { recipients; _ }; _ }
        when List.exists (( = ) recipient) recipients -> Ok Unchanged
      | Some { phase = Delivered _; _ } ->
        Error (Printf.sprintf "rejection does not belong to delivered event_id=%s" event_id)
      | Some _ | None ->
        Error (Printf.sprintf "target rejection without plan event_id=%s" event_id))
;;

let mark_delivered ~event_id ~at =
  let ( let* ) = Result.bind in
  let* () = validate_event_id event_id in
  let* () = if Float.is_finite at then Ok () else Error "board signal outbox delivery time must be finite" in
  transition
    ~make_row:(fun () ->
      `Assoc
        [ "schema", `String schema
        ; "event_id", `String event_id
        ; "phase", `String "delivered"
        ; "at", `Float at
        ])
    ~decide:(fun current ->
      match Event_map.find_opt event_id current with
      | Some
          { phase = Committed { recipients = None; _ }; _ } ->
        Error (Printf.sprintf "delivery without recipient plan event_id=%s" event_id)
      | Some
          { phase =
              Committed
                { recipients = Some recipients; settled_recipients; _ }
          ; _
          }
        when recipients = settled_recipients -> Ok Append
      | Some { phase = Committed _; _ } ->
        Error (Printf.sprintf "delivery with unsettled recipients event_id=%s" event_id)
      | Some { phase = Delivered _; _ } -> Ok Unchanged
      | Some _ | None ->
        Error (Printf.sprintf "delivery without committed event_id=%s" event_id))
;;

let entries () =
  Result.map
    (fun (_, index) ->
       Event_map.bindings index
       |> List.map snd
       |> List.sort (fun left right -> Int.compare left.order right.order))
    (load_snapshot (path ()))
;;

let transition_row ~event_id ~phase ~payload =
  `Assoc
    [ "schema", `String schema
    ; "event_id", `String event_id
    ; "phase", `String phase
    ; "payload", payload
    ]
;;

let unresolved_recipient = function
  | Keeper_lane _ as recipient -> recipient
  | Target_identity { identity; keeper_name = _ } ->
    Target_identity { identity; keeper_name = None }
;;

let recipient_state_rows ~event_id ~recipients ~settled_recipients =
  let initial_plan = List.map unresolved_recipient recipients in
  [ `Assoc
      [ "schema", `String schema
      ; "event_id", `String event_id
      ; "phase", `String "delivery_planned"
      ; "recipients", `List (List.map recipient_to_yojson initial_plan)
      ]
  ]
  @ List.filter_map
      (function
        | Target_identity { identity; keeper_name = Some keeper_name } ->
          Some
            (`Assoc
              [ "schema", `String schema
              ; "event_id", `String event_id
              ; "phase", `String "target_resolved"
              ; "identity", `String identity
              ; "keeper_name", `String keeper_name
              ])
        | Keeper_lane _ | Target_identity { keeper_name = None; _ } -> None)
      recipients
  @ List.map
      (fun recipient ->
         let phase =
           match recipient with
           | Target_identity { keeper_name = None; _ } -> "recipient_rejected"
           | Keeper_lane _ | Target_identity { keeper_name = Some _; _ } ->
             "recipient_settled"
         in
         `Assoc
           [ "schema", `String schema
           ; "event_id", `String event_id
           ; "phase", `String phase
           ; "recipient", recipient_to_yojson recipient
           ])
      settled_recipients
;;

let event_rows (entry : entry) =
  match entry.phase with
  | Prepared command ->
    let payload = Board_signal_command.to_yojson command in
    [ transition_row ~event_id:entry.event_id ~phase:"prepared" ~payload ]
  | Committed { mutation; recipients; settled_recipients } ->
    let payload = Board_signal_command.to_yojson mutation in
    [ transition_row ~event_id:entry.event_id ~phase:"prepared" ~payload
    ; `Assoc
        [ "schema", `String schema
        ; "event_id", `String entry.event_id
        ; "phase", `String "committed"
        ]
    ]
    @ (match recipients with
       | None -> []
       | Some recipients ->
         recipient_state_rows
           ~event_id:entry.event_id
           ~recipients
           ~settled_recipients)
  | Delivered { mutation; recipients; at } ->
    let payload = Board_signal_command.to_yojson mutation in
    [ transition_row ~event_id:entry.event_id ~phase:"prepared" ~payload
    ; `Assoc
        [ "schema", `String schema
        ; "event_id", `String entry.event_id
        ; "phase", `String "committed"
        ]
    ]
    @ recipient_state_rows
        ~event_id:entry.event_id
        ~recipients
        ~settled_recipients:recipients
    @ [ `Assoc
        [ "schema", `String schema
        ; "event_id", `String entry.event_id
        ; "phase", `String "delivered"
        ; "at", `Float at
        ]
    ]
;;

let is_pending (entry : entry) =
  match entry.phase with
  | Prepared _ | Committed _ -> true
  | Delivered _ -> false
;;

let compact_terminal () =
  let expected_path = path () in
  match
    Fs_compat.read_private_jsonl_durable_locked_result expected_path ~after:None
  with
  | Error error -> Error (Fs_compat.private_jsonl_transaction_error_to_string error)
  | Ok snapshot ->
    (match parse_bytes snapshot.bytes with
     | Error _ as error -> error
     | Ok current ->
       let ordered =
         Event_map.bindings current
         |> List.map snd
         |> List.sort (fun left right -> Int.compare left.order right.order)
       in
       let retained =
         match List.find_opt is_pending ordered with
         | None -> []
         | Some first_pending ->
           List.filter (fun entry -> entry.order >= first_pending.order) ordered
       in
       let content =
         retained
         |> List.concat_map event_rows
         |> List.map row_to_suffix
         |> String.concat ""
       in
       (match
          Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
            expected_path
            ~expected:snapshot.cursor
            content
        with
        | Error error -> Error (Fs_compat.private_jsonl_transaction_error_to_string error)
        | Ok _cursor -> Ok ()))
;;
