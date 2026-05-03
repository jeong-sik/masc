
let encode_uint (n : int) : string =
  let buf = Buffer.create 8 in
  let rec loop num =
    if num < 128 then Buffer.add_char buf (Char.chr num)
    else begin
      Buffer.add_char buf (Char.chr ((num land 0x7f) lor 0x80));
      loop (num lsr 7)
    end
  in
  loop n;
  Buffer.contents buf

(** Dashboard_yjs — Yjs WebSocket Projection Layer for Live Telemetry
    @since Project World Building (Big Bang) *)

let frame_update payload =
  let buf = Buffer.create (String.length payload + 8) in
  Buffer.add_char buf (Char.chr 0);
  Buffer.add_char buf (Char.chr 2);
  Buffer.add_string buf (encode_uint (String.length payload));
  Buffer.add_string buf payload;
  Buffer.contents buf

let broadcast_update ~kind payload =
  let frame = frame_update payload in
  let json =
    `Assoc
      [
        ("type", `String "dashboard_yjs_update");
        ("kind", `String kind);
        ("payload", `String payload);
        ("payload_len", `Int (String.length payload));
        ("frame_base64", `String (Base64.encode_string frame));
        ("encoding", `String "yjs_update_v1_base64");
      ]
  in
  try Sse.broadcast_to Sse.Observers json with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
      Log.Dashboard.warn "dashboard Yjs SSE broadcast failed: %s"
        (Printexc.to_string exn)

let broadcast_keeper_telemetry ~keeper_name ~trace_id ~turn_index ~model_id =
  let payload =
    `Assoc
      [
        ("kind", `String "keeper_update");
        ("keeper_name", `String keeper_name);
        ("trace_id", `String trace_id);
        ("turn_index", `Int turn_index);
        ("model_id", `String model_id);
      ]
    |> Yojson.Safe.to_string
  in
  broadcast_update ~kind:"keeper_update" payload

let broadcast_trace_telemetry ~author ~position =
  let payload =
    `Assoc
      [
        ("kind", `String "trace_update");
        ("author", `String author);
        ("position", `Int position);
      ]
    |> Yojson.Safe.to_string
  in
  broadcast_update ~kind:"trace_update" payload
