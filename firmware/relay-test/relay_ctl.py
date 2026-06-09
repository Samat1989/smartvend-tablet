#!/usr/bin/env python3
"""
PC-side tester for the relay-test firmware (talks over USB-serial to the ESP32).

Install:  pip install pyserial
Usage:
  python relay_ctl.py                      # interactive shell on COM9
  python relay_ctl.py --port COM9
  python relay_ctl.py --selftest           # auto: on 0 -> wait -> off 0
  python relay_ctl.py -c "g 2 1"           # send one command and print reply

Firmware commands (see relay_test.c):
  on <ch> | off <ch> | g <pin> <0|1> | p <pin> <ms> | pins | help
"""
import sys, time, argparse, threading
import serial   # pyserial

def reader(ser, stop):
    while not stop.is_set():
        try:
            data = ser.read(256)
        except Exception:
            break
        if data:
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()

def send(ser, line):
    ser.write((line.strip() + "\n").encode())
    ser.flush()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="COM9")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("-c", "--cmd", help="send a single command, print reply, exit")
    ap.add_argument("--selftest", action="store_true",
                    help="activate then deactivate channel 0 with a pause")
    ap.add_argument("--ch", type=int, default=0)
    ap.add_argument("--hold", type=float, default=3.0, help="selftest hold seconds")
    args = ap.parse_args()

    ser = serial.Serial(args.port, args.baud, timeout=0.2)
    print(f"[OK] open {args.port} @ {args.baud}")
    time.sleep(0.3)
    ser.reset_input_buffer()

    stop = threading.Event()
    t = threading.Thread(target=reader, args=(ser, stop), daemon=True)
    t.start()

    try:
        if args.cmd:
            send(ser, args.cmd); time.sleep(1.0)
        elif args.selftest:
            print(f"\n--- selftest CH{args.ch}: ON, hold {args.hold}s, OFF ---")
            send(ser, f"on {args.ch}");  time.sleep(args.hold)
            send(ser, f"off {args.ch}"); time.sleep(1.0)
        else:
            print("type firmware commands (Ctrl+C to quit). e.g.  on 0 / off 0 / g 2 1\n")
            send(ser, "help"); time.sleep(0.3)
            while True:
                line = input()
                if line.strip() in ("quit", "exit"):
                    break
                send(ser, line)
    except (KeyboardInterrupt, EOFError):
        pass
    finally:
        stop.set(); time.sleep(0.3); ser.close()
        print("\n[bye]")

if __name__ == "__main__":
    main()
