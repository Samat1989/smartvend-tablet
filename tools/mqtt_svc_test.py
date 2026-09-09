#!/usr/bin/env python3
"""Стендовая проверка брокера сервисного открытия (HiveMQ Cloud).

Зачем свой клиент, а не mosquitto_pub: в системе нет ни mosquitto-clients, ни
paho-mqtt, а нужны ровно три пакета MQTT 3.1.1 — CONNECT, SUBSCRIBE, PUBLISH.
Это тот же минимум, что зашит в supabase/functions/service-open-request, так что
скрипт заодно проверяет ту самую логику на живом брокере, а не её пересказ.

Что проверяем:

  1. Учётка на чтение (svc-device) подключается и подписывается на svc/#.
  2. Учётка на запись (svc-backend) публикует туда.
  3. ВАЖНОЕ: читающая учётка опубликовать НЕ может. Если может — ACL настроен
     неверно: любая плата в парке сможет разбудить любую другую. Замок от этого
     не откроется (разрешение живёт в БД), но шуметь чужими пинками она сможет.

Примеры:

    # послушать всё, что летит в топики сервисного открытия
    python3 tools/mqtt_svc_test.py sub --user svc-device --pass '…'

    # разбудить конкретную машину так же, как это делает Edge-функция
    python3 tools/mqtt_svc_test.py pub --user svc-backend --pass '…' --machid 1234

    # проверить, что читающая учётка не имеет права публиковать
    python3 tools/mqtt_svc_test.py pub --user svc-device --pass '…' --machid 1234 \\
        --expect-denied

Хост и порт по умолчанию совпадают с зашитыми в firmware/esp-pulse/main/main.c.
"""

import argparse
import json
import os
import socket
import ssl
import sys
import time

DEFAULT_HOST = "55e988bf88a449f3a2dd612bd472230e.s1.eu.hivemq.cloud"
DEFAULT_PORT = 8883

CONNACK_REASON = {
    0: "accepted",
    1: "unacceptable protocol version",
    2: "identifier rejected",
    3: "server unavailable",
    4: "bad username or password",
    5: "not authorized",
}


def _rlen(n: int) -> bytes:
    """Remaining Length — переменная длина, 7 бит на байт."""
    out = bytearray()
    while True:
        byte = n % 128
        n //= 128
        if n:
            byte |= 0x80
        out.append(byte)
        if not n:
            return bytes(out)


def _str(s: str) -> bytes:
    b = s.encode()
    return len(b).to_bytes(2, "big") + b


def connect_packet(client_id: str, user: str, password: str, keepalive: int = 30) -> bytes:
    flags = 0xC2  # username + password + clean session
    body = (
        _str("MQTT") + bytes([0x04, flags]) + keepalive.to_bytes(2, "big")
        + _str(client_id) + _str(user) + _str(password)
    )
    return b"\x10" + _rlen(len(body)) + body


def subscribe_packet(topic_filter: str, packet_id: int = 1) -> bytes:
    body = packet_id.to_bytes(2, "big") + _str(topic_filter) + b"\x00"  # QoS 0
    return b"\x82" + _rlen(len(body)) + body


def publish_packet(topic: str, payload: str) -> bytes:
    body = _str(topic) + payload.encode()
    return b"\x30" + _rlen(len(body)) + body  # QoS 0, без packet id


def read_packet(sock, timeout=None):
    """Возвращает (тип, тело) или None по таймауту/закрытию соединения."""
    if timeout is not None:
        sock.settimeout(timeout)
    try:
        head = sock.recv(1)
    except (socket.timeout, ssl.SSLWantReadError):
        return None
    if not head:
        return None
    length, mult = 0, 1
    while True:
        b = sock.recv(1)
        if not b:
            return None
        length += (b[0] & 0x7F) * mult
        if not b[0] & 0x80:
            break
        mult *= 128
    body = b""
    while len(body) < length:
        chunk = sock.recv(length - len(body))
        if not chunk:
            return None
        body += chunk
    return head[0], body


def connect(host, port, user, password, client_id):
    raw = socket.create_connection((host, port), timeout=15)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    sock.sendall(connect_packet(client_id, user, password))
    pkt = read_packet(sock, timeout=15)
    if not pkt or (pkt[0] & 0xF0) != 0x20:
        raise SystemExit("нет CONNACK — брокер закрыл соединение")
    rc = pkt[1][1]
    if rc != 0:
        raise SystemExit(f"CONNACK rc={rc} ({CONNACK_REASON.get(rc, 'unknown')})")
    print(f"✓ подключились как {user} (client_id={client_id})")
    return sock


