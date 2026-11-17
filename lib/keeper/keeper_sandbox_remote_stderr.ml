let rs = Char.chr 0x1e

let split_final_trailer stderr =
  match String.rindex_opt stderr rs with
  | None -> Error "no result trailer delimiter"
  | Some close_i when close_i <> String.length stderr - 1 ->
    Error "bytes followed the final result trailer delimiter"
  | Some close_i ->
    (match String.rindex_from_opt stderr (close_i - 1) rs with
     | None -> Error "result trailer has no opening delimiter"
     | Some open_i ->
       let trailer = String.sub stderr open_i (close_i - open_i + 1) in
       let payload_stderr = String.sub stderr 0 open_i in
       Ok (payload_stderr, trailer))
;;

let trailer_tail_limit = 64 * 1024

(* The front of a stderr stream is held only while it could still become the
   acceptance frame, and only for a request that asked for one. *)
type stderr_head =
  | Head_released
  | Awaiting_head of string

type t =
  { callback : (string -> unit) option
  ; mutable tail : string
  ; mutable head : stderr_head
  ; on_accepted : unit -> unit
  }

(* The trailer is the final RS-delimited frame, so its opening delimiter is the
   second-to-last RS of the completed stream, and every byte before that RS is
   payload no matter what arrives next. Returns how much of [text] can be handed
   to the caller now. Holding the whole tail back instead would delay a stderr
   line until the process exits, and [gh auth login] writes its one-time code to
   stderr and then waits for the browser: a code delivered at exit arrives after
   the login it was needed for has already timed out. *)
let releasable_prefix_len text =
  match String.rindex_opt text rs with
  | None -> String.length text
  | Some last ->
    (match String.rindex_from_opt text (last - 1) rs with
     | None -> last
     | Some second_last -> second_last)
;;

let stream_payload_chunk stream chunk =
  let combined = stream.tail ^ chunk in
  (* The tail limit still bounds the retained region when payload bytes carry an
     RS of their own; a trailer is orders of magnitude below it. *)
  let release =
    max (releasable_prefix_len combined) (String.length combined - trailer_tail_limit)
  in
  if release > 0
  then (
    Option.iter
      (fun callback -> callback (String.sub combined 0 release))
      stream.callback;
    stream.tail <- String.sub combined release (String.length combined - release))
  else stream.tail <- combined
;;

let stream_chunk stream chunk =
  match stream.head with
  | Head_released -> stream_payload_chunk stream chunk
  | Awaiting_head held ->
    let head = held ^ chunk in
    (match Exec_ssh_protocol.split_acceptance_head head with
     | Exec_ssh_protocol.Head_pending -> stream.head <- Awaiting_head head
     | Exec_ssh_protocol.Head_payload ->
       stream.head <- Head_released;
       stream_payload_chunk stream head
     | Exec_ssh_protocol.Head_frame { preamble; rest; _ } ->
       stream.head <- Head_released;
       stream.on_accepted ();
       let payload = preamble ^ rest in
       if payload <> "" then stream_payload_chunk stream payload)
;;

(* The process ended while the front was still undecided: those bytes are
   payload, less a frame the wire cut off. *)
let settle_head stream =
  match stream.head with
  | Head_released -> ()
  | Awaiting_head held ->
    stream.head <- Head_released;
    let payload = Exec_ssh_protocol.settle_acceptance_head held in
    if payload <> "" then stream_payload_chunk stream payload
;;

let flush_payload stream payload =
  if payload <> "" then Option.iter (fun callback -> callback payload) stream.callback;
  stream.tail <- ""
;;

let create ?callback ~acceptance_frame ~on_accepted () =
  { callback; tail = "";
    head = (if acceptance_frame then Awaiting_head "" else Head_released);
    on_accepted }

let tail stream = stream.tail
