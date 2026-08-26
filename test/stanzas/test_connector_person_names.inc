(test
 (name test_connector_person_names)
 (modules test_connector_person_names)
 ; [fs_compat], not [masc.fs_compat]: inside this workspace the public name
 ; resolves to the installed package and its modules stay hidden, so the
 ; stanza reads as correct while [Fs_compat] is unbound. Every other stanza
 ; here names the internal library.
 (libraries alcotest masc fs_compat unix))
