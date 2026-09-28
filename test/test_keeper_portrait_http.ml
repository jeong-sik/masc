open Alcotest
open Masc

module Http = Http_server_eio
module Api = Server_dashboard_http_keeper_portrait

let () = Mirage_crypto_rng_unix.use_default ()

let keeper = "portrait-http-probe"
let png_signature = "\137PNG\r\n\026\n"

let require_ok error = function Ok value -> value | Error value -> fail (error value)

(* IHDR follows the signature: length(4) "IHDR"(4) width(4) height(4) depth colour ... *)
let ihdr png =
  check string "PNG signature" png_signature (String.sub png 0 8);
  check string "first chunk is IHDR" "IHDR" (String.sub png 12 4);
  let u32 at = Int32.to_int (String.get_int32_be png at) in
  u32 16, u32 20, Char.code png.[24], Char.code png.[25]

let present () = Ok true
let never_asked () = fail "keeper presence must not be read for a malformed request"

let expect_png = function
  | Api.Png png -> png
  | Api.Invalid_name -> fail "Invalid_name"
  | Api.Invalid_size raw -> fail ("Invalid_size " ^ raw)
  | Api.Unknown_keeper -> fail "Unknown_keeper"
  | Api.Lookup_failed message -> fail ("Lookup_failed " ^ message)
  | Api.Encode_failed message -> fail ("Encode_failed " ^ message)

let test_route_is_exact () =
  check (option string) "portrait path" (Some keeper)
    (Api.route ("/api/v1/keepers/" ^ keeper ^ "/portrait.png"));
  List.iter (fun path -> check (option string) path None (Api.route path))
    [ "/api/v1/keepers//portrait.png"
    ; "/api/v1/keepers/" ^ keeper ^ "/portrait.png/extra"
    ; "/api/v1/keepers/" ^ keeper ^ "/portrait.jpg"
    ; "/api/v1/keepers/" ^ keeper
    ; "/api/v1/other/" ^ keeper ^ "/portrait.png" ]

let test_size_and_default () =
  let width, height, depth, colour =
    ihdr (expect_png (Api.answer ~name:keeper ~size:None ~keeper_present:present)) in
  check int "default width" Api.default_size width;
  check int "default height" Api.default_size height;
  check int "8-bit samples" 8 depth;
  check int "RGBA colour type keeps the transparent corners" 6 colour;
  let width, _, _, _ =
    ihdr (expect_png (Api.answer ~name:keeper ~size:(Some "64") ~keeper_present:present)) in
  check int "requested size" 64 width

let test_bad_sizes_are_refused_not_clamped () =
  List.iter (fun raw ->
    match Api.answer ~name:keeper ~size:(Some raw) ~keeper_present:never_asked with
    | Api.Invalid_size echoed -> check string "refusal names the value" raw echoed
    | Api.Png _ | Api.Invalid_name | Api.Unknown_keeper | Api.Lookup_failed _
    | Api.Encode_failed _ -> fail ("accepted size " ^ raw))
    [ ""; "0"; "15"; "513"; "0x40"; "+64"; "6_4"; " 64"; "64px"; "1e2"; "99999999999999999999" ]

let test_order_of_checks () =
  (match Api.answer ~name:"../escape" ~size:(Some "nonsense") ~keeper_present:never_asked with
   | Api.Invalid_name -> ()
   | _ -> fail "a malformed name is refused before anything else");
  (match Api.answer ~name:keeper ~size:None ~keeper_present:(fun () -> Ok false) with
   | Api.Unknown_keeper -> ()
   | _ -> fail "an absent keeper is not drawn");
  match Api.answer ~name:keeper ~size:None ~keeper_present:(fun () -> Error "store down") with
  | Api.Lookup_failed message -> check string "store error kept" "store down" message
  | _ -> fail "a store failure is not an absent keeper"

let test_same_name_same_bytes () =
  let draw name = expect_png (Api.answer ~name ~size:(Some "96") ~keeper_present:present) in
  check string "deterministic" (draw keeper) (draw keeper);
  check bool "another name draws another picture" false
    (String.equal (draw keeper) (draw "portrait-http-other"))

(* ---- the real router, over an in-memory HTTP/1.1 connection ---- *)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_router f =
  let base_path = Filename.temp_dir "keeper-portrait-http" "" in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Fs_compat.clear_fs ();
      remove_tree base_path)
    (fun () -> Eio_main.run @@ fun env ->
      Fs_compat.set_fs (Eio.Stdenv.fs env);
      Eio.Switch.run @@ fun sw ->
      let state = Mcp_server.For_testing.create_state ~base_path in
      let config = Mcp_server.workspace_config state in
      ignore (Workspace.init config ~agent_name:None);
      Server_auth.For_testing.restore_server_state (Some state);
      let meta = require_ok Fun.id
        (Masc_test_deps.meta_of_json_fixture (`Assoc [ "name", `String keeper ])) in
      require_ok Fun.id (Keeper_meta_store.replace_snapshot config meta);
      let router = Server_routes_http_routes_dashboard.add_routes ~sw
        ~clock:(Eio.Stdenv.clock env) (Http.Router.create ()) in
      f router)

