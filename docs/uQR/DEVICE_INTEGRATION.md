# Device integration guide

> **Is this the right document?** This one is for when **the machine itself
> talks to us** — it holds a credential, creates its own orders, and polls for
> the result. If instead your *backend* controls the fleet and brokers payment
> on the machine's behalf, so the machine never reaches us at all, you want
> [ETM_INTEGRATION.md](ETM_INTEGRATION.md).

For firmware engineers adding SmartVend as a payment method to a vending
machine. This is the whole protocol: two phases, six endpoints.

You do not register anything with us ahead of time. There are no factory
credentials, no batch files, no per-machine setup on our side. A machine you
build gets its credential from us the first time an operator turns it on and
asks for one.

- **Integration environment:** `https://paygatestage.smartvend.kz` — real Kaspi
  payments, scoped so they never mix with production. Build against this.
- **Production:** issued to you separately. The base URL is the only thing that
  changes.
- **Reference client:** [`scripts/device_sim.py`](scripts/device_sim.py) —
  stdlib-only Python that speaks every call below. Run it against stage to see
  the expected traffic, or as a conformance check against your own
  implementation.

All requests and responses are JSON. All amounts are **whole tenge** — integers,
no decimals, no minor unit.

---

## Phase 1 — Enrollment (once, on first activation)

The machine has no credential. The operator selects SmartVend in your payment
menu; you obtain a code, show it, and wait.

### 1. Open an enrollment

```http
POST /api/v1/device/enroll
Content-Type: application/json

{ "manufacturer": "Acme Vending", "serial": "SN-4471-A" }
```

Both fields are optional. Send them if you have them: the operator sees them
while claiming and uses them to confirm they are claiming the machine in front
of them rather than a neighbouring one. We treat them as **display text only** —
they are never used to identify or authenticate the machine, are not required to
be unique, and nothing breaks if two machines report the same serial.

```json
{
  "enrollment_id": "kJ3s...",
  "enrollment_secret": "9fJ...",
  "code": "PTZ7-VV6R",
  "claim_url": "https://panel.smartvend.kz/tenant/devices/claim?code=PTZ7-VV6R",
  "expires_at": "2026-07-30T13:12:54Z",
  "poll_interval_seconds": 3
}
```

**Display both** `code` and a QR encoding `claim_url`. The QR is the fast path —
the operator scans it and lands on the claim form with the code already filled
in. The printed code is the fallback when scanning is inconvenient.

Rate-limited per source IP. If you get **429**, honour `Retry-After`.

### 2. Poll until claimed

```http
GET /api/v1/device/enroll/{enrollment_id}
Authorization: Bearer {enrollment_id}:{enrollment_secret}
```

Poll every `poll_interval_seconds`.

| Status | Meaning | What to do |
|---|---|---|
| **202** | Not claimed yet | Keep polling, keep the code on screen |
| **200** | Claimed | Store the credential, leave enrollment mode |
| **410** | Expired | Stop. Start a new enrollment and show the new code |
| **401** | Bad credential | Stop. This is a bug in your header |
| **429** | Polling too fast | Back off per `Retry-After` |

The 200 body:

```json
{
  "status": "claimed",
  "device_id": 2,
  "device_secret": "HmmCTDzp...",
  "bearer": "2:HmmCTDzp..."
}
```

**Write `device_id` and `device_secret` to non-volatile storage before you
acknowledge anything else.** They are the machine's permanent identity. We keep
them retrievable for a few minutes after the claim — so a dropped response is
recoverable by simply polling again — but after that the only way to get a
working credential is for the operator to rotate the secret from their panel and
re-provision the machine by hand.

The device is `active` on arrival and can take payments immediately.

### Re-enrollment

Enrollment is a first-life event. A machine that changes owners keeps its
credential — the transfer happens on our side and needs nothing from firmware.

Do **not** re-enroll on every boot, and do not discard a stored credential on a
routine factory reset unless the operator explicitly asks to unbind the machine.
Because we have no hardware identity, a machine that enrolls again is a *new
device* to us: it gets a new `device_id` and the operator's order history stays
with the old one.

---

## Phase 2 — Payments (every sale)

All calls: `Authorization: Bearer {device_id}:{device_secret}`.

### 3. Create an order and get the QR

```http
POST /api/v1/device/orders
{ "price": 150, "slot": "A1", "product_name": "Cola" }
```

