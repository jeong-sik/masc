(** Keeper_behavior_trace — shadow trace harness foundation (P3-2). *)

type event =
  { agent : string
  ; turn : int
  ; tool : string
  ; arguments : Yojson.Safe.t
  }

type fixture =
  { name : string
  ; identity : string
  ; surface : string list
  ; events : event list
  }

type selector =
  | Any
  | Tool of string
  | Agent of string
  | Turn_range of int * int

let select s events =
  match s with
  | Any -> events
  | Tool name -> List.filter (fun e -> String.equal e.tool name) events
  | Agent name -> List.filter (fun e -> String.equal e.agent name) events
  | Turn_range (lo, hi) ->
    List.filter (fun e -> e.turn >= lo && e.turn <= hi) events
;;

let event_to_json e =
  `Assoc
    [ ("agent", `String e.agent)
    ; ("turn", `Int e.turn)
    ; ("tool", `String e.tool)
    ; ("arguments", e.arguments)
    ]
;;

let event_of_json = function
  | `Assoc fields ->
    let find key = List.assoc_opt key fields in
    (match find "agent", find "turn", find "tool", find "arguments" with
     | Some (`String agent), Some (`Int turn), Some (`String tool), Some arguments ->
       Ok { agent; turn; tool; arguments }
     | _ -> Error "event_of_json: missing or malformed fields")
  | _ -> Error "event_of_json: expected object"
;;

let fixture_to_json f =
  `Assoc
    [ ("name", `String f.name)
    ; ("identity", `String f.identity)
    ; ("surface", `List (List.map (fun s -> `String s) f.surface))
    ; ("events", `List (List.map event_to_json f.events))
    ]
;;

let fixture_of_json = function
  | `Assoc fields ->
    let find key = List.assoc_opt key fields in
    (match find "name", find "identity", find "surface", find "events" with
     | Some (`String name)
     , Some (`String identity)
     , Some (`List surface_jsons)
     , Some (`List event_jsons) ->
       let surface =
         List.filter_map
           (function
             | `String s -> Some s
             | _ -> None)
           surface_jsons
       in
       let rec parse_events acc = function
         | [] -> Ok (List.rev acc)
         | hd :: tl ->
           (match event_of_json hd with
            | Ok e -> parse_events (e :: acc) tl
            | Error _ as err -> err)
       in
       (match parse_events [] event_jsons with
        | Ok events -> Ok { name; identity; surface; events }
        | Error msg -> Error msg)
     | _ -> Error "fixture_of_json: missing or malformed fields")
  | _ -> Error "fixture_of_json: expected object"
;;
