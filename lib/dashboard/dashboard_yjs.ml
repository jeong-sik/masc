
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

let broadcast_update payload =
  let buf = Buffer.create 16 in
  Buffer.add_char buf (Char.chr 0);
  Buffer.add_char buf (Char.chr 2);
  Buffer.add_string buf (encode_uint (String.length payload));
  Buffer.add_string buf payload;
  let bin_msg = Buffer.contents buf in
  (* Prototype: In a real system, this forwards the binary message to Httpun-ws clients *)
  ignore bin_msg;
  ()

let broadcast_keeper_telemetry ~keeper_name ~trace_id:_ ~turn_index ~model_id:_ =
  (* Prototype: Mocking a Yjs binary update payload for a YMap *)
  let payload = Printf.sprintf "keeper_update:%s:%d" keeper_name turn_index in
  broadcast_update payload

let broadcast_trace_telemetry ~author ~position =
  (* Prototype: Mocking a Yjs binary update payload for a YArray *)
  let payload = Printf.sprintf "trace_update:%s:%d" author position in
  broadcast_update payload
