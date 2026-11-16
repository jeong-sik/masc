(test
 (name test_keeper_librarian_worker_request)
 (modules test_keeper_librarian_worker_request)
 (deps (source_tree ../addons/keeper-librarian) ../addons/protocol.py ../addons/exact_worker.py)
 (libraries masc.fs_compat masc masc_process mcp_protocol eio eio_main alcotest yojson unix))
