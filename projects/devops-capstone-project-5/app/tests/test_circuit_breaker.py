"""Circuit Breaker (Devre Kesici) birim testleri.

Neden test ediyoruz?
Kaos deneylerinde (ör. Deney 02 Cassandra ağ gecikmesi ve Deney 03 RabbitMQ
ağ bölünmesi) devre kesicinin tam olarak `failure_threshold` hatadan sonra
`OPEN (2)` durumuna geçtiğini, `reset_timeout` süresi dolunca `HALF_OPEN (1)`
olduğunu ve başarılı çağrıda tekrar `CLOSED (0)` durumuna döndüğünü kanıtlar.
Hem `pytest` hem de standart `python3 -m unittest` ile doğrudan çalıştırılabilir.
"""
import unittest

from src.resilience import CLOSED, HALF_OPEN, OPEN, CircuitBreaker, CircuitOpenError


class FakeClock:
    """Zaman bağımlı devre kesici geçişlerini deterministik test etmek için sahte saat."""

    def __init__(self, initial: float = 100.0) -> None:
        self.now = initial

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


class TestCircuitBreaker(unittest.TestCase):
    def test_circuit_breaker_opens_after_threshold_and_notifies_callback(self) -> None:
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

        self.assertEqual(cb.state, CLOSED)

        def failing_op():
            raise TimeoutError("Cassandra timeout")

        # İlk 2 hatada devre hâlâ CLOSED kalmalı
        for _ in range(2):
            with self.assertRaises(TimeoutError):
                cb.call(failing_op)
            self.assertEqual(cb.state, CLOSED)

        # 3. hatada devre OPEN (2) durumuna geçmeli
        with self.assertRaises(TimeoutError):
            cb.call(failing_op)
        self.assertEqual(cb.state, OPEN)
        self.assertEqual(transitions, [("cassandra", OPEN)])

        # Devre açıkken (`OPEN`) fonksiyon hiç çağrılmadan `CircuitOpenError` fırlatılmalı (Fail-Fast)
        called = False

        def should_not_run():
            nonlocal called
            called = True
            return "ok"

        with self.assertRaises(CircuitOpenError):
            cb.call(should_not_run)
        self.assertFalse(called)

    def test_circuit_breaker_half_open_and_recovery_to_closed(self) -> None:
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
            with self.assertRaises(RuntimeError):
                cb.call(lambda: (_ for _ in ()).throw(RuntimeError("broker down")))

        self.assertEqual(cb.state, OPEN)

        # 10 saniye ileri sar -> HALF_OPEN (1)
        clock.advance(10.5)
        self.assertEqual(cb.state, HALF_OPEN)

        # Başarılı çağrı -> CLOSED (0)
        result = cb.call(lambda: "recovered")
        self.assertEqual(result, "recovered")
        self.assertEqual(cb.state, CLOSED)
        self.assertEqual(
            transitions,
            [
                ("rabbitmq", OPEN),
                ("rabbitmq", HALF_OPEN),
                ("rabbitmq", CLOSED),
            ],
        )

    def test_circuit_breaker_half_open_failure_reopens_immediately(self) -> None:
        """`HALF_OPEN` durumundaki deneme çağrısı başarısız olursa devre tek hatada
        yeniden `OPEN (2)` durumuna dönmelidir."""
        clock = FakeClock()
        cb = CircuitBreaker(name="postgres", failure_threshold=2, reset_timeout=5.0, clock=clock)

        cb.record_failure()
        cb.record_failure()
        self.assertEqual(cb.state, OPEN)

        clock.advance(5.0)
        self.assertEqual(cb.state, HALF_OPEN)

        with self.assertRaises(ConnectionError):
            cb.call(lambda: (_ for _ in ()).throw(ConnectionError("still down")))

        self.assertEqual(cb.state, OPEN)


if __name__ == "__main__":
    unittest.main()
