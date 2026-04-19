open! Core
open! Bonsai_web

let () =
  Start.start ~bind_to_element_with_id:"app" Dashboard_bonsai_lib.App.root;
  Dashboard_bonsai_lib.Logs_fetch.run ();
  Dashboard_bonsai_lib.Logs_fetch.start_polling ()
;;
