-- roomkey: users, with quotas in total and per server, expiry, device limits
-- and their own subscriptions; node hostnames kept on the server's address;
-- alerts. See worker/src/users.ts and worker/src/roomkey.ts.

-- roomkey starts from an empty D1: on a psm-panel database (servers already
-- enrolled with upstream psm-agents) this fails, and the migration with it,
-- by `wrangler d1 migrations apply` as well as the panel's own runner.
CREATE TABLE IF NOT EXISTS roomkey_fresh (servers_before INTEGER NOT NULL CHECK (servers_before = 0));
INSERT INTO roomkey_fresh SELECT COUNT(*) FROM servers;

CREATE TABLE IF NOT EXISTS users (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL UNIQUE,              -- psm user name: a-z0-9_-, up to 32
    note              TEXT NOT NULL DEFAULT '',
    uuid_enc          TEXT NOT NULL,                     -- AES-GCM, like nodes.params_enc
    password_enc      TEXT NOT NULL,
    enabled           INTEGER NOT NULL DEFAULT 1,
    expires_at        TEXT,                              -- UTC; NULL = never (or not started, see first_use_days)
    first_use_days    INTEGER,                           -- set: the term starts at the first traffic
    first_used_at     TEXT,
    quota_total_bytes INTEGER,                           -- NULL = no total limit
    reset_period      TEXT NOT NULL DEFAULT 'monthly',   -- daily | weekly | monthly | never
    reset_day         INTEGER NOT NULL DEFAULT 1,        -- weekly: 1-7 (Monday = 1); monthly: 1-28
    period_start      TEXT,                              -- the period the counts belong to (YYYY-MM-DD)
    period_seq        INTEGER NOT NULL DEFAULT 0,        -- bumped by "reset usage": servers start their counts over too
    used_total_bytes  INTEGER NOT NULL DEFAULT 0,        -- this period, every server
    device_limit      INTEGER NOT NULL DEFAULT 0,        -- client IPs at once; 0 = no limit
    unmetered         INTEGER NOT NULL DEFAULT 0,        -- with a quota, may still use nodes not counted per user
    blocked_until     TEXT,                              -- paused for too many devices until then
    blocked_reason    TEXT,
    alerted_state     TEXT NOT NULL DEFAULT 'active',    -- the state last sent to Telegram
    sub_token_hash    TEXT NOT NULL UNIQUE,
    sub_token_enc     TEXT NOT NULL,
    last_sub_at       TEXT,
    created_at        TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Which nodes a user gets: every one, those with a label, or one node.
CREATE TABLE IF NOT EXISTS user_access (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind    TEXT NOT NULL,                               -- all | label | node
    value   TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (user_id, kind, value)
);

-- A user on one server: an optional quota there, this period's use, and the
-- last reading of the server's counter for them (which only grows).
CREATE TABLE IF NOT EXISTS user_servers (
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    server_id    INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    quota_bytes  INTEGER,                                -- NULL = only the total applies
    used_bytes   INTEGER NOT NULL DEFAULT 0,
    last_counter INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, server_id)
);

CREATE TABLE IF NOT EXISTS user_traffic_daily (
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    server_id INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    day       TEXT NOT NULL,
    bytes     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, server_id, day)
);

-- Each user's client IPs on each server, as last reported.
CREATE TABLE IF NOT EXISTS user_online (
    user_id   INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    server_id INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    ips       TEXT NOT NULL DEFAULT '[]',
    at        TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (user_id, server_id)
);

-- A host name kept on the server's IPv4 address (Cloudflare DNS, not proxied):
-- nodes use it as their address, so a new IP needs no new links.
ALTER TABLE servers ADD COLUMN dns_name TEXT;
ALTER TABLE servers ADD COLUMN dns_ip TEXT;
ALTER TABLE servers ADD COLUMN dns_at TEXT;
ALTER TABLE servers ADD COLUMN dns_error TEXT;
-- what the server's users are (the last user.sync), so a change can be told
ALTER TABLE servers ADD COLUMN users_hash TEXT;
ALTER TABLE servers ADD COLUMN users_error TEXT;
-- offline alerts: 1 once the server was reported offline
ALTER TABLE servers ADD COLUMN alert_offline INTEGER NOT NULL DEFAULT 0;
