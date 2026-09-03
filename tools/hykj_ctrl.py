#!/usr/bin/env python3
"""Стенд для ручной проверки облака Hykj (умный холодильник).

Проверяет по шагам: подпись -> связь -> открытие замка -> состав заказа -> видео.
Спецификация: ShowDoc-выгрузка вендора, BASE_URL /locker-minimerchant/interface.
Интеграция целиком: docs/smartfridge-hykj-integration.md

Доступы берутся из окружения (в git не класть):
    HYKJ_MERCHANT_NO   Me00000000
    HYKJ_PRIVATE_KEY   путь к PEM с приватным RSA-ключом мерчанта
    HYKJ_CABINET       cabinetSerialNumber (W...) или readyNumber (WE...)
    HYKJ_DOOR          номер двери, по умолчанию 1
    HYKJ_BASE_URL      по умолчанию https://m.hykj.cn/locker-minimerchant/interface

Команды:
    cabinets                  список шкафов          (только чтение)
    status                    статус и температура    (только чтение)
    goods                     товары мерчанта         (только чтение)
    order <orderNo>           состав и сумма заказа   (только чтение)
    video <orderNo>           ссылки на видео заказа  (только чтение)
    open --yes-open-door      СОЗДАЁТ ЗАКАЗ И ОТКРЫВАЕТ ЗАМОК

Подпись (§«签名(sign)算法»): параметры по возрастанию имени -> JSON без null ->
MD5withRSA приватным ключом -> заголовок Authorization. Точная форма строки в
документации описана неоднозначно, поэтому вариант выбирается --sign-variant:
    body   (по умолчанию) подписывается всё тело {nonce,timestamp,value}
    value  подписывается только объект value
Если приходит 50001 — пробовать второй вариант и спрашивать вендора.
"""

import argparse
import base64
import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

import requests
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

# Вендор живёт в UTC+8, все его метки времени в этой зоне (док §11).
CN = timezone(timedelta(hours=8))


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"[ERR] не задана переменная окружения {name}")
    return v


def load_key(path):
    try:
        with open(path, "rb") as f:
            return serialization.load_pem_private_key(f.read(), password=None)
    except Exception as e:
        sys.exit(f"[ERR] не читается приватный ключ {path}: {e}")


def canonical(obj):
    """JSON с сортировкой ключей на всех уровнях и выброшенными null."""
    if isinstance(obj, dict):
        return {k: canonical(v) for k, v in sorted(obj.items()) if v is not None}
    if isinstance(obj, list):
        return [canonical(v) for v in obj]
    return obj


def sign(key, payload, variant):
    target = payload if variant == "body" else payload["value"]
    raw = json.dumps(canonical(target), ensure_ascii=False,
                     separators=(",", ":"), sort_keys=True).encode()
    sig = key.sign(raw, padding.PKCS1v15(), hashes.MD5())
    return base64.b64encode(sig).decode(), raw


def call(args, path, value, key):
    payload = {
        "nonce": uuid.uuid4().hex[:24],
        "timestamp": int(time.time() * 1000),
        "value": value,
    }
    authorization, signed = sign(key, payload, args.sign_variant)
    url = f"{args.base_url.rstrip('/')}{path}"

    if args.verbose:
        print(f"[>] POST {url}")
        print(f"[>] подписано: {signed.decode()}")

    try:
        resp = requests.post(
            url,
            json=payload,
            headers={"Content-Type": "application/json",
                     "Authorization": authorization},
            timeout=args.timeout,
        )
    except requests.RequestException as e:
        sys.exit(f"[ERR] сеть до {url}: {e}")

    print(f"[<] HTTP {resp.status_code} за {resp.elapsed.total_seconds():.2f} с")
    try:
        body = resp.json()
    except ValueError:
        sys.exit(f"[ERR] не JSON в ответе: {resp.text[:400]}")

    code = str(body.get("code"))
    if code != "00000":
        hint = {
            "50001": "подпись или мерчант — попробовать --sign-variant value",
            "20001": "параметры: проверить cabinetSerialNumber и doorNumber",
            "30001": "ресурс не найден: шкаф или заказ не принадлежит мерчанту",
            "30002": "такой orderNo уже создан — взять новый",
            "60001": "ограничение вендора (для видео — не чаще раза в 5 минут)",
        }.get(code, "")
        print(f"[ERR] code={code} msg={body.get('msg')}" + (f"  ({hint})" if hint else ""))
    print(json.dumps(body, ensure_ascii=False, indent=2))
    return body


