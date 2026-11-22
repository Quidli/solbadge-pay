<img src="assets/icon.svg" width="64" height="64" alt="">

# Connect Pay for the Solana Breakpoint badge

Pay anyone by their X handle from a [Breakpoint 2026 badge](https://solana.com/breakpoint/badge),
through [Quidli Connect](https://connect.quid.li). Pick a badge nearby or type a handle, see
their social reputation, choose an amount, confirm. No phone, no wallet signature, and no
key on the badge.

This is a reference client for **Quidli Connect on Solana**: send SOL or USDC to an X handle
with one API call, no wallet signature, and Connect resolves the handle to a wallet. The
badge is the smallest client we could think of. The same calls work from any app, bot or
server: see [connect.quid.li](https://connect.quid.li).

## How it works

```
badge app  ──▶  badge server  ──▶  your worker  ──▶  Connect  ──▶  recipient's wallet
(no secret)     (signs who is       (checks the signature,          (resolved from
                 calling)            your badge id and the caps;     their handle)
                                     holds your Connect key)
```

- The badge can't make its own HTTPS calls. The badge server makes them and signs each one
  with the badge's id. That signature is the badge's credential.
- The worker runs on **your own** Cloudflare account, with your Connect key as a secret. It
  accepts only your badge and enforces a cap per payment. Nobody holds anyone else's key.
- The badge app is the same for everyone. Only the worker is yours.

## Set it up

You need a badge, a free Cloudflare account, a GitHub account, and a Connect API key
([connect.quid.li](https://connect.quid.li), **Enable API access**).

Use a separate Connect account funded with small amounts. The badge has no lock: whoever
holds it can send, one capped payment after another, until that wallet is empty.

**1. Get your badge's id.** Install **Connect Pay** on the badge and open it. The home
screen shows **Set up**, with your badge id under it (like `7K2Q9M`).

> Until Connect Pay is in the badge store, load it yourself: on the badge site, open
> `/apps/submit` signed in with X linked, drop the `app/` folder on it, and press
> **Run on badge**. Apps loaded this way can only reach the network during a 12-hour test
> run, which **Run on badge** starts and renews.

**2. Deploy your worker.**

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Quidli/connectpay-solanabadge/tree/main/worker)

It copies this worker into your GitHub account, deploys it, and asks for two settings:
`CONNECT_API_KEY` (your Connect key) and `BADGE_IDS` (your badge id). When it's done it
shows the worker's address, like `connect-pay.you.workers.dev`.

**3. Point the badge at it.** In the app: **Set up**, **Enter worker address**, type the
address. The screen should say "The worker accepts this badge."

That's all. To let another badge in later, or change the key, edit the setting in the
Cloudflare dashboard: your worker, **Settings**, **Variables and Secrets**.

<details>
<summary>Deploy from the command line instead</summary>

```bash
cd worker
npx wrangler deploy
npx wrangler secret put CONNECT_API_KEY
npx wrangler secret put BADGE_IDS
```
</details>

## What you can send

`ASSETS` at the top of [`worker/worker.js`](worker/worker.js): USDC and SOL on Solana, ETH
on Base, each with a cap per payment and quick-pick amounts. The badge reads the list from
your worker, so changing an asset or a cap is an edit to your copy of the worker. Connect's
chains are listed at `https://api.connect.quid.li/chains`.

## Safety

- **Every payment needs a confirm** on the badge naming the amount, the handle and the chain.
- **A payment is never sent twice.** It is saved with one id before the first try, and every
  retry reuses that id as Connect's `idempotencyKey`. When an answer is lost, the badge says
  "No final answer yet" and offers the same payment again, never a new one.
- **The cap is per payment, not per day.** The total at risk is the balance of the Connect
  account behind the key.
- **Whom you trust.** The badge server could sign a request in your badge's name. The cap and
  the account's balance bound what that could cost.

## Build on it

- [`docs/worker-api.md`](docs/worker-api.md): what the badge and the worker say to each other,
  for writing your own worker or your own badge app.
- [`app/`](app): the badge app (Lua). To publish your own version, give it a new `id` in
  `app.json`, and set the worker's `APP_ID` var to match.
- [`worker/`](worker): the worker, plain JavaScript, no build step.

## Tests

```bash
node --test test/worker.test.mjs
```

checks the worker against a stand-in badge server and a stand-in Connect (Node 20+, nothing
to install).

`test/harness.lua` drives the app key press by key press, on the badge's own Lua, with the
badge's modules stubbed to their documented rules:

```bash
git clone --depth 1 https://github.com/solana-foundation/solana-os
V=solana-os/main/lua/vendor
gcc -O1 -w -I$V -o runner test/runner.c $V/l*.c -lm
./runner test/harness.lua app/main.lua test/data
```

Both run on every push (`.github/workflows/test.yml`).

## Licence

[MIT](LICENSE)
