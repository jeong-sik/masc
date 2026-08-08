(** See [wire_observer.mli]. *)

type observation =
  { capture_id : string option
  ; provider : string
  ; model : string
  ; redacted_chunk : string
  }
[@@deriving yojson, show]

type rejection = { reason : string } [@@deriving yojson, show]
type try_observe = observation -> (unit, rejection) result
type observe_chunk = provider:string -> model:string -> chunk:string -> unit

type failure_cause =
  | Observer_rejected of rejection
  | Observer_raised of
      { message : string
      ; backtrace : string
      }
[@@deriving yojson, show]

type failure =
  { capture_id : string option
  ; provider : string
  ; model : string
  ; cause : failure_cause
  }
[@@deriving yojson, show]

let observe try_observe ~capture_id ~provider ~model ~chunk =
  let observation =
    { capture_id; provider; model; redacted_chunk = Secret_redactor.redact_string chunk }
  in
  match try_observe observation with
  | Ok () -> Ok ()
  | Error rejection ->
    Error { capture_id; provider; model; cause = Observer_rejected rejection }
  | exception exn ->
    let backtrace = Printexc.get_raw_backtrace () in
    Reserved_exn.reraise_if_reserved exn;
    Error
      { capture_id
      ; provider
      ; model
      ; cause =
          Observer_raised
            { message = Printexc.to_string exn
            ; backtrace = Printexc.raw_backtrace_to_string backtrace
            }
      }
;;

let%test "observer receives one redacted observation with exact metadata" =
  let authorization = "Authorization: Bearer opaque-token" in
  let observed = ref None in
  let result =
    observe
      (fun observation ->
         observed := Some observation;
         Ok ())
      ~capture_id:(Some "request-1")
      ~provider:"openai"
      ~model:"exact-model"
      ~chunk:("prefix " ^ authorization ^ " suffix")
  in
  result = Ok ()
  &&
  match !observed with
  | Some
      { capture_id = Some "request-1"
      ; provider = "openai"
      ; model = "exact-model"
      ; redacted_chunk = "prefix Authorization: Bearer [REDACTED] suffix"
      } -> true
  | Some _ | None -> false
;;

let%test "caller rejection remains exact typed evidence" =
  let rejection = { reason = "caller queue unavailable" } in
  match
    observe
      (fun _ -> Error rejection)
      ~capture_id:None
      ~provider:"anthropic"
      ~model:"exact-model"
      ~chunk:"chunk"
  with
  | Error
      { capture_id = None
      ; provider = "anthropic"
      ; model = "exact-model"
      ; cause = Observer_rejected actual
      } -> actual = rejection
  | Ok () | Error _ -> false
;;

let%test "ordinary observer exception becomes typed evidence" =
  match
    observe
      (fun _ -> failwith "observer unavailable")
      ~capture_id:(Some "request-2")
      ~provider:"ollama"
      ~model:"exact-model"
      ~chunk:"chunk"
  with
  | Error { cause = Observer_raised { message; _ }; _ } ->
    String.equal message "Failure(\"observer unavailable\")"
  | Ok () | Error _ -> false
;;

let%test "reserved observer exception preserves propagation" =
  match
    observe
      (fun _ -> raise Sys.Break)
      ~capture_id:None
      ~provider:"openai"
      ~model:"exact-model"
      ~chunk:"chunk"
  with
  | exception Sys.Break -> true
  | Ok () | Error _ -> false
;;
