"""Circuit Breaker (Devre Kesici) birim testleri.

Neden test ediyoruz?
Kaos deneylerinde (ör. Deney 02 Cassandra ağ gecikmesi ve Deney 03 RabbitMQ
ağ bölünmesi) devre kesicinin tam olarak `failure_threshold` hatadan sonra
`OPEN (2)` durumuna geçtiğini, `reset_timeout` süresi dolunca `HALF_OPEN (1)`
olduğunu ve başarılı çağrıda tekrar `CLOSED (0)` durumuna döndüğünü kanıtlar.
"""
import pytest

from src.resilience import CLOSED, HALF_OPEN, OPEN, CircuitBreaker, CircuitOpenError


class FakeClock:
    """Zaman bağımlı devre kesici geçişlerini deterministik test etmek için sahte saat."""

    def __init__(self, initial: float = 100.0) -> None:
        self.now = initial

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_circuit_breaker_opens_after_threshold_and_notifies_callback():
    """Ardışık hatalar eşik değerine (`failure_threshold=3`) ulaştığında devre
    `OPEN (2)` olmalı ve `on_state_change` callback'i tetiklenmelidir."""
    clock = FakeClock()
    transitions = []
    cb = CircuitBreaker(
        name="cassandra",
        failure_threshold=3,
        reset_timeout=15.0,
        clock=clock,
        on_state_change=lambda name, st: transitions.append((name, st)),
    )

    assert cb.state == CLOSED

    def failing_op():
        raise TimeoutError("Cassandra timeout")

    # İlk 2 hatada devre hâlâ CLOSED kalmalı
    for _ in range(2):
        with pytest.raises(TimeoutError):
            cb.call(failing_op)
        assert cb.state == CLOSED

    # 3. hatada devre OPEN (2) durumuna geçmeli
    with pytest.raises(TimeoutError):
        cb.call(failing_op)
    assert cb.state == OPEN
    assert transitions == [("cassandra", OPEN)]

    # Devre açıkken (`OPEN`) fonksiyon hiç çağrılmadan `CircuitOpenError` fırlatılmalı (Fail-Fast)
    called = False

    def should_not_run():
        nonlocal called
        called = True
        return "ok"

    with pytest.raises(CircuitOpenError):
        cb.call(should_not_run)
    assert called is False


def test_circuit_breaker_half_open_and_recovery_to_closed():
    """`reset_timeout` süresi geçtiğinde devre `HALF_OPEN (1)` olmalı; tek bir
    başarılı çağrı devreyi tekrar `CLOSED (0)` durumuna döndürmelidir."""
    clock = FakeClock()
    transitions = []
    cb = CircuitBreaker(
        name="rabbitmq",
        failure_threshold=2,
        reset_timeout=10.0,
        clock=clock,
        on_state_change=lambda name, st: transitions.append((name, st)),
    )

    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(lambda: (_ for _ in ()).throw(RuntimeError("broker down")))

    assert cb.state == OPEN

    # 10 saniye ileri sar -> HALF_OPEN (1)
    clock.advance(10.5)
    assert cb.state == HALF_OPEN

    # Başarılı çağrı -> CLOSED (0)
    result = cb.call(lambda: "recovered")
    assert result == "recovered"
    assert cb.state == CLOSED
    assert transitions == [
        ("rabbitmq", OPEN),
        ("rabbitmq", HALF_OPEN),
        ("rabbitmq", CLOSED),
    ]


def test_circuit_breaker_half_open_failure_reopens_immediately():
    """`HALF_OPEN` durumundaki deneme çağrısı başarısız olursa devre tek hatada
    yeniden `OPEN (2)` durumuna dönmelidir."""
    clock = FakeClock()
    cb = CircuitBreaker(name="postgres", failure_threshold=2, reset_timeout=5.0, clock=clock)

    cb.record_failure()
    cb.record_failure()
    assert cb.state == OPEN

    clock.advance(5.0)
    assert cb.state == HALF_OPEN

    with pytest.raises(ConnectionError):
        cb.call(lambda: (_ for _ in ()).throw(ConnectionError("still down")))

    assert cb.state == OPEN
