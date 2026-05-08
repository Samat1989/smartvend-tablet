import serial
import time
import struct

class M102Controller:
    def __init__(self, port, slave_addr=1):
        self.ser = serial.Serial(port, 9600, timeout=1)
        self.slave_addr = slave_addr
        self.master_addr = 0
    
    def crc16(self, data):
        # CRC-16 (Modbus) для 20 байт
        crc = 0xFFFF
        for byte in data:
            crc ^= byte
            for _ in range(8):
                if crc & 1:
                    crc = (crc >> 1) ^ 0xA001
                else:
                    crc >>= 1
        return crc.to_bytes(2, 'little')
    
    def send_command(self, cmd, data_bytes):
        # Формируем 20-байтный кадр
        frame = bytearray(20)
        frame[0] = self.slave_addr
        frame[1] = cmd
        # Заполняем данные (максимум 16 байт)
        for i, b in enumerate(data_bytes[:16]):
            frame[2 + i] = b
        # Добавляем CRC
        crc = self.crc16(frame[:-2])
        frame[-2:] = crc
        # Отправляем
        self.ser.write(frame)
        time.sleep(0.05)
        # Читаем ответ
        response = self.ser.read(20)
        return response
    
    def dispense(self, motor_num, motor_type=2):  # type: 2=двухпроводной (ваши L/C)
        """Выдать товар из ячейки motor_num (0-99)"""
        # motor_num: 0-59 для моторов, 60-99 для электромагнитов
        data = bytes([motor_num, motor_type, 0, 0, 0, 0] + [0]*10)
        response = self.send_command(0x05, data)
        if len(response) >= 3:
            result = response[2]  # Z1
            if result == 0:
                print(f"Мотор {motor_num} запущен")
                return True
            elif result == 1:
                print(f"Ошибка: неверный номер мотора {motor_num}")
            elif result == 2:
                print("Ошибка: другой мотор уже работает")
        return False
    
    def get_status(self):
        """Получить статус выполнения"""
        response = self.send_command(0x03, bytes([0]*16))
        if len(response) >= 12:
            status = response[2]  # Z1: 0=свободен, 1=выполняется, 2=завершен
            result = response[4]  # Z3: 0=успех, 1=перегруз, 2=обрыв, 3=таймаут
            # Z4-Z5: пиковый ток, Z6-Z7: средний ток, Z8-Z9: время
            if status == 2:
                print(f"Выдача завершена. Результат: {result}")
            return status, result
        return None, None

# Использование:
ctrl = M102Controller('COM6')  # замените на ваш порт

# Выдать товар из ячейки (соответствие между motor_num и L/C/H см. в таблице ниже)
ctrl.dispense(0)  # выдача из первой ячейки

# Проверить статус
status, result = ctrl.get_status()