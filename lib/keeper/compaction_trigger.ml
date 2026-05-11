type t =
  | Ratio_threshold of
      { ratio : float
      ; threshold : float
      }
  | Message_count of
      { count : int
      ; threshold : int
      }
  | Token_count of
      { count : int
      ; threshold : int
      }
  | Tool_heavy of
      { messages : int
      ; ratio : float
      }
  | Manual

let to_label = function
  | Ratio_threshold _ -> "ratio"
  | Message_count _ -> "messages"
  | Token_count _ -> "tokens"
  | Tool_heavy _ -> "tool_heavy"
  | Manual -> "manual"
;;

let to_human = function
  | Ratio_threshold { ratio; threshold } ->
    Printf.sprintf "ratio(%.4f>=%.4f)" ratio threshold
  | Message_count { count; threshold } ->
    Printf.sprintf "messages(%d>=%d)" count threshold
  | Token_count { count; threshold } -> Printf.sprintf "tokens(%d>=%d)" count threshold
  | Tool_heavy { messages; ratio } ->
    Printf.sprintf "tool_heavy(msgs=%d,ratio=%.4f)" messages ratio
  | Manual -> "manual"
;;

let to_detail_json : t -> Yojson.Safe.t = function
  | Ratio_threshold { ratio; threshold } ->
    `Assoc
      [ "kind", `String "ratio"; "ratio", `Float ratio; "threshold", `Float threshold ]
  | Message_count { count; threshold } ->
    `Assoc
      [ "kind", `String "messages"; "count", `Int count; "threshold", `Int threshold ]
  | Token_count { count; threshold } ->
    `Assoc [ "kind", `String "tokens"; "count", `Int count; "threshold", `Int threshold ]
  | Tool_heavy { messages; ratio } ->
    `Assoc
      [ "kind", `String "tool_heavy"; "messages", `Int messages; "ratio", `Float ratio ]
  | Manual -> `Assoc [ "kind", `String "manual" ]
;;

let of_detail_json (json : Yojson.Safe.t) : t option =
  match json with
  | `Assoc fields ->
    let str key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    let num_float key =
      match List.assoc_opt key fields with
      | Some (`Float f) -> Some f
      | Some (`Int i) -> Some (float_of_int i)
      | _ -> None
    in
    let num_int key =
      match List.assoc_opt key fields with
      | Some (`Int i) -> Some i
      | Some (`Intlit s) -> int_of_string_opt s
      | _ -> None
    in
    (match str "kind" with
     | Some "ratio" ->
       (match num_float "ratio", num_float "threshold" with
        | Some ratio, Some threshold -> Some (Ratio_threshold { ratio; threshold })
        | _ -> None)
     | Some "messages" ->
       (match num_int "count", num_int "threshold" with
        | Some count, Some threshold -> Some (Message_count { count; threshold })
        | _ -> None)
     | Some "tokens" ->
       (match num_int "count", num_int "threshold" with
        | Some count, Some threshold -> Some (Token_count { count; threshold })
        | _ -> None)
     | Some "tool_heavy" ->
       (match num_int "messages", num_float "ratio" with
        | Some messages, Some ratio -> Some (Tool_heavy { messages; ratio })
        | _ -> None)
     | Some "manual" -> Some Manual
     | _ -> None)
  | _ -> None
;;
