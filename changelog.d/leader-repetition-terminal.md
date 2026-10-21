### Fixed

- Treat host-detected tool and assistant repetition as a typed invocation failure instead of automatically resuming the same checkpoint. Preserve the original conversation and completed-effect evidence while allowing later requests to run.
