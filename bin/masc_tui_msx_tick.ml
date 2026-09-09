type reference = { revision : string; width : int; height : int }
type pixels = { reference : reference; rgb : string }
type scope = { host : string; port : int; headers : (string * string) list }

let same_scope a b =
  String.equal a.host b.host && Int.equal a.port b.port && a.headers = b.headers

type t = {
  mutex : Mutex.t;
  mutable scope : scope option;
  mutable pixels : pixels option;
  mutable request_token : unit ref;
}

let create () =
  { mutex = Mutex.create (); scope = None; pixels = None; request_token = ref () }

let frame_with_rgb ?rgb json : Masc_tui_types.msx_frame option =
  let open Yojson.Safe.Util in
  try match member "loaded" json with
  | `Bool true ->
      let frame =
        { Masc_tui_types.msx_number = member "number" json |> to_int
        ; msx_width = member "width" json |> to_int
        ; msx_height = member "height" json |> to_int
        ; msx_mode = member "mode" json |> to_string
        ; msx_cartridge = member "cartridge" json |> to_string_option
        ; msx_disk = member "disk" json |> to_string_option
        ; msx_rgb = (match rgb with Some bytes -> bytes | None ->
            member "rgb_base64" json |> to_string |> Base64.decode_exn)
        ; msx_players =
            (match member "players" json with
             | `List items -> List.filter_map
                 (fun it -> match member "who" it with `String w -> Some w | _ -> None) items
             | _ -> [])
        } in
      if frame.msx_width > 0 && frame.msx_height > 0
         && frame.msx_width <= max_int / 3 / frame.msx_height
         && String.length frame.msx_rgb = frame.msx_width * frame.msx_height * 3
      then Some frame else None
  | _ -> None
  with Yojson.Safe.Util.Type_error _ | Invalid_argument _ -> None

let frame_of_json json = frame_with_rgb json

let reference_json reference =
  `Assoc ["revision", `String reference.revision; "width", `Int reference.width;
          "height", `Int reference.height]

let decode_reference fields =
  match List.assoc_opt "revision" fields, List.assoc_opt "width" fields,
        List.assoc_opt "height" fields with
  | Some (`String revision), Some (`Int width), Some (`Int height)
    when String.length revision = 64 && width > 0 && height > 0
         && width <= max_int / 3 / height
         && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) revision ->
      Ok { revision; width; height }
  | _ -> Error "MSX tick: invalid pixel reference"

let decode previous json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names <> List.length (List.sort_uniq String.compare names)
      then Error "MSX tick: duplicate frame fields"
      else (match List.assoc_opt "loaded" fields, List.assoc_opt "pixels" fields with
       | Some (`Bool false), _ -> Ok (None, None)
       | Some (`Bool true), Some (`Assoc pixel_fields) ->
           let names = List.map fst pixel_fields in
           let* () = if List.length names <> List.length (List.sort_uniq String.compare names)
             then Error "MSX tick: duplicate pixel fields" else Ok () in
           let* reference = decode_reference pixel_fields in
           let* pixels =
             match List.assoc_opt "kind" pixel_fields, List.assoc_opt "rgb_base64" pixel_fields with
             | Some (`String "inline"), Some (`String encoded) ->
                 (match Base64.decode encoded with
                  | Ok rgb when String.length rgb = reference.width * reference.height * 3 ->
                      Ok { reference; rgb }
                  | Ok _ | Error _ -> Error "MSX tick: invalid inline pixels")
             | Some (`String "retained"), None ->
                 (match previous with
                  | Some pixels when pixels.reference = reference -> Ok pixels
                  | Some _ | None -> Error "MSX tick: pixels were not retained for this request")
             | _ -> Error "MSX tick: invalid pixel representation" in
           (match frame_with_rgb ~rgb:pixels.rgb json with
            | Some frame when frame.msx_width = reference.width && frame.msx_height = reference.height ->
                Ok (Some frame, Some pixels)
            | Some _ | None -> Error "MSX tick: invalid frame metadata")
       | Some (`Bool true), None ->
           (* A complete frame is also a valid answer to a retention hint. *)
           (match frame_of_json json with
            | Some frame -> Ok (Some frame, None)
            | None -> Error "MSX tick: invalid full frame")
       | _ -> Error "MSX tick: invalid frame response")
  | _ -> Error "MSX tick: expected an object"

let fetch t ~host ~port ~headers ~request =
  let scope = { host; port; headers } and token = ref () in
  let previous = Mutex.protect t.mutex (fun () ->
    if not (Option.fold ~none:false ~some:(same_scope scope) t.scope) then
      t.pixels <- None;
    t.scope <- Some scope;
    t.request_token <- token;
    t.pixels) in
  let body = Yojson.Safe.to_string (`Assoc
    (["pixel_response", `String "retained"] @
     match previous with None -> [] | Some pixels -> ["known_pixels", reference_json pixels.reference])) in
  let result = Result.bind (request ~body) (decode previous) in
  Mutex.protect t.mutex (fun () ->
    if t.request_token == token then
      t.pixels <- (match result with Ok (_, pixels) -> pixels | Error _ -> None));
  Result.map fst result
