import serial
import time
import struct
import sys

# Попытка настроить кодировку для корректного вывода в Windows CMD
if sys.platform == 'win32':
    try:
        import codecs
        sys.stdout.reconfigure(encoding='utf-8')
    except:
        pass

class M102Controller:
    def __init__(self, port, slave_addr=1):
        """
        Инициализация контроллера M102.
        :param port: COM-порт (например, 'COM6' или '/dev/ttyUSB0')
        :param slave_addr: Адрес платы (по умолчанию 1)
        """
        try:
            self.ser = serial.Serial(port, 9600, timeout=1)
            print(f"[OK] Подключено к {port}")
        except Exception as e:
            print(f"[ERR] Ошибка подключения к {port}: {e}")
            raise
        self.slave_addr = slave_addr
        self.master_addr = 0

    def crc16(self, data):
        """Расчет CRC-16 (Modbus) для протокола M102"""
        crc = 0xFFFF
        for byte in data:
            crc ^= byte
            for _ in range(8):
                if crc & 1:
                    crc = (crc >> 1) ^ 0xA001
                else:
                    crc >>= 1
        return crc.to_bytes(2, 'little')

    def send_command(self, cmd, data_bytes=None):
        """Отправка 20-байтного кадра и получение ответа"""
        if data_bytes is None:
            data_bytes = [0] * 16
        
        frame = bytearray(20)
        frame[0] = self.slave_addr
        frame[1] = cmd
        
        # Заполнение данных (16 байт)
        for i in range(min(len(data_bytes), 16)):
            frame[2 + i] = data_bytes[i]
            
        # CRC на первые 18 байт
        crc = self.crc16(frame[:-2])
        frame[-2:] = crc
        
        # Очистка буфера перед отправкой
        self.ser.reset_input_buffer()
        self.ser.write(frame)
        
        # Ожидание 50мс по документации
        time.sleep(0.05)
        
        # Чтение ответа (20 байт)
        response = self.ser.read(20)
        if len(response) < 20:
            return None
        return response

    def get_id(self):
        """Инструкция 01H: Получить серийный номер (ID)"""
        response = self.send_command(0x01)
        if response:
            # Z1-Z12: серийный номер
            sn_bytes = response[2:14]
            # Декодируем аккуратно, игнорируя непечатные символы
            sn = "".join([chr(b) for b in sn_bytes if 32 <= b <= 126]).strip()
            return sn
        return None

    def motor_run(self, motor_idx, motor_type=2, light_curtain=0):
        """
        Инструкция 05H: Запуск мотора.
        :param motor_idx: 00-59 (моторы), 60-99 (замки)
        :param motor_type: 0=без обр.связи, 1=с обр.связью, 2=2-проводной, 3=3-проводной
        :param light_curtain: 0=без датчика, 1=самопроверка, 2=стоп по падению
        """
        # Y1=idx, Y2=type, Y3=curtain, Y4=overcurrent, Y5=undercurrent, Y6=timeout
        data = [motor_idx, motor_type, light_curtain, 0, 0, 0] + [0]*10
        response = self.send_command(0x05, data)
        if response:
            res = response[2] # Z1
            if res == 0:
                return "Started"
            elif res == 1:
                return "Invalid Index"
            elif res == 2:
                return "Busy"
        return "No Response"

    def motor_poll(self):
        """Инструкция 03H: Опрос состояния мотора"""
        response = self.send_command(0x03)
        if response:
            status = response[2]  # Z1: 0=Idle, 1=Running, 2=Done
            motor_num = response[3] # Z2
            result = response[4]   # Z3: 0=OK, 1=Overload, 2=Underflow, 3=Timeout, 4=LightCurtainErr
            
            # Токи и время (16-битные, big-endian в пакете согласно доке Z4-Z9)
            peak_curr = int.from_bytes(response[5:7], 'big')
            avg_curr = int.from_bytes(response[8:10], 'big')
            run_time = int.from_bytes(response[10:12], 'big')
            # Z10: статус завесы (0=нет, 1-200 время падения)
            curtain_stat = response[12]
            
            return {
                "status": status,
                "motor": motor_num,
                "result": result,
                "peak_mA": peak_curr,
                "avg_mA": avg_curr,
                "time_ms": run_time,
                "status_10": curtain_stat
            }
        return None

    def motor_scan(self, motor_idx):
        """Инструкция 04H: Тест мотора (Motor Scan)"""
        data = [motor_idx] + [0]*15
        response = self.send_command(0x04, data)
        if response:
            res_code = response[2]
            res_map = {0xAA: "Normal", 0xBB: "Abnormal", 0xCC: "Overload"}
            return res_map.get(res_code, f"Unknown ({hex(res_code)})")
        return "No Response"

    def read_temp(self):
        """Инструкция 07H: Чтение температуры"""
        response = self.send_command(0x07)
        if response:
            # Z1-Z2: 16-бит целое (value * 10)
            temp_val = int.from_bytes(response[2:4], 'big', signed=True)
            return temp_val / 10.0
        return None

    def write_do(self, do_idx, state):
        """Инструкция 08H: Управление выходом (DO)"""
        # Y1=index (0-6), Y2=1(ON)/0(OFF)
        data = [do_idx, 1 if state else 0] + [0]*14
        response = self.send_command(0x08, data)
        if response:
            # Z2 = Y2 + F0 -> 0x00->0xF0, 0x01->0xF1
            res_code = response[3]
            return res_code in [0xF0, 0xF1]
        return False

    def read_di(self):
        """Инструкция 09H: Чтение входов (DI)"""
        response = self.send_command(0x09)
        if response:
            # Z1-Z4 == DI1-DI4 (1=connected, 0=disconnected)
            return [response[2], response[3], response[4], response[5]]
        return None

    def dispense_and_wait(self, motor_idx, motor_type=2, curtain=0):
        """Запуск и ожидание завершения с выводом прогресса"""
        print(f"\n--- [ACTION] Запуск мотора {motor_idx} (Тип: {motor_type}, Завеса: {curtain}) ---")
        res = self.motor_run(motor_idx, motor_type, curtain)
        if res != "Started":
            print(f"[ERR] Ошибка запуска: {res}")
            return False
        
        print("Мотор запущен, ожидание завершения...")
        start_time = time.time()
        last_poll_time = 0
        while True:
            if time.time() - last_poll_time >= 0.5:
                poll = self.motor_poll()
                last_poll_time = time.time()
                
                if not poll:
                    print("[!] Нет ответа от платы (таймаут опроса)")
                    break
                    
                if poll['status'] == 2: # Done
                    print(f"\n[FINISH] Выполнение завершено!")
                    print(f"Результат: {self._get_result_desc(poll['result'])}")
                    print(f"Ток (пик/сред): {poll['peak_mA']}/{poll['avg_mA']} mA")
                    print(f"Время работы: {poll['time_ms']} ms")
                    if curtain > 0:
                        print(f"Статус завесы: {'Товар упал' if poll['status_10'] > 0 else 'Нет падения'} ({poll['status_10']} ms)")
                    return poll['result'] == 0
                
                elif poll['status'] == 0: # Idle
                    if time.time() - start_time > 1.5: # Даем время на старт
                        print("\n[?] Плата вернулась в Idle без завершения")
                        break
                
                print(f".", end="", flush=True)
            
            time.sleep(0.1)
        return False

    def motor_scan_all(self, limit=60):
        """Сканирование всех моторов по очереди"""
        print(f"\n--- [ACTION] Сканирование всех моторов (0-{limit-1}) ---")
        found = []
        for i in range(limit):
            res = self.motor_scan(i)
            if res == "Normal":
                print(f"Мотор {i:02d}: OK")
                found.append(i)
            elif res == "Overload":
                print(f"Мотор {i:02d}: OVERLOAD")
                found.append(i)
            # Abnormal обычно значит не подключен, не выводим для краткости
            if i % 10 == 9:
                print(f"Проверено {i+1}...")
        
        print(f"\n[INFO] Найдено активных моторов: {len(found)}")
        return found

    def set_address(self, new_addr):
        """Инструкция FFH: Изменение адреса платы (нужно подключать по одной!)"""
        if not (1 <= new_addr <= 8):
            print("Адрес должен быть от 1 до 8")
            return False
            
        print(f"--- [CAUTION] Смена адреса платы на {new_addr} ---")
        print("Убедитесь, что подключена только ОДНА плата!")
        
        # Используем широковещательный адрес 255 (0xFF)
        old_slave = self.slave_addr
        self.slave_addr = 0xFF
        data = [new_addr] + [0]*15
        response = self.send_command(0xFF, data)
        self.slave_addr = old_slave # Возвращаем старый
        
        if response:
            print(f"[OK] Адрес изменен. Подтвердите визуально (мигание светодиода {new_addr} раз)")
            self.slave_addr = new_addr
            return True
        return False

    def _get_result_desc(self, res):
        descs = {
            0: "Успешно (OK)",
            1: "Перегрузка (Overload/Jam)",
            2: "Обрыв (Underflow/No Load)",
            3: "Таймаут (Timeout)",
            4: "Ошибка световой завесы",
            5: "Замок не открылся"
        }
        return descs.get(res, f"Неизвестный код {res}")

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="M102 Vending Controller CLI")
    parser.add_argument("--port", default="COM6", help="COM port (default: COM6)")
    parser.add_argument("--motor", type=int, help="Motor index to run (0-99)")
    parser.add_argument("--type", type=int, default=2, help="Motor type (0=lock, 2=2-wire, 3=3-wire)")
    parser.add_argument("--curtain", type=int, default=0, help="Light curtain mode (0-2)")
    parser.add_argument("--scan", type=int, help="Scan motor index for errors")
    parser.add_argument("--scan-all", action="store_true", help="Scan all 60 motors")
    parser.add_argument("--info", action="store_true", help="Show board info and temp")
    parser.add_argument("--di", action="store_true", help="Read digital inputs status")
    parser.add_argument("--monitor-di", action="store_true", help="Monitor digital inputs in real-time")
    parser.add_argument("--do", nargs=2, metavar=('INDEX', 'STATE'), help="Write digital output (e.g. --do 0 1)")
    parser.add_argument("--set-addr", type=int, help="Change board address (1-8)")
    parser.add_argument("--scan-addr", action="store_true", help="Scan addresses 1-8 to find connected boards")
    
    args = parser.parse_args()
    
    try:
        if args.scan_addr:
            print("--- [SCAN] Перебор адресов 1-8 ---")
            found_any = False
            ctrl = M102Controller(args.port)
            for addr in range(1, 9):
                ctrl.slave_addr = addr
                sn = ctrl.get_id()
                if sn:
                    print(f"[FOUND] Адрес {addr}: ID = {sn}")
                    found_any = True
                else:
                    print(f"Адрес {addr}: нет ответа")
                time.sleep(0.1)
            if not found_any:
                print("\n[!] Платы не найдены ни на одном адресе.")
                print("    Проверьте: питание платы, GND, TX/RX (не перепутаны ли),")
                print("    отключите RS485-клеммы A/B на время теста TTL.")
            sys.exit(0)

        ctrl = M102Controller(args.port)

        if args.info or (len(sys.argv) == 1):
            sn = ctrl.get_id()
            print(f"ID платы: {sn if sn else 'н/д'}")
            temp = ctrl.read_temp()
            print(f"Температура: {temp if temp is not None else 'н/д'}°C")
            
        if args.set_addr:
            ctrl.set_address(args.set_addr)

        if args.di:
            inputs = ctrl.read_di()
            if inputs:
                print(f"Входы (DI1-DI4): {inputs}")
            else:
                print("Не удалось прочитать входы")

        if args.monitor_di:
            print("--- [MONITOR] Отслеживание входов (Ctrl+C для выхода) ---")
            last_inputs = None
            while True:
                inputs = ctrl.read_di()
                if inputs and inputs != last_inputs:
                    print(f"Изменение: {inputs}")
                    last_inputs = inputs
                time.sleep(0.1)

        if args.do:
            idx = int(args.do[0])
            state = int(args.do[1])
            if ctrl.write_do(idx, state):
                print(f"Выход {idx} установлен в {state}")
            else:
                print(f"Ошибка при записи выхода {idx}")

        if args.scan_all:
            ctrl.motor_scan_all()

        elif args.scan is not None:
            res = ctrl.motor_scan(args.scan)
            print(f"Результат сканирования мотора {args.scan}: {res}")

        if args.motor is not None:
            ctrl.dispense_and_wait(args.motor, motor_type=args.type, curtain=args.curtain)
            
    except KeyboardInterrupt:
        print("\nМониторинг завершен")
    except Exception as e:
        print(f"\nОшибка: {e}")