- `price` is **required** and authoritative — it is what the customer pays.
- `slot` + `product_name` also upsert that slot in the machine's catalog, so the
  operator's panel stays in sync with what is physically loaded. Send `slot`
  alone to reuse the name the operator already configured; send neither for a
  one-off sale.
- `vm_order_id` (optional) is an opaque string of yours, stored for correlation.

```json
{
  "id": 1,
  "account": "order-1",
  "status": "created",
  "amount": 150,
  "currency": "KZT",
  "qr_payload": "https://kaspi.kz/pay/Smartvend?service_id=4680&7363=order-1",
  "expires_at": "2026-07-30T13:01:34Z"
}
```

Render `qr_payload` as a QR for the customer. It is an opaque string — do not
parse it; its shape differs per payment rail and may change.

**201** for a new order, **200** when you are getting an order back rather than a
new one. Both are success.

A machine holds one open order at a time, and `vm_order_id` decides what happens
when you ask for another while one is open — so **send it, reuse it when you
retry, and change it for each new sale**:

- **Same `vm_order_id`** → you get the same order and the same `qr_payload`
  back, with a **200**. Nothing new is minted. Retry as often as you need after a
  timeout or a lost response.
- **A different `vm_order_id`** → the open order is closed and a fresh one is
  minted (**201**), even if it had not expired yet. You never have to cancel
  first, and you are never stuck behind an order the customer walked away from.

Omit `vm_order_id` and we compare the request instead — same `price` and `slot`
counts as a retry, a different `price` starts a new order. That is a reasonable
guess, not a guarantee.

Two consequences worth designing for:

- **Stop showing the old QR** once you get a **201** back. The previous one is no
  longer yours, and its `order_id` will not go `paid`.
- **A payment against a closed order is refunded automatically.** We cannot
  revoke a QR that Kaspi already minted, so a customer who pays one late is
  charged and then refunded. That order never reaches `paid`, and the machine
  must not vend for it.

### 4. Poll the order

```http
GET /api/v1/device/orders/{order_id}/status
```

`created` → `paid` → `confirmed`, or `expired` if nobody pays before
`expires_at`. Poll until `paid`, then stop showing the QR.

This call also registers the machine as online, so keep polling even when idle
if you want the operator's fleet view to show it as alive.

### 5. Confirm receipt — **time-critical**

```http
POST /api/v1/device/orders/{order_id}/confirm
{ "vend_status": true }
```

Call this **as soon as you see `paid`**. If we do not hear from you within the
refund window, we automatically refund the customer on the assumption the
machine never got the money. That window is short (one minute in production).

`vend_status` is optional here and reports whether the product actually came
out. Send it if you already know; otherwise confirm first and report separately.

### 6. Report the vend outcome

```http
POST /api/v1/device/orders/{order_id}/vend
{ "vend_status": false }
```

Dispensing is a separate axis from payment: the customer can pay and the machine
can still fail to vend. Report honestly. If the operator has enabled
auto-refund-on-dispense-failure, `false` triggers the customer's refund — that
policy is theirs to set, and your job is only to tell the truth about what
happened.

---

## Errors

| Status | Meaning | Firmware behaviour |
|---|---|---|
| **401** | Bad or missing credential | Stop. Do not retry — the credential is wrong |
| **403** | Device suspended or revoked | Stop and display a service message. The operator controls this from their panel |
| **404** | Unknown order, or a slot with no configured product | Fix the request; do not retry as-is |
| **409** | Conflicting state (e.g. confirming an expired order). May carry `existing_order_id` | Read the body; do not blind-retry |
| **410** | Enrollment lifetime ended | Start a new enrollment |
| **422** | Malformed request | Bug in your request. Do not retry |
| **429** | Rate limited | Back off for `Retry-After` seconds |
| **503** | Upstream payment provider unavailable. Carries `Retry-After` | Safe to retry as-is — nothing was created |

**503 on order creation is fully rolled back.** No order exists, and the machine
is not left holding an open one. Retry after the given delay.

---

## Checklist

- [ ] Credential written to non-volatile storage before anything else
- [ ] Enrollment code **and** QR both shown on screen
- [ ] Enrollment retried with a fresh code on 410
- [ ] `confirm` called immediately on `paid` — the refund window is short
- [ ] `qr_payload` rendered verbatim, never parsed
- [ ] `Retry-After` honoured on 429 and 503
- [ ] 401 and 403 stop the loop instead of retrying
- [ ] Vend failures reported truthfully
- [ ] Verified end to end against stage with real Kaspi payments
