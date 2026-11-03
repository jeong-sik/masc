(** A held tool call and a Keeper's tool approval mode announce their changes,
    and a reader that answers the announcement sees the change: the wait is
    listed when its registration is heard and gone when its answer, timeout or
    ending turn is heard; the mode reads as set when its change is heard. *)

open Masc
module Registry = Keeper_tool_approval_registry
module Mode = Keeper_tool_approval_mode

let keeper = "announcing-keeper"

let event_of_frame frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> None
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields ->
       (match List.assoc_opt "type" fields, List.assoc_opt "name" fields with
        | Some (`String event), Some (`String name) -> Some (event, name)
        | _ -> None)
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

(* Calls [f] with a list that gains [read ()] each time [event] naming
   [keeper] is heard. *)
let hearing ~event ~read f =
  let id = Printf.sprintf "tool-approval-announces-%d-%s" (Unix.getpid ()) event in
  let heard = ref [] in
  Sse.subscribe_external ~id
    ~callback:(fun (ev : Sse.external_event) ->
      match event_of_frame ev.Sse.ext_frame with
      | Some (name, who) when String.equal name event && String.equal who keeper ->
        heard := read () :: !heard
      | Some _ | None -> ())
    ();
  Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () -> f heard)
;;

let listed registry () =
  List.length
    (List.filter
       (fun (p : Registry.pending) -> String.equal p.keeper_name keeper)
       (Registry.pending registry))
;;

let await registry ~clock ~tool_call_id ~timeout_sec =
  Registry.await registry ~clock ~on_registered:Fun.id ~approval_id:("approval-" ^ tool_call_id)
    ~tool_name:"Execute" ~args:"{}" ~question:"run?" ~because:"policy: ask"
    ~keeper_name:keeper ~tool_call_id ~timeout_sec
;;

let rec until_listed registry ~clock attempts =
  if listed registry () = 0 && attempts > 0 then begin
    Eio.Time.sleep clock 0.005;
    until_listed registry ~clock (attempts - 1)
  end
;;

let check_heard label expected heard =
  Alcotest.(check (list int)) label expected (List.rev !heard)
;;

let test_an_answered_wait_is_announced_listed_then_gone () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let registry = Registry.create () in
  hearing ~event:Keeper_tool_approval_broadcast.waits_changed_event ~read:(listed registry)
    (fun heard ->
       Eio.Fiber.both
         (fun () -> ignore (await registry ~clock ~tool_call_id:"answered" ~timeout_sec:5.0))
         (fun () ->
            until_listed registry ~clock 100;
            ignore
              (Registry.settle registry ~keeper_name:keeper ~tool_call_id:"answered"
                 ~approval_id:"approval-answered" Registry.Approve));
       check_heard "registered, then answered" [ 1; 0 ] heard)
;;

let test_a_timed_out_wait_is_announced_gone () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let registry = Registry.create () in
  hearing ~event:Keeper_tool_approval_broadcast.waits_changed_event ~read:(listed registry)
    (fun heard ->
       ignore (await registry ~clock ~tool_call_id:"timed-out" ~timeout_sec:0.05);
       check_heard "registered, then timed out" [ 1; 0 ] heard)
;;

let test_a_wait_ended_with_its_turn_is_announced_gone () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let registry = Registry.create () in
  hearing ~event:Keeper_tool_approval_broadcast.waits_changed_event ~read:(listed registry)
    (fun heard ->
       Eio.Fiber.first
         (fun () -> ignore (await registry ~clock ~tool_call_id:"cancelled" ~timeout_sec:5.0))
         (fun () -> until_listed registry ~clock 100);
       check_heard "registered, then gone with the turn" [ 1; 0 ] heard)
;;

let test_a_mode_change_is_announced_as_set () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_file "tool-approval-announces-" ".dir" in
  Sys.remove base_path;
  Unix.mkdir base_path 0o700;
  Fun.protect ~finally:(fun () -> Fs_compat.remove_tree base_path) (fun () ->
    let modes = Mode.create () in
    let read () = match Mode.resolve modes ~keeper_name:keeper with Mode.Yolo -> 1 | Mode.Auto -> 0 in
    hearing ~event:Keeper_tool_approval_broadcast.mode_changed_event ~read (fun heard ->
      let set mode =
        match Mode.set modes ~base_path ~actor:"operator" ~keeper_name:keeper mode with
        | Ok _ -> ()
        | Error detail -> Alcotest.fail detail
      in
      set Mode.Yolo;
      set Mode.Auto;
      check_heard "each change reads as set when heard" [ 1; 0 ] heard))
;;

let () =
  Alcotest.run "keeper_tool_approval_announces"
    [ ( "waits"
      , [ Alcotest.test_case "an answered wait is announced listed, then gone" `Quick
            test_an_answered_wait_is_announced_listed_then_gone
        ; Alcotest.test_case "a timed-out wait is announced gone" `Quick
            test_a_timed_out_wait_is_announced_gone
        ; Alcotest.test_case "a wait ended with its turn is announced gone" `Quick
            test_a_wait_ended_with_its_turn_is_announced_gone
        ] )
    ; ( "mode"
      , [ Alcotest.test_case "a mode change is announced as set" `Quick
            test_a_mode_change_is_announced_as_set
        ] )
    ]
;;
