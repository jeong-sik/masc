(* RFC-0301 item 6 — see keeper_stream_media_accum.mli. Mirrors the media chunk
   accumulation the SSE bridge does ([Keeper_chat_oas_stream_bridge]'s
   [Active_media] block), kept as a parallel turn-local collector rather than a
   shared abstraction so the bridge (which owns live SSE translation) and this
   collector (which owns durable persistence) stay on their own side of the
   OAS-stream / chat-store boundary. *)

(* Attach-block label for generated media with no dedicated image/voice reload
   block (documents, unrecognized types). The payload is still persisted and served
   by token, so this keeps it visible on reload rather than dropping it silently. *)
let generic_media_label = "generated media"

type finalized = {
  media_type : string;
  data : string;
}

type t = {
  (* index -> (media_type, reversed data chunks) for media blocks still open *)
  mutable open_media : (int * (string * string list)) list;
  mutable finalized_rev : finalized list;
}

let create () = { open_media = []; finalized_rev = [] }

let on_event t (evt : Agent_sdk.Types.sse_event) =
  match evt with
  | Agent_sdk.Types.ContentBlockDelta
      { index; delta = Agent_sdk.Types.MediaDelta { media_type; data; _ } } ->
    let prev =
      match List.assoc_opt index t.open_media with
      | Some (_, chunks) -> chunks
      | None -> []
    in
    t.open_media <-
      (index, (media_type, data :: prev)) :: List.remove_assoc index t.open_media
  | Agent_sdk.Types.ContentBlockStop { index } -> (
    match List.assoc_opt index t.open_media with
    | Some (media_type, chunks) ->
      let data = String.concat "" (List.rev chunks) in
      t.finalized_rev <- { media_type; data } :: t.finalized_rev;
      t.open_media <- List.remove_assoc index t.open_media
    | None -> ())
  | _ -> ()

let to_chat_blocks ~base_dir t =
  List.rev t.finalized_rev
  |> List.map (fun { media_type; data } ->
         let _token, media_ref =
           Keeper_chat_media_store.persist ~base_dir ~media_type ~data
         in
         match Keeper_chat_media_store.category_of_media_type media_type with
         | Keeper_chat_media_store.Image ->
           Keeper_chat_blocks.Image { src = media_ref; cap = None }
         | Keeper_chat_media_store.Audio ->
           Keeper_chat_blocks.Voice
             {
               secs = None;
               wave = None;
               via = None;
               size = None;
               transcript = None;
               src = Some media_ref;
             }
         | Keeper_chat_media_store.Document | Keeper_chat_media_store.Other ->
           Keeper_chat_blocks.Attach
             {
               name = generic_media_label;
               dims = None;
               src = Some media_ref;
               svg = None;
               ph = None;
               via = None;
               size = None;
               data = None;
               mime_type = Some media_type;
               size_bytes = None;
               kind = None;
             })
