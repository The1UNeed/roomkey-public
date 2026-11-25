# roomkey

Private panel for the myroom.asia nodes: users with traffic limits, expiry dates and node access, one subscription link each, nodes that report in by themselves.

## Setup

One command, on your computer (macOS or Linux with Node.js 20+ and git):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/The1UNeed/roomkey-public/main/setup.sh)
```

It downloads roomkey into `~/roomkey`, signs you in to Cloudflare, asks for your two addresses and an admin password, deploys the panel, and prints the install command for your first server: run that as root on a **freshly installed** VPS. From a checkout, `./setup.sh` does the same. Details: [docs/DEPLOY.md](docs/DEPLOY.md).

## Layout

| Folder | From | What it is | License |
|---|---|---|---|
| `panel/` | [jinqians/psm-panel](https://github.com/jinqians/psm-panel) | Web panel on Cloudflare Workers + D1. Users, servers, nodes, per-user subscriptions. | AGPL-3.0 |
| `stack/` | [jinqians/proxy-stack](https://github.com/jinqians/proxy-stack) | PSM: installs and runs the proxy cores (Xray / sing-box / mihomo) on each VPS, plus the agent that talks to the panel. | AGPL-3.0 |
| `3x-ui/` | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | Reference for per-user features: traffic limits, expiry, IP limits, client stats. | GPL-3.0 |

Each folder was imported with `git subtree --squash`, so upstream fixes can still be pulled in.

## Pulling upstream changes

```bash
git subtree pull --prefix=panel https://github.com/jinqians/psm-panel.git main --squash
git subtree pull --prefix=stack https://github.com/jinqians/proxy-stack.git main --squash
git subtree pull --prefix=3x-ui https://github.com/MHSanaei/3x-ui.git main --squash
```

## Rules for this project

- The panel never carries proxy traffic. It only serves the admin page, subscriptions and the node API.
- REALITY's fallback (`dest` / `target`) points at the node's own site, never at a third-party or CDN-hosted domain.
- Don't put "vpn" in hostnames. Use names like `sub.myroom.asia` and `n1.myroom.asia`.

## License

Each folder keeps its upstream license. The panel and stack are AGPL-3.0: anyone who uses a modified version over the network (for example, friends fetching subscriptions) is entitled to its source code.
