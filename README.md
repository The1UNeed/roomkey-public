# roomkey

Private panel for the myroom.asia nodes: users with traffic limits, expiry dates and node access, one subscription link each, nodes that report in by themselves.

## Setup

One command, on your computer or a Linux server (it installs what it needs: git, curl, Node.js 22):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/The1UNeed/roomkey-public/main/setup.sh)
```

It asks what you want:

1. **A new panel.** It signs you in to Cloudflare, asks for your two addresses, makes an admin username and a strong password for you (or takes yours), deploys the panel, and gives you the install command for your first server. It can install that server right there, too.
2. **Connect this server to a panel you already have** (`--join`). It signs in to your panel, adds this server and installs it.

Every question shows a suggestion in [brackets]: press Enter to take it. The panel can also keep itself and every server up to date: in 系统设置 → 更新, pick an update window and turn on automatic updates. New releases are installed then, the panel first. A server must be **freshly installed**: roomkey refuses one that already runs other proxies or nginx, and changes nothing there. From a checkout, `./setup.sh` does the same. Details: [docs/DEPLOY.md](docs/DEPLOY.md).

## Layout

roomkey is its own panel, built on the projects below (credits and licenses in [NOTICE](NOTICE)):

| Folder | What it is | Built on | License |
|---|---|---|---|
| `panel/` | The panel on Cloudflare Workers + D1: users, servers, nodes, per-user subscriptions. | [jinqians/psm-panel](https://github.com/jinqians/psm-panel) | AGPL-3.0 |
| `stack/` | PSM: installs and runs the proxy cores (Xray / sing-box / mihomo) on each VPS, plus the agent that talks to the panel. | [jinqians/proxy-stack](https://github.com/jinqians/proxy-stack) | AGPL-3.0 |
| `3x-ui/` | Reference for per-user features: traffic limits, expiry, IP limits, client stats. | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui) | GPL-3.0 |

`panel/` and `stack/` were imported with `git subtree --squash`, so upstream fixes can still be pulled in.

## Pulling upstream changes

```bash
git subtree pull --prefix=panel https://github.com/jinqians/psm-panel.git main --squash
git subtree pull --prefix=stack https://github.com/jinqians/proxy-stack.git main --squash
git subtree pull --prefix=3x-ui https://github.com/MHSanaei/3x-ui.git main --squash
```

## Rules for this project

- The panel never carries proxy traffic. It only serves the admin page, subscriptions and the node API.
- REALITY's fallback (`dest` / `target`) points at the node's own site by default. Borrowing another site (www.samsung.com, say) is an explicit per-node choice: you tick that you accept the risk, the target is one domain on port 443 that is also the node's SNI, and a target on a shared CDN (Cloudflare, for example) gets a fallback speed limit and a warning. Every other off-server fallback is still refused when the core starts.
- Don't put "vpn" in hostnames. Use names like `sub.myroom.asia` and `n1.myroom.asia`.

## License

roomkey is licensed under the [GNU AGPL-3.0](LICENSE), the license of the projects it is built on. [NOTICE](NOTICE) credits them. `3x-ui/` keeps its own GPL-3.0. Under the AGPL, anyone who runs a changed roomkey for other people (for example, friends fetching subscriptions) must offer them that version's source; the footer of every panel page links to it.
