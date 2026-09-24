module Sources = Lane_addon_sources

type machine_time = Msx_frame of int | Dos_steps of int
type screen = {
  width : int; height : int; rgb : string; time : machine_time;
  incarnation : string; counter : int;
}
type reading = Not_loaded | Unchanged of int | Loaded of screen
type error = Capture_failed of string

let error_to_string (Capture_failed detail) = "machine capture failed: " ^ detail

type capture = Sources.live_reader -> since:int option -> (reading, error) result

(* The counter alone decides "unchanged", so an unchanged answer never copies
   a frame. A counter that moved between the two reads is simply read again
   with the picture. *)
let counted ~since ~changes ~capture =
  match changes () with
  | None -> Ok Not_loaded
  | Some counter when since = Some counter -> Ok (Unchanged counter)
  | Some _ -> capture ()

let msx_capture () =
  match Msx_lane.capture_with_identity () with
  | Ok c -> Ok (Loaded { width = c.frame.width; height = c.frame.height; rgb = c.frame.rgb;
      time = Msx_frame c.frame.number; incarnation = c.incarnation; counter = c.changes })
  | Error Msx_lane.No_machine -> Ok Not_loaded
  | Error (Msx_lane.Invalid_request _ | Msx_lane.Unreadable _ as e) ->
      Error (Capture_failed (Msx_lane.error_to_string e))

let dos_capture () =
  match Dos_lane.capture_with_identity () with
  | Ok c -> Ok (Loaded { width = c.frame.width; height = c.frame.height; rgb = c.frame.rgb;
      time = Dos_steps c.observation.steps; incarnation = c.incarnation; counter = c.changes })
  | Error Dos_lane.No_machine -> Ok Not_loaded
  | Error (Dos_lane.Invalid_request _ | Dos_lane.Unreadable _ | Dos_lane.Held_by _
          | Dos_lane.Guest_fault _ as e) ->
      Error (Capture_failed (Dos_lane.error_to_string e))

let machine_capture : capture = fun reader ~since ->
  match reader with
  | Sources.Msx_screen -> counted ~since ~changes:Msx_lane.loaded_changes ~capture:msx_capture
  | Sources.Dos_screen -> counted ~since ~changes:Dos_lane.loaded_changes ~capture:dos_capture

let on_systhread (capture : capture) : capture = fun reader ~since ->
  Eio_unix.run_in_systhread (fun () -> capture reader ~since)

let default_capture = on_systhread machine_capture

let reader_of_kind name =
  match Sources.kind_of_string name with
  | None -> Error ("unknown source kind: " ^ name)
  | Some kind ->
      (match Sources.live_screen_of_kind kind with
       | Some reader -> Ok reader
       | None -> Error (name ^ " has no live screen"))

let time_field = function
  | Msx_frame frame -> "frame", `Int frame
  | Dos_steps steps -> "steps", `Int steps

let reading_json = function
  | Not_loaded -> `Assoc ["loaded", `Bool false]
  | Unchanged counter -> `Assoc ["changed", `Bool false; "counter", `Int counter]
  | Loaded s ->
      `Assoc (("loaded", `Bool true) :: ("changed", `Bool true)
        :: Sources.screen_image_fields ~width:s.width ~height:s.height ~rgb:s.rgb
        @ [time_field s.time; "counter", `Int s.counter; "incarnation", `String s.incarnation])

let read ~reader ~since ~(capture : capture) =
  Result.map reading_json (capture reader ~since)
