# Explicit Librarian owner mixed-walk check

[Selected run39879335145](https://github.com/jeong-sik/masc/actions/runs/39879335145)
compiled all seven selected executables on exact `2c9ce3323a0eed8457fd3b4ed0ace93f786fda6e`.
The seven suites ran166 cases:165 passed, one failed. The owner suite passed21/22;
the complete-input codec and five other suites passed. The receipt lists the
actual seven TARGET_SUITES, including Curator commit. This was not full regression.

The failure was an assertion treating `refuses_input_capacity` as permission to
partition. That helper records named-capacity evidence after the invalid-output
veto. The actual `Keeper_librarian_admission_parts.check_size` also checks
`not size_independent_execution_failure` before permitting partition. Runtime
reports capacity evidence and the independent-failure veto separately. Changing
the shared observation merely to satisfy this assertion would change other
consumers' semantics. The fixture must distinguish observation from permission
and reach its existing actual worker/no-child/no-ACK/no-Memory checks.

The excerpt retains the actual expected-false/received-true failure. The JSON
receipt hashes the complete original failed-job log, not this excerpt. Repairs
and any later execution receipts are separate evidence. These results do not
establish external-provider, Docker, visible UI, installed-runtime or E03 success.
