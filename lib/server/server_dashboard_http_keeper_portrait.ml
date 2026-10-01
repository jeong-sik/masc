module Http = Http_server_eio
module Look = Keeper_portrait_look
module Draw = Keeper_portrait_draw

let prefix = Server_dashboard_http_keeper_api_types.keeper_api_prefix
let file_name = "portrait.png"

(* A request without [size] gets a picture big enough to scale down cleanly
   into any avatar the dashboard draws, and still quick to draw. *)
let default_size = 160

(* Store the image but revalidate before reuse: the tag says whether the
   copy is still this binary's drawing. *)
let cache_control = "no-cache"

(* A budget in bytes rather than a count of entries, because one 512 px
   portrait weighs as much as dozens of the 64 px ones the dashboard asks
   for. Eight MiB holds a handful of the largest and every Keeper at the
   dashboard's size many times over. *)
let cache_byte_budget = 8 * 1024 * 1024

let route path =
  if not (String.starts_with ~prefix path) then None
  else
    let rest = String.sub path (String.length prefix) (String.length path - String.length prefix) in
    match String.split_on_char '/' rest with
    | [ name; file ] when name <> "" && String.equal file file_name -> Some name
    | _ -> None

type build =
  | Executable of string
  | Unscoped

(* [Build_identity] hashes the executable once per process and keeps the
   digest; the server asks for it at start-up. *)
let current_build () =
  match (Build_identity.current ()).executable_sha256 with
  | Some digest -> Executable digest
  | None -> Unscoped

module Cache = struct
  type key = string * int * string

  type t =
    { byte_budget : int
    ; table : (key, string) Hashtbl.t
    ; order : key Queue.t  (* insertion order, oldest first *)
    ; mutable bytes : int
    ; lock : Mutex.t  (* no I/O or yield inside; requests may run on any domain *)
    }

  let create ~byte_budget =
    { byte_budget; table = Hashtbl.create 64; order = Queue.create (); bytes = 0; lock = Mutex.create () }

  let length t = Mutex.protect t.lock (fun () -> Hashtbl.length t.table)
  let bytes t = Mutex.protect t.lock (fun () -> t.bytes)
  let find t key = Mutex.protect t.lock (fun () -> Hashtbl.find_opt t.table key)

  let rec evict_until_within t =
    if t.bytes > t.byte_budget then
      match Queue.take_opt t.order with
      | None -> ()
      | Some key ->
        (match Hashtbl.find_opt t.table key with
         | Some png ->
           Hashtbl.remove t.table key;
           t.bytes <- t.bytes - String.length png
         | None -> ());
        evict_until_within t

  (* A picture larger than the whole budget is served but not kept. Two
     requests that drew the same picture at once store it once. *)
  let add t key png =
    if String.length png <= t.byte_budget then
      Mutex.protect t.lock (fun () ->
        if not (Hashtbl.mem t.table key) then begin
          Hashtbl.replace t.table key png;
          Queue.push key t.order;
          t.bytes <- t.bytes + String.length png;
          evict_until_within t
        end)
end

let process_cache = Cache.create ~byte_budget:cache_byte_budget

type answer =
  | Invalid_name
  | Invalid_size of string
  | Unknown_keeper
  | Lookup_failed of string
  | Encode_failed of string
  | Not_modified of string
  | Png of { etag : string; png : string }

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

let draw ~name ~equipment size =
  let image = Draw.render (Look.body_of_name name) equipment size in
  Rgb_png.encode_rgba ~width:image.edge ~height:image.edge ~rgba:image.rgba

(* The cached bytes, or a drawing that is then kept. *)
let png_of cache ~name ~equipment size =
  let edge = Draw.int_of_size size in
  let key = name, edge, Keeper_portrait_equipment.key equipment in
  match Cache.find cache key with
  | Some png -> Ok png
  | None ->
    match Domain_pool_ref.submit_cpu_or_inline (fun () -> draw ~name ~equipment size) with
    | Ok png -> Cache.add cache key png; Ok png
    | Error _ as refused -> refused

let build_tag digest ~name ~equipment size =
  Http.Response.etag_of_body
    (String.concat "\000" [ digest; name; string_of_int (Draw.int_of_size size); Keeper_portrait_equipment.key equipment ])

let answer ~cache ~build ~name ~size ~keeper_present ~equipment ~holds_tag =
  if not (Keeper_config.validate_name name) then Invalid_name
  else
    match size_of_request size with
    | Error raw -> Invalid_size raw
    | Ok size ->
      match keeper_present () with
      | Error message -> Lookup_failed message
      | Ok false -> Unknown_keeper
      | Ok true ->
        match equipment () with
        | Error message -> Lookup_failed message
        | Ok equipment ->
        match build with
        | Executable digest ->
          let etag = build_tag digest ~name ~equipment size in
          if holds_tag etag then Not_modified etag
          else (
            match png_of cache ~name ~equipment size with
            | Ok png -> Png { etag; png }
            | Error message -> Encode_failed message)
        | Unscoped ->
          match png_of cache ~name ~equipment size with
          | Error message -> Encode_failed message
          | Ok png ->
            let etag = Http.Response.etag_of_body png in
            if holds_tag etag then Not_modified etag else Png { etag; png }

(* [lstat], not a read: a public GET must not decode, repair, rewrite or
   count failures on the Keeper's metadata. The path is built here rather than
   by [Keeper_types_profile.keeper_meta_path], which creates the Keeper
   directory when it is missing. *)
let keeper_present config name () =
  let path =
    Filename.concat
      (Workspace.keepers_runtime_dir config)
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name:name Keeper_runtime_root_entry.Metadata)
  in
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> Ok true
  | { Unix.st_kind = (Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK); _ } ->
    Error (Printf.sprintf "keeper metadata %s is not a regular file" path)
  (* A name too long for the file system cannot belong to a Keeper either. *)
  | exception Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.ENAMETOOLONG), _, _) -> Ok false
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "keeper metadata %s: %s" path (Unix.error_message error))

let error_json message = `Assoc [ "error", `String message ]

let handle_get state request reqd name =
  let config = Mcp_server.workspace_config state in
  let refuse status message =
    Server_auth.respond_json_value_with_cors ~status request reqd (error_json message)
  in
  match
    answer ~cache:process_cache ~build:(current_build ()) ~name
      ~size:(Server_utils.query_param request "size")
      ~keeper_present:(keeper_present config name)
      ~equipment:(fun () -> Candle_equipment.read_persisted ~now:Time_compat.now ~base_path:config.Workspace.base_path ~keeper:name)
      ~holds_tag:(fun etag -> Http.Response.request_holds_tag ~etag request)
  with
  | Invalid_name -> refuse `Bad_request (Printf.sprintf "invalid keeper name: %s" name)
  | Invalid_size raw ->
    refuse `Bad_request
      (Printf.sprintf "size must be a whole number of pixels from %d to %d, not %S"
         Draw.min_size Draw.max_size raw)
  | Unknown_keeper -> refuse `Not_found (Printf.sprintf "keeper %S not found" name)
  | Lookup_failed message -> refuse `Service_unavailable message
  | Encode_failed message -> refuse `Internal_server_error message
  | Not_modified etag -> Http.Response.bytes_not_modified ~etag ~cache_control reqd
  | Png { etag; png } ->
    Http.Response.bytes_cached ~etag ~cache_control ~request ~content_type:"image/png" png reqd
