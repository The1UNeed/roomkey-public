-- roomkey, second step (on top of 0016, whether or not a server ever synced):
-- which users and nodes each server has taken, user list revisions, counter
-- generations, a pause made on a server, and the local page's events.

-- bumped when a user's UUID / password change: a server has the user only
-- once it took these credentials
ALTER TABLE users ADD COLUMN cred_rev INTEGER NOT NULL DEFAULT 0;

-- per user and server: the counter generation (newer sorts after older), the
-- credentials revision and the nodes the server took for the user (JSON
-- array of node names; NULL: it has not, or no longer), the usage banked
-- from an earlier counter generation within this period, and whether the
-- server's local page paused the user there
ALTER TABLE user_servers ADD COLUMN counter_epoch TEXT;
ALTER TABLE user_servers ADD COLUMN synced_cred_rev INTEGER;
ALTER TABLE user_servers ADD COLUMN synced_nodes TEXT;
ALTER TABLE user_servers ADD COLUMN period_base INTEGER NOT NULL DEFAULT 0;
ALTER TABLE user_servers ADD COLUMN local_paused INTEGER NOT NULL DEFAULT 0;
-- the counter generation this period's use belongs to (period_base banks the ones before)
ALTER TABLE user_servers ADD COLUMN used_epoch TEXT;
-- whether the server, when it took the user, was told to let them in
ALTER TABLE user_servers ADD COLUMN synced_enabled INTEGER NOT NULL DEFAULT 0;

-- the user list: the last revision queued, the one the server confirmed, and
-- when a list that failed may be sent again
ALTER TABLE servers ADD COLUMN users_rev INTEGER NOT NULL DEFAULT 0;
ALTER TABLE servers ADD COLUMN users_acked_rev INTEGER NOT NULL DEFAULT 0;
ALTER TABLE servers ADD COLUMN users_retry_at TEXT;
-- the list that failed: only another try at that same list waits
ALTER TABLE servers ADD COLUMN users_failed_hash TEXT;

-- the local page's events already recorded: one delivered again (a lost
-- answer) changes nothing twice
CREATE TABLE IF NOT EXISTS agent_events (
    server_id INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    event_id  TEXT NOT NULL,
    at        TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (server_id, event_id)
);

-- this period's use on servers that have since left the panel: it still
-- counts toward a total quota until the period ends
ALTER TABLE users ADD COLUMN period_retired_bytes INTEGER NOT NULL DEFAULT 0;
-- an event whose effects have committed (0: claimed, under way or interrupted)
ALTER TABLE agent_events ADD COLUMN done INTEGER NOT NULL DEFAULT 0;
