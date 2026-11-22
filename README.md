<img src="assets/icon.svg" width="64" height="64" alt="">

# Connect Pay for the Solana Breakpoint badge

Pay anyone by their X handle from a [Breakpoint 2026 badge](https://solana.com/breakpoint/badge),
through [Quidli Connect](https://connect.quid.li). Pick a badge nearby or type a handle, see
their social reputation, choose an amount, confirm. No phone, no wallet signature, and no
key on the badge.

This is a reference client for **Quidli Connect on Solana**: send SOL or any SPL token to an
X handle with one API call, no wallet signature, and Connect resolves the handle to a wallet. The
badge is the smallest client we could think of. The same calls work from any app, bot or
server: see [connect.quid.li](https://connect.quid.li).

## How it works

```
badge app  ──▶  badge server  ──▶  your worker  ──▶  Connect  ──▶  recipient's wallet
(no secret)     (signs who is       (checks the signature           (resolved from
                 calling)            and your badge id;              their handle)
                                     holds your Connect key)
```

- The badge can't make its own HTTPS calls. The badge server makes them and signs each one
  with the badge's id. That signature is the badge's credential.
- The worker runs on **your own** Cloudflare account, with your Connect key as a secret. It
  accepts only your badge. Nobody holds anyone else's key.
- The badge app is the same for everyone. Only the worker is yours.

## Set it up

You need a badge, a free Cloudflare account, a GitHub account, and a Quidli Connect account.

**Get your Connect account ready** at [connect.quid.li](https://connect.quid.li):

1. Sign in, with X if you can (see [Getting paid](#getting-paid)).
2. **Smart Send** tab, **Configuration**: turn on **Enable Smart Send**. It lets Connect send
   from your Connect wallet when your worker asks; without it every payment fails.
3. **API Dashboard** tab: copy your API key (it starts with `QC_`). Keep it secret: it can
   spend from your Connect wallet. It goes into your worker, never onto the badge.

> **Treat it like pocket money.** The badge has no PIN or lock: whoever holds it can send
> everything in the wallet behind it. Use a separate Connect account just for the badge, and
> keep only what you'd be fine losing if you left the badge on a table.

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

**4. Add funds.** In the app: **Add funds** shows your Connect wallet's Solana address as a QR
code. Scan it with your phone's wallet app (Phantom, Solflare, ...) and send SOL and any
token you want to pay with. They show up on the badge, ready to send. (The same address is
on connect.quid.li under **Smart Send**, **Smart Send wallet**, **Solana**.)

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

Whatever your Connect wallet holds on Solana: SOL and any SPL token. **To add a token, send
some to the wallet**; the badge lists it the next time you pick what to send, with your
balance next to it. There's nothing to configure.

- **Keep about 0.01 SOL in the wallet.** Every payment pays a small fee in SOL, and sending a
  token to someone for the first time costs about 0.002 SOL to open their token account. The
  badge never offers that last 0.01 SOL.
- The smallest SOL payment is 0.001 SOL.
- Token-2022 tokens can't be sent yet. The list shows up to 8 tokens, SOL first.
- A Connect key allows 20 requests a minute. A payment takes a few, so that's plenty for one
  badge, not for a crowd sharing one key.

## Getting paid

Payments go to an **X account**, not to a badge. Connect finds the wallet that belongs to
that X account, and makes one if the person has never used Connect. They don't need a badge,
an app or a wallet, and don't have to do anything first.

To see and spend what they were sent, they sign in at [connect.quid.li](https://connect.quid.li)
**with that X account**: it's the same wallet, already holding the payment. If they have a
badge too, the setup above (about 10 minutes) lets them pay it forward from there.

## Safety

- **Every payment needs a confirm** on the badge naming the amount, the handle and the chain.
- **A payment is never sent twice.** It is saved with one id before the first try, and every
  retry reuses that id as Connect's `idempotencyKey`. When an answer is lost, the badge says
  "No final answer yet" and offers the same payment again, never a new one.
- **The most anyone can send is what's in the wallet.** There is no other limit, so keep it
  small (see above).
- **Whom you trust.** The badge server could sign a request in your badge's name. The
  wallet's balance bounds what that could cost.

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
