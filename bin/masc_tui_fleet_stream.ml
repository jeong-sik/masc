module F = Masc.Fleet_stream

type reading =
  { revision : F.Revision.t
  ; measured_at : float
  ; fleet : F.fleet
  ; degraded : F.degradation option
  }

type trouble =
  | Scans_failing of F.degradation
  | Disconnected of { since : float }

type failure =
  | Refused of { status : int; detail : string }
  | Schema_mismatch of { expected : int; received : int }
  | Frame_rejected of string

type view =
  | Awaiting_first_reading
  | Reading of { reading : reading; trouble : trouble option }
  | Cannot_read of failure

type step =
  | Keep_reading
  | Reconnect

(* [following] is the revision of the last event of this connection, [None]
   until its [Snapshot]. [down_since] is [None] exactly while a connection that
   delivered a [Snapshot] is open. *)
type t =
  { mutable decoder : Sse_wire.decoder
  ; mutable reading : reading option
  ; mutable following : F.Revision.t option
  ; mutable down_since : float option
  ; mutable failure : failure option
  }

let create () =
  { decoder = Sse_wire.create_decoder ()
  ; reading = None
  ; following = None
  ; down_since = None
  ; failure = None
  }
;;

let started t =
  t.decoder <- Sse_wire.create_decoder ();
  t.following <- None
;;

let reject t failure =
  t.failure <- Some failure;
  t.following <- None;
  Reconnect
;;

let refused t ~status ~detail =
  ignore (reject t (Refused { status; detail }) : step)
;;

let lost t ~now =
  match t.down_since with
  | Some _ -> ()
  | None -> t.down_since <- Some now
;;

let take_snapshot t reading =
  t.reading <- Some reading;
  t.following <- Some reading.revision;
  t.down_since <- None;
  t.failure <- None;
  Keep_reading
;;

(* An event that follows the last one extends the reading; any other event is
   a gap, or an event with no [Snapshot] before it. *)
let take_next t revision update =
  match t.following, t.reading with
  | Some last, Some reading when F.Revision.is_next ~after:last revision ->
    t.reading <- Some (update reading);
    t.following <- Some revision;
    Keep_reading
  | Some _, (Some _ | None) | None, (Some _ | None) ->
    t.following <- None;
    Reconnect
;;

let apply t = function
  | F.Snapshot { revision; measured_at; fleet; degraded } ->
    take_snapshot t { revision; measured_at; fleet; degraded }
  | F.Changed { revision; measured_at; fleet } ->
    take_next t revision (fun _ -> { revision; measured_at; fleet; degraded = None })
  | F.Degraded { revision; degradation } ->
    take_next t revision (fun reading ->
      { reading with revision; degraded = Some degradation })
;;

let apply_frame t (frame : Sse_wire.frame) =
  match Yojson.Safe.from_string frame.data with
  | exception Yojson.Json_error detail ->
    reject t (Frame_rejected ("not JSON: " ^ detail))
  | json ->
    (match F.decode json with
     | Ok event -> apply t event
     | Error (F.Schema_mismatch { expected; received }) ->
       reject t (Schema_mismatch { expected; received })
     | Error
         (( F.Not_an_object _ | F.Missing_field _ | F.Unknown_field _
          | F.Duplicate_field _ | F.Wrong_type _ | F.Out_of_range _
          | F.Unknown_word _ | F.Not_canonical _ | F.Unknown_event _ ) as error) ->
       reject t (Frame_rejected (F.decode_error_to_string error)))
;;

let feed t chunk =
  let rec apply_all = function
    | [] -> Keep_reading
    | frame :: later ->
      (match apply_frame t frame with
       | Keep_reading -> apply_all later
       | Reconnect -> Reconnect)
  in
  apply_all (Sse_wire.feed t.decoder chunk)
;;

let view t =
  match t.failure, t.reading with
  | Some failure, (Some _ | None) -> Cannot_read failure
  | None, None -> Awaiting_first_reading
  | None, Some reading ->
    let trouble =
      match t.down_since with
      | Some since -> Some (Disconnected { since })
      | None -> Option.map (fun degradation -> Scans_failing degradation) reading.degraded
    in
    Reading { reading; trouble }
;;
