"""Retry + Exponential Backoff + Full Jitter birim testleri.

Neden test ediyoruz?
1. Geçici ağ hatalarında (`attempts=3`) işlemin yeniden denendiğini ve başarılı
   olduğunda sonucu döndürdüğünü doğrulamak.
2. 'Full Jitter' (`backoff_delay`) formülünün `0` ile `min(cap, base * 2^attempt)`
   arasında kaldığını kanıtlamak (Thundering Herd önlemi).
3. `CircuitOpenError` fırlatıldığında retry döngüsünün boşuna beklemeden anında
   hatayı yukarı ilettiğini (fail-fast) doğrulamak.
Hem `pytest` hem de standart `python3 -m unittest` ile doğrudan çalıştırılabilir.
"""
import unittest

from src.resilience import CircuitOpenError, backoff_delay, retry


class TestRetryAndBackoff(unittest.TestCase):
    def test_backoff_delay_respects_exponential_cap_and_jitter(self) -> None:
        """Full jitter gecikmesi `rng() * min(cap, base * 2^attempt)` formülüne uymalıdır."""
        self.assertAlmostEqual(backoff_delay(0, base=0.1, cap=2.0, rng=lambda: 1.0), 0.1)
        self.assertAlmostEqual(backoff_delay(1, base=0.1, cap=2.0, rng=lambda: 1.0), 0.2)
        self.assertAlmostEqual(backoff_delay(2, base=0.1, cap=2.0, rng=lambda: 1.0), 0.4)
        # 2^6 * 0.1 = 6.4 -> cap=2.0 ile sınırlandırılmalı
        self.assertAlmostEqual(backoff_delay(6, base=0.1, cap=2.0, rng=lambda: 1.0), 2.0)
        # rng=0.5 olduğunda yarısını dönmeli
        self.assertAlmostEqual(backoff_delay(2, base=0.1, cap=2.0, rng=lambda: 0.5), 0.2)

    def test_retry_succeeds_after_transient_failures(self) -> None:
        """İlk 2 denemede hata veren fonksiyon 3. denemede başarılı olmalı ve
        arada tam 2 kez `sleep` çağrılmalıdır."""
        calls = 0
        sleeps = []

        def flaky_operation() -> str:
            nonlocal calls
            calls += 1
            if calls < 3:
                raise OSError(f"transient error #{calls}")
            return "ok"

        result = retry(
            flaky_operation,
            attempts=3,
            base=0.1,
            cap=1.0,
            sleep=lambda s: sleeps.append(s),
            rng=lambda: 0.5,
        )
        self.assertEqual(result, "ok")
        self.assertEqual(calls, 3)
        self.assertEqual(len(sleeps), 2)
        self.assertAlmostEqual(sleeps[0], 0.05)  # 0.5 * 0.1
        self.assertAlmostEqual(sleeps[1], 0.10)  # 0.5 * 0.2

    def test_retry_raises_last_exception_when_all_attempts_exhausted(self) -> None:
        """Tüm denemeler başarısız olduğunda son fırlatılan istisna yükseltilmelidir."""
        sleeps = []

        def always_fails():
            raise ValueError("permanent failure")

        with self.assertRaisesRegex(ValueError, "permanent failure"):
            retry(always_fails, attempts=3, sleep=lambda s: sleeps.append(s), rng=lambda: 1.0)

        self.assertEqual(len(sleeps), 2)

    def test_retry_does_not_retry_circuit_open_error(self) -> None:
        """Devre açıkken (`CircuitOpenError`) retry yapılmamalı, anında fail-fast çıkılmalıdır."""
        calls = 0
        sleeps = []

        def open_circuit_call():
            nonlocal calls
            calls += 1
            raise CircuitOpenError("circuit 'kafka' open")

        with self.assertRaises(CircuitOpenError):
            retry(open_circuit_call, attempts=5, sleep=lambda s: sleeps.append(s))

        self.assertEqual(calls, 1)
        self.assertEqual(sleeps, [])


if __name__ == "__main__":
    unittest.main()
