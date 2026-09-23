(* The DOS spectator's reading of [GET /api/v1/dos/frame] (#38424).

   A DOS frame is about 1.2 MB of base64 and changes only when a tool call
   moves the machine, so a poll names the frame it already holds -- its
   incarnation and step count -- and the server answers [pixels:"unchanged"]
   while that is still the machine's frame. This module turns an answer back
   into a whole [dos_frame], reusing the held pixels when the server says they
   are current. It does no I/O; [Masc_tui_http] asks and hands the JSON here. *)

(* The query that names the held frame, or none when nothing is held. *)
let known_query (held : Masc_tui_types.dos_frame option) : (string * string) list =
  match held with
  | None -> []
  | Some f -> [ ("incarnation", f.dos_incarnation); ("steps", string_of_int f.dos_steps) ]

(* How the server sent the pixels. A wire value that is neither is refused,
   not read as one of them. *)
type pixels = Inline of string | Unchanged

let ( let* ) = Result.bind

let field name fields =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> Error ("DOS frame: missing " ^ name)

let int_field name fields =
  let* v = field name fields in
  match v with
  | `Int n -> Ok n
  | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ | `Assoc _ ->
    Error ("DOS frame: " ^ name ^ " is not an integer")

let string_field name fields =
  let* v = field name fields in
  match v with
  | `String s -> Ok s
  | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null | `List _ | `Assoc _ ->
    Error ("DOS frame: " ^ name ^ " is not a string")

let optional_string_field name fields =
  let* v = field name fields in
  match v with
  | `String s -> Ok (Some s)
  | `Null -> Ok None
  | `Int _ | `Intlit _ | `Float _ | `Bool _ | `List _ | `Assoc _ ->
    Error ("DOS frame: " ^ name ^ " is neither a string nor null")

let pixels_of fields =
  let* kind = string_field "pixels" fields in
  match kind with
  | "inline" ->
    let* encoded = string_field "rgb_base64" fields in
    (match Base64.decode encoded with
     | Ok rgb -> Ok (Inline rgb)
     | Error (`Msg m) -> Error ("DOS frame: rgb_base64 does not decode: " ^ m))
  | "unchanged" -> Ok Unchanged
  | other -> Error ("DOS frame: unknown pixels kind " ^ other)

(* [held] is the frame the poll named. [Ok None] is the server saying no
   machine is loaded; [Error] is an answer that cannot be read, which the
   spectator shows rather than treating as an empty machine. *)
let decode ~(held : Masc_tui_types.dos_frame option) (json : Yojson.Safe.t) :
    (Masc_tui_types.dos_frame option, string) result =
  match json with
  | `Assoc fields -> (
    let* loaded = field "loaded" fields in
    match loaded with
    | `Bool false -> Ok None
    | `Bool true ->
      let* incarnation = string_field "incarnation" fields in
      let* steps = int_field "steps" fields in
      let* program = optional_string_field "program" fields in
      let* controller = optional_string_field "controller" fields in
      let* video_mode = int_field "video_mode" fields in
      let* width = int_field "width" fields in
      let* height = int_field "height" fields in
      let* () =
        if width > 0 && height > 0 && width <= max_int / 3 / height then Ok ()
        else Error "DOS frame: width and height must be positive"
      in
      let* pixels = pixels_of fields in
      let* rgb =
        match pixels, held with
        | Inline rgb, _ when String.length rgb = width * height * 3 -> Ok rgb
        | Inline _, _ -> Error "DOS frame: rgb is not width x height x 3 bytes"
        | Unchanged, Some h
          when String.equal h.dos_incarnation incarnation && h.dos_steps = steps
               && h.dos_width = width && h.dos_height = height ->
          Ok h.dos_rgb
        | Unchanged, (Some _ | None) ->
          Error "DOS frame: the server kept pixels this spectator does not hold"
      in
      Ok
        (Some
           { Masc_tui_types.dos_incarnation = incarnation
           ; dos_steps = steps
           ; dos_program = program
           ; dos_controller = controller
           ; dos_video_mode = video_mode
           ; dos_width = width
           ; dos_height = height
           ; dos_rgb = rgb
           })
    | `Int _ | `Intlit _ | `Float _ | `String _ | `Null | `List _ | `Assoc _ ->
      Error "DOS frame: loaded is not a boolean")
  | `Int _ | `Intlit _ | `Float _ | `String _ | `Bool _ | `Null | `List _ ->
    Error "DOS frame: expected an object"
