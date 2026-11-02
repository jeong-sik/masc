(** Every chat-store writer announces the rows it appends.

    An external SSE subscriber counts [keeper_chat_appended] frames for one
    Keeper. A first write of a row is heard once; writing the same delivery
    again appends nothing and is not heard. *)

open Masc
module K = Keeper_chat_store

let keeper_name = "chat-store-announces-keeper"

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_chat_store_announces_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let chat_appended_fields frame =
  match Sse.data_payload_of_frame frame with
  | Error Sse.Missing_data_payload -> None
  | Ok payload ->
    (match Yojson.Safe.from_string payload with
     | `Assoc fields
       when List.assoc_opt "type" fields = Some (`String "keeper_chat_appended")
            && List.assoc_opt "name" fields = Some (`String keeper_name) ->
       Some fields
     | _ -> None
     | exception Yojson.Json_error _ -> None)
;;

(* Runs [f] with a fresh workspace and the list of chat-appended events heard
   so far, newest first. *)
let with_heard f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_dir = temp_dir () in
  let heard = ref [] in
  let subscriber_id =
    Printf.sprintf "chat-store-announces-%d-%d" (Unix.getpid ()) (Random.int 1_000_000)
  in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree base_dir)
    (fun () ->
       Eio.Switch.run @@ fun sw ->
       Eio.Switch.on_release sw (fun () -> Sse.unsubscribe_external subscriber_id);
       Sse.subscribe_external ~id:subscriber_id
         ~callback:(fun (ev : Sse.external_event) ->
           match chat_appended_fields ev.Sse.ext_frame with
           | Some fields -> heard := fields :: !heard
           | None -> ())
         ();
       f ~base_dir heard)
;;

let request_id value =
  match Keeper_chat_delivery_identity.Request_id.of_string value with
  | Ok id -> id
  | Error detail -> Alcotest.fail detail
;;

let ok = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let check_heard heard expected label =
  Alcotest.(check int) label expected (List.length !heard)
;;

let connector fields =
  match List.assoc_opt "connector" fields with
  | Some (`String value) -> Some value
  | Some _ | None -> None
;;

let test_user_row_once () =
  with_heard @@ fun ~base_dir heard ->
  let write () =
    K.append_user_message_once ~base_dir ~keeper_name
      ~delivery_key:(Keeper_chat_delivery_identity.Connector_message (request_id "user-row"))
      ~content:"hello" ~surface:Surface_ref.Broadcast ()
    |> ok
  in
  ignore (write () : K.append_once_result);
  check_heard heard 1 "first append is heard";
  Alcotest.(check (option string)) "connector is the row's surface label"
    (Some "broadcast") (connector (List.hd !heard));
  ignore (write () : K.append_once_result);
  check_heard heard 1 "the same delivery appends nothing and is not heard"
;;

let test_user_row () =
  with_heard @@ fun ~base_dir heard ->
  K.append_user_message ~base_dir ~keeper_name ~content:"ambient"
    ~surface:Surface_ref.Agent ();
  check_heard heard 1 "an ambient user row is heard"
;;

let test_assistant_row_carries_its_clip () =
  with_heard @@ fun ~base_dir heard ->
  let audio : K.audio_clip =
    { token = "clip-token"
    ; audio_url = None
    ; mime = "audio/mpeg"
    ; duration_sec = None
    ; message_text = "spoken"
    ; device_id = None
    ; expired = false
    }
  in
  K.append_assistant_message_result ~base_dir ~keeper_name ~content:"spoken"
    ~surface:(Surface_ref.Dashboard { session_id = None }) ~audio ()
  |> ok;
  check_heard heard 1 "an assistant row is heard";
  let token =
    match List.assoc_opt "audio" (List.hd !heard) with
    | Some (`Assoc clip) -> List.assoc_opt "token" clip
    | Some _ | None -> None
  in
  Alcotest.(check bool) "the event carries the stored clip" true
    (token = Some (`String "clip-token"))
;;

let test_terminal_row_once () =
  with_heard @@ fun ~base_dir heard ->
  let delivery_key = Keeper_chat_delivery_identity.Operation (request_id "terminal-row") in
  let write () =
    K.append_assistant_message_once ~base_dir ~keeper_name ~delivery_key ~content:"done" ()
    |> ok
  in
  ignore (write () : K.append_once_result);
  ignore (write () : K.append_once_result);
  check_heard heard 1 "a terminal row is heard once";
  Alcotest.(check (option string)) "a row without a surface has no connector" None
    (connector (List.hd !heard))
;;

let test_tool_rows_once () =
  with_heard @@ fun ~base_dir heard ->
  let write () =
    K.append_tool_calls_once ~base_dir ~keeper_name
      ~delivery_key:(Keeper_chat_delivery_identity.Operation (request_id "tool-rows"))
      ~tool_calls:
        [ { K.call_id = "call-1"; execution_id = None; call_name = "Read"; args = "{}" }
        ; { K.call_id = "call-2"; execution_id = None; call_name = "Read"; args = "{}" }
        ]
      ()
    |> ok
  in
  ignore (write () : K.append_once_result);
  ignore (write () : K.append_once_result);
  check_heard heard 1 "one write of two tool rows is heard once"
;;

let test_settled_failures_per_row () =
  with_heard @@ fun ~base_dir heard ->
  let failure name : string * K.Settled_failure.t =
    ( name
    , { K.Settled_failure.delivery_key =
          Keeper_chat_delivery_identity.Operation (request_id name)
      ; content = "failed"
      ; route = Lazy.from_val K.Row_route.none
      } )
  in
  let write () =
    K.append_settled_failures_once ~base_dir ~keeper_name
      [ failure "failed-a"; failure "failed-b" ]
    |> ok
  in
  ignore (write () : (string * (K.append_once_result, string) result) list);
  check_heard heard 2 "each appended failure row is heard";
  ignore (write () : (string * (K.append_once_result, string) result) list);
  check_heard heard 2 "failures already present are not heard again"
;;

let test_approval_row_once () =
  with_heard @@ fun ~base_dir heard ->
  let lifecycle : K.approval_lifecycle =
    { approval_id = "approval-row"
    ; tool_name = Some "Write"
    ; phase = Keeper_approval_lifecycle.Approval_requested
    ; artifact_ref = None
    ; call_summary = None
    }
  in
  let write () = K.append_approval_lifecycle_once ~base_dir ~keeper_name ~lifecycle |> ok in
  ignore (write () : K.append_once_result);
  ignore (write () : K.append_once_result);
  check_heard heard 1 "an approval row is heard once"
;;

let () =
  Alcotest.run "keeper_chat_store_announces"
    [ ( "writers"
      , [ Alcotest.test_case "user row once" `Quick test_user_row_once
        ; Alcotest.test_case "ambient user row" `Quick test_user_row
        ; Alcotest.test_case "assistant row carries its clip" `Quick
            test_assistant_row_carries_its_clip
        ; Alcotest.test_case "terminal row once" `Quick test_terminal_row_once
        ; Alcotest.test_case "tool rows once" `Quick test_tool_rows_once
        ; Alcotest.test_case "settled failures per row" `Quick test_settled_failures_per_row
        ; Alcotest.test_case "approval row once" `Quick test_approval_row_once
        ] )
    ]
;;
