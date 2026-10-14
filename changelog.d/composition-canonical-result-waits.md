### Added

- Read an accepted named async Composition through `keeper_composition_result`, retaining its original source, full result artifact and failure diagnostics. Prepared async parents persist tagged result dependencies and resume their original read occurrences without starting the child again.
