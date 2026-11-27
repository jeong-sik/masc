(** Integration tests for:
    - [Server_routes_http_routes_attachments] (raw & multipart upload, auth,
      GET/HEAD, ETag/304, security headers, [?download=1], [?format=png],
      [?max_px=], [/meta], 400/404/413/415/422)
    - [GET /api/v1/media/<id>] delegation to [Attachment_store] + legacy fallback
    - [Server_tool_blob_scope] & [Tool_blob_sweep] non-halting GC + attachment
      reachability scan
    - [Mcp_server_eio_resource] [masc://attachments/<id>] BlobResourceContents *)

module Att = Attachment_store
module Routes = Server_routes_http_routes_attachments
module Voice_routes = Server_routes_http_routes_voice
module Http = Masc.Http_server_eio

let () = Masc.Server_startup_state.mark_state_ready () |> Result.get_ok

let with_temp_base_path f =
  let dir = Filename.temp_file "masc_attachments_http_test_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let cleanup () =
    let rec rm path =
      if Sys.file_exists path
      then
        if Sys.is_directory path
        then (
          Array.iter (fun n -> rm (Filename.concat path n)) (Sys.readdir path);
          Unix.rmdir path)
        else Unix.unlink path
    in
    try rm dir with
    | Sys_error _ | Unix.Unix_error _ -> ()
  in
  let r =
    try Ok (f dir) with
    | e -> Error e
  in
  cleanup ();
  match r with
  | Ok v -> v
  | Error e -> raise e
;;

let make_png ~width ~height ~seed =
  let rgb =
    String.init (width * height * 3) (fun i -> Char.chr ((i + seed) land 0xff))
  in
  match Rgb_png.encode ~width ~height ~rgb with
  | Ok png -> png
  | Error msg -> Alcotest.fail ("Rgb_png.encode failed: " ^ msg)
;;

let create_token_exn base_path ~agent_name ~role =
  match Auth.create_token base_path ~agent_name ~role with
  | Ok (raw_token, _) -> raw_token
  | Error error ->
    Alcotest.fail
      ("create_token failed: " ^ Masc_domain.masc_error_to_string error)
;;

let valid_1x1_gif =
  "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b"
;;

let dispatch_in_eio ~router ~meth ~path ?token ?(headers = []) ?content_length ~body () =
  let output = Buffer.create 1024 in
  let connection =
    Httpun.Server_connection.create (fun reqd ->
      Http.Router.dispatch
        router
        (Httpun.Reqd.request reqd)
        (Masc.Http_reqd.of_httpun reqd))
  in
  let auth_hdr =
    match token with
    | None -> []
    | Some value -> [ "Authorization", "Bearer " ^ value ]
  in
  let cl_hdr =
    match meth with
    | "POST" ->
      [ "Content-Length", string_of_int (Option.value content_length ~default:(String.length body)) ]
    | _ -> []
  in
  let all_headers = ("Host", "localhost") :: (auth_hdr @ headers @ cl_hdr) in
  let header_block =
    String.concat
      "\r\n"
      (List.map (fun (k, v) -> Printf.sprintf "%s: %s" k v) all_headers)
  in
  let raw_request =
    Printf.sprintf "%s %s HTTP/1.1\r\n%s\r\n\r\n%s" meth path header_block body
  in
  let input =
    Bigstringaf.of_string ~off:0 ~len:(String.length raw_request) raw_request
  in
  ignore
    (Httpun.Server_connection.read_eof
       connection
       input
       ~off:0
       ~len:(Bigstringaf.length input));
  let rec drain () =
    match Httpun.Server_connection.next_write_operation connection with
    | `Write iovecs ->
      let written =
        List.fold_left
          (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
             Buffer.add_string
               output
               (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
             total + iov.len)
          0
          iovecs
      in
      Httpun.Server_connection.report_write_result connection (`Ok written);
      drain ()
    | `Yield | `Close _ -> ()
  in
  drain ();
  Buffer.contents output
;;

let dispatch_raw ~router ~meth ~path ?token ?headers ?content_length ~body () =
  Eio_main.run (fun _env ->
    dispatch_in_eio ~router ~meth ~path ?token ?headers ?content_length ~body ())
;;

let split_response response =
  let rec find i =
    if i + 4 > String.length response
    then Alcotest.failf "malformed HTTP response: %S" response
    else if String.sub response i 4 = "\r\n\r\n"
    then String.sub response 0 i, String.sub response (i + 4) (String.length response - i - 4)
    else find (i + 1)
  in
  let head, body = find 0 in
  let lines =
    String.split_on_char '\n' head
    |> List.map (fun l ->
      let len = String.length l in
      if len > 0 && l.[len - 1] = '\r' then String.sub l 0 (len - 1) else l)
  in
  let status =
    match lines with
    | status_line :: _ ->
      (match String.split_on_char ' ' status_line with
       | _ :: code :: _ -> int_of_string code
       | _ -> Alcotest.failf "bad status line: %S" status_line)
    | [] -> Alcotest.fail "empty HTTP head"
  in
  let hdrs =
    match lines with
    | _ :: rest ->
      List.filter_map
        (fun line ->
           match String.index_opt line ':' with
           | None -> None
           | Some idx ->
             let k = String.lowercase_ascii (String.trim (String.sub line 0 idx)) in
             let v = String.trim (String.sub line (idx + 1) (String.length line - idx - 1)) in
             Some (k, v))
        rest
    | [] -> []
  in
  status, hdrs, body
;;

let with_router f =
  with_temp_base_path (fun base_path ->
    Auth.save_auth_config
      base_path
      { Masc_domain.default_auth_config with enabled = true; require_token = true };
    let worker =
      create_token_exn base_path ~agent_name:"chat-worker" ~role:Masc_domain.Worker
    in
    let player =
      create_token_exn base_path ~agent_name:"guest-player" ~role:Masc_domain.Player
    in
    let saved_state = Server_auth.For_testing.snapshot_server_state () in
    Fun.protect
      ~finally:(fun () -> Server_auth.For_testing.restore_server_state saved_state)
      (fun () ->
         let state = Masc.Mcp_server.For_testing.create_state ~base_path in
         Server_auth.For_testing.restore_server_state (Some state);
         let router =
           Http.Router.create ()
           |> Routes.add_routes
           |> Voice_routes.add_routes
         in
         f ~base_path ~state ~router ~worker ~player))
;;

let test_http_auth_and_upload_variants () =
  with_router (fun ~base_path:_ ~state:_ ~router ~worker ~player ->
    let png = make_png ~width:64 ~height:48 ~seed:5 in
    (* Anonymous -> 401; Player -> 403 *)
    let st_anon, _, _ =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~headers:[ "Content-Type", "image/png" ]
        ~body:png
        ()
      |> split_response
    in
    Alcotest.(check int) "anonymous upload 401" 401 st_anon;
    let st_player, _, _ =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:player
        ~headers:[ "Content-Type", "image/png" ]
        ~body:png
        ()
      |> split_response
    in
    Alcotest.(check int) "player upload 403" 403 st_player;
    (* Worker (CanBroadcast, NOT CanAdmin) raw binary upload -> 201 *)
    let st_raw, _, body_raw =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "image/png"; "X-Filename", "hero.png" ]
        ~body:png
        ()
      |> split_response
    in
    Alcotest.(check int) "worker raw upload 201" 201 st_raw;
    let open Yojson.Safe.Util in
    let j_raw = Yojson.Safe.from_string body_raw in
    Alcotest.(check bool) "ok=true" true (j_raw |> member "ok" |> to_bool);
    let data = j_raw |> member "data" in
    let id = data |> member "id" |> to_string in
    let sha256 = data |> member "sha256" |> to_string in
    Alcotest.(check string) "attachment_id matches id" id (data |> member "attachment_id" |> to_string);
    Alcotest.(check string) "url" ("/api/v1/attachments/" ^ id) (data |> member "url" |> to_string);
    Alcotest.(check int) "width" 64 (data |> member "width" |> to_int);
    Alcotest.(check int) "height" 48 (data |> member "height" |> to_int);
    Alcotest.(check string) "filename" "hero.png" (data |> member "filename" |> to_string);
    (* Multipart upload of the exact same PNG returns identical id *)
    let boundary = "----MascTestBoundary987654" in
    let mp_body =
      Printf.sprintf
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"multi.png\"\r\nContent-Type: image/png\r\n\r\n%s\r\n--%s--\r\n"
        boundary
        png
        boundary
    in
    let st_mp, _, body_mp =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "multipart/form-data; boundary=" ^ boundary ]
        ~body:mp_body
        ()
      |> split_response
    in
    Alcotest.(check int) "multipart upload 201" 201 st_mp;
    let id_mp =
      Yojson.Safe.from_string body_mp |> member "data" |> member "id" |> to_string
    in
    Alcotest.(check string) "multipart dedups to same id" id id_mp;
    (* SVG upload rejected with 415 *)
    let st_svg, _, _ =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "image/svg+xml" ]
        ~body:"<svg></svg>"
        ()
      |> split_response
    in
    Alcotest.(check int) "svg rejected 415" 415 st_svg;
    (* GET content + headers *)
    let st_get, hdrs_get, body_get =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "GET 200" 200 st_get;
    Alcotest.(check string) "GET exact bytes" png body_get;
    Alcotest.(check (option string)) "content-type" (Some "image/png") (List.assoc_opt "content-type" hdrs_get);
    Alcotest.(check (option string)) "nosniff" (Some "nosniff") (List.assoc_opt "x-content-type-options" hdrs_get);
    Alcotest.(check (option string)) "csp" (Some "default-src 'none'; sandbox") (List.assoc_opt "content-security-policy" hdrs_get);
    Alcotest.(check (option string)) "etag" (Some ("\"" ^ sha256 ^ "\"")) (List.assoc_opt "etag" hdrs_get);
    Alcotest.(check (option string)) "cache-control" (Some "private, max-age=31536000, immutable") (List.assoc_opt "cache-control" hdrs_get);
    Alcotest.(check (option string)) "inline disposition" (Some "inline; filename=\"hero.png\"") (List.assoc_opt "content-disposition" hdrs_get);
    (* Conditional GET -> 304 Not Modified *)
    let st_304, _, body_304 =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "If-None-Match", "\"" ^ sha256 ^ "\"" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "If-None-Match 304" 304 st_304;
    Alcotest.(check string) "304 empty body" "" body_304;
    (* HEAD -> 200 with empty body *)
    let st_head, hdrs_head, body_head =
      dispatch_raw
        ~router
        ~meth:"HEAD"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "HEAD 200" 200 st_head;
    Alcotest.(check string) "HEAD empty body" "" body_head;
    Alcotest.(check (option string)) "HEAD content-type" (Some "image/png") (List.assoc_opt "content-type" hdrs_head);
    (* ?download=1 *)
    let st_dl, hdrs_dl, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id ^ "?download=1")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "download=1 200" 200 st_dl;
    Alcotest.(check (option string))
      "attachment disposition"
      (Some "attachment; filename=\"hero.png\"")
      (List.assoc_opt "content-disposition" hdrs_dl);
    (* ?max_px=32 and ?max_px=100 on 240x180 PNG quantize to 160px bucket *)
    let png240 = make_png ~width:240 ~height:180 ~seed:6 in
    let st_240, _, body_240 =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:
          [ "Content-Type", "image/png"
          ; "X-Origin", "model_generated"
          ; "X-Retention", "ephemeral"
          ; "X-Keeper", "victim-keeper"
          ]
        ~body:png240
        ()
      |> split_response
    in
    Alcotest.(check int) "240px upload 201" 201 st_240;
    let data_240 = Yojson.Safe.from_string body_240 |> member "data" in
    let id_240 = data_240 |> member "id" |> to_string in
    let sha_240 = data_240 |> member "sha256" |> to_string in
    (* Public HTTP upload MUST ignore untrusted X-Origin/X-Retention/X-Keeper *)
    Alcotest.(check string) "public upload forces user_upload origin" "user_upload" (data_240 |> member "origin" |> to_string);
    Alcotest.(check string) "public upload forces durable retention" "durable" (data_240 |> member "retention" |> to_string);
    let st_thumb, hdrs_thumb, body_thumb =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id_240 ^ "?max_px=32")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "max_px=32 200" 200 st_thumb;
    Alcotest.(check (option string)) "thumb mime" (Some "image/png") (List.assoc_opt "content-type" hdrs_thumb);
    Alcotest.(check (option string))
      "max_px=32 ETag quantized to max160"
      (Some ("\"" ^ sha_240 ^ "-max160\""))
      (List.assoc_opt "etag" hdrs_thumb);
    (match Att.detect_image_dimensions body_thumb with
     | Some (w, h) -> Alcotest.(check bool) "thumb <= 160px" true (max w h <= 160 && min w h > 0)
     | None -> Alcotest.fail "thumb PNG unreadable");
    let st_thumb2, hdrs_thumb2, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id_240 ^ "?max_px=100")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "max_px=100 200" 200 st_thumb2;
    Alcotest.(check (option string))
      "max_px=100 shares quantized max160 ETag"
      (Some ("\"" ^ sha_240 ^ "-max160\""))
      (List.assoc_opt "etag" hdrs_thumb2);
    (* /meta *)
    let st_meta, _, body_meta =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id ^ "/meta")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "GET /meta 200" 200 st_meta;
    Alcotest.(check string)
      "meta id"
      id
      (Yojson.Safe.from_string body_meta |> member "data" |> member "id" |> to_string);
    (* Invalid ID -> 400; absent valid ID -> 404 *)
    let st_bad, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:"/api/v1/attachments/bad-id" ~token:worker ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "invalid id 400" 400 st_bad;
    let st_404, _, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/att_" ^ String.make 64 '0')
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "absent id 404" 404 st_404;
    (* Non-image ?format=png -> 422 *)
    let pdf = "%PDF-1.7\n%%EOF\n" in
    let st_pdf_up, _, body_pdf =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "application/pdf" ]
        ~body:pdf
        ()
      |> split_response
    in
    Alcotest.(check int) "pdf upload 201" 201 st_pdf_up;
    let pdf_id =
      Yojson.Safe.from_string body_pdf |> member "data" |> member "id" |> to_string
    in
    let st_422, _, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ pdf_id ^ "?format=png")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "pdf ?format=png 422" 422 st_422;
    (* /api/v1/media/<id> and /api/v1/media/<sha256> delegate to Attachment_store *)
    let st_media_id, _, body_media_id =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/media/" ^ id) ~token:worker ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "/api/v1/media/<att_id> 200" 200 st_media_id;
    Alcotest.(check string) "media att_id bytes" png body_media_id;
    let st_media_sha, _, body_media_sha =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/media/" ^ sha256) ~token:worker ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "/api/v1/media/<sha256> 200" 200 st_media_sha;
    Alcotest.(check string) "media sha256 bytes" png body_media_sha;
    (* Header X-Filename is percent-decoded, while multipart filename is preserved verbatim *)
    let png_hdr = make_png ~width:12 ~height:12 ~seed:101 in
    let st_hdr_fn, _, body_hdr_fn =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "image/png"; "X-Filename", "my%20shot.png" ]
        ~body:png_hdr
        ()
      |> split_response
    in
    Alcotest.(check int) "x-filename upload 201" 201 st_hdr_fn;
    Alcotest.(check string)
      "x-filename pct-decoded"
      "my shot.png"
      (Yojson.Safe.from_string body_hdr_fn |> member "data" |> member "filename" |> to_string);
    let png_mp = make_png ~width:12 ~height:12 ~seed:102 in
    let mp_pct_body =
      Printf.sprintf
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"100%%20done.png\"\r\nContent-Type: image/png\r\n\r\n%s\r\n--%s--\r\n"
        boundary
        png_mp
        boundary
    in
    let st_mp_fn, _, body_mp_fn =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "multipart/form-data; boundary=" ^ boundary ]
        ~body:mp_pct_body
        ()
      |> split_response
    in
    Alcotest.(check int) "multipart literal % upload 201" 201 st_mp_fn;
    Alcotest.(check string)
      "multipart filename is not pct-decoded"
      "100%20done.png"
      (Yojson.Safe.from_string body_mp_fn |> member "data" |> member "filename" |> to_string);
    (* Non-ASCII UTF-8 filename emits ASCII fallback + RFC 5987 filename*=UTF-8'' *)
    let korean_name = "테스트_패턴.png" in
    let korean_pct = "%ED%85%8C%EC%8A%A4%ED%8A%B8_%ED%8C%A8%ED%84%B4.png" in
    let png_kr = make_png ~width:12 ~height:12 ~seed:103 in
    let mp_kr_body =
      Printf.sprintf
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\nContent-Type: image/png\r\n\r\n%s\r\n--%s--\r\n"
        boundary
        korean_name
        png_kr
        boundary
    in
    let st_kr_up, _, body_kr_up =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "multipart/form-data; boundary=" ^ boundary ]
        ~body:mp_kr_body
        ()
      |> split_response
    in
    Alcotest.(check int) "korean filename upload 201" 201 st_kr_up;
    let kr_data = Yojson.Safe.from_string body_kr_up |> member "data" in
    let kr_id = kr_data |> member "id" |> to_string in
    Alcotest.(check string) "korean meta filename preserved" korean_name (kr_data |> member "filename" |> to_string);
    let st_kr_dl, hdrs_kr_dl, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ kr_id ^ "?download=1")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "korean ?download=1 200" 200 st_kr_dl;
    let expected_kr_dl =
      Printf.sprintf "attachment; filename=\"%s.png\"; filename*=UTF-8''%s" kr_id korean_pct
    in
    Alcotest.(check (option string))
      "korean download Content-Disposition has ASCII fallback + RFC 5987"
      (Some expected_kr_dl)
      (List.assoc_opt "content-disposition" hdrs_kr_dl);
    Alcotest.(check bool)
      "korean download header is strictly ASCII"
      true
      (String.for_all (fun c -> Char.code c >= 0x20 && Char.code c <= 0x7e) expected_kr_dl);
    Alcotest.(check string)
      "RFC 5987 pct-decode round-trips UTF-8 filename"
      korean_name
      (Uri.pct_decode korean_pct);
    let st_kr_inline, hdrs_kr_inline, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ kr_id)
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "korean inline GET 200" 200 st_kr_inline;
    Alcotest.(check (option string))
      "korean inline Content-Disposition has ASCII fallback + RFC 5987"
      (Some (Printf.sprintf "inline; filename=\"%s.png\"; filename*=UTF-8''%s" kr_id korean_pct))
      (List.assoc_opt "content-disposition" hdrs_kr_inline);
    (* Mixed ASCII + non-ASCII keeps ASCII stem fallback alongside RFC 5987 *)
    let mixed_name = "report_테스트.png" in
    let png_mixed = make_png ~width:12 ~height:12 ~seed:104 in
    let mp_mixed_body =
      Printf.sprintf
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\nContent-Type: image/png\r\n\r\n%s\r\n--%s--\r\n"
        boundary
        mixed_name
        png_mixed
        boundary
    in
    let st_mixed_up, _, body_mixed_up =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "multipart/form-data; boundary=" ^ boundary ]
        ~body:mp_mixed_body
        ()
      |> split_response
    in
    Alcotest.(check int) "mixed utf8 filename upload 201" 201 st_mixed_up;
    let mixed_id =
      Yojson.Safe.from_string body_mixed_up |> member "data" |> member "id" |> to_string
    in
    let st_mixed_dl, hdrs_mixed_dl, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ mixed_id ^ "?download=1")
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "mixed ?download=1 200" 200 st_mixed_dl;
    Alcotest.(check (option string))
      "mixed download preserves ASCII stem fallback + RFC 5987"
      (Some "attachment; filename=\"report_.png\"; filename*=UTF-8''report_%ED%85%8C%EC%8A%A4%ED%8A%B8.png")
      (List.assoc_opt "content-disposition" hdrs_mixed_dl))
