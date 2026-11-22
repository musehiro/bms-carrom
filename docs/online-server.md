# BMS Carrom — Online Server

Real online multiplayer needs a server: it matches two players of similar
level, then relays their shots. The server is deliberately tiny — it does
**not** simulate physics (both clients simulate the same shot inputs and
resync with a full state snapshot after every shot). That keeps hosting
cheap and the server easy to run anywhere.

## What the server is

- `server/` in this repo — a small headless Godot 4.3 project.
- `server/net_server.gd` — matchmaking queue + relay (autoload `Net`).
- `server/server_main.gd` + `server/server.tscn` — keeps the tree alive.
- Default port **8910**, ENet (UDP). One process serves all matches.

## How matchmaking works

1. Client sends `{"type":"queue","name","level","table"}`.
2. Server pairs two players on the **same table** whose levels are within
   **±2**. If either player has waited **30 s**, the window widens to **±4**.
3. Both get `{"type":"matched","opponent","opp_level","you_break"}`.
   One of them breaks (random).
4. During the match the server only relays `shot`, `state` and `forfeit`
   messages between the pair. If a player disconnects, the other gets
   `opponent_left` (and wins).
5. If no opponent is found in 60 s, the client offers a clearly-labelled
   **BOT practice match** — never a fake human.

## Run it locally (testing)

```bash
# From the repo root. Needs the Godot 4.3 binary.
godot --headless --path server -- --port 8910
```

Then set the server address in the game to `127.0.0.1` (the default) and
play Online — two game instances on the same machine will match each other.
This is how online was verified in development (see `docs/verification.md`).

## Host it for real players (free tiers)

The server is a plain Linux binary: `godot --headless` + the `server/`
folder. It uses almost no CPU/RAM (no physics, no rendering). Any of
these free options works — pick one, no paid service is needed:

### Option A — Oracle Cloud Free Tier (recommended)
1. Create a free Oracle Cloud account, launch an **Always Free** VM
   (Ampere A1 or E2 Micro, Ubuntu 22.04).
2. Copy the `server/` folder to the VM and install Godot 4.3 headless:
   `wget https://github.com/godotengine/godot/releases/download/4.3-stable/Godot_v4.3-stable_linux.x86_64.zip`
   then `unzip` it and use the binary.
3. Open UDP port **8910** in the VM firewall *and* in the Oracle
   security list (Ingress rule, UDP, port 8910, source 0.0.0.0/0).
4. Run it persistently, e.g. with systemd:
   ```
   [Unit]
   Description=BMS Carrom server
   After=network.target
   [Service]
   ExecStart=/home/ubuntu/godot --headless --path /home/ubuntu/bms-carrom-server -- --port 8910
   Restart=always
   [Install]
   WantedBy=multi-user.target
   ```
5. Note the VM's public IP.

### Option B — Fly.io free allowance
1. `fly launch` a tiny app from a Dockerfile that installs the Godot
   4.3 binary and runs the command above. Fly's free allowance covers
   small always-on apps; UDP needs a dedicated IPv4 or `fly proxy`
   setup — check Fly's current UDP docs before choosing this.
2. Use the app's public hostname as the server address.

### Option C — any cheap VPS / home PC
Any Linux machine with a public IP (or port-forwarded UDP 8910) works:
a Raspberry Pi, an old PC, or the cheapest VPS. Same command as above.

## Point the game at the server

In the game, the server address is stored in the local save
(`Save.online_host`, default `127.0.0.1`). For a hosted server, set it to
the server's public IP or hostname. (v1: edit the default in
`scripts/save_data.gd` before building, or set it from a future Settings
screen. The value is just a string — no code change needed beyond that.)

## Scaling notes

- One server process handles many simultaneous matches (each match is
  just two peers relaying small JSON messages a few times per minute).
- If the player base grows, run one process per region and let the client
  pick the nearest — the protocol is identical.
- Anti-cheat in v1 is light: the server validates message shapes and
  relays only. Full server-side shot validation (re-simulating shots) is
  a Phase-2 hardening step; the aim-assist line is capped at 1 bounce so
  no client can ever have a perfect line.

## Status

- ✅ Server builds and runs headless; matchmaking verified locally with
  two clients on `127.0.0.1` (see `docs/verification.md`).
- ⚠️ **Not yet verified over the internet** — that needs a hosted server
  (above) plus two real devices. Do not claim worldwide online works
  until that test passes.
