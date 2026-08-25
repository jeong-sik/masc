(** See [request_wire_observer.mli]. *)

type phase = Pre_dispatch_serialization [@@deriving yojson, show]

type observation =
  { phase : phase
  ; capture_id : string option
  ; provider : string
  ; model : string
  ; http_codec : string
  ; stream : bool
  ; body_bytes : int
  ; body_sha256 : string
  }
[@@deriving yojson, show]

type rejection = { reason : string } [@@deriving yojson, show]
type try_observe = observation -> (unit, rejection) result

type failure_cause =
  | Observer_rejected of rejection
  | Observer_raised of
      { message : string
      ; backtrace : string
      }
[@@deriving yojson, show]

type failure =
  { observation : observation
  ; cause : failure_cause
  }
[@@deriving yojson, show]

let body_sha256 body = Digestif.SHA256.(to_hex (digest_string body))

let observation ~capture_id ~provider ~model ~http_codec ~stream ~body =
  { phase = Pre_dispatch_serialization
  ; capture_id
  ; provider
  ; model
  ; http_codec
  ; stream
  ; body_bytes = String.length body
  ; body_sha256 = body_sha256 body
  }
;;

let observe try_observe observation =
  match try_observe observation with
  | Ok () -> Ok ()
  | Error rejection -> Error { observation; cause = Observer_rejected rejection }
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Reserved_exn.reraise_if_reserved exn;
    Error
      { observation
      ; cause =
          Observer_raised
            { message = Printexc.to_string exn
            ; backtrace = Printexc.raw_backtrace_to_string backtrace
            }
      }
;;

let%test "observation measures the exact serialized body" =
  let body = {|{"model":"m","messages":[]}|} in
  let actual =
    observation
      ~capture_id:(Some "request-1")
      ~provider:"openai"
      ~model:"m"
      ~http_codec:"openai_chat"
      ~stream:false
      ~body
  in
  actual.body_bytes = String.length body
  && String.equal actual.body_sha256 (body_sha256 body)
;;

let%test "observer rejection remains typed" =
  let observed =
    observation
      ~capture_id:None
      ~provider:"ollama"
      ~model:"m"
      ~http_codec:"ollama_chat"
      ~stream:true
      ~body:"{}"
  in
  match observe (fun _ -> Error { reason = "queue full" }) observed with
  | Error { observation = actual; cause = Observer_rejected { reason = "queue full" } } ->
    actual = observed
  | Ok () | Error _ -> false
;;

let%test "ordinary observer exception becomes typed evidence" =
  let observed =
    observation
      ~capture_id:None
      ~provider:"openai"
      ~model:"m"
      ~http_codec:"openai_chat"
      ~stream:false
      ~body:"{}"
  in
  match observe (fun _ -> failwith "observer unavailable") observed with
  | Error { cause = Observer_raised { message; _ }; _ } ->
    String.equal message "Failure(\"observer unavailable\")"
  | Ok () | Error _ -> false
;;

let%test "reserved observer exception propagates" =
  let observed =
    observation
      ~capture_id:None
      ~provider:"openai"
      ~model:"m"
      ~http_codec:"openai_chat"
      ~stream:false
      ~body:"{}"
  in
  match observe (fun _ -> raise Sys.Break) observed with
  | exception Sys.Break -> true
  | Ok () | Error _ -> false
;;
