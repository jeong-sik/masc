(* MSX HTTP control routes (RFC-0439 §3.7, RFC #38695).
   Tests tick, press, checkpoint, carts and load HTTP route endpoints
   and responses under a real loaded machine. Machine spectating is
   handled via GET /api/v1/lane-addons/live. *)

open Alcotest
module Lane = Msx_lane
module Route = Server_routes_http_routes_msx

let member name = function
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None
;;

let with_tick_machine f =
  let dir = Filename.temp_dir "msx-tick-route-" "" in
  Fun.protect
    ~finally:(fun () ->
      (match Lane.eject () with
       | Ok () | Error Lane.No_machine -> ()
       | Error e -> fail (Lane.error_to_string e));
      Array.iter
        (fun name -> Sys.remove (Filename.concat dir name))
        (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () ->
      (match
         Lane.load
           ~ledger_dir:dir
           ~roms_dir:None
           ~cart_path:None
           ~disk_path:None
       with
       | Ok _ -> ()
       | Error e -> fail (Lane.error_to_string e));
      f ())
;;

let current_frame_number () =
  match Lane.frame () with
  | Some f -> f.number
  | None -> fail "missing current frame"
;;

let frame_number json =
  match member "number" json with
  | Some (`Int n) -> n
  | _ -> fail "missing frame number"
;;

let pixels_object json =
  match member "pixels" json with
  | Some (`Assoc fields) -> fields
  | _ -> fail "missing pixels"
;;

let retained_request ?(frames = 1) json =
  let fields = pixels_object json in
  let reference =
    List.map
      (fun name -> name, List.assoc name fields)
      [ "revision"; "width"; "height" ]
  in
  Yojson.Safe.to_string
    (`Assoc
       [ "frames", `Int frames
       ; "pixel_response", `String "retained"
       ; "known_pixels", `Assoc reference
       ])
;;

let assert_pixels_kind expected json =
  check
    (option string)
    "pixel representation"
    (Some expected)
    (match List.assoc_opt "kind" (pixels_object json) with
     | Some (`String s) -> Some s
     | _ -> None)
;;

let test_retained_tick () =
  with_tick_machine (fun () ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let pool =
          Eio.Executor_pool.create
            ~sw
            ~domain_count:1
            (Eio.Stdenv.domain_mgr env)
        in
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          let first_status, first =
            Route.tick_response
              ~body:{|{"frames":1,"pixel_response":"retained"}|}
          in
          check bool "first tick succeeds" true (first_status = `OK);
          (match
             ( Lane.current_publication ()
             , member "change_count" first
             , member "incarnation" first )
           with
           | ( Lane.Stable mark
             , Some (`Int count)
             , Some (`String incarnation) ) ->
             check int "tick includes its machine change count" mark.count count;
             check
               string
               "tick includes its machine incarnation"
               mark.incarnation
               incarnation
           | _ -> fail "tick omitted its change mark");
          assert_pixels_kind "inline" first;
          let before = frame_number first in
          let status, next =
            Route.tick_response ~body:(retained_request first)
          in
          check bool "retained tick succeeds" true (status = `OK);
          assert_pixels_kind "retained" next;
          check
            int
            "retention still advances exactly once"
            (before + 1)
            (frame_number next);
          check
            bool
            "retained response carries no encoded pixels"
            false
            (List.mem_assoc "rgb_base64" (pixels_object next));
          (match Lane.step_frame ~frames:1 with
           | Error error -> fail (Lane.error_to_string error)
           | Ok (snapshot, ledger, _) ->
             ignore (Lane.step ~frames:1);
             check
               int
               "captured frame remains at its own atomic step"
               (before + 2)
               snapshot.number;
             check bool "captured ledger is immutable" true (ledger = []));
          ignore
            (Lane.press
               ~who:"bob"
               ~keys:[ Result.get_ok (Lane.key_of_string "space") ]
               ~hold_frames:1
               ~step_frames:1
               ~sequence:false);
          let _, after_press =
            Route.tick_response ~body:(retained_request next)
          in
          assert_pixels_kind "retained" after_press;
          check
            bool
            "fresh players survive retained pixels"
            true
            (match member "players" after_press with
             | Some (`List players) ->
               List.exists
                 (fun json -> member "who" json = Some (`String "bob"))
                 players
             | _ -> false);
          ignore (Lane.eject ());
          let status, empty =
            Route.tick_response ~body:(retained_request next)
          in
          check
            bool
            "missing machine remains a successful empty observation"
            true
            (status = `OK && member "loaded" empty = Some (`Bool false));
          check
            bool
            "empty machine never advertises stale pixels"
            true
            (member "pixels" empty = None)))))
;;

let test_tick_validation_precedes_mutation () =
  with_tick_machine (fun () ->
    let before = current_frame_number () in
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      List.iter
        (fun body ->
          let status, response = Route.tick_response ~body in
          check bool "invalid tick is a bad request" true (status = `Bad_request);
          check
            bool
            "invalid tick carries failure"
            true
            (member "ok" response = Some (`Bool false));
          check
            int
            "invalid tick never advances the loaded machine"
            before
            (current_frame_number ()))
        [ ""
        ; "{"
        ; "null"
        ; "[]"
        ; "18"
        ; {|{"frames":"18"}|}
        ; {|{"frames":1.5}|}
        ; {|{"frames":true}|}
        ; {|{"frames":null}|}
        ; {|{"frames":1,"frames":2}|}
        ; {|{"frames":1,"unexpected":true}|}
        ; {|{"unexpected":18}|}
        ; {|{"pixel_response":"unknown"}|}
        ; {|{"pixel_response":null}|}
        ; {|{"known_pixels":{}}|}
        ; {|{"pixel_response":"retained","known_pixels":{}}|}
        ; {|{"pixel_response":"retained","pixel_response":"retained"}|}
        ; {|{"pixel_response":"retained","known_pixels":{"revision":"bad","width":1,"height":1}}|}
        ];
      let status, _ = Route.tick_response ~body:"{}" in
      check
        bool
        "missing executor cannot fall back to inline mutation"
        true
        (status = `Service_unavailable);
      check
        int
        "missing executor preserves machine"
        before
        (current_frame_number ())))
;;

let test_tick_worker_advances_and_returns_frame () =
  with_tick_machine (fun () ->
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let pool =
          Eio.Executor_pool.create
            ~sw
            ~domain_count:1
            (Eio.Stdenv.domain_mgr env)
        in
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          List.iter
            (fun (body, frames) ->
              let before = current_frame_number () in
              let status, response = Route.tick_response ~body in
              check
                bool
                "accepted tick succeeds through executor"
                true
                (status = `OK);
              check
                int
                "response includes exactly the accepted advance"
                frames
                (frame_number response - before);
              check
                int
                "returned frame matches current machine"
                (frame_number response)
                (current_frame_number ()))
            [ "{}", Route.msx_tick_default_frames
            ; {|{"frames":0}|}, 1
            ; {|{"frames":999999}|}, Lane.max_frames_per_call
            ]))))
;;

let test_checkpoint_route () =
  with_tick_machine (fun () ->
    let (config : Masc.Workspace.config) =
      Masc.Workspace.default_config
        (Filename.temp_dir "msx-checkpoint-route-" "")
    in
    let base_path = config.base_path in
    let before = current_frame_number () in
    Executor_pool_ref.For_testing.with_pool_option None (fun () ->
      List.iter
        (fun body ->
          let status, _ =
            Route.checkpoint_response ~config ~restore:false ~body
          in
          check
            bool
            "checkpoint validates before requesting worker"
            true
            (status = `Bad_request))
        [ "[]"
        ; {|{"slot":3}|}
        ; {|{"slot":"../escape"}|}
        ; {|{"slot":"x","slot":"y"}|}
        ; {|{"extra":true}|}
        ];
      let status, _ = Route.checkpoint_response ~config ~restore:false ~body:"{}" in
      check
        bool
        "checkpoint never runs inline without a worker"
        true
        (status = `Service_unavailable));
    Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
        let pool =
          Eio.Executor_pool.create
            ~sw
            ~domain_count:1
            (Eio.Stdenv.domain_mgr env)
        in
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          let status, _ =
            Route.checkpoint_response ~config ~restore:false ~body:"{}"
          in
          check bool "save through executor succeeds" true (status = `OK);
          ignore (Lane.step ~frames:12 : (Lane.observation, Lane.error) result);
          let status, _ =
            Route.checkpoint_response ~config ~restore:true ~body:"{}"
          in
          check bool "restore through executor succeeds" true (status = `OK);
          check int "saved clock restored" before (current_frame_number ());
          let destination =
            Filename.concat base_path ".masc/msx/saves/quick.json"
          in
          Sys.remove destination;
          Sys.mkdir destination 0o700;
          let status, response =
            Route.checkpoint_response ~config ~restore:false ~body:"{}"
          in
          check
            bool
            "storage failure is server error"
            true
            (status = `Internal_server_error);
          check
            bool
            "storage error carries failure"
            true
            (member "ok" response = Some (`Bool false));
          check
            int
            "storage failure preserves machine"
            before
            (current_frame_number ())))))
;;

let unwatched_config =
  lazy (Masc.Workspace.default_config (Filename.temp_dir "msx-press-route-" ""))
;;

let ledger_whos () = List.map (fun (e : Lane.entry) -> e.who) (Lane.ledger ())

let test_press_rejects_wrong_types () =
  with_tick_machine (fun () ->
    let before = current_frame_number () in
    List.iter
      (fun (body, expected) ->
        let status, response =
          Route.press_response
            ~config:(Lazy.force unwatched_config)
            ~who:"unit-presser"
            ~body
        in
        check
          bool
          ("wrong type is a bad request: " ^ body)
          true
          (status = `Bad_request);
        check
          (option string)
          ("the refusal names the field: " ^ body)
          (Some expected)
          (match member "message" response with
           | Some (`String m) -> Some m
           | _ -> None);
        check
          int
          ("nothing is pressed: " ^ body)
          before
          (current_frame_number ());
        check bool ("nothing reaches the ledger: " ^ body) true (ledger_whos () = []))
      [ {|{"keys":["space"],"hold_frames":"5"}|}, "hold_frames must be a positive integer"
      ; {|{"keys":["space"],"hold_frames":0}|}, "hold_frames must be a positive integer"
      ; {|{"keys":["space"],"frames":1.5}|}, "frames must be a positive integer"
      ; {|{"keys":["space"],"frames":null}|}, "frames must be a positive integer"
      ; {|{"keys":["space"],"sequence":1}|}, "sequence must be a boolean"
      ; {|{"keys":["space"],"sequence":"true"}|}, "sequence must be a boolean"
      ; {|{"keys":["space",1]}|}, "keys must be an array of strings"
      ; {|{"keys":"space"}|}, "keys must be an array of strings"
      ; {|{}|}, "keys must name at least one key"
      ; {|{"keys":[]}|}, "keys must name at least one key"
      ])
;;

let test_press_defaults_and_identity () =
  with_tick_machine (fun () ->
    Eio_main.run @@ fun _env ->
    let before = current_frame_number () in
    let status, response =
      Route.press_response
        ~config:(Lazy.force unwatched_config)
        ~who:"unit-presser"
        ~body:{|{"keys":["space"]}|}
    in
    check bool "a well-typed press succeeds" true (status = `OK);
    check
      (option bool)
      "ok is true"
      (Some true)
      (match member "ok" response with
       | Some (`Bool b) -> Some b
       | _ -> None);
    check
      int
      "absent frames means the named default"
      Route.press_default_step_frames
      (current_frame_number () - before);
    check
      bool
      "the edge is recorded under the caller's who"
      true
      (List.mem "unit-presser" (ledger_whos ()));
    let before = current_frame_number () in
    let status, _ =
      Route.press_response
        ~config:(Lazy.force unwatched_config)
        ~who:"unit-presser"
        ~body:
          {|{"keys":["space","space"],"sequence":true,"hold_frames":1,"frames":2}|}
    in
    check bool "a typed sequence press succeeds" true (status = `OK);
    check
      int
      "a sequence advances frames per key"
      4
      (current_frame_number () - before);
    let status, _ =
      Route.press_response
        ~config:(Lazy.force unwatched_config)
        ~who:"unit-presser"
        ~body:{|{"keys":["space"],"hold_frames":20}|}
    in
    check bool "the lane's own bounds still answer 400" true (status = `Bad_request))
;;

let remove_tree path =
  let rec go path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> go (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else
      Unix.unlink path
  in
  go path
;;

let loopback_request_authority () =
  match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
  | Ok authority -> authority
  | Error `Malformed -> fail "failed to construct loopback request authority"
;;

let dispatch_press ~state ~authorization ~body =
  Server_request_authority.with_current (loopback_request_authority ()) (fun () ->
    let router = Route.add_routes (Masc.Http_server_eio.Router.create ()) in
    Server_auth.publish_server_state state;
    let response_buf = Buffer.create 1024 in
    let conn =
      Httpun.Server_connection.create (fun reqd ->
        Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) reqd)
    in
    let request_str =
      Printf.sprintf
        "POST /api/v1/msx/press HTTP/1.1\r\n\
         Host: 127.0.0.1:8935\r\n\
         Origin: http://127.0.0.1:8935\r\n\
         %sContent-Type: application/json\r\n\
         Content-Length: %d\r\n\
         \r\n\
         %s"
        (match authorization with
         | Some token -> Printf.sprintf "Authorization: Bearer %s\r\n" token
         | None -> "")
        (String.length body)
        body
    in
    let bytes =
      Bigstringaf.of_string ~off:0 ~len:(String.length request_str) request_str
    in
    ignore
      (Httpun.Server_connection.read_eof
         conn
         bytes
         ~off:0
         ~len:(Bigstringaf.length bytes));
    let rec flush () =
      match Httpun.Server_connection.next_write_operation conn with
      | `Write iovecs ->
        let written =
          List.fold_left
            (fun total (iov : Bigstringaf.t Httpun.IOVec.t) ->
               Buffer.add_string
                 response_buf
                 (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
               total + iov.len)
            0
            iovecs
        in
        Httpun.Server_connection.report_write_result conn (`Ok written);
        flush ()
      | `Yield | `Close _ -> ()
    in
    flush ();
    Server_auth.clear_server_state ();
    Buffer.contents response_buf)
;;

let status_of_response response =
  match String.split_on_char ' ' response with
  | _ :: status :: _ -> int_of_string status
  | _ -> failf "could not parse response status: %S" response
;;

let test_press_route_names_the_resolved_actor () =
  with_tick_machine (fun () ->
    let base_path = Filename.temp_dir "msx-press-actor-" "" in
    Fun.protect
      ~finally:(fun () -> remove_tree base_path)
      (fun () ->
        Auth.save_auth_config
          base_path
          { Masc_domain.default_auth_config with enabled = true; require_token = true };
        let token =
          match
            Auth.create_token
              base_path
              ~agent_name:"tui-presser"
              ~role:Masc_domain.Admin
          with
          | Ok (token, _) -> token
          | Error err ->
            failf "create_token failed: %s" (Masc_domain.masc_error_to_string err)
        in
        let state = Masc.Mcp_server.For_testing.create_state ~base_path in
        Eio_main.run (fun _env ->
          let before = current_frame_number () in
          let refused =
            dispatch_press
              ~state
              ~authorization:None
              ~body:{|{"keys":["space"]}|}
          in
          check int "no credential is refused" 401 (status_of_response refused);
          check bool "a refused press reaches no ledger" true (ledger_whos () = []);
          check
            int
            "a refused press advances nothing"
            before
            (current_frame_number ());
          let accepted =
            dispatch_press
              ~state
              ~authorization:(Some token)
              ~body:{|{"keys":["space"]}|}
          in
          check
            int
            "a bearer press without x-masc-agent succeeds"
            200
            (status_of_response accepted);
          check
            bool
            "the ledger names the token's agent, not a literal"
            true
            (List.mem "tui-presser" (ledger_whos ()));
          check
            bool
            "no edge is attributed to \"operator\""
            false
            (List.mem "operator" (ledger_whos ())))))
;;

let () =
  run
    "msx routes"
    [ ( "checkpoint"
      , [ test_case
            "validation, worker, restore and storage failure"
            `Quick
            test_checkpoint_route
        ] )
    ; ( "press_json"
      , [ test_case "press result carries ok and the new frame" `Quick (fun () ->
            let dir = Filename.temp_dir "msx-press-route-" "" in
            (match
               Lane.load
                 ~ledger_dir:dir
                 ~roms_dir:None
                 ~cart_path:None
                 ~disk_path:None
             with
             | Ok _ -> ()
             | Error e -> fail (Lane.error_to_string e));
            (match
               Lane.press
                 ~who:"operator"
                 ~keys:[ Result.get_ok (Lane.key_of_string "space") ]
                 ~hold_frames:2
                 ~step_frames:6
                 ~sequence:false
             with
             | Ok obs ->
               let j = Route.press_result_json ~ok:true (Some obs) in
               check
                 (option bool)
                 "ok true"
                 (Some true)
                 (match member "ok" j with
                  | Some (`Bool b) -> Some b
                  | _ -> None);
               check
                 bool
                 "frame advanced past boot"
                 true
                 (match member "frame" j with
                  | Some (`Int n) -> n > Lane.boot_frames
                  | _ -> false);
               check
                 bool
                 "operator edge recorded"
                 true
                 (List.exists
                    (fun (e : Lane.entry) -> e.who = "operator")
                    (Lane.ledger ()))
             | Error e -> fail (Lane.error_to_string e));
            let j = Route.press_result_json ~ok:false ~message:"nope" None in
            check
              (option bool)
              "failure is ok:false"
              (Some false)
              (match member "ok" j with
               | Some (`Bool b) -> Some b
               | _ -> None);
            check
              (option string)
              "failure carries the message"
              (Some "nope")
              (match member "message" j with
               | Some (`String m) -> Some m
               | _ -> None);
            ignore (Lane.eject () : (unit, Lane.error) result))
        ] )
    ; ( "carts_json"
      , [ test_case
            "the inventory lists the cartridges under carts/"
            `Quick
            (fun () ->
              ignore (Lane.eject () : (unit, Lane.error) result);
              let base = Filename.temp_dir "msx-carts-route-" "" in
              let mk d = if not (Sys.file_exists d) then Sys.mkdir d 0o755 in
              let masc = Filename.concat base ".masc" in
              let msx = Filename.concat masc "msx" in
              let carts = Filename.concat msx "carts" in
              mk masc;
              mk msx;
              mk carts;
              let touch name =
                Out_channel.with_open_bin
                  (Filename.concat carts name)
                  (fun oc -> output_string oc "\xff")
              in
              touch "dig-dug.rom";
              touch "pac-man.rom";
              let j = Route.carts_json ~base_path:base in
              let names =
                match member "carts" j with
                | Some (`List items) ->
                  List.filter_map
                    (function
                      | `String s -> Some s
                      | _ -> None)
                    items
                | _ -> []
              in
              check
                bool
                "both cartridges are listed"
                true
                (List.mem "dig-dug.rom" names && List.mem "pac-man.rom" names);
              check
                (option bool)
                "nothing is loaded yet"
                (Some false)
                (match member "loaded" j with
                 | Some (`Bool b) -> Some b
                 | _ -> None))
        ] )
    ; ( "load_result_json"
      , [ test_case
            "ok and refusal carry the shape the TUI reads"
            `Quick
            (fun () ->
              let ok =
                Route.load_result_json ~ok:true ~message:"loaded xspelunker"
              in
              check
                (option bool)
                "ok is true"
                (Some true)
                (match member "ok" ok with
                 | Some (`Bool b) -> Some b
                 | _ -> None);
              let bad =
                Route.load_result_json ~ok:false ~message:"unknown cartridge"
              in
              check
                (option bool)
                "a refusal is ok:false"
                (Some false)
                (match member "ok" bad with
                 | Some (`Bool b) -> Some b
                 | _ -> None);
              check
                (option string)
                "and carries the message"
                (Some "unknown cartridge")
                (match member "message" bad with
                 | Some (`String m) -> Some m
                 | _ -> None))
        ] )
    ; ( "press_response"
      , [ test_case
            "a field of the wrong type is a 400 naming the field"
            `Quick
            test_press_rejects_wrong_types
        ; test_case
            "absent fields default and the who is the caller's"
            `Quick
            test_press_defaults_and_identity
        ] )
    ; ( "press_route"
      , [ test_case
            "the ledger names the actor the resolver returned"
            `Quick
            test_press_route_names_the_resolved_actor
        ] )
    ; ( "tick"
      , [ test_case
            "retained pixels keep atomic advancement and fresh metadata"
            `Quick
            test_retained_tick
        ; test_case
            "invalid ticks never mutate and missing workers refuse"
            `Quick
            test_tick_validation_precedes_mutation
        ; test_case
            "accepted ticks advance once on the worker and return pixels"
            `Quick
            test_tick_worker_advances_and_returns_frame
        ] )
    ]
;;
