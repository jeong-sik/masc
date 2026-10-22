(* RFC-0301 item 6 — see keeper_stream_media_accum.mli. The live SSE bridge and
   this turn-local durable collector retain their separate delivery policies. *)

module State = Keeper_stream_media_state

type t = { mutable state : State.t }

let create () =
  (* Freeze the wire cap before any event. Persistence still owns its separate
     decoded-byte limit and reads that limit when the files are written. *)
  let max_wire_bytes = Keeper_chat_media_store.max_wire_bytes () in
  { state = State.create ~max_wire_bytes }

let start_runtime_attempt t =
  t.state <- State.start_runtime_attempt t.state

let record_oversize_drop t ~index (dropped : State.wire_drop) =
  Log.Keeper.warn
    "generated media dropped index=%d media_type=%S: %d wire-carrier bytes exceed the %d-byte cap"
    index
    dropped.media_type
    dropped.encoded_bytes
    dropped.max_wire_bytes;
  (* The logger can invoke an observer. Preserve its changes, and record no
     drop if the warning raised. *)
  t.state <- State.record_completed t.state (State.Wire_dropped dropped)

let finalize_media t pending =
  let index =
    match State.finalize_media pending with
    | Ok finalized ->
        t.state <- State.record_completed t.state (State.Persistable finalized);
        finalized.index
    | Error (index, dropped) ->
        record_oversize_drop t ~index dropped;
        index
  in
  t.state <- State.close_block t.state index

let on_event ?(stream_scope = 0) t evt =
  (* Scope entry precedes event evaluation, including any diagnostic failure. *)
  t.state <- State.enter_stream_scope t.state stream_scope;
  match State.on_event t.state evt with
  | State.Unchanged -> ()
  | State.Updated state -> t.state <- state
  | State.Metadata_drift
      { index; expected_media_type; received_media_type;
        expected_source_type; received_source_type } ->
      Log.Keeper.warn
        "generated media metadata drift ignored index=%d expected_media_type=%S received_media_type=%S expected_source_type=%s received_source_type=%s"
        index
        expected_media_type
        received_media_type
        (Agent_core.Types.media_source_kind_to_string expected_source_type)
        (Agent_core.Types.media_source_kind_to_string received_source_type)
  | State.Wire_rejected (index, dropped) ->
      record_oversize_drop t ~index dropped;
      t.state <- State.reject_block t.state index
  | State.Finalize (pending, terminal) ->
      (* Publish each completed block before the next concatenation or warning.
         The captured entries survive observer changes to current occupancy. *)
      List.iter (finalize_media t) pending;
      Option.iter
        (fun terminal -> t.state <- State.finish_message t.state terminal)
        terminal

(* Attach-block label for generated media without a dedicated image/voice
   reload block. Its payload is still persisted and served by token. *)
let generic_media_label = "generated media"

(* Reload placeholder for an oversize drop: no payload to serve (src = None),
   but the reader sees what was generated, its type, and how large it was
   instead of the media silently missing from the persisted turn. *)
let unavailable_attachment ~name ~media_type ~size ~size_bytes =
  Keeper_chat_blocks.Attach
    { name;
      dims = None;
      src = None;
      svg = None;
      ph = Some "Generated media is unavailable.";
      via = None;
      size;
      data = None;
      mime_type = Some media_type;
      size_bytes;
      kind = None
    }

let wire_drop_placeholder_block
    ({ media_type; encoded_bytes; max_wire_bytes } : State.wire_drop) =
  unavailable_attachment
    ~name:
      (Printf.sprintf
         "generated media unavailable: %s exceeded the %d-byte wire-carrier cap"
         media_type
         max_wire_bytes)
    ~media_type
    ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
    ~size_bytes:(Some encoded_bytes)

let persist_failure_placeholder ~media_type ~encoded_bytes = function
  | Keeper_chat_media_store.Unsupported_source_type source_type ->
      unavailable_attachment
        ~name:
          (Printf.sprintf
             "generated media unavailable: unsupported source type %s"
             (Agent_core.Types.media_source_kind_to_string source_type))
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)
  | Keeper_chat_media_store.Invalid_base64 _ ->
      unavailable_attachment
        ~name:"generated media unavailable: provider returned invalid base64"
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)
  | Keeper_chat_media_store.Media_too_large { size_bytes; max_bytes } ->
      unavailable_attachment
        ~name:
          (Printf.sprintf
             "generated media unavailable: decoded payload exceeded the %d-byte storage cap"
             max_bytes)
        ~media_type
        ~size:(Some (Printf.sprintf "%d decoded bytes observed" size_bytes))
        ~size_bytes:(Some size_bytes)
  | Keeper_chat_media_store.Write_failed _ ->
      unavailable_attachment
        ~name:"generated media unavailable: storage write failed"
        ~media_type
        ~size:(Some (Printf.sprintf "%d wire-carrier bytes observed" encoded_bytes))
        ~size_bytes:(Some encoded_bytes)

let persisted_block ~media_type media_ref =
  let attachment name =
    Keeper_chat_blocks.Attach
      { name; dims = None; src = Some media_ref; svg = None; ph = None;
        via = None; size = None; data = None; mime_type = Some media_type;
        size_bytes = None; kind = None } in
  match Keeper_chat_media_store.category_of_media_type media_type with
  | Keeper_chat_media_store.Image ->
      Keeper_chat_blocks.Image { src = media_ref; cap = None }
  | Keeper_chat_media_store.Audio ->
      Keeper_chat_blocks.Voice
        { secs = None;
          wave = None;
          via = None;
          size = None;
          transcript = None;
          src = Some media_ref
        }
  | Keeper_chat_media_store.Midi -> attachment "generated.mid"
  | Keeper_chat_media_store.Document | Keeper_chat_media_store.Other ->
      attachment generic_media_label

let completed_to_chat_block ~base_dir = function
  | State.Wire_dropped dropped -> wire_drop_placeholder_block dropped
  | State.Persistable { index; media_type; source_type; data } ->
      (match
         Keeper_chat_media_store.persist_media_source_result ~base_dir
           ~media_type ~source_type ~data
       with
       | Ok (_token, media_ref) -> persisted_block ~media_type media_ref
       | Error err ->
           Log.Keeper.warn
             "generated media reload persist failed index=%d media_type=%S source_type=%s: %s"
             index
             media_type
             (Agent_core.Types.media_source_kind_to_string source_type)
             (Keeper_chat_media_store.persist_error_to_string err);
           persist_failure_placeholder
             ~media_type
             ~encoded_bytes:(String.length data)
             err)

let to_chat_blocks ~base_dir t =
  State.completed t.state
  |> List.map (completed_to_chat_block ~base_dir)
