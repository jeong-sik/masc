(* Writes the AG-UI frame fixtures native clients decode
   (apps/fixtures/keeper_chat/). Each frame is the server encoder's output
   for one case, with object keys sorted, so the fixture compares JSON
   values: an encoder that writes the same keys in another order leaves it
   unchanged.

   agui_frames.json lists {case, frame}. agui_frames.sse carries the same
   frames as one SSE stream framed by the server's Sse_wire, with ids from 1. *)

let frame_json event = Agui_frame_cases.normalize (Ag_ui.event_to_json event)

let json () =
  `List
    (List.map
       (fun (name, event) -> `Assoc [ "case", `String name; "frame", frame_json event ])
       Agui_frame_cases.cases)
  |> Yojson.Safe.pretty_to_string
  |> print_endline

let sse () =
  List.iteri
    (fun index (_, event) ->
      print_string (Sse_wire.format_event_yojson ~id:(index + 1) (frame_json event)))
    Agui_frame_cases.cases

let () =
  match Sys.argv with
  | [| _; "json" |] -> json ()
  | [| _; "sse" |] -> sse ()
  | _ ->
    prerr_endline "usage: emit_agui_fixtures (json|sse)";
    exit 2
