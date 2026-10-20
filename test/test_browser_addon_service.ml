open Alcotest
module W = Masc.Browser_addon_wire
module Owner = Masc.Browser_addon_owner
module Service = Masc.Browser_addon_service
let ok = function Ok value -> value | Error message -> fail message
let incarnation = "0b000000-0000-4000-8000-000000000001"
let scenario () =
  let directory = Filename.temp_file "ba" "" in
  Unix.unlink directory;Unix.mkdir directory 0o700;
  let directory = Unix.realpath directory in
  Fun.protect ~finally:(fun () -> Unix.rmdir directory) (fun () ->
    Eio_main.run (fun env ->
      Time_compat.set_clock (Eio.Stdenv.clock env);
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. (fun () -> Eio.Switch.run (fun sw ->
        let net = Eio.Stdenv.net env in
        let owner = ok (Owner.create ~incarnation) in
        Eio.Switch.on_release sw (fun () -> Owner.revoke owner);
        let path = Filename.concat directory "s" and small = Filename.concat directory "t" in
        let ready path =
          let rec wait () = match Unix.lstat path with
            | _ -> ()
            | exception Unix.Unix_error (Unix.ENOENT,_,_) -> Eio.Fiber.yield ();wait () in wait () in
        let connect path = Eio.Net.connect ~sw net (`Unix path) in
        Eio.Fiber.first
          (fun () -> Service.serve ~net ~owner ~socket_path:path ~max_message_bytes:4096)
          (fun () ->
            ready path;
            let idle = connect path in Eio.Flow.copy_string "{" idle;
            let live = connect path in
            Eio.Flow.copy_string (Yojson.Safe.to_string (W.to_json {W.incarnation;command=W.Snapshot}) ^ "\n") live;
            let raw = Eio.Buf_read.line (Eio.Buf_read.of_flow live ~max_size:4096) in
            check bool "idle client does not block another request" true
              (match ok (W.reply_of_json (Yojson.Safe.from_string raw)) with
               | W.Snapshot_result _ -> true
               | W.Poll_result _|Receipt|Issue_result _|Service_refusal _ -> false);
            Eio.Fiber.first
              (fun () -> Service.serve ~net ~owner ~socket_path:small ~max_message_bytes:1)
              (fun () ->
                ready small;let flow=connect small in Eio.Flow.copy_string "{}\n" flow;
                let reader=Eio.Buf_read.of_flow flow ~max_size:4096 in
                let output=Eio.Buf_read.take_all reader in
                check int "small bound is never exceeded by fallback" 0 (String.length output));
            Owner.revoke owner);
        check bool "normal socket removed after cancellation" false (Sys.file_exists path);
        check bool "small socket removed after cancellation" false (Sys.file_exists small)))))
let () = run "browser addon service" ["transport",[test_case "idle cancellation and tiny bound" `Quick scenario]]
