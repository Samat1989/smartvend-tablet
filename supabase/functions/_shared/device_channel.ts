// Server side of a board's Realtime channel `dev:<topic>` (firmware/esp-rt).
//
// The channel is public — the board joins it with the publishable key — so
// anything that opens the lock is signed with the board's key (HMAC-SHA256 over
// "event|id|...|exp") and the board checks the signature, the expiry and that
// it has not seen the id before. Everything else (ping, Presence) only tells
// us the board is there.
//
// Messages the board sends into the channel reach only whoever is subscribed
// at that moment; the database never sees them. That is why the payment
// window runs inside create-payment's background task and stays subscribed
// for its whole length.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

type Payload = Record<string, unknown>;
type Waiter = { event: string; pred: (p: Payload) => boolean; resolve: (p: Payload | null) => void };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function hmacHex(key: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

export class DeviceChannel {
  private waiters: Waiter[] = [];
  private joinWaiters: Array<{ key: string; resolve: (ok: boolean) => void }> = [];

  private constructor(
    private sb: SupabaseClient,
    // deno-lint-ignore no-explicit-any
    private ch: any,
    readonly machid: number,
  ) {}

  // Joins the board's channel. Throws if Realtime does not confirm the join
  // in time — the caller treats that as "board unreachable".
  static async open(sb: SupabaseClient, topic: string, machid: number, timeoutMs = 5000) {
    const ch = sb.channel(`dev:${topic}`, {
      config: { broadcast: { self: false, ack: false }, presence: { key: "" } },
    });
    const dc = new DeviceChannel(sb, ch, machid);
    for (const event of ["pong", "opened"]) {
      ch.on("broadcast", { event }, ({ payload }: { payload: Payload }) => dc.dispatch(event, payload));
    }
    ch.on("presence", { event: "join" }, ({ key }: { key: string }) => {
      const ready = dc.joinWaiters.filter((w) => w.key === key);
      dc.joinWaiters = dc.joinWaiters.filter((w) => w.key !== key);
      ready.forEach((w) => w.resolve(true));
    });

    await new Promise<void>((resolve, reject) => {
      const tid = setTimeout(() => reject(new Error("realtime join timeout")), timeoutMs);
      ch.subscribe((status: string) => {
        if (status === "SUBSCRIBED") { clearTimeout(tid); resolve(); }
        else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
          clearTimeout(tid); reject(new Error(`realtime ${status}`));
        }
      });
    });
    return dc;
  }

  private dispatch(event: string, payload: Payload) {
    const hit = this.waiters.filter((w) => w.event === event && w.pred(payload));
    this.waiters = this.waiters.filter((w) => !hit.includes(w));
    hit.forEach((w) => w.resolve(payload));
  }

  // Board is in the channel's Presence right now. Presence state arrives a
  // moment after the join, so a fresh channel may say false for ~0.5 s.
  present(): boolean {
    return Object.prototype.hasOwnProperty.call(this.ch.presenceState(), String(this.machid));
  }

  waitFor(event: string, pred: (p: Payload) => boolean, ms: number): Promise<Payload | null> {
    return new Promise((resolve) => {
      const w: Waiter = { event, pred, resolve };
      this.waiters.push(w);
      setTimeout(() => {
        if (this.waiters.includes(w)) {
          this.waiters = this.waiters.filter((x) => x !== w);
          resolve(null);
        }
      }, ms);
    });
  }

  // Resolves true as soon as the board (re)joins Presence, false on timeout.
  waitJoin(ms: number): Promise<boolean> {
    if (this.present()) return Promise.resolve(true);
    return new Promise((resolve) => {
      const w = { key: String(this.machid), resolve };
      this.joinWaiters.push(w);
      setTimeout(() => {
        if (this.joinWaiters.includes(w)) {
          this.joinWaiters = this.joinWaiters.filter((x) => x !== w);
          resolve(this.present());
        }
      }, ms);
    });
  }

  async send(event: string, payload: Payload) {
    await this.ch.send({ type: "broadcast", event, payload });
  }

  // Round trip to the board. null = no answer in time.
  async ping(ms = 3000): Promise<Payload | null> {
    const nonce = crypto.randomUUID().slice(0, 8);
    const pong = this.waitFor("pong", (p) => p.nonce === nonce, ms);
    await this.send("ping", { nonce });
    return pong;
  }

  // Sends a signed command and waits for `opened{id}`. Repeats while the
  // board is in Presence; while it is not, waits for it to rejoin. Gives up at
  // `deadline` (epoch ms). Returns the ack or null.
  async command(
    event: "open" | "service-open",
    key: string,
    id: string,
    extra: Payload,
    deadline: number,
    ackMs = 5000,
  ): Promise<Payload | null> {
    while (Date.now() < deadline) {
      if (!this.present()) {
        await this.waitJoin(Math.min(5000, deadline - Date.now()));
        continue;
      }
      const exp = Math.floor(Date.now() / 1000) + 30;
      const seconds = extra.seconds ?? "";
      const sig = await hmacHex(key, `${event}|${id}|${seconds}|${exp}`);
      const ack = this.waitFor("opened", (p) => p.id === id, Math.min(ackMs, Math.max(deadline - Date.now(), 1000)));
      await this.send(event, { ...extra, id, exp, sig });
      const got = await ack;
      if (got) return got;
    }
    return null;
  }

  async close() {
    try { await this.sb.removeChannel(this.ch); } catch (_) { /* already gone */ }
  }
}

export { sleep };
