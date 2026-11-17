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

(* The front of a stderr stream is held only while it could still become the
   acceptance frame, and only for a request that asked for one. *)
type stderr_head =
  | Head_released
  | Awaiting_head of string

(* Each segment starts with its delimiter. Only these last two segments can
   still belong to the final frame; a third delimiter releases the oldest. *)
type stderr_suffix =
  | No_delimiter
  | One_delimiter of Buffer.t
  | Two_delimiters of Buffer.t * Buffer.t

type t =
  { callback : (string -> unit) option
  ; mutable suffix : stderr_suffix
  ; mutable materialized_tail : string option
  ; mutable head : stderr_head
  ; on_accepted : unit -> unit
  }

let stream_payload_chunk stream chunk =
  stream.materialized_tail <- None;
  let released = ref [] in
  let release bytes = released := bytes :: !released in
  let append start length =
    if length > 0 then
      match stream.suffix with
      | No_delimiter ->
        release (String.sub chunk start length)
      | One_delimiter latest | Two_delimiters (_, latest) ->
        Buffer.add_substring latest chunk start length;
        stream.materialized_tail <- None
  in
  let new_segment () =
    let segment = Buffer.create 256 in
    Buffer.add_char segment rs;
    segment
  in
  let delimiter () =
    stream.suffix <-
      (match stream.suffix with
      | No_delimiter -> One_delimiter (new_segment ())
      | One_delimiter latest -> Two_delimiters (latest, new_segment ())
      | Two_delimiters (older, latest) ->
        release (Buffer.contents older);
        (* Reuse the segment object without retaining a previously large
           payload allocation after that segment has been released. *)
        Buffer.reset older;
        Buffer.add_char older rs;
        Two_delimiters (latest, older));
    stream.materialized_tail <- None
  in
  let rec consume start =
    match String.index_from_opt chunk start rs with
    | None -> append start (String.length chunk - start)
    | Some at ->
      append start (at - start);
      delimiter ();
      consume (at + 1)
  in
  (* Scan only the arriving chunk; appending is amortized linear even for an
     unbounded observed_syscalls trailer split over many transport chunks. *)
  consume 0;
  (* A finite process collector may continue after a user callback raises.
     Retain every control byte already read before that policy takes effect;
     interactive callers still receive the original callback exception. *)
  Option.iter (fun callback -> List.iter callback (List.rev !released)) stream.callback
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
  stream.suffix <- No_delimiter;
  stream.materialized_tail <- None
;;

let create ?callback ~acceptance_frame ~on_accepted () =
  { callback; suffix = No_delimiter; materialized_tail = None;
    head = (if acceptance_frame then Awaiting_head "" else Head_released);
    on_accepted }

let tail stream =
  match stream.materialized_tail with
  | Some tail -> tail
  | None ->
    let tail = match stream.suffix with
      | No_delimiter -> ""
      | One_delimiter latest -> Buffer.contents latest
      | Two_delimiters (older, latest) -> Buffer.contents older ^ Buffer.contents latest
    in
    stream.materialized_tail <- Some tail;
    tail
