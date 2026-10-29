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
  | Unreachable of { since : float }
  | Reading of { reading : reading; trouble : trouble option }
  | Unavailable of { degradation : F.degradation; disconnected_since : float option }
  | Cannot_read of failure

type step =
  | Keep_reading
  | Reconnect

(* [following] is the revision of the last event of this connection, [None]
   until its [Snapshot]. [down_since] is the time of the first loss since the
   last state arrived (a [Snapshot] or an [Unavailable_snapshot]), and [None]
   before any loss and once a state arrived after it. *)
type t =
  { mutable decoder : Sse_wire.decoder
  ; mutable reading : reading option
  ; mutable unavailable : F.degradation option
  ; mutable following : F.Revision.t option
  ; mutable down_since : float option
  ; mutable failure : failure option
  }

let create () =
  { decoder = Sse_wire.create_decoder ()
  ; reading = None
  ; unavailable = None
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
  t.unavailable <- None;
  t.following <- Some reading.revision;
  t.down_since <- None;
  t.failure <- None;
  Keep_reading
;;

let take_unavailable_snapshot t revision degradation =
  t.reading <- None;
  t.unavailable <- Some degradation;
  t.following <- Some revision;
  t.down_since <- None;
  t.failure <- None;
  Keep_reading
;;

(* A cursor can exist without a reading after an unavailable snapshot. A
   Changed event then supplies the first reading; a Degraded event without a
   reading violates the producer's lifecycle and requires a new snapshot. *)
let take_next t revision update =
  match t.following with
  | Some last when F.Revision.is_next ~after:last revision && update () ->
    t.following <- Some revision;
    Keep_reading
  | Some _ | None ->
    t.following <- None;
    Reconnect
;;

let apply t = function
  | F.Snapshot { revision; measured_at; fleet; degraded } ->
    take_snapshot t { revision; measured_at; fleet; degraded }
  | F.Unavailable_snapshot { revision; degradation } ->
    take_unavailable_snapshot t revision degradation
  | F.Changed { revision; measured_at; fleet } ->
    take_next t revision (fun () ->
      t.reading <- Some { revision; measured_at; fleet; degraded = None };
      t.unavailable <- None;
      true)
  | F.Degraded { revision; degradation } ->
    take_next t revision (fun () ->
      match t.reading with
      | None -> false
      | Some reading ->
        t.reading <- Some { reading with revision; degraded = Some degradation };
        true)
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
  match t.failure, t.reading, t.unavailable with
  | Some failure, (Some _ | None), (Some _ | None) -> Cannot_read failure
  | None, None, None ->
    (match t.down_since with
     | None -> Awaiting_first_reading
     | Some since -> Unreachable { since })
  | None, None, Some degradation ->
    Unavailable { degradation; disconnected_since = t.down_since }
  | None, Some reading, (Some _ | None) ->
    let trouble =
      match t.down_since with
      | Some since -> Some (Disconnected { since })
      | None -> Option.map (fun degradation -> Scans_failing degradation) reading.degraded
    in
    Reading { reading; trouble }
;;
