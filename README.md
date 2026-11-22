<img src="assets/icon.svg" width="64" height="64" alt="">

# SolBadge Pay

**Contactless Solana payments from your [Breakpoint 2026 badge](https://solana.com/breakpoint/badge).**
Pick a nearby badge, or type an X username, and send SOL or any SPL token. No phone, no wallet
signature, no address needed, and no key on the badge.

Payments go to the person's X account through [Quidli Connect](https://connect.quid.li); they
sign in with X to use them (see [Getting paid](#getting-paid)).

This is a reference client for **Quidli Connect on Solana**: send SOL or any SPL token to an
X account with one API call, no wallet signature, and Connect resolves the account to a
wallet. The badge is the smallest client we could think of. The same calls work from any
app, bot or server: see [connect.quid.li](https://connect.quid.li).

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

**1. Get your badge's id.** Install **SolBadge Pay** from the badge's App Store (under
**Tools**) and open it. The home screen shows **Set up**, with your badge id under it (like
`7K2Q9M`).

**2. Deploy your worker.**

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/Quidli/solbadge-pay/tree/main/worker)

It copies this worker into your GitHub account, deploys it, and asks for two settings:
`CONNECT_API_KEY` (your Connect key) and `BADGE_IDS` (your badge id). Pick **"Create private
Git repository"** and a **short project name**, like `pay`: you'll type the worker's address
on the badge's buttons. When it's done, the address is on the worker's **Domains** tab, like
`pay.you.workers.dev`.

**3. Point the badge at it.** In the app: **Set up**, **Enter worker address**, type the
address without `.workers.dev` (the app adds it): `pay.you`. The screen should say "The
worker accepts this badge."

**4. Add funds.** In the app: **Wallet**, then **Add funds**, shows your Connect wallet's Solana
address as a QR code. Scan it with your phone's wallet app (Phantom, Solflare, ...) and send the
tokens you want to pay with, **and always some SOL** (0.05 SOL is plenty to start). They show up
under **Wallet**, ready to send. (The same address is on connect.quid.li under **Smart Send**,
**Smart Send wallet**, **Solana**.)

> **Why SOL, even to pay in USDC?** On Solana every payment pays its network fee in SOL (a
> tiny amount). And the first time someone receives a token, a small account for it has to be
> opened in their wallet, which costs about 0.002 SOL; that SOL stays with them. So 0.05 SOL
> covers about 20 payments to people who never had that token. The badge keeps 0.01 SOL
> aside for this, shows the fee before you confirm, and warns you under **Wallet** when SOL
> runs low.

That's all. To let another badge in later, or change the key, open your worker in the
Cloudflare dashboard: **Settings**, **Variables and Secrets**, edit the setting and press
**Rotate**. Secrets can't be read back, only replaced. Several badges: `2S19S2,7K2Q9M`.

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

- **Keep some SOL in the wallet** for fees (see [Add funds](#set-it-up)). The badge never
  offers the last 0.01 SOL.
- The smallest SOL payment is 0.001 SOL.
- Token-2022 tokens can't be sent yet. The list shows up to 8 tokens, SOL first.
- A Connect key allows 20 requests a minute. A payment takes a few, so that's plenty for one
  badge, not for a crowd sharing one key.

## Before and after paying

- **Reputation.** Before you pay, the badge shows what [Quidli Connect](https://connect.quid.li)
  knows about the person: their Quidli score if they use Connect, and their X, Farcaster, Lens
  or wallet reputation. It's there so you know you've got the right person. (For now the worker
  also asks [Ethos](https://ethos.network) for the X reputation, which Connect leaves out for
  some accounts.)
- **Receipt.** After **Sent**, the badge shows the transaction as a QR code: scan it with your
  phone to see it on [Solscan](https://solscan.io).

## Getting paid

Payments go to an **X account**, not to a badge. Connect finds the wallet that belongs to
that X account, and makes one if the person has never used Connect. They don't need a badge,
an app or a wallet, and don't have to do anything first.

To see and spend what they were sent, they sign in at [connect.quid.li](https://connect.quid.li)
**with that X account**: it's the same wallet, already holding the payment. If they have a
badge too, the setup above (about 10 minutes) lets them pay it forward from there.

## If something goes wrong

| The badge says | What to do |
| --- | --- |
| The worker answered 404 | The address has a typo. **Set up**, **Change worker address**; it's on the worker's **Domains** tab in Cloudflare. |
| Badge … isn't on this worker's list | Add the id to `BADGE_IDS`: worker, **Settings**, **Variables and Secrets**, edit, **Rotate**. |
| The worker has no CONNECT_API_KEY yet | Same place: add the `CONNECT_API_KEY` secret. |
| Connect refused the worker's API key | The key was changed or revoked: copy it again from the **API Dashboard** tab and rotate the secret. |
| Not a signed request from the badge app | The app's id and the worker's `APP_ID` differ (only if you published your own copy of the app). |
| The badge server refused: the app needs a test run… | Install SolBadge Pay from the App Store (this shows up only for a copy loaded by hand). |
| No Wi-Fi | Turn Wi-Fi on in the badge's Wi-Fi app. |
| Low on SOL / Insufficient funds | Add SOL (see [Add funds](#set-it-up)). |
| Payments fail with Smart Send errors | Turn on **Enable Smart Send** on connect.quid.li. |
| No final answer yet | Press **Select** to retry: it's the same payment, never a second one. |

Every failed call also prints its address and answer to the console under **Run on badge**.

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
- [`app/`](app): the badge app (Lua), as published in the store. To try changes, drop the
  folder on the badge site's `/apps/submit` and press **Run on badge** (a 12-hour test run).
  To publish your own version, give it a new `id` in `app.json`, and set the worker's
  `APP_ID` var to match.
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
