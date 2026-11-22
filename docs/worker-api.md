# The worker's API

What the badge app and the worker say to each other. Use it to write your own
worker (any host that can verify Ed25519 and call Connect) or your own badge app
against this worker. The reference code is [`worker/worker.js`](../worker/worker.js).

## Every request

The badge can't make HTTPS calls itself: the badge server makes them and adds
signed `X-Badge-*` headers (see `docs/LUA_API.md` in
[solana-os](https://github.com/solana-foundation/solana-os), "What your server receives").
The worker accepts a request only when all of these hold:

1. `X-Badge-App` is the app's id (`connect-pay`).
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

What this badge may send. The app reads it once per launch.

```json
{"assets": [{"id": "usdc-sol", "label": "USDC", "chain": "Solana", "dec": 6,
             "max": "5", "amounts": ["0.10", "0.50", "1", "2", "5"]}]}
```

Amounts are decimal strings, never numbers: the badge's numbers are 32-bit.

## GET /score/&lt;handle&gt;

A handle's social reputation from Connect, cut down for the badge's screen.

```json
{"score": 96, "lines": ["Farcaster reputation: 0.96", "Lens reputation: 0.89"]}
```

`score` is `null` when Connect has none. `{text}` alone means Connect couldn't
answer; the app shows the text. A handle that isn't 1 to 15 of `[A-Za-z0-9_]` gets 400.

## POST /pay

```json
{"id": "<uuid v4>", "handle": "quidliprotocol", "asset": "usdc-sol", "amount": "1"}
```

`id` is made by the badge and saved before the first try. The worker passes it
to Connect's `POST /drop` as `idempotencyKey`, so every retry with the same id
is the same payment.

The answer is always 200 with a `state`:

| `state` | Meaning | What the app does |
| --- | --- | --- |
| `sent` | Connect accepted the payment | Done; forgets it |
| `processing` | Connect is setting up the recipient; nothing sent yet | Asks again with the same id shortly |
| `failed` | This request sent nothing (bad input, over the cap, Connect refused) | Forgets it, unless an earlier try may have gone through |
| `unknown` | No final answer (Connect timed out or answered 5xx) | Keeps it and offers a retry with the same id |

`failed` and `unknown` carry `{text}` to show. The worker gives Connect 4.5 s,
since the badge gives up at 6 s.
