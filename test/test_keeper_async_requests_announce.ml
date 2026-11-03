(** A Keeper's durable async message requests announce each change to the
    active inventory, and a reader that answers the announcement sees it: the
    request is listed when its submission is heard, and gone from the list
    when its settlement is heard. *)

open Alcotest
module Async = Masc.Keeper_msg_async

let () = Mirage_crypto_rng_unix.use_default ()
let caller = "async-announce-test"
let keeper = "announcing-async-keeper"

let rec rm_rf path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> rm_rf (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_base f =
  let path = Filename.temp_file "keeper-async-announce-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  Fun.protect ~finally:(fun () -> rm_rf path) (fun () -> f path)
;;

let named_event frame =
  match Masc.Sse.data_payload_of_frame frame with
  | Error Masc.Sse.Missing_data_payload -> None
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       (match List.assoc_opt "type" fields, List.assoc_opt "name" fields with
        | Some (`String event), Some (`String name) -> Some (event, name)
        | _ -> None)
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

(* Calls [f] with a list that gains [read ()] each time a change of
   [keeper]'s requests is heard. *)
let hearing ~read f =
  let id = Printf.sprintf "keeper-async-announce-%d" (Unix.getpid ()) in
  let heard = ref [] in
  Masc.Sse.subscribe_external ~id
    ~callback:(fun (ev : Masc.Sse.external_event) ->
      match named_event ev.Masc.Sse.ext_frame with
      | Some (event, name)
        when String.equal event Masc.Keeper_msg_async_broadcast.requests_changed_event
             && String.equal name keeper ->
        heard := read () :: !heard
      | Some _ | None -> ())
    ();
  Fun.protect ~finally:(fun () -> Masc.Sse.unsubscribe_external id) (fun () -> f heard)
;;

let listed ~base_path ~request_id () =
  match Async.read_durable_active_inventory ~base_path with
  | Ok { entries; _ } ->
    List.exists (fun (entry : Async.entry) -> String.equal entry.request_id request_id) entries
  | Error _ -> fail "the active inventory could not be read"
;;

let test_submission_and_settlement_are_announced () =
  with_temp_base (fun base_path ->
    Eio_main.run
    @@ fun _env ->
    Eio.Switch.run
    @@ fun sw ->
    let request_id = ref "" in
    hearing ~read:(fun () -> listed ~base_path ~request_id:!request_id ()) (fun heard ->
      let started, resolve_started = Eio.Promise.create () in
      let release, resolve_release = Eio.Promise.create () in
      let settled, resolve_settled = Eio.Promise.create () in
      (* The id is known only once [submit] returns, so the reads heard before
         it are taken again below against the id. *)
      let submitted =
        Async.submit
          ~on_worker_settled:(fun settlement -> Eio.Promise.resolve resolve_settled settlement)
          ~background_sw:sw
          ~base_path
          ~caller
          ~keeper_name:keeper
          ~f:(fun _request_sw ->
            Eio.Promise.resolve resolve_started ();
            Eio.Promise.await release;
            Masc.Keeper_types_profile.tool_result_ok "done")
          ()
      in
      (match submitted with
       | Ok { Async.acceptance = Async.Durably_accepted; request_id = id } -> request_id := id
       | Ok outcome -> fail (Async.submit_outcome_to_json outcome |> Yojson.Safe.to_string)
       | Error error -> fail (Async.submit_error_to_json error |> Yojson.Safe.to_string));
      Eio.Promise.await started;
      check bool "the submission was announced" true (!heard <> []);
      check bool "and the request is listed" true (listed ~base_path ~request_id:!request_id ());
      heard := [];
      Eio.Promise.resolve resolve_release ();
      (match Eio.Promise.await settled with
       | Async.Status_settlement { entry = { status = Async.Done _; _ }; durability = Async.Durable; _ } -> ()
       | _ -> fail "the request did not settle durably");
      (match !heard with
       | last :: _ -> check bool "the last change heard leaves the request unlisted" false last
       | [] -> fail "the settlement was not announced")))
;;

let () =
  run
    "keeper_async_requests_announce"
    [ ( "active inventory"
      , [ test_case "submission and settlement are announced" `Quick
            test_submission_and_settlement_are_announced
        ] )
    ]
;;
