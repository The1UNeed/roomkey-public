-- roomkey, third step (on top of 0017).

-- roomkey runs no relays (a public forward hands whatever is behind it to
-- anyone). psm guard takes every relay rule off a server when it joins or
-- upgrades, and the panel hands a psm-agent older than roomkey's nothing but
-- its upgrade, so the panel keeps no relay of its own.
DELETE FROM tasks WHERE kind IN ('relay.add', 'relay.update', 'relay.delete');
DELETE FROM relay_samples;
DELETE FROM relays;

-- whether the node on its server is the panel's: set once psm-agent confirms
-- it created it. Only an owned node is changed in place, metered, given to
-- users or removed from its server; a first create that met a node of the
-- same name made by hand (a conflict) leaves that one alone for good. Nodes
-- from before roomkey that reached their server are the panel's.
ALTER TABLE nodes ADD COLUMN owned INTEGER NOT NULL DEFAULT 0;
UPDATE nodes SET owned = 1 WHERE status IN ('applied', 'deleting') OR link_enc IS NOT NULL;
