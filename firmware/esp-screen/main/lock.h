// Электрозамок. Открывается только по HTTP 200 от complete-order — это
// инвариант, зашитый в прошивку реле и повторённый здесь.
#pragma once

#include <stdbool.h>

void lock_init(void);

// Держит замок открытым LOCK_OPEN_SECONDS. Возвращает false, если открывать
// нечем: нога не назначена (стенд ещё не собран).
bool lock_open(void);
