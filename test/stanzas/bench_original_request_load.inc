; Not a test: prints how late a fiber of the calling domain wakes while
; another fiber of that domain loads retained original requests, with the body
; check on the calling domain or on a domain pool. Run by hand from
; _build/default/test.

(executable
 (name bench_original_request_load)
 (modules bench_original_request_load)
 (libraries masc masc.masc_core eio eio_main yojson unix))