def cmd_cabinets(args, key):
    call(args, "/cabinet/queryList", {"merchantNo": args.merchant_no, "productNo": "WEIGHING_CABINET"}, key)


def cmd_status(args, key):
    call(args, "/cabinet/cabinetStatusPage",
         {"merchantNo": args.merchant_no, "productNo": "WEIGHING_CABINET", "pageNum": 1, "pageSize": 20}, key)


def cmd_goods(args, key):
    call(args, "/weightGoods/queryPage",
         {"merchantNo": args.merchant_no, "pageNum": 1, "pageSize": 20}, key)


def cmd_order(args, key):
    call(args, "/order/query",
         {"merchantNo": args.merchant_no, "orderNo": args.order_no}, key)


def cmd_video(args, key):
    print("[i] видео снимается с устройства асинхронно; повторный запрос по"
          " тому же заказу — не чаще одного раза в 5 минут")
    call(args, "/order/orderVideo",
         {"merchantNo": args.merchant_no, "orderNo": args.order_no}, key)


def cmd_open(args, key):
    order_no = args.order_no or ("W" + datetime.now(CN).strftime("%Y%m%d%H%M%S"))
    value = {
        "merchantNo": args.merchant_no,
        "productNo": args.product_no,
        "orderNo": order_no,
        "cabinetSerialNumber": args.cabinet,
        "doorNumber": args.door,
        "orderCreateTime": datetime.now(CN).strftime("%Y-%m-%d %H:%M:%S"),
        "payType": "MERCHANT_SELF_OPERATED_ORDER",
        "operateType": args.operate_type,
    }
    print(f"[i] заказ {order_no}, шкаф {args.cabinet}, дверь {args.door},"
          f" тип {args.operate_type}")
    body = call(args, "/order/create", value, key)

    if str(body.get("code")) == "00000":
        print("\n[OK] замок должен открыться. Дальше:")
        print("     1. забрать товар и закрыть дверь")
        print(f"     2. состав заказа:  {sys.argv[0]} order {order_no}")
        print(f"     3. видео (>5 мин): {sys.argv[0]} video {order_no}")
        print("     Колбэк status/notify тут не виден — состав смотреть через order.")


def main():
    p = argparse.ArgumentParser(description="Стенд Hykj: замок, заказы, видео")
    p.add_argument("--base-url", default=env("HYKJ_BASE_URL",
                   "https://m.hykj.cn/locker-minimerchant/interface"))
    p.add_argument("--merchant-no", default=env("HYKJ_MERCHANT_NO"))
    p.add_argument("--key", default=env("HYKJ_PRIVATE_KEY"))
    p.add_argument("--cabinet", default=env("HYKJ_CABINET"))
    p.add_argument("--door", type=int, default=int(env("HYKJ_DOOR", "1")))
    p.add_argument("--product-no", default="WEIGHING_ORDER",
                   choices=["WEIGHING_ORDER", "VISUAL"])
    p.add_argument("--operate-type", default="OPERATOR",
                   choices=["OPERATOR", "SHOPPING"],
                   help="OPERATOR — пополнение (по умолчанию, безопаснее для теста),"
                        " SHOPPING — покупка")
    p.add_argument("--sign-variant", default="body", choices=["body", "value"])
    p.add_argument("--timeout", type=float, default=15)
    p.add_argument("-v", "--verbose", action="store_true")

    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("cabinets")
    sub.add_parser("status")
    sub.add_parser("goods")
    for name in ("order", "video"):
        s = sub.add_parser(name)
        s.add_argument("order_no")
    s = sub.add_parser("open")
    s.add_argument("--yes-open-door", action="store_true")
    s.add_argument("--order-no", help="по умолчанию W + время UTC+8")

    args = p.parse_args()
    if not args.merchant_no or not args.key:
        sys.exit("[ERR] нужны HYKJ_MERCHANT_NO и HYKJ_PRIVATE_KEY (или --merchant-no/--key)")
    if args.cmd == "open" and not args.yes_open_door:
        sys.exit("[STOP] эта команда физически открывает замок холодильника.\n"
                 "       Запускать, только стоя у шкафа, с флагом --yes-open-door")
    if args.cmd == "open" and not args.cabinet:
        sys.exit("[ERR] нужен HYKJ_CABINET — серийный номер шкафа (W...) или номер на точке (WE...)")

    key = load_key(args.key)
    {"cabinets": cmd_cabinets, "status": cmd_status, "goods": cmd_goods,
     "order": cmd_order, "video": cmd_video, "open": cmd_open}[args.cmd](args, key)


if __name__ == "__main__":
    main()
