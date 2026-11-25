# migrate.sh — English
MSG[migrate.usage]="Usage:
  psm migrate export [--output FILE] [--no-encrypt] Bundle this server for safekeeping: nodes, keys, certificates, Nginx, acme.sh (encrypted with a passphrase unless --no-encrypt)
  (import and push are off: a server moves through the panel, where the new server is added and its nodes recreated)"
MSG[migrate.nothing]="PSM has no configuration on this server; nothing to export."
MSG[migrate.exporting]="Collecting nodes, keys, certificates and service configs…"
MSG[migrate.pack_failed]="Could not write the bundle."
MSG[migrate.exported]="Bundle written: %s (%s, %s node(s))."
MSG[migrate.secret_warn]="It holds every private key and password of this server: keep it somewhere only you can read, and copy it over SSH only."
MSG[migrate.next_steps]="Bundle kept at %s. To move this server, add the new one in the panel and recreate its nodes there."
MSG[migrate.need_pass]="The passphrase is needed: set PSM_MIGRATE_PASS or run this in a terminal (--no-encrypt for a bundle without one)."
MSG[migrate.ask_pass]="Bundle passphrase:"
MSG[migrate.ask_pass2]="Repeat the passphrase:"
MSG[migrate.pass_mismatch]="The passphrase is empty or the two entries differ."
MSG[migrate.menu.export]="Export a bundle of this server (to keep)"
MSG[migrate.ask_encrypt]="The bundle holds every private key and password here. Encrypt it with a passphrase?"