;;

(* Regression test for P0: live server initializes Process_eio; derivatives must
   run on the Eio fiber (not inside Eio_unix.run_in_systhread) so
   Process_eio.run_argv_with_status_split_or_refusal can enter Eio.Switch.run
   without raising Effect.Unhandled. *)
let test_derivatives_with_process_eio_init () =
  with_router (fun ~base_path:_ ~state:_ ~router ~worker ~player:_ ->
    Eio_main.run (fun env ->
      Process_eio.init
        ~cwd_default:(Eio.Stdenv.cwd env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env);
      Fun.protect
        ~finally:Process_eio.reset_for_testing
        (fun () ->
           Alcotest.(check bool)
             "Process_eio initialized"
             true
             (Process_eio.is_initialized ());
           let open Yojson.Safe.Util in
           let png240 = make_png ~width:240 ~height:180 ~seed:77 in
           let st_up, _, body_up =
             dispatch_in_eio
               ~router
               ~meth:"POST"
               ~path:"/api/v1/attachments"
               ~token:worker
               ~headers:[ "Content-Type", "image/png" ]
               ~body:png240
               ()
             |> split_response
           in
           Alcotest.(check int) "png upload 201" 201 st_up;
           let png_id =
             Yojson.Safe.from_string body_up |> member "data" |> member "id" |> to_string
           in
           let st_thumb, hdrs_thumb, body_thumb =
             dispatch_in_eio
               ~router
               ~meth:"GET"
               ~path:("/api/v1/attachments/" ^ png_id ^ "?max_px=32")
               ~token:worker
               ~body:""
               ()
             |> split_response
           in
           Alcotest.(check int) "Process_eio active ?max_px=32 returns 200" 200 st_thumb;
           Alcotest.(check (option string))
             "thumb content-type"
             (Some "image/png")
             (List.assoc_opt "content-type" hdrs_thumb);
           (match Att.detect_image_dimensions body_thumb with
            | Some (w, h) ->
              Alcotest.(check bool) "thumb <= 160px" true (max w h <= 160 && min w h > 0)
            | None -> Alcotest.fail "thumb PNG unreadable under Process_eio");
           let st_gif_up, _, body_gif_up =
             dispatch_in_eio
               ~router
               ~meth:"POST"
               ~path:"/api/v1/attachments"
               ~token:worker
               ~headers:[ "Content-Type", "image/gif" ]
               ~body:valid_1x1_gif
               ()
             |> split_response
           in
           Alcotest.(check int) "gif upload 201" 201 st_gif_up;
           let gif_id =
             Yojson.Safe.from_string body_gif_up |> member "data" |> member "id" |> to_string
           in
           let st_png, hdrs_png, body_png =
             dispatch_in_eio
               ~router
               ~meth:"GET"
               ~path:("/api/v1/attachments/" ^ gif_id ^ "?format=png")
               ~token:worker
               ~body:""
               ()
             |> split_response
           in
           Alcotest.(check int) "Process_eio active ?format=png returns 200" 200 st_png;
           Alcotest.(check (option string))
             "transcoded content-type"
             (Some "image/png")
             (List.assoc_opt "content-type" hdrs_png);
           Alcotest.(check bool)
             "transcoded bytes sniff as PNG"
             true
             (Att.sniff_mime body_png = Some Att.Image_png);
           let st_media_png, _, body_media_png =
             dispatch_in_eio
               ~router
               ~meth:"GET"
               ~path:("/api/v1/media/" ^ gif_id ^ "?format=png")
               ~token:worker
               ~body:""
               ()
             |> split_response
           in
           Alcotest.(check int) "/api/v1/media/<id>?format=png 200" 200 st_media_png;
           Alcotest.(check bool)
             "media delegation ?format=png sniffs as PNG"
             true
             (Att.sniff_mime body_media_png = Some Att.Image_png))))
