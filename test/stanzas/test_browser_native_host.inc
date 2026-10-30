(rule
 (alias runtest-test_browser_native_host)
 (deps test_browser_native_host.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_native_host.py} %{dep:../bin/masc_browser_host.exe})))

(rule
 (alias runtest-test_browser_bidi_host_link)
 (deps test_browser_bidi_host_link.py ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_bidi_host_link.py} %{dep:../bin/masc_browser_host.exe})))

; Focused destination coverage in both host modes, without the long lifecycle suite.
(rule
 (alias runtest-test_browser_host_public_origin)
 (deps test_browser_native_host.py test_browser_bidi_host_link.py ../bin/masc_browser_host.exe)
 (action
  (progn
   (run python3 %{dep:test_browser_native_host.py} %{dep:../bin/masc_browser_host.exe}
    NativeHost.test_public_base_url_does_not_override_workspace
    NativeHost.test_loopback_base_url_does_not_override_workspace
    NativeHost.test_server_argument_takes_precedence
    NativeHost.test_failed_poll_reads_the_workspace_port_again
    NativeHost.test_an_exported_port_is_never_followed
    NativeHost.test_unsupported_verb_is_not_forwarded
    NativeHost.test_tabs_and_page_roundtrip_fragmented_utf8
    Destination.test_remote_and_credentialed_origins_rejected
    Destination.test_malformed_workspace_port_is_an_error_not_a_default
    Destination.test_invalid_environment_port_is_an_error_not_a_default
    Destination.test_non_loopback_workspace_host_identifies_the_source)
   (run python3 %{dep:test_browser_bidi_host_link.py} %{dep:../bin/masc_browser_host.exe}
    BidiHostLink.test_inherited_public_base_url_does_not_block_bidi_link
    BidiHostLink.test_a_server_restarted_on_another_port_is_followed
    BidiHostLink.test_a_stop_while_the_session_is_being_asked_for_ends_that_session))))

; The command as the install script and the docs run it: the real executable.
(rule
 (alias runtest-test_browser_lane_setup_cli)
 (deps test_browser_lane_setup_cli.py ../bin/main_eio.exe ../bin/masc_browser_host.exe)
 (action (run python3 %{dep:test_browser_lane_setup_cli.py} %{dep:../bin/main_eio.exe}
          %{dep:../bin/masc_browser_host.exe})))

(alias
 (name runtest)
 (deps
  (alias runtest-test_browser_native_host)
  (alias runtest-test_browser_bidi_host_link)
  (alias runtest-test_browser_lane_setup_cli)))
