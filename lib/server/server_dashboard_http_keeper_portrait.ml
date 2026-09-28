module Http = Http_server_eio
module Look = Keeper_portrait_look
module Draw = Keeper_portrait_draw

let prefix = "/api/v1/keepers/"
let file_name = "portrait.png"

(* Twice the largest avatar the dashboard draws (72 CSS px on a 2x screen
   rounds up to this), and small enough to draw in a few milliseconds. *)
let default_size = 160

(* Store the image but revalidate before reuse: the bytes change when the
   drawing does, and the tag is what says so. *)
let cache_control = "no-cache"

let route path =
  if not (String.starts_with ~prefix path) then None
  else
    let rest = String.sub path (String.length prefix) (String.length path - String.length prefix) in
    match String.split_on_char '/' rest with
    | [ name; file ] when name <> "" && String.equal file file_name -> Some name
    | _ -> None

type answer =
  | Invalid_name
  | Invalid_size of string
  | Unknown_keeper
  | Lookup_failed of string
  | Encode_failed of string
  | Png of string

(* Digits only: [int_of_string] would also take "0x40", "1_6" and "+64". The
   length bound keeps the conversion from overflowing before the range check. *)
let parse_size raw =
  let digits = String.length (string_of_int Draw.max_size) in
  let is_digit c = c >= '0' && c <= '9' in
  if String.length raw = 0 || String.length raw > digits || not (String.for_all is_digit raw)
  then None
  else Draw.size_of_int (int_of_string raw)

(* A constant outside the renderer's range is a build mistake, so it stops the
   module from loading rather than turning every plain request into a 400. *)
let default_draw_size =
  match Draw.size_of_int default_size with
  | Some size -> size
  | None -> invalid_arg "keeper portrait default_size is outside the renderer's range"

let size_of_request = function
  | None -> Ok default_draw_size
  | Some raw -> Option.to_result ~none:raw (parse_size raw)

let draw ~name size =
  let image = Draw.render (Look.body_of_name name) (Look.equipment_of_name name) size in
  Rgb_png.encode_rgba ~width:image.edge ~height:image.edge ~rgba:image.rgba

let answer ~name ~size ~keeper_present =
  if not (Keeper_config.validate_name name) then Invalid_name
  else
    match size_of_request size with
    | Error raw -> Invalid_size raw
    | Ok size ->
      match keeper_present () with
      | Error message -> Lookup_failed message
      | Ok false -> Unknown_keeper
      | Ok true ->
        match Domain_pool_ref.submit_cpu_or_inline (fun () -> draw ~name size) with
        | Ok png -> Png png
        | Error message -> Encode_failed message

let keeper_present config name () =
  match Keeper_meta_store.read_meta_presence config name with
  | Error message -> Error message
  | Ok Keeper_meta_store.Meta_absent -> Ok false
  (* A file this binary does not decode is still a Keeper's file: the portrait
     needs only the name. *)
  | Ok (Keeper_meta_store.Meta_present _ | Keeper_meta_store.Meta_not_current _) -> Ok true

let error_json message = `Assoc [ "error", `String message ]

let handle_get state request reqd name =
  let config = Mcp_server.workspace_config state in
  let refuse status message =
    Server_auth.respond_json_value_with_cors ~status request reqd (error_json message)
  in
  match
    answer ~name ~size:(Server_utils.query_param request "size")
      ~keeper_present:(keeper_present config name)
  with
  | Invalid_name -> refuse `Bad_request (Printf.sprintf "invalid keeper name: %s" name)
  | Invalid_size raw ->
    refuse `Bad_request
      (Printf.sprintf "size must be a whole number of pixels from %d to %d, not %S"
         Draw.min_size Draw.max_size raw)
  | Unknown_keeper -> refuse `Not_found (Printf.sprintf "keeper %S not found" name)
  | Lookup_failed message -> refuse `Service_unavailable message
  | Encode_failed message -> refuse `Internal_server_error message
  | Png png ->
    Http.Response.bytes_cached ~etag:(Http.Response.etag_of_body png) ~cache_control
      ~request ~content_type:"image/png" png reqd