;;

let test_opaque_serve_and_ephemeral_scope () =
  with_router (fun ~base_path ~state:_ ~router ~worker ~player:_ ->
    let store = Att.create ~base_path in
    let admin = create_token_exn base_path ~agent_name:"ops-admin" ~role:Masc_domain.Admin in
    let keeper_b = create_token_exn base_path ~agent_name:"keeper-b" ~role:Masc_domain.Worker in
    (* 1. Opaque generated binary (FLAC) MUST always serve as octet-stream attachment, never inline *)
    let flac = "fLaC\x00\x00\x00\x22opaque-http-payload" in
    let opaque_meta =
      Att.put_opaque
        ~declared_mime:"audio/flac"
        ~filename:"clip.flac"
        ~origin:Att.Model_generated
        ~created_by:"keeper:music"
        ~retention:Att.Durable
        store
        ~bytes:flac
      |> Result.get_ok
    in
    let st_op, hdrs_op, body_op =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ opaque_meta.id)
        ~token:worker
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "opaque GET 200" 200 st_op;
    Alcotest.(check string) "opaque raw bytes match" flac body_op;
    Alcotest.(check (option string))
      "opaque forced application/octet-stream"
      (Some "application/octet-stream")
      (List.assoc_opt "content-type" hdrs_op);
    Alcotest.(check (option string))
      "opaque forced Content-Disposition attachment (never inline)"
      (Some "attachment; filename=\"clip.flac\"")
      (List.assoc_opt "content-disposition" hdrs_op);
    Alcotest.(check (option string)) "opaque nosniff" (Some "nosniff") (List.assoc_opt "x-content-type-options" hdrs_op);
    Alcotest.(check (option string)) "opaque sandbox csp" (Some "default-src 'none'; sandbox") (List.assoc_opt "content-security-policy" hdrs_op);
    (* 2. Ephemeral attachment scope: owning keeper & admin allowed; sibling non-admin 403 *)
    let frame = make_png ~width:16 ~height:16 ~seed:205 in
    let eph_meta =
      Att.put
        ~origin:Att.Tool_capture
        ~created_by:"keeper:chat-worker"
        ~retention:(Att.Ephemeral { keeper = "chat-worker" })
        store
        ~bytes:frame
      |> Result.get_ok
    in
    let st_owner, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ eph_meta.id) ~token:worker ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "owning keeper reads own ephemeral 200" 200 st_owner;
    let st_other, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ eph_meta.id) ~token:keeper_b ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "sibling keeper refused ephemeral 403" 403 st_other;
    let st_other_meta, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ eph_meta.id ^ "/meta") ~token:keeper_b ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "sibling keeper refused ephemeral /meta 403" 403 st_other_meta;
    let st_admin, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ eph_meta.id) ~token:admin ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "admin reads ephemeral 200" 200 st_admin;
    (* Once keeper-b also pins identical frame, keeper-b is permitted *)
    ignore
      (Att.put
         ~origin:Att.Tool_capture
         ~created_by:"keeper:keeper-b"
         ~retention:(Att.Ephemeral { keeper = "keeper-b" })
         store
         ~bytes:frame
       |> Result.get_ok);
    let st_other_after, _, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ eph_meta.id) ~token:keeper_b ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "keeper-b permitted after pinning identical bytes 200" 200 st_other_after)
