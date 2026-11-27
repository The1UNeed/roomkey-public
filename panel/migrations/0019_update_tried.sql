-- Updates (worker/src/updates.ts): the version a server was last asked to
-- upgrade to by the update window ("<psm-agent>/<PSM>"), so each version is
-- asked for once, not every five minutes while it installs.
ALTER TABLE servers ADD COLUMN update_tried TEXT;