type reply = { status : int; headers : (string * string) list; body : string }

let get ~router ?if_none_match path =
  let output = Buffer.create 4096 in
  let connection = Httpun.Server_connection.create (fun reqd ->
    Http.Router.dispatch router (Httpun.Reqd.request reqd) reqd) in
  let conditional = match if_none_match with
    | None -> "" | Some tag -> "If-None-Match: " ^ tag ^ "\r\n" in
  let raw_request =
    Printf.sprintf "GET %s HTTP/1.1\r\nHost: x\r\n%sContent-Length: 0\r\n\r\n" path conditional in
  let input = Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request in
  ignore (Httpun.Server_connection.read_eof connection input ~off:0 ~len:(Bigstringaf.length input));
  let rec drain () = match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let bytes = List.fold_left (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
        Buffer.add_string output (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
        total + iov.len) 0 iovecs in
      Httpun.Server_connection.report_write_result connection (`Ok bytes); drain ()
    | `Yield | `Close _ -> () in
  drain ();
  let raw = Buffer.contents output in
  let rec head_end index =
    if index + 4 > String.length raw then fail ("no end of headers: " ^ raw)
    else if String.sub raw index 4 = "\r\n\r\n" then index
    else head_end (index + 1) in
  let stop = head_end 0 in
  let lines = String.split_on_char '\n' (String.sub raw 0 stop) in
  let status = int_of_string (List.nth (String.split_on_char ' ' (List.hd lines)) 1) in
  let headers = List.filter_map (fun line ->
    match String.index_opt line ':' with
    | None -> None
    | Some at ->
      Some (String.lowercase_ascii (String.sub line 0 at),
            String.trim (String.sub line (at + 1) (String.length line - at - 1))))
    (List.tl lines) in
  { status; headers; body = String.sub raw (stop + 4) (String.length raw - stop - 4) }

let header reply name =
  match List.assoc_opt name reply.headers with
  | Some value -> value
  | None -> fail ("missing header " ^ name)

let path ?size name =
  "/api/v1/keepers/" ^ name ^ "/portrait.png"
  ^ match size with None -> "" | Some size -> "?size=" ^ size

let test_router_serves_png_with_a_strong_tag () =
  with_router (fun router ->
    let first = get ~router (path ~size:"72" keeper) in
    check int "200 without a token" 200 first.status;
    check string "content type" "image/png" (header first "content-type");
    check string "revalidate" "no-cache" (header first "cache-control");
    let tag = header first "etag" in
    check bool "strong tag" false (String.starts_with ~prefix:"W/" tag);
    let width, height, _, _ = ihdr first.body in
    check int "width" 72 width;
    check int "height" 72 height;
    let again = get ~router (path ~size:"72" keeper) in
    check string "same bytes" first.body again.body;
    check string "same tag" tag (header again "etag");
    let cached = get ~router ~if_none_match:tag (path ~size:"72" keeper) in
    check int "304 on the tag" 304 cached.status;
    check string "no body on 304" "" cached.body;
    check string "304 repeats the tag" tag (header cached "etag");
    let listed = get ~router ~if_none_match:("\"stale\", " ^ tag) (path ~size:"72" keeper) in
    check int "304 when the tag is in a list" 304 listed.status;
    let other_size = get ~router ~if_none_match:tag (path ~size:"96" keeper) in
    check int "a different size is a different image" 200 other_size.status)

let test_router_refusals () =
  with_router (fun router ->
    check int "unknown keeper" 404 (get ~router (path "portrait-http-nobody")).status;
    check int "size out of range" 400 (get ~router (path ~size:"4096" keeper)).status;
    check int "size not a number" 400 (get ~router (path ~size:"big" keeper)).status;
    check int "malformed name" 400 (get ~router (path "Not_A_Keeper!")).status)

let () =
  run "Keeper portrait HTTP"
    [ "answer",
      [ test_case "route is exact" `Quick test_route_is_exact
      ; test_case "default and requested size" `Quick test_size_and_default
      ; test_case "bad sizes are refused, not clamped" `Quick test_bad_sizes_are_refused_not_clamped
      ; test_case "name, size, presence, in that order" `Quick test_order_of_checks
      ; test_case "same name, same bytes" `Quick test_same_name_same_bytes ]
    ; "router",
      [ test_case "PNG with a strong tag and 304" `Quick test_router_serves_png_with_a_strong_tag
      ; test_case "400 and 404" `Quick test_router_refusals ] ]
