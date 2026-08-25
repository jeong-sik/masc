(** See {!Masc_tui_attachment} (.mli) for the contract. *)

type error =
  | Unreadable of { path : string; detail : string }
  | Empty of { path : string }
  | Too_large of { path : string; size : int; max : int }
  | Unsupported of { path : string; detail : string }

(* Same cap as the dashboard composer (MAX_IMAGE_SIZE in
   dashboard/src/components/chat/attachments.ts). One number on both surfaces
   means a file the operator can attach in the browser is a file they can attach
   here; two numbers would make "too large" depend on which window is open. *)
let max_bytes = 5 * 1024 * 1024

let read_all path =
  match open_in_bin path with
  | exception Sys_error detail -> Error (Unreadable { path; detail })
  | channel ->
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        match really_input_string channel (in_channel_length channel) with
        | bytes -> Ok bytes
        | exception End_of_file ->
          Error (Unreadable { path; detail = "file ended early while reading" })
        | exception Sys_error detail -> Error (Unreadable { path; detail }))
;;

let of_file ~path =
  match read_all path with
  | Error _ as error -> error
  | Ok bytes ->
    let size = String.length bytes in
    if size = 0
    then Error (Empty { path })
    else if size > max_bytes
    then Error (Too_large { path; size; max = max_bytes })
    else (
      (* The bytes decide the media type, not the extension. A .png that is
         actually a PDF has to fail here; announcing it to the endpoint as
         image/png would make the provider reject the whole turn instead. *)
      match Masc.Keeper_vision_tool.sniff_image_media_type bytes with
      | Error detail -> Error (Unsupported { path; detail })
      | Ok mime_type ->
        Ok
          { Masc_tui_keeper_chat_projection.attachment_id =
              "tui-att-" ^ Random_id.uuid_v7 ()
          ; name = Filename.basename path
          ; mime_type
          ; size
          ; data = Base64.encode_string bytes
          })
;;

let error_to_string = function
  | Unreadable { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Empty { path } -> Printf.sprintf "%s is empty" path
  | Too_large { path; size; max } ->
    Printf.sprintf
      "%s is %d bytes; the limit is %d"
      path
      size
      max
  | Unsupported { path; detail } -> Printf.sprintf "%s: %s" path detail
;;

type drop =
  | Attach of Masc_tui_keeper_chat_projection.attachment
  | Keep_path
  | Refuse of error

let classify_drop ~path =
  match of_file ~path with
  | Ok attachment -> Attach attachment
  | Error (Unsupported _) -> Keep_path
  | Error error -> Refuse error
;;
