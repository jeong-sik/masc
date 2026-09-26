(* The live route's three answers, parsed once into a closed type. The screen
   draws from [view]; it never looks at the JSON again. *)

type source = Msx | Dos

let source_kind = function Msx -> "msx_capture" | Dos -> "dos_capture"
let source_label = function Msx -> "MSX" | Dos -> "DOS"

type mark = { count : int; incarnation : string }
type time = Frame of int | Untimed

type picture = {
  width : int;
  height : int;
  rgb : string;
  mark : mark;
  time : time;
}

type answer = No_machine | Unchanged of mark | Picture of picture
type activity_entry = { at : float; who : string; action : string }
type activity = No_activity_feed | Activity of activity_entry list

let live_path = "/api/v1/lane-addons/live"

(* RFC 3986 unreserved characters pass; every other byte is escaped, so an
   incarnation can never add a parameter of its own. *)
let query_escape value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun c ->
      match c with
      | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' -> Buffer.add_char buf c
      | _ -> Buffer.add_string buf (Printf.sprintf "%%%02X" (Char.code c)))
    value;
  Buffer.contents buf

let path source ~since =
  let kind = "source_kind=" ^ source_kind source in
  match since with
  | None -> live_path ^ "?" ^ kind
  | Some { count; incarnation } ->
      Printf.sprintf "%s?%s&since=%d&incarnation=%s" live_path kind count
        (query_escape incarnation)

(* The server writes this name beside the pixels. *)
let rgb8_format = "rgb8"

let ( let* ) = Result.bind

let has_duplicates fields =
  let names = List.map fst fields in
  List.length names <> List.length (List.sort_uniq String.compare names)

let positive name = function
  | Some (`Int n) when n > 0 -> Ok n
  | Some _ | None -> Error ("live: " ^ name ^ " is not a positive integer")

let mark_of fields =
  match List.assoc_opt "change_count" fields, List.assoc_opt "incarnation" fields with
  | Some (`Int count), Some (`String incarnation) when count >= 0 && incarnation <> "" ->
      Ok { count; incarnation }
  | _, _ -> Error "live: change_count and incarnation do not name a mark"

(* Only MSX reports a frame number. A DOS answer that carried one would be a
   server answering for the wrong machine, so it is refused, not ignored. *)
let time_of source fields =
  match source, List.assoc_opt "frame_number" fields with
  | Msx, Some (`Int frame) when frame >= 0 -> Ok (Frame frame)
  | Dos, None -> Ok Untimed
  | Msx, _ -> Error "live: an MSX picture carries a nonnegative frame_number"
  | Dos, Some _ -> Error "live: a DOS picture carries no frame_number"

let screen_of = function
  | Some (`Assoc fields) when has_duplicates fields -> Error "live: duplicate screen fields"
  | Some (`Assoc fields) ->
      let* () = match List.assoc_opt "format" fields with
        | Some (`String format) when String.equal format rgb8_format -> Ok ()
        | Some _ | None -> Error "live: screen format is not rgb8" in
      let* width = positive "width" (List.assoc_opt "width" fields) in
      let* height = positive "height" (List.assoc_opt "height" fields) in
      let* () = if width <= max_int / 3 / height then Ok ()
        else Error "live: dimensions overflow" in
      let* rgb = match List.assoc_opt "rgb_base64" fields with
        | Some (`String encoded) -> (
            match Base64.decode encoded with
            | Ok rgb when String.length rgb = width * height * 3 -> Ok rgb
            | Ok rgb -> Error (Printf.sprintf "live: %d pixel bytes for a %dx%d picture"
                                 (String.length rgb) width height)
            | Error (`Msg detail) -> Error ("live: rgb_base64 does not decode: " ^ detail))
        | Some _ | None -> Error "live: rgb_base64 is not a string" in
      Ok (width, height, rgb)
  | Some _ | None -> Error "live: a changed answer carries no screen object"

let activity_entry_of index = function
  | `Assoc fields when has_duplicates fields ->
      Error (Printf.sprintf "live: duplicate activity[%d] fields" index)
  | `Assoc fields ->
      let* at = match List.assoc_opt "at" fields with
        | Some (`Int at) -> Ok (Float.of_int at)
        | Some (`Float at) when Float.is_finite at -> Ok at
        | Some _ | None ->
            Error (Printf.sprintf "live: activity[%d].at is not a finite number" index) in
      let string_field name =
        match List.assoc_opt name fields with
        | Some (`String value) -> Ok value
        | Some _ | None ->
            Error (Printf.sprintf "live: activity[%d].%s is not a string" index name)
      in
      let* who = string_field "who" in
      let* action = string_field "action" in
      Ok { at; who; action }
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error (Printf.sprintf "live: activity[%d] is not an object" index)

let activity_of source fields =
  match source, List.assoc_opt "activity" fields with
  | Msx, None -> Ok No_activity_feed
  | Msx, Some _ -> Error "live: an MSX answer carries no activity field"
  | Dos, Some (`List items) ->
      let rec entries index acc = function
        | [] -> Ok (Activity (List.rev acc))
        | item :: rest ->
            let* entry = activity_entry_of index item in
            entries (index + 1) (entry :: acc) rest
      in
      entries 0 [] items
  | Dos, (Some _ | None) -> Error "live: a DOS answer carries an activity array"

let decode source json =
  match json with
  | `Assoc fields when has_duplicates fields -> Error "live: duplicate fields"
  | `Assoc fields -> (
      let* () = match List.assoc_opt "source_kind" fields with
        | Some (`String kind) when String.equal kind (source_kind source) -> Ok ()
        | Some _ | None -> Error ("live: the answer is not for " ^ source_kind source) in
      let* answer = match List.assoc_opt "state" fields with
      | Some (`String "no_machine") -> Ok No_machine
      | Some (`String "unchanged") ->
          let* mark = mark_of fields in
          Ok (Unchanged mark)
      | Some (`String "changed") ->
          let* mark = mark_of fields in
          let* time = time_of source fields in
          let* width, height, rgb = screen_of (List.assoc_opt "screen" fields) in
          Ok (Picture { width; height; rgb; mark; time })
      | Some _ | None -> Error "live: state is not no_machine, unchanged or changed" in
      let* activity = activity_of source fields in
      Ok (answer, activity))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      Error "live: expected an object"

type view = Unread | Not_loaded | Showing of picture | Failed of string

let since = function
  | Showing picture -> Some picture.mark
  | Unread | Not_loaded | Failed _ -> None

let same_mark a b = a.count = b.count && String.equal a.incarnation b.incarnation

let advance view result =
  match result, view with
  | Ok (Unchanged mark), Showing drawn when same_mark mark drawn.mark -> None
  | Ok (Unchanged mark), (Showing _ | Unread | Not_loaded | Failed _) ->
      Some (Failed (Printf.sprintf
        "the server answered unchanged at change %d, which is not the drawn picture's"
        mark.count))
  | Ok No_machine, Not_loaded -> None
  | Ok No_machine, (Unread | Showing _ | Failed _) -> Some Not_loaded
  | Ok (Picture picture), (Unread | Not_loaded | Showing _ | Failed _) -> Some (Showing picture)
  | Error detail, (Unread | Not_loaded | Showing _ | Failed _) -> Some (Failed detail)
