// SmartVend / LV payment API (docs/refs/qr_payment_api_docs.txt, §6-7) for the
// Realtime path. create-payment and complete-order keep their own copies of
// sign() and the payment_result call until the old MQTT fleet is gone — their
// legacy branches are deliberately not touched during the rollout.

export const RESULT_URL = "https://levending.smartvend.kz/payment_result";

// sha1 over appkey, randstr and timestamp sorted as strings (LV §7).
export async function sign(appkey: string, randstr: string, timestamp: string): Promise<string> {
  const combined = [appkey, randstr, timestamp].sort().join("");
  const buf = await crypto.subtle.digest("SHA-1", new TextEncoder().encode(combined));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function lvTimestamp(): string {
  return new Date().toISOString().replace(/[-:T]/g, "").split(".")[0].substring(0, 14);
}

export function lvRandstr(): string {
  return Math.random().toString(36).substring(2, 18).padEnd(16, "0");
}

export interface PaymentResult {
  code: number;
  msg?: string;
}

// One payment_result call (LV §6.2). code 1 = paid, 2 = waiting, 3 = expired,
// 4 = closed, 5 = completed. The FIRST code=1 answer is what closes the
// payment on SmartVend's side; without it SmartVend refunds after ~60 s. So
// this must only be called while the board is known to be online.
// Returns null on a transport error — the caller retries on the next tick.
export async function paymentResult(
  orderid: string,
  torderid: string,
  machid: number,
  appkey: string,
): Promise<PaymentResult | null> {
  const timestamp = lvTimestamp();
  const randstr = lvRandstr();
  const form = new URLSearchParams();
  form.append("ver", "v1");
  form.append("orderid", orderid);
  form.append("torderid", torderid ?? "");
  form.append("machid", String(machid));
  form.append("channelid", "36");
  form.append("randstr", randstr);
  form.append("timestamp", timestamp);
  form.append("sign", await sign(appkey, randstr, timestamp));

  const controller = new AbortController();
  const tid = setTimeout(() => controller.abort(), 8000);
  try {
    const r = await fetch(RESULT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: form.toString(),
      signal: controller.signal,
    });
    const j = await r.json();
    return { code: parseInt(j.code), msg: j.msg };
  } catch (_) {
    return null;
  } finally {
    clearTimeout(tid);
  }
}
