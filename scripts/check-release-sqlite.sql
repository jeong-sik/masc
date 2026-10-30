.bail on
-- The Owner store has STRICT REAL timestamps and a terminal BEFORE UPDATE
-- trigger. SQLite 3.37.2 rejects integral REAL transitions in this shape.
CREATE TABLE operations (state TEXT NOT NULL, started_at REAL) STRICT;
CREATE TRIGGER terminal_immutable BEFORE UPDATE ON operations
WHEN OLD.state IN ('succeeded', 'failed', 'cancelled')
BEGIN SELECT RAISE(ABORT, 'terminal operation is immutable'); END;
INSERT INTO operations VALUES ('queued', NULL);
UPDATE operations SET state = 'running', started_at = 42.0 WHERE state = 'queued';
SELECT state = 'running' AND started_at = 42.0 AND typeof(started_at) = 'real' FROM operations;
UPDATE operations SET state = 'queued', started_at = NULL;
UPDATE operations SET state = 'running', started_at = 42.25 WHERE state = 'queued';
SELECT state = 'running' AND started_at = 42.25 AND typeof(started_at) = 'real' FROM operations;
CREATE VIRTUAL TABLE fulltext USING fts5(content);
CREATE VIRTUAL TABLE spatial USING rtree(id, min_x, max_x);
