type plan =
  { limit : int
  ; fixed : int
  ; shared_pool : int
  ; read_pool : int
  ; execution_codec : int
  }

type error =
  | Override_exceeds_limit of
      { override : int
      ; limit : int
      ; fixed : int
      ; read_pool : int
      ; execution_codec : int
      }

(* The codec runtime encodes and decodes execution events. With six workers
   it ran no fiber in a 60 s rtev_fibers window on 2026-10-27 (21:52 KST),
   while its idle domains reached 61% of stop-the-world barriers last. Two
   keep two codec jobs in parallel. *)
let execution_codec_domains = 2

(* HTTP reads (RFC-0204 L3). On the live server, 2026-10-27 14:16-14:18Z with
   a shared pool of 6 and load 15-21, 173 read jobs ran in 120 s at 73.8 ms
   mean, so reads keep about 0.11 workers busy. As an M/M/c queue that makes
   about 11% of reads wait with one worker and about 0.5% with two. Read run
   times have a long tail (p99 in the 2-5 s bucket), so these are estimates. *)
let read_pool_domains = 2

(* In the same window background work ran 3,007 jobs at 64.8 ms mean, about
   1.6 busy workers against the reads' 0.11. So the shared pool keeps two
   workers before the codec runtime or the read pool takes a second one. *)
let shared_pool_kept_first = 2

let plan ~recommended ~fixed ~override =
  let limit = Int.max 1 (recommended - 1) in
  let room = limit - fixed in
  (* Short of room, the codec runtime gives up its second domain first, then
     the read pool, then the shared pool its second; each pool keeps one
     worker even on a host too small for the limit, so the largest shared
     pool is never below 1. *)
  let execution_codec =
    if room >= shared_pool_kept_first + read_pool_domains + execution_codec_domains
    then execution_codec_domains
    else 1
  in
  let read_pool =
    if room >= shared_pool_kept_first + read_pool_domains + execution_codec
    then read_pool_domains
    else 1
  in
  let largest_shared_pool = Int.max 1 (room - execution_codec - read_pool) in
  match override with
  | Some override when override > largest_shared_pool ->
    Error (Override_exceeds_limit { override; limit; fixed; read_pool; execution_codec })
  | Some shared_pool -> Ok { limit; fixed; shared_pool; read_pool; execution_codec }
  | None ->
    Ok { limit; fixed; shared_pool = largest_shared_pool; read_pool; execution_codec }

let total t = t.fixed + t.shared_pool + t.read_pool + t.execution_codec
let within_limit t = total t <= t.limit

let error_to_string = function
  | Override_exceeds_limit { override; limit; fixed; read_pool; execution_codec } ->
    Printf.sprintf
      "MASC_EXECUTOR_DOMAIN_COUNT=%d with %d fixed, %d read pool and %d execution codec \
       domains makes %d, above the limit of %d (Domain.recommended_domain_count () - 1); \
       set it to %d or less"
      override fixed read_pool execution_codec
      (override + fixed + read_pool + execution_codec)
      limit
      (Int.max 1 (limit - fixed - read_pool - execution_codec))
