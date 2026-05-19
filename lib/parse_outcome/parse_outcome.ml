(* Parse_outcome — see .mli for design contract. RFC-0145. *)

type error =
  [ `Json_parse_error of string
  | `Other of exn ]

type 'a t = ('a, error) result

let of_exn (exn : exn) : error =
  (* Classify without a Yojson link dependency. Yojson.Json_error carries
     a single string payload; we recover it via Printexc when available. *)
  let slot = Printexc.exn_slot_name exn in
  if String.equal slot "Yojson.Json_error" then
    (* Best-effort message extraction: Printexc.to_string formats as
       "Yojson.Json_error(\"...\")". We keep the full printable form
       rather than trying to substring-parse; downstream callers should
       treat the string as opaque diagnostic text. *)
    `Json_parse_error (Printexc.to_string exn)
  else
    `Other exn

let parse_safe (f : string -> 'a) (s : string) : 'a t =
  try Ok (f s)
  with
  | Eio.Cancel.Cancelled _ as e ->
      (* RFC-0145 §Design — cancellation MUST re-raise per Eio rules.
         Anti-goal: do not classify Cancelled as a parse failure. *)
      raise e
  | exn -> Error (of_exn exn)

let bind (o : 'a t) (f : 'a -> 'b t) : 'b t =
  match o with
  | Ok x -> f x
  | Error _ as e -> e

let map (f : 'a -> 'b) (o : 'a t) : 'b t =
  match o with
  | Ok x -> Ok (f x)
  | Error _ as e -> e

let to_option (o : 'a t) : 'a option =
  match o with
  | Ok x -> Some x
  | Error _ -> None
