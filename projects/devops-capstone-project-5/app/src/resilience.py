"""Dayanıklılık (resilience) yapı taşları: retry + exponential backoff + jitter ve circuit breaker.

Neden prod'da böyle?
- Retry'sız sistem geçici ağ hıçkırıklarında hata verir.
- Jitter'sız retry, yüzlerce pod'un AYNI anda tekrar denemesine (thundering herd) yol açar.
- Circuit breaker, ölü bir bağımlılığa sürekli istek atıp thread/bağlantı tüketmeyi engeller
  ve hatayı hızlıca (fail-fast) döndürür.
"""
import random
import threading
import time
from typing import Callable, Optional, Tuple, Type, TypeVar

T = TypeVar("T")

CLOSED, HALF_OPEN, OPEN = 0, 1, 2  # rs_circuit_breaker_state değerleriyle aynı


class CircuitOpenError(Exception):
    """Devre açıkken çağrı hiç denenmeden reddedilir."""


def backoff_delay(attempt: int, base: float = 0.1, cap: float = 2.0,
                  rng: Callable[[], float] = random.random) -> float:
    """'Full jitter' (AWS mimari bloğu): delay = random(0, min(cap, base*2^attempt))."""
    return rng() * min(cap, base * (2 ** attempt))


def retry(fn: Callable[[], T], attempts: int = 3, base: float = 0.1, cap: float = 2.0,
          exceptions: Tuple[Type[BaseException], ...] = (Exception,),
          sleep: Callable[[float], None] = time.sleep,
          rng: Callable[[], float] = random.random) -> T:
    """fn'i en fazla `attempts` kez dener; denemeler arasında jitter'lı bekler.
    CircuitOpenError tekrar denenmez: devre açıkken beklemek anlamsızdır."""
    last: Optional[BaseException] = None
    for i in range(attempts):
        try:
            return fn()
        except CircuitOpenError:
            raise
        except exceptions as exc:  # noqa: PERF203
            last = exc
            if i < attempts - 1:
                sleep(backoff_delay(i, base, cap, rng))
    assert last is not None
    raise last


class CircuitBreaker:
    """Basit üç durumlu devre kesici.

    CLOSED   -> normal; ardışık `failure_threshold` hata olursa OPEN.
    OPEN     -> `reset_timeout` saniye boyunca çağrı reddedilir.
    HALF_OPEN-> süre dolunca tek deneme; başarılıysa CLOSED, değilse yeniden OPEN.
    """

    def __init__(self, name: str, failure_threshold: int = 5, reset_timeout: float = 15.0,
                 clock: Callable[[], float] = time.monotonic,
                 on_state_change: Optional[Callable[[str, int], None]] = None):
        self.name = name
        self.failure_threshold = failure_threshold
        self.reset_timeout = reset_timeout
        self._clock = clock
        self._on_change = on_state_change
        self._lock = threading.Lock()
        self._failures = 0
        self._opened_at = 0.0
        self._state = CLOSED

    def _set(self, state: int) -> None:
        if state != self._state:
            self._state = state
            if self._on_change:
                self._on_change(self.name, state)

    @property
    def state(self) -> int:
        with self._lock:
            if self._state == OPEN and self._clock() - self._opened_at >= self.reset_timeout:
                self._set(HALF_OPEN)
            return self._state

    def call(self, fn: Callable[[], T]) -> T:
        if self.state == OPEN:
            raise CircuitOpenError(f"circuit '{self.name}' open")
        try:
            result = fn()
        except Exception:
            self.record_failure()
            raise
        self.record_success()
        return result

    def record_success(self) -> None:
        with self._lock:
            self._failures = 0
            self._set(CLOSED)

    def record_failure(self) -> None:
        with self._lock:
            self._failures += 1
            if self._state == HALF_OPEN or self._failures >= self.failure_threshold:
                self._opened_at = self._clock()
                self._set(OPEN)