def cmd_sub(args):
    sock = connect(args.host, args.port, args.user, args.password, args.client_id)
    sock.sendall(subscribe_packet(args.topic))
    pkt = read_packet(sock, timeout=10)
    if not pkt or (pkt[0] & 0xF0) != 0x90:
        raise SystemExit("нет SUBACK")
    # SUBACK payload: [packet_id(2)] + по байту на топик. 0x80 = отказано.
    granted = pkt[1][2]
    if granted == 0x80:
        raise SystemExit(f"✗ подписка на {args.topic} ОТКЛОНЕНА брокером (ACL)")
    print(f"✓ подписались на {args.topic} (QoS {granted}); слушаю {args.seconds} с, Ctrl+C для выхода")

    deadline = time.time() + args.seconds
    while time.time() < deadline:
        pkt = read_packet(sock, timeout=1)
        if not pkt:
            continue
        if (pkt[0] & 0xF0) != 0x30:
            continue
        body = pkt[1]
        tlen = int.from_bytes(body[:2], "big")
        topic = body[2:2 + tlen].decode(errors="replace")
        payload = body[2 + tlen:].decode(errors="replace")
        print(f"  ← {topic}  {payload}")
    print("время вышло")


def cmd_pub(args):
    topic = args.topic or f"svc/{args.machid}/in"
    payload = args.payload or json.dumps(
        {"cmd": "service-open", "id": "bench-test", "seconds": args.seconds_open},
        ensure_ascii=False,
    )
    sock = connect(args.host, args.port, args.user, args.password, args.client_id)
    sock.sendall(publish_packet(topic, payload))
    print(f"→ {topic}  {payload}")

    # PUBLISH QoS 0 не подтверждается, поэтому отказ ACL выглядит как разрыв
    # соединения через мгновение после отправки. Ждём и смотрим, живы ли мы.
    time.sleep(1.5)
    denied = False
    try:
        sock.settimeout(1.5)
        if sock.recv(1) == b"":
            denied = True
    except (socket.timeout, ssl.SSLWantReadError):
        pass  # тишина = соединение живо = публикацию приняли
    except (ssl.SSLError, OSError):
        denied = True
    sock.close()

    if args.expect_denied:
        if denied:
            print("✓ как и ожидалось: публикация ОТКЛОНЕНА (брокер разорвал соединение)")
            return
        print("✗ ОПАСНО: этой учётке публиковать нельзя, а брокер разрешил — проверьте ACL")
        sys.exit(1)

    if denied:
        print("✗ публикация отклонена — соединение разорвано (скорее всего ACL)")
        sys.exit(1)
    print("✓ опубликовано (соединение живо)")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default=os.environ.get("MQTT_SVC_HOST", DEFAULT_HOST))
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    # Через переменные окружения, а не только аргументами: пароли содержат
    # $ } # ~ и прочее, что в argv приходится экранировать, а один промах
    # означает «брокер отказал» вместо настоящего результата проверки.
    #   set -a; . ~/svc-backend.env; set +a; python3 tools/mqtt_svc_test.py pub …
    p.add_argument("--user", default=os.environ.get("MQTT_SVC_USER"))
    p.add_argument("--pass", dest="password", default=os.environ.get("MQTT_SVC_PASS"))
    p.add_argument("--client-id", default=f"bench-{os.getpid()}")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("sub", help="подписаться и печатать входящее")
    s.add_argument("--topic", default="svc/#")
    s.add_argument("--seconds", type=int, default=60, help="сколько слушать")
    s.set_defaults(func=cmd_sub)

    q = sub.add_parser("pub", help="опубликовать пинок сервисного открытия")
    q.add_argument("--machid", help="номер аппарата (топик svc/<machid>/in)")
    q.add_argument("--topic", help="топик целиком, вместо --machid")
    q.add_argument("--payload", help="произвольное тело вместо стандартного пинка")
    q.add_argument("--seconds-open", type=int, default=180, help="поле seconds в пинке")
    q.add_argument("--expect-denied", action="store_true",
                   help="успех = брокер ОТКАЗАЛ в публикации (проверка ACL читающей учётки)")
    q.set_defaults(func=cmd_pub)

    args = p.parse_args()
    if not args.user or not args.password:
        p.error("нужны --user/--pass или MQTT_SVC_USER/MQTT_SVC_PASS в окружении")
    if args.cmd == "pub" and not args.machid and not args.topic:
        p.error("нужен --machid или --topic")
    args.func(args)


if __name__ == "__main__":
    main()
