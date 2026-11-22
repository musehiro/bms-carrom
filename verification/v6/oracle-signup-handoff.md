# Oracle Cloud signup — handoff for the parent agent (browser step)

## What is needed
An **Oracle Cloud Always Free** account, created in the signed-in browser
with Buddhika's Gmail **bmsirimanna@gmail.com**. The agent (Hiro) cannot
do this step: Oracle's signup is a web form with CAPTCHA + email/phone
verification **and a credit/debit card for identity verification**.

## The card step (the blocker)
- Oracle requires a **credit or debit card** to create the account — for
  identity verification only. Oracle's own FAQ says it is a temporary
  authorization hold, **not a charge**, and the Always Free tier itself
  costs nothing. Prepaid / virtual / single-use cards are refused.
- **Buddhika must enter the card himself in the browser.** The agent
  must never ask for card details in chat and must never enter them.
- If he prefers not to use a card, there is no free hosted server:
  the game still works via NEARBY (same-Wi-Fi) play in v6, and worldwide
  online waits until a server exists.

## Exact signup steps (browser)
1. Go to https://www.oracle.com/cloud/free/ (or cloud.oracle.com) and
   click **Start for free** / **Sign up**.
2. Country: **Sri Lanka**. Email: **bmsirimanna@gmail.com**. Set a
   password (Buddhika's own — the agent does not set or store it).
3. Verify email (code to the Gmail) and phone (SMS code).
4. **Payment verification:** enter the card in Oracle's form (Buddhika
   himself, in the browser). This is the step that needs him.
5. Choose the **home region: Singapore** (closest to Sri Lanka / South
   Asia; Mumbai is the fallback if Singapore is full). The home region
   cannot be changed later — Always Free resources only exist there.
6. Once the account is active: create an **Always Free VM** (Compute →
   Create Instance → Image: Ubuntu 22.04, Shape: Ampere A1 — 1 OCPU /
   6 GB, or E2 Micro; Always Free eligible). Keep the default VCN.
7. In the instance's VCN security list, add an **Ingress Rule: UDP,
   port 8910, source 0.0.0.0/0** (the game server port).
8. SSH into the VM and run the ready-made script from the repo:
   `server/deploy-oracle.sh` (downloads Godot 4.3 headless, clones the
   server code, opens UDP 8910 in ufw, installs the systemd service).
   The script prints the VM's public IP at the end.
9. Type that public IP into the game: PLAY → NEARBY → INTERNET SERVER
   field → SAVE. ONLINE will use it from then on. Then two real phones
   anywhere can match.

## Cost / limits (honest)
- Always Free: $0, no expiry. VM: up to 2 AMD micro VMs or Ampere A1
  (2 OCPU / 12 GB after the June 2026 halving). Outbound data 10 TB/mo.
- Oracle reclaims idle Always Free instances after 7 days under 20% CPU
  use — the game server idles near 0% when nobody plays, so check it
  weekly or add a tiny keep-alive (a cron that queues a heartbeat).
  If reclaimed, re-create the instance and re-run the script.
- Realistic capacity of one free VM: ~1,000–2,000 concurrent players /
  500–1,000 simultaneous matches — plenty for launch, not 200K
  simultaneous (that needs a fleet, paid for by ad revenue later).

## If Oracle signup fails
- Fallback region Mumbai (same steps, home region Mumbai).
- If the card is refused: no other free host works without an account +
  card (Fly.io needs a card + is paid now; Google Cloud / AWS / Azure
  all need a card; Render/Railway/Heroku cannot carry raw UDP). The
  game keeps working via NEARBY until a server is possible.
