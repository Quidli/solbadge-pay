# The worker's API

What the badge app and the worker say to each other. Use it to write your own
worker (any host that can verify Ed25519 and call Connect) or your own badge app
against this worker. The reference code is [`worker/worker.js`](../worker/worker.js).

## Every request

The badge can't make HTTPS calls itself: the badge server makes them and adds
signed `X-Badge-*` headers (see `docs/LUA_API.md` in
[solana-os](https://github.com/solana-foundation/solana-os), "What your server receives").
The worker accepts a request only when all of these hold:

1. `X-Badge-App` is the app's id (`solbadge-pay`).
2. `X-Badge-Time` is within 60 s of now.
3. The Ed25519 signature in `X-Badge-Signature` verifies, with the key named by
   `X-Badge-Key` from `https://badge-api.solana.com/api/http/key`, over these lines
   joined by `\n`:
   `badge-http-v1`, method, full URL, hex SHA-256 of the body, app id,
   `X-Badge-Id`, `X-Badge-User`, `X-Badge-Time`, `X-Badge-Request`.
4. `X-Badge-Request` hasn't been seen in the last minute (no replays).
5. `X-Badge-Id` is in `BADGE_IDS`.

| Answer | When |
| --- | --- |
| 401 `{text}` | Not a valid signed request from the app |
| 403 `{text}` | Badge not in `BADGE_IDS`, or no `CONNECT_API_KEY` set |
| 413 `{text}` | Body over 2 KB |
| 404 `{text}` | Unknown path |

The worker never answers 5xx itself. The app treats any 5xx (say, from
Cloudflare in front of the worker) as "no final answer".

## GET /assets

What the badge can send: what the Connect wallet holds on Solana, from Connect's
`GET /drop/balance?chainId=1399811149`. The app reads it when the player picks
what to send, and again after each payment.

```json
{"assets": [
  {"id": "sol", "label": "SOL", "chain": "Solana", "dec": 9, "max": "0.052096561",
   "amounts": ["0.005", "0.01", "0.02", "0.05"]},
  {"id": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v", "label": "USDC", "chain": "Solana",
   "dec": 6, "max": "10", "amounts": ["1", "2", "5", "10"]}
], "wallet": "Badge4BJRYfnu29GPWdksz7EMUbiqx5CKSZgov3AHQXe"}
```

- `id` is `sol` or the token's mint address.
- `max` is the most one payment can be: the balance, less 0.01 SOL kept for fees.
- `amounts` are up to four round amounts (1, 2 or 5 times a power of ten) up to `max`.
- `wallet` is the Connect wallet's Solana address, for the app's **Add funds** QR
  code. It comes with the `{text}` answer for an empty wallet too.
- At most 8 entries, SOL first. Amounts are decimal strings, never numbers: the
  badge's numbers are 32-bit.

When there is nothing to offer (an empty wallet, a refused key, no answer from
Connect), the answer is 200 with `{text}` alone, which the app shows.

## GET /score/&lt;handle&gt;

A handle's social reputation from Connect (`GET /scores/twitter/<handle>`, asked
without the API key so the check never sets anything up on Connect), cut down for
the badge's screen.

```json
{"score": 96, "lines": ["Farcaster reputation: 0.96", "Lens reputation: 0.89"]}
```

Stopgap: once an X account belongs to a Connect user, Connect leaves its X
reputation out, and a wallet Connect set up for someone who never used it scores
0 (untrusted). So the worker also asks Ethos (`api.ethos.network`, public) for
the X score when Connect's answer lacks it, and leaves out wallet scores of 0.

`score` is `null` when Connect has none. `{text}` alone means Connect couldn't
answer; the app shows the text. A handle that isn't 1 to 15 of `[A-Za-z0-9_]` gets 400.

## POST /pay

```json
{"id": "<uuid v4>", "handle": "quidliprotocol", "asset": "sol", "units": "5000000"}
```

`asset` is an `id` from `/assets`; `units` is the amount in the token's smallest
unit (here 0.005 SOL), worked out on the badge from `dec`. `id` is made by the
badge and saved before the first try. The worker passes it to Connect's
`POST /drop` as `idempotencyKey`, so every retry with the same id is the same
payment.

The answer is always 200 with a `state`:

| `state` | Meaning | What the app does |
| --- | --- | --- |
| `sent` | Connect sent it; `tx` is the Solana transaction when Connect gave one | Done; forgets it, shows `tx` as a Solscan QR code |
| `processing` | Connect is setting up the recipient; nothing sent yet | Asks again with the same id shortly |
| `failed` | This request sent nothing (bad input, Connect refused) | Forgets it, unless an earlier try may have gone through |
| `unknown` | No final answer (Connect timed out or answered 5xx) | Keeps it and offers a retry with the same id |

`failed` and `unknown` carry `{text}` to show. The worker gives Connect 4.5 s,
since the badge gives up at 6 s.
