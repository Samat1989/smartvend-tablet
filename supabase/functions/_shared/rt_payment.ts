// Payment window for a board on the Realtime path (firmware/esp-rt).
//
// SmartVend refunds by itself unless payment_result is called within ~60 s of
// the QR, and the first code=1 answer is what takes the money. So:
//
//   - poll payment_result only while the board is in Presence — a board that
//     dropped off means nobody polls, and the customer gets the auto-refund;
//   - on code=1 record the sale at once (the money is taken) with
//     door_status='pending', then send a signed `open` and wait for `opened`;
//   - everything fits into the same 60 s window from the QR. If code=1 lands in
//     the last seconds, `open` still gets ~15 s of delivery to a board that is
//     online — that is delivering the command, not waiting for a reconnect.
//
// The door's outcome lands in sales.door_status: opened | failed | no_ack.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { DeviceChannel, sleep } from "./device_channel.ts";
import { paymentResult } from "./smartvend.ts";

export const PAY_WINDOW_MS = 60_000;
const POLL_EVERY_MS = 3_000;
const OPEN_MIN_MS = 15_000;

export interface PaymentWindow {
  seconds: number;  // micromarkets.open_seconds — goes into the signed `open`
  orderid: string;
  torderid: string;
  machid: number;
  appkey: string;
  key: string;      // device_rt.key, HMAC key for `open`
  qrAt: number;     // epoch ms when SmartVend issued the QR
}

export async function runPaymentWindow(sb: SupabaseClient, ch: DeviceChannel, w: PaymentWindow) {
  const tag = `[rt ${w.machid} ${w.orderid}]`;
  const deadline = w.qrAt + PAY_WINDOW_MS;
  try {
    let paid = false;
    while (Date.now() < deadline) {
      await sleep(Math.min(POLL_EVERY_MS, Math.max(deadline - Date.now(), 0)));
      if (!ch.present()) {
        console.log(tag, "board not in presence — not polling");
        continue;
      }
      const r = await paymentResult(w.orderid, w.torderid, w.machid, w.appkey);
      if (!r) continue;
      if (r.code === 1) { paid = true; break; }
      if (r.code === 3 || r.code === 4) {
        console.log(tag, "transaction expired/closed", r.code, r.msg);
        break;
      }
    }

    if (!paid) {
      await sb.from("pending_orders").update({ status: "expired" })
        .eq("orderid", w.orderid).eq("status", "pending");
      console.log(tag, "window closed without payment");
      return;
    }

    // Money is taken: record the sale before anything else. A failure here is
    // retried a few times; if it still fails the door is opened anyway — the
    // customer has paid — and the log is the only trace, so it is loud.
    let recorded = false;
    for (let i = 0; i < 3 && !recorded; i++) {
      const { data, error } = await sb.rpc("finalize_paid_order", {
        p_orderid: w.orderid, p_door_status: "pending",
      });
      if (!error) {
        recorded = true;
        console.log(tag, "paid, sale", data?.status, data?.sale_id ?? "");
      } else {
        console.error(tag, "finalize_paid_order failed", error.message);
        await sleep(1000);
      }
    }
    if (!recorded) console.error(tag, "PAID BUT SALE NOT RECORDED");

    const openDeadline = Math.max(deadline, Date.now() + OPEN_MIN_MS);
    const ack = await ch.command("open", w.key, w.orderid, { seconds: w.seconds }, openDeadline);
    const door = ack ? (ack.ok === false ? "failed" : "opened") : "no_ack";
    console.log(tag, "door", door, ack?.err ?? "");
    const { error } = await sb.rpc("set_sale_door_status", { p_orderid: w.orderid, p_status: door });
    if (error) console.error(tag, "set_sale_door_status failed", error.message);
  } catch (e) {
    console.error(tag, "payment window crashed", (e as Error).message);
  } finally {
    await ch.close();
  }
}
