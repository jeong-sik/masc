type plan =
  { limit : int
  ; fixed : int
  ; shared_pool : int
  ; execution_codec : int
  }

type error =
  | Override_exceeds_limit of
      { override : int
      ; limit : int
      ; fixed : int
      ; execution_codec : int
      }

(* The codec runtime encodes and decodes execution events. With six workers
   it ran no fiber in a 60 s rtev_fibers window on 2026-10-27 (21:52 KST),
   while its idle domains reached 61% of stop-the-world barriers last. Two
   keep two codec jobs in parallel. *)
let execution_codec_domains = 2

let plan ~recommended ~fixed ~override =
  let limit = Int.max 1 (recommended - 1) in
  let execution_codec =
    if limit - fixed >= execution_codec_domains + 1 then execution_codec_domains else 1
  in
  (* Each pool keeps one worker even on a host too small for the limit, so
     the largest shared pool is never below 1. *)
  let largest_shared_pool = Int.max 1 (limit - fixed - execution_codec) in
  match override with
  | Some override when override > largest_shared_pool ->
    Error (Override_exceeds_limit { override; limit; fixed; execution_codec })
  | Some shared_pool -> Ok { limit; fixed; shared_pool; execution_codec }
  | None -> Ok { limit; fixed; shared_pool = largest_shared_pool; execution_codec }

let total t = t.fixed + t.shared_pool + t.execution_codec
let within_limit t = total t <= t.limit

let error_to_string = function
  | Override_exceeds_limit { override; limit; fixed; execution_codec } ->
    Printf.sprintf
      "MASC_EXECUTOR_DOMAIN_COUNT=%d with %d fixed and %d execution codec domains makes %d, \
       above the limit of %d (Domain.recommended_domain_count () - 1); set it to %d or less"
      override fixed execution_codec (override + fixed + execution_codec) limit
      (Int.max 1 (limit - fixed - execution_codec))
