type upgrade = Gluten.impl -> unit

type acceptance = Transport_metrics.response_write_acceptance =
  | Accepted_by_writer
  | Rejected_by_writer

(* One constructor per transport that carries requests. RFC-0512 S3 adds
   [Http2]; every function below gains one arm then. *)
type t =
  | Http1 of
      { reqd : Httpun.Reqd.t
      ; upgrade : upgrade option
      }

let of_gluten (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) =
  Http1
    { reqd = gluten_reqd.Gluten.Reqd.reqd
    ; upgrade = Some gluten_reqd.Gluten.Reqd.upgrade
    }
;;

let of_httpun reqd = Http1 { reqd; upgrade = None }
let request (Http1 { reqd; _ }) = Httpun.Reqd.request reqd
let upgrade (Http1 { upgrade; _ }) = upgrade

(* The [Failure] payloads are the only way httpun and its Faraday writer
   report these two states, so matching their text (warning 52) is the
   dependency, kept in this one place. If a library version rewords them, a
   late write logs at warn instead of debug; nothing else changes. *)
[@@@warning "-52"]

module Late_response = struct
  let classify_write_failure = function
    | Failure msg
      when String.starts_with msg ~prefix:"httpun.Reqd.respond_with_string: invalid state" ->
      Some msg
    | Failure msg when String.equal msg "cannot write to closed writer" ->
      Some "cannot write to closed writer"
    | _ -> None
  ;;
end

[@@@warning "+52"]

let log_rejected_write exn =
  match Late_response.classify_write_failure exn with
  | Some msg ->
    Log.Http.debug "[http] response skipped, the request can no longer take one: %s" msg
  | None ->
    let backtrace = Printexc.get_backtrace () in
    let summary = Printexc.to_string exn in
    if String.trim backtrace = ""
    then Log.Http.warn "[http] response failed: %s" summary
    else Log.Http.warn "[http] response failed: %s\n%s" summary backtrace
;;

let try_respond_with_string (Http1 { reqd; _ }) response body =
  Cancel_safe.protect
    ~on_exn:(fun exn ->
      log_rejected_write exn;
      Rejected_by_writer)
    (fun () ->
       Httpun.Reqd.respond_with_string reqd response body;
       Accepted_by_writer)
;;

let respond_with_string t response body =
  match try_respond_with_string t response body with
  | Accepted_by_writer | Rejected_by_writer -> ()
;;

module Body_writer = struct
  type t = H1 of Httpun.Body.Writer.t

  let write_string (H1 writer) s = Httpun.Body.Writer.write_string writer s
  let flush (H1 writer) f = Httpun.Body.Writer.flush writer f
  let close (H1 writer) = Httpun.Body.Writer.close writer
  let is_closed (H1 writer) = Httpun.Body.Writer.is_closed writer
end

let respond_with_streaming ?flush_headers_immediately (Http1 { reqd; _ }) response =
  Body_writer.H1 (Httpun.Reqd.respond_with_streaming ?flush_headers_immediately reqd response)
;;

module Body_reader = struct
  type t = H1 of Httpun.Body.Reader.t

  let schedule_read (H1 reader) ~on_eof ~on_read =
    Httpun.Body.Reader.schedule_read reader ~on_eof ~on_read
  ;;

  let close (H1 reader) = Httpun.Body.Reader.close reader
end

let request_body (Http1 { reqd; _ }) = Body_reader.H1 (Httpun.Reqd.request_body reqd)

let respond_with_upgrade (Http1 { reqd; _ }) headers k =
  Httpun.Reqd.respond_with_upgrade reqd headers k
;;