;;

let test_gc_scope_non_halt_and_reachability () =
  with_temp_base_path (fun base_path ->
    let store = Att.create ~base_path in
    let p_chat = make_png ~width:8 ~height:8 ~seed:1 in
    let p_comment = make_png ~width:8 ~height:8 ~seed:11 in
    let p_eph = make_png ~width:8 ~height:8 ~seed:2 in
    let p_orphan = make_png ~width:8 ~height:8 ~seed:3 in
    let m_chat =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes:p_chat
      |> Result.get_ok
    in
    let m_comment =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes:p_comment
      |> Result.get_ok
    in
    let m_eph =
      Att.put
        ~origin:Att.Tool_capture
        ~created_by:"keeper:k1"
        ~retention:(Att.Ephemeral { keeper = "k1" })
        store
        ~bytes:p_eph
      |> Result.get_ok
    in
    let m_orphan =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes:p_orphan
      |> Result.get_ok
    in
    (* Also create legacy .masc/media/ directory to verify it never halts GC *)
    let masc_dir = Common.masc_dir_from_base_path ~base_path in
    let legacy_media_dir = Filename.concat masc_dir Att.legacy_media_dirname in
    Fs_compat.mkdir_p legacy_media_dir;
    (* Reference m_chat inside keeper_chat/k1.jsonl *)
    let chat_dir = Filename.concat masc_dir Masc.Keeper_chat_store.chat_dirname in
    Fs_compat.mkdir_p chat_dir;
    Fs_compat.save_file
      (Filename.concat chat_dir "k1.jsonl")
      (Printf.sprintf "{\"role\":\"user\",\"attachments\":[{\"attachment_id\":\"%s\"}]}\n" m_chat.id);
    (* Reference m_comment inside board_comments.jsonl to verify classification & reachability *)
    let comments_file =
      Filename.concat
        masc_dir
        (Masc_board_handlers.Board_paths.persisted_filename Masc_board_handlers.Board_paths.Comments)
    in
    Fs_compat.save_file
      comments_file
      (Printf.sprintf "{\"id\":\"c1\",\"post_id\":\"p1\",\"body\":\"see %s\"}\n" m_comment.id);
    (* Scope check: ZERO unclassified entries (including board_comments.jsonl)! *)
    (match
       Tool_blob_maintenance.unclassified_entries ~base_path Server_tool_blob_scope.scope
     with
     | Ok entries ->
       let names = List.map Tool_blob_maintenance.unclassified_entry_to_string entries in
       Alcotest.(check (list string))
         "no unclassified entries with attachments/, media/, and board_comments.jsonl"
         []
         names
     | Error err -> Alcotest.fail (Tool_blob_maintenance.error_to_string err));
    (* Tool_blob_sweep.observe also reports unclassified = [] and deletes nothing *)
    (match Tool_blob_sweep.observe ~base_path ~scope:Server_tool_blob_scope.scope with
     | Ok report ->
       Alcotest.(check (list string)) "sweep observe unclassified empty" [] report.unclassified;
       Alcotest.(check bool) "observe attachment_sweep is None" true (report.attachment_sweep = None)
     | Error err -> Alcotest.fail (Tool_blob_sweep.error_to_string err));
    (* Attachment reachability scan *)
    (match
       Tool_blob_sweep.scan_attachment_reachability ~base_path ~scope:Server_tool_blob_scope.scope
     with
     | Error err -> Alcotest.fail err
     | Ok reach ->
       Alcotest.(check int) "total attachment blobs" 4 reach.total_blobs;
       Alcotest.(check bool)
         "chat-referenced blob is live"
         true
         (Set_util.StringSet.mem m_chat.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "board_comments.jsonl-referenced blob is live"
         true
         (Set_util.StringSet.mem m_comment.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "ephemeral-pinned blob is live"
         true
         (Set_util.StringSet.mem m_eph.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "orphan blob is unreferenced"
         true
         (Set_util.StringSet.mem m_orphan.sha256 reach.unreferenced_sha256s);
       Alcotest.(check bool)
         "chat-referenced blob not unreferenced"
         false
         (Set_util.StringSet.mem m_chat.sha256 reach.unreferenced_sha256s));
    (* Grace period retains fresh unreferenced blob *)
    (match
       Tool_blob_sweep.sweep_attachments
         ~min_age_seconds:3600.0
         ~base_path
         ~scope:Server_tool_blob_scope.scope
         ()
     with
     | Error err -> Alcotest.fail err
     | Ok rep ->
       Alcotest.(check int) "fresh orphan not deleted" 0 rep.deleted;
       Alcotest.(check int) "fresh orphan retained within grace" 1 rep.retained_within_grace);
    (* Age m_orphan and m_comment past grace period; sweep deletes only m_orphan *)
    let age_blob sha256 =
      let shard = String.sub sha256 0 2 in
      let old_ts = Unix.gettimeofday () -. 7200.0 in
      let bpath = Filename.concat (Filename.concat (Filename.concat (Att.root_dir store) "blobs") shard) sha256 in
      let mpath = Filename.concat (Filename.concat (Filename.concat (Att.root_dir store) "meta") shard) (sha256 ^ ".json") in
      Unix.utimes bpath old_ts old_ts;
      Unix.utimes mpath old_ts old_ts
    in
    age_blob m_orphan.sha256;
    age_blob m_comment.sha256;
    (match
       Tool_blob_sweep.sweep_attachments
         ~min_age_seconds:3600.0
         ~base_path
         ~scope:Server_tool_blob_scope.scope
         ()
     with
     | Error err -> Alcotest.fail err
     | Ok rep ->
       Alcotest.(check int) "aged orphan deleted" 1 rep.deleted;
       Alcotest.(check bool) "not blocked" false rep.blocked_by_unclassified);
    Alcotest.(check bool) "orphan removed" true (Att.get_bytes store ~id:m_orphan.id = Ok None);
    Alcotest.(check bool) "referenced chat blob survived" true (Att.get_bytes store ~id:m_chat.id = Ok (Some p_chat));
    Alcotest.(check bool) "board_comments.jsonl blob survived" true (Att.get_bytes store ~id:m_comment.id = Ok (Some p_comment));
    Alcotest.(check bool) "ephemeral-pinned blob survived" true (Att.get_bytes store ~id:m_eph.id = Ok (Some p_eph));
    (* Tool_blob_sweep.reclaim runs attachment sweep and surfaces outcome in report.attachment_sweep *)
    let p_orphan2 = make_png ~width:8 ~height:8 ~seed:4 in
    let m_orphan2 =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes:p_orphan2
      |> Result.get_ok
    in
    age_blob m_orphan2.sha256;
    (match
       Tool_blob_sweep.reclaim
         ~min_age_seconds:3600.0
         ~base_path
         ~scope:Server_tool_blob_scope.scope
         ()
     with
     | Error err -> Alcotest.fail (Tool_blob_sweep.error_to_string err)
     | Ok rep ->
       (match rep.attachment_sweep with
        | Some (Ok att) -> Alcotest.(check int) "reclaim report surfaces attachments deleted=1" 1 att.deleted
        | Some (Error err) -> Alcotest.fail ("unexpected attachment_sweep error: " ^ err)
        | None -> Alcotest.fail "expected reclaim report.attachment_sweep = Some _");
       Alcotest.(check bool) "reclaim deleted aged orphan2" true (Att.get_bytes store ~id:m_orphan2.id = Ok None);
       Alcotest.(check bool) "reclaim preserved m_chat" true (Att.get_bytes store ~id:m_chat.id = Ok (Some p_chat));
       Alcotest.(check bool) "reclaim preserved m_comment" true (Att.get_bytes store ~id:m_comment.id = Ok (Some p_comment)));
    (* Fail-closed: unreadable ephemeral dir surfaces Error in reclaim.attachment_sweep and deletes 0 *)
    let p_orphan3 = make_png ~width:8 ~height:8 ~seed:5 in
    let m_orphan3 =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes:p_orphan3
      |> Result.get_ok
    in
    age_blob m_orphan3.sha256;
    let eph_k1_dir = Filename.concat (Filename.concat (Att.root_dir store) "ephemeral") "k1" in
    Unix.chmod eph_k1_dir 0o000;
    Fun.protect
      ~finally:(fun () -> try Unix.chmod eph_k1_dir 0o700 with Unix.Unix_error _ -> ())
      (fun () ->
         match
           Tool_blob_sweep.reclaim
             ~min_age_seconds:0.0
             ~base_path
             ~scope:Server_tool_blob_scope.scope
             ()
         with
         | Error err -> Alcotest.fail (Tool_blob_sweep.error_to_string err)
         | Ok rep ->
           (match rep.attachment_sweep with
            | Some (Error _) -> ()
            | Some (Ok _) | None ->
              Alcotest.fail "reclaim must surface Error in report.attachment_sweep when ephemeral dir is unreadable"));
    Alcotest.(check bool)
      "orphan3 survived fail-closed unreadable ephemeral dir"
      true
      (Att.get_bytes store ~id:m_orphan3.id = Ok (Some p_orphan3));
    (* Fail-closed: unreadable consumer dir aborts sweep_attachments and deletes nothing *)
    Unix.chmod chat_dir 0o000;
    Fun.protect
      ~finally:(fun () -> try Unix.chmod chat_dir 0o755 with Unix.Unix_error _ -> ())
      (fun () ->
         match
           Tool_blob_sweep.sweep_attachments
             ~min_age_seconds:0.0
             ~base_path
             ~scope:Server_tool_blob_scope.scope
             ()
         with
         | Error _ -> ()
         | Ok _ -> Alcotest.fail "sweep_attachments must fail closed on unreadable consumer dir");
    Alcotest.(check bool)
      "orphan3 survived fail-closed unreadable dir"
      true
      (Att.get_bytes store ~id:m_orphan3.id = Ok (Some p_orphan3)))
;;

let test_mcp_attachment_resource () =
  with_router (fun ~base_path ~state ~router:_ ~worker:_ ~player:_ ->
    (* Template discovery: masc://attachments/{id} advertised in resource_templates *)
    Alcotest.(check bool)
      "masc://attachments/{id} registered in Mcp_server.resource_templates"
      true
      (List.exists
         (fun (t : Masc.Mcp_server.mcp_resource_template) ->
            String.equal t.uri_template "masc://attachments/{id}")
         Masc.Mcp_server.resource_templates);
    let store = Att.create ~base_path in
    let png = make_png ~width:10 ~height:10 ~seed:42 in
    let meta =
      Att.put ~origin:Att.Model_generated ~created_by:"keeper" ~retention:Att.Durable store ~bytes:png
      |> Result.get_ok
    in
    let uri = "masc://attachments/" ^ meta.id in
    let resp =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          state
          (`Int 7)
          (Some (`Assoc [ "uri", `String uri ])))
    in
    let open Yojson.Safe.Util in
    let contents = resp |> member "result" |> member "contents" |> to_list in
    Alcotest.(check int) "one content entry" 1 (List.length contents);
    let item = List.hd contents in
    Alcotest.(check string) "uri echoed" uri (item |> member "uri" |> to_string);
    Alcotest.(check string) "mimeType" "image/png" (item |> member "mimeType" |> to_string);
    let blob_b64 = item |> member "blob" |> to_string in
    Alcotest.(check string) "decoded blob matches raw PNG" png (Base64.decode_exn blob_b64);
    (* Ephemeral attachment MCP caller scope enforcement *)
    let eph_png = make_png ~width:10 ~height:10 ~seed:43 in
    let eph_meta =
      Att.put
        ~origin:Att.Tool_capture
        ~created_by:"keeper:alpha"
        ~retention:(Att.Ephemeral { keeper = "alpha" })
        store
        ~bytes:eph_png
      |> Result.get_ok
    in
    let eph_uri = "masc://attachments/" ^ eph_meta.id in
    let dummy_reader = Masc_board_handlers.Board_access.named "alpha" in
    let eph_admin =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          ~caller:Masc.Mcp_server_eio_resource.Operator_admin
          state
          (`Int 10)
          (Some (`Assoc [ "uri", `String eph_uri ])))
    in
    Alcotest.(check int)
      "MCP Operator_admin reads ephemeral"
      1
      (eph_admin |> member "result" |> member "contents" |> to_list |> List.length);
    let eph_owner =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          ~caller:(Masc.Mcp_server_eio_resource.Authenticated_reader
                     { agent_name = "alpha"; board_reader = dummy_reader })
          state
          (`Int 11)
          (Some (`Assoc [ "uri", `String eph_uri ])))
    in
    Alcotest.(check int)
      "MCP owning keeper reads ephemeral"
      1
      (eph_owner |> member "result" |> member "contents" |> to_list |> List.length);
    let eph_other =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          ~caller:(Masc.Mcp_server_eio_resource.Authenticated_reader
                     { agent_name = "beta"; board_reader = Masc_board_handlers.Board_access.named "beta" })
          state
          (`Int 12)
          (Some (`Assoc [ "uri", `String eph_uri ])))
    in
    Alcotest.(check int)
      "MCP sibling keeper denied ephemeral (-32007 Insufficient_scope)"
      (-32007)
      (eph_other |> member "error" |> member "code" |> to_int);
    let eph_anon =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          ~caller:Masc.Mcp_server_eio_resource.Anonymous_reader
          state
          (`Int 13)
          (Some (`Assoc [ "uri", `String eph_uri ])))
    in
    Alcotest.(check bool)
      "MCP anonymous denied ephemeral"
      true
      (eph_anon |> member "error" <> `Null);
    (* Invalid attachment id -> JSON-RPC Invalid_params (-32602) *)
    let bad_resp =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          state
          (`Int 8)
          (Some (`Assoc [ "uri", `String "masc://attachments/not-valid" ])))
    in
    Alcotest.(check int)
      "invalid id jsonrpc code"
      (-32602)
      (bad_resp |> member "error" |> member "code" |> to_int);
    (* Absent valid id -> JSON-RPC -32602 Resource not found *)
    let missing_resp =
      Eio_main.run (fun _env ->
        Masc.Mcp_server_eio_resource.handle_read_resource_eio
          state
          (`Int 9)
          (Some (`Assoc [ "uri", `String ("masc://attachments/att_" ^ String.make 64 'f') ])))
    in
    Alcotest.(check int)
      "missing id jsonrpc code"
      (-32602)
      (missing_resp |> member "error" |> member "code" |> to_int))
;;

let generate_tiny_mp4_in_eio () =
  let out = Filename.temp_file "masc_http_test_vid_" ".mp4" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove out with Sys_error _ -> ())
    (fun () ->
       match
         Process_eio.run_argv_with_status_split_or_refusal
           ~timeout_sec:10.0
           [ "ffmpeg"
           ; "-nostdin"
           ; "-hide_banner"
           ; "-loglevel"
           ; "error"
           ; "-y"
           ; "-f"
           ; "lavfi"
           ; "-i"
           ; "color=c=red:s=320x240:d=0.2:r=5"
           ; "-pix_fmt"
           ; "yuv420p"
           ; "-movflags"
           ; "+faststart"
           ; out
           ]
       with
       | Ok (Unix.WEXITED 0, _, _) when Sys.file_exists out ->
         let ic = open_in_bin out in
         let bytes =
           Fun.protect
             ~finally:(fun () -> close_in_noerr ic)
             (fun () -> really_input_string ic (in_channel_length ic))
         in
         if String.length bytes > 0 then Some bytes else None
       | _ -> None)
;;

let test_http_range_and_video_poster () =
  with_router (fun ~base_path:_ ~state:_ ~router ~worker ~player:_ ->
    let png = make_png ~width:16 ~height:16 ~seed:88 in
    let total = String.length png in
    let st_up, _, body_up =
      dispatch_raw
        ~router
        ~meth:"POST"
        ~path:"/api/v1/attachments"
        ~token:worker
        ~headers:[ "Content-Type", "image/png" ]
        ~body:png
        ()
      |> split_response
    in
    Alcotest.(check int) "upload 201" 201 st_up;
    let open Yojson.Safe.Util in
    let id = Yojson.Safe.from_string body_up |> member "data" |> member "id" |> to_string in
    (* Full GET advertises Accept-Ranges: bytes *)
    let st_200, hdrs_200, _ =
      dispatch_raw ~router ~meth:"GET" ~path:("/api/v1/attachments/" ^ id) ~token:worker ~body:"" ()
      |> split_response
    in
    Alcotest.(check int) "full GET 200" 200 st_200;
    Alcotest.(check (option string)) "Accept-Ranges bytes" (Some "bytes") (List.assoc_opt "accept-ranges" hdrs_200);
    (* Bounded Range: bytes=0-9 -> 206 *)
    let st_r1, hdrs_r1, body_r1 =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "Range", "bytes=0-9" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "bounded range 206" 206 st_r1;
    Alcotest.(check string) "bounded range slice" (String.sub png 0 10) body_r1;
    Alcotest.(check (option string))
      "bounded Content-Range"
      (Some (Printf.sprintf "bytes 0-9/%d" total))
      (List.assoc_opt "content-range" hdrs_r1);
    Alcotest.(check (option string)) "206 Accept-Ranges" (Some "bytes") (List.assoc_opt "accept-ranges" hdrs_r1);
    (* Open-ended Range: bytes=10- -> 206 *)
    let st_r2, hdrs_r2, body_r2 =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "Range", "bytes=10-" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "open-ended range 206" 206 st_r2;
    Alcotest.(check string) "open-ended slice" (String.sub png 10 (total - 10)) body_r2;
    Alcotest.(check (option string))
      "open-ended Content-Range"
      (Some (Printf.sprintf "bytes 10-%d/%d" (total - 1) total))
      (List.assoc_opt "content-range" hdrs_r2);
    (* Suffix Range: bytes=-8 -> 206 *)
    let st_r3, hdrs_r3, body_r3 =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "Range", "bytes=-8" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "suffix range 206" 206 st_r3;
    Alcotest.(check string) "suffix slice" (String.sub png (total - 8) 8) body_r3;
    Alcotest.(check (option string))
      "suffix Content-Range"
      (Some (Printf.sprintf "bytes %d-%d/%d" (total - 8) (total - 1) total))
      (List.assoc_opt "content-range" hdrs_r3);
    (* Out-of-bounds and malformed ranges -> 416 with Content-Range: bytes */<total> *)
    let st_416a, hdrs_416a, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "Range", "bytes=999999-" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "out-of-bounds range 416" 416 st_416a;
    Alcotest.(check (option string))
      "416 Content-Range"
      (Some (Printf.sprintf "bytes */%d" total))
      (List.assoc_opt "content-range" hdrs_416a);
    let st_416b, _, _ =
      dispatch_raw
        ~router
        ~meth:"GET"
        ~path:("/api/v1/attachments/" ^ id)
        ~token:worker
        ~headers:[ "Range", "bytes=20-10" ]
        ~body:""
        ()
      |> split_response
    in
    Alcotest.(check int) "inverted range 416" 416 st_416b;
    List.iter
      (fun bad_range ->
         let st_bad, _, _ =
           dispatch_raw
             ~router
             ~meth:"GET"
             ~path:("/api/v1/attachments/" ^ id)
             ~token:worker
             ~headers:[ "Range", bad_range ]
             ~body:""
             ()
           |> split_response
         in
         Alcotest.(check int) ("non-ASCII-digit range 416: " ^ bad_range) 416 st_bad)
      [ "bytes=0x10-0x20"; "bytes=1_0-2_0"; "bytes=+0-5"; "bytes=-+5" ];
    (* Video upload + ?poster=1 + ?format=png&max_px=160 with Process_eio.init active *)
    Eio_main.run (fun env ->
      Process_eio.init
        ~cwd_default:(Eio.Stdenv.cwd env)
        ~proc_mgr:(Eio.Stdenv.process_mgr env)
        ~clock:(Eio.Stdenv.clock env);
      Fun.protect
        ~finally:Process_eio.reset_for_testing
        (fun () ->
           match generate_tiny_mp4_in_eio () with
           | None -> ()
           | Some mp4_bytes ->
             let st_vid, _, body_vid =
               dispatch_in_eio
                 ~router
                 ~meth:"POST"
                 ~path:"/api/v1/attachments"
                 ~token:worker
                 ~headers:[ "Content-Type", "video/mp4"; "X-Filename", "demo.mp4" ]
                 ~body:mp4_bytes
                 ()
               |> split_response
             in
             Alcotest.(check int) "video upload 201" 201 st_vid;
             let vdata = Yojson.Safe.from_string body_vid |> member "data" in
             let vid = vdata |> member "id" |> to_string in
             Alcotest.(check string) "video kind" "video" (vdata |> member "kind" |> to_string);
             Alcotest.(check string) "video mime" "video/mp4" (vdata |> member "mime_type" |> to_string);
             let st_p1, hdrs_p1, body_p1 =
               dispatch_in_eio
                 ~router
                 ~meth:"GET"
                 ~path:("/api/v1/attachments/" ^ vid ^ "?poster=1&max_px=160")
                 ~token:worker
                 ~body:""
                 ()
               |> split_response
             in
             Alcotest.(check int) "video ?poster=1&max_px=160 returns 200" 200 st_p1;
             Alcotest.(check (option string))
               "poster content-type"
               (Some "image/png")
               (List.assoc_opt "content-type" hdrs_p1);
             Alcotest.(check bool)
               "poster sniffs PNG"
               true
               (Att.sniff_mime body_p1 = Some Att.Image_png);
             let st_p2, hdrs_p2, body_p2 =
               dispatch_in_eio
                 ~router
                 ~meth:"GET"
                 ~path:("/api/v1/attachments/" ^ vid ^ "?format=png&max_px=160")
                 ~token:worker
                 ~body:""
                 ()
               |> split_response
             in
             Alcotest.(check int) "video ?format=png&max_px=160 returns 200" 200 st_p2;
             Alcotest.(check (option string))
               "video format=png content-type"
               (Some "image/png")
               (List.assoc_opt "content-type" hdrs_p2);
             Alcotest.(check string) "poster and format=png return identical cached PNG" body_p1 body_p2)))
;;

let test_gc_protects_wiki_tasks_goals_and_published_artifact_bodies () =
  with_temp_base_path (fun base_path ->
    let store = Att.create ~base_path in
    let p_wiki = make_png ~width:8 ~height:8 ~seed:21 in
    let p_task = make_png ~width:8 ~height:8 ~seed:22 in
    let p_goal = make_png ~width:8 ~height:8 ~seed:23 in
    let p_artifact = make_png ~width:8 ~height:8 ~seed:24 in
    let p_orphan = make_png ~width:8 ~height:8 ~seed:25 in
    let put bytes =
      Att.put ~origin:Att.User_upload ~created_by:"op" ~retention:Att.Durable store ~bytes
      |> Result.get_ok
    in
    let m_wiki = put p_wiki in
    let m_task = put p_task in
    let m_goal = put p_goal in
    let m_artifact = put p_artifact in
    let m_orphan = put p_orphan in
    let masc_dir = Common.masc_dir_from_base_path ~base_path in
    (* 1. Wiki Markdown page referencing m_wiki *)
    let wiki_dir = Filename.concat masc_dir Config_dir_resolver.wiki_dirname in
    Fs_compat.mkdir_p wiki_dir;
    Fs_compat.save_file
      (Filename.concat wiki_dir "visual-guide.md")
      (Printf.sprintf
         "---\ntitle: Visual Guide\n---\n\n![Diagram](/api/v1/attachments/%s)\n"
         m_wiki.id);
    (* 2. Task JSON referencing m_task *)
    let tasks_dir = Filename.concat masc_dir Workspace_utils_paths_backend.tasks_dirname in
    Fs_compat.mkdir_p tasks_dir;
    Fs_compat.save_file
      (Filename.concat tasks_dir "task-1.json")
      (Printf.sprintf
         "{\"id\":\"task-1\",\"description\":\"See ![Shot](/api/v1/attachments/%s)\"}\n"
         m_task.id);
    (* 3. Goals file referencing m_goal *)
    Fs_compat.save_file
      (Filename.concat masc_dir Goal_store.goals_filename)
      (Printf.sprintf "{\"goals\":[{\"id\":\"g1\",\"note\":\"%s\"}]}\n" m_goal.id);
    (* 4. Published artifact HTML body stored in Tool_blob_store referencing m_artifact *)
    let req =
      Masc.Published_artifact.request_of_json
        (`Assoc
          [ "title", `String "Visual Report"
          ; "summary", `String "Artifact referencing attachment in Tool_blob_store body"
          ; "format", `String "html"
          ; ( "content"
            , `String
                (Printf.sprintf
                   "<!doctype html><html><body><img src=\"/api/v1/attachments/%s\"></body></html>"
                   m_artifact.id) )
          ])
      |> Result.get_ok
    in
    (match
       Eio_main.run (fun _env ->
         Masc.Published_artifact_store.publish ~base_path ~author:"tester" req)
     with
     | Ok _ -> ()
     | Error err ->
       Alcotest.fail
         ("publish failed: " ^ Masc.Published_artifact_store.error_message err));
    (* Scope remains 100% classified and Tool_blob_sweep.observe succeeds on Markdown wiki dir *)
    (match Tool_blob_sweep.observe ~base_path ~scope:Server_tool_blob_scope.scope with
     | Ok report ->
       Alcotest.(check (list string)) "observe unclassified empty" [] report.unclassified
     | Error err -> Alcotest.fail (Tool_blob_sweep.error_to_string err));
    (* Reachability protects wiki, tasks, goals, and published artifact body blobs *)
    (match
       Tool_blob_sweep.scan_attachment_reachability
         ~base_path
         ~scope:Server_tool_blob_scope.scope
     with
     | Error err -> Alcotest.fail err
     | Ok reach ->
       Alcotest.(check int) "total attachment blobs" 5 reach.total_blobs;
       Alcotest.(check bool)
         "wiki-referenced blob is live"
         true
         (Set_util.StringSet.mem m_wiki.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "task-referenced blob is live"
         true
         (Set_util.StringSet.mem m_task.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "goal-referenced blob is live"
         true
         (Set_util.StringSet.mem m_goal.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "published-artifact body blob is live"
         true
         (Set_util.StringSet.mem m_artifact.sha256 reach.live_sha256s);
       Alcotest.(check bool)
         "orphan blob is unreferenced"
         true
         (Set_util.StringSet.mem m_orphan.sha256 reach.unreferenced_sha256s));
    let age_blob sha256 =
      let shard = String.sub sha256 0 2 in
      let old_ts = Unix.gettimeofday () -. 7200.0 in
      let bpath =
        Filename.concat (Filename.concat (Filename.concat (Att.root_dir store) "blobs") shard) sha256
      in
      let mpath =
        Filename.concat
          (Filename.concat (Filename.concat (Att.root_dir store) "meta") shard)
          (sha256 ^ ".json")
      in
      Unix.utimes bpath old_ts old_ts;
      Unix.utimes mpath old_ts old_ts
    in
    List.iter
      age_blob
      [ m_wiki.sha256; m_task.sha256; m_goal.sha256; m_artifact.sha256; m_orphan.sha256 ];
    (match
       Tool_blob_sweep.sweep_attachments
         ~min_age_seconds:3600.0
         ~base_path
         ~scope:Server_tool_blob_scope.scope
         ()
     with
     | Error err -> Alcotest.fail err
     | Ok rep ->
       Alcotest.(check int) "only aged orphan deleted" 1 rep.deleted;
       Alcotest.(check bool) "not blocked" false rep.blocked_by_unclassified);
    Alcotest.(check bool) "orphan deleted" true (Att.get_bytes store ~id:m_orphan.id = Ok None);
    Alcotest.(check bool) "wiki blob survived" true (Att.get_bytes store ~id:m_wiki.id = Ok (Some p_wiki));
    Alcotest.(check bool) "task blob survived" true (Att.get_bytes store ~id:m_task.id = Ok (Some p_task));
    Alcotest.(check bool) "goal blob survived" true (Att.get_bytes store ~id:m_goal.id = Ok (Some p_goal));
    Alcotest.(check bool)
      "artifact body blob survived"
      true
      (Att.get_bytes store ~id:m_artifact.id = Ok (Some p_artifact)))
;;

let () =
  Alcotest.run
    "attachments_http_and_gc"
    [ ( "http, gc scope, and mcp resource"
      , [ Alcotest.test_case "HTTP upload/get/head/304/download/thumb/meta/media-delegation" `Quick test_http_auth_and_upload_variants
        ; Alcotest.test_case "HTTP ?max_px and ?format=png with Process_eio.init active" `Quick test_derivatives_with_process_eio_init
        ; Alcotest.test_case "HTTP Range 206/416 streaming and video ?poster=1" `Quick test_http_range_and_video_poster
        ; Alcotest.test_case "HTTP opaque attachment download-only and ephemeral keeper scope" `Quick test_opaque_serve_and_ephemeral_scope
        ; Alcotest.test_case "GC scope non-halt, reachability, and fail-closed sweep" `Quick test_gc_scope_non_halt_and_reachability
        ; Alcotest.test_case "GC protects wiki, tasks, goals, and published artifact bodies" `Quick test_gc_protects_wiki_tasks_goals_and_published_artifact_bodies
        ; Alcotest.test_case "MCP masc://attachments/{id} template, BlobResourceContents, and ephemeral scope" `Quick test_mcp_attachment_resource
        ] )
    ]
;;
