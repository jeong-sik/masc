type t =
  | Ui
  | Io
  | Worker

(* A minor collection stops every domain, so the process collects each time
   any one domain fills its own heap. On a loaded host each stop also waits
   until every domain is back on a core.

   Ui: every frame allocates the rows it draws. On a live chat with
   PageUp/PageDown held, the 4M-word heap cut the median key-to-output time
   by about a quarter.

   Worker: a refresh of the overview reads the local task files, several
   MB of JSON, so this domain fills a heap far faster than the other two.
   Measured 2026-11-19, when a refresh still decoded every task, against
   the frozen replay: overview at 120x40,
   Down/Up every 33 ms, r every 45 presses, key-to-output of the presses
   within 600 ms of an r, builds interleaved round by round, ms:

     worker heap         load 131-370, 6 rounds   load 295-418, 6 rounds
                         p90    p95    p99        p90    p95    p99
     256k (runtime)      25.7   63.8   124.4      -      -      -
     1M                  8.8    20.6   98.6       16.3   33.6   132.1
     4M                  9.7    19.1   87.7       17.0   32.8   85.2
     every domain 4M     9.2    17.8   62.7       18.5   33.3   87.4

   The last row is every domain on 4M words, Io included; the other rows
   keep Io on the runtime's heap. A 1M worker also kept p99 about 1.5
   times the last row's in 8 more rounds at load 283-418.

   The worker's heap is also the memory a smaller one saves. Physical
   footprint after 5 minutes idle at 200x60, eight to ten TUIs at once,
   two runs per build on the overview and two on Keepers: 4M 223-243 MB,
   every domain 4M 220-236 MB, 1M 173-200 MB, 256k 171-210 MB. The tail
   decides.

   Measured again 2026-11-20, after a refresh decodes only the tasks whose
   bytes changed (#53618): same replay and keys, the task file renamed
   over itself before each r, 6 interleaved rounds at load 131-421, ms:

     worker heap         p90    p95    p99
     256k (runtime)      7.6    13.0   47.3
     4M                  6.6    10.0   24.6

   256k was worse in 4 of the 6 rounds (median p99 +8.6). Resident size at
   the end of each run: 4M 287-294 MB, 256k 234-248 MB. The worker stays on
   4M.

   Io: it sends requests and reads answers, and leaves decoding to the
   worker. Its heap changed neither figure beyond the spread between
   rounds: compare the 4M row with the last. *)
let minor_heap = function
  | Ui -> Minor_heap.Tuned
  | Io -> Minor_heap.Runtime_default
  | Worker -> Minor_heap.Tuned
;;

let use_ui_heap () = Minor_heap.apply (minor_heap Ui)

(* One worker keeps answer decoding and local reads off the UI domain; HTTP
   requests have their own domain. The server's core-sized default would add
   idle domains to every stop-the-world collection, and the client has no
   Keeper actors to spread over them. *)
let start_worker_pool ~sw domain_mgr =
  Domain_pool.create ~sw ~domain_count:1 (Minor_heap.domain_mgr (minor_heap Worker) domain_mgr)
;;
