// =====================================================================
// k6 "Black Friday" yük testi — POST /api/orders
// Çalıştırma:
//   k6 run -e BASE_URL=http://app.<APP_IP>.nip.io chaos/load/k6-black-friday.js
// Lab kotası küçük (order-api 2 replica, 2 vCPU node) → hedef 20 VU yeterli.
// =====================================================================
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';
const errorRate = new Rate('order_errors');

export const options = {
  // Isınma → zirve → sürdürme → soğuma (toplam ~16 dk, workflow 09 ile örtüşür)
  stages: [
    { duration: '1m', target: 5 },
    { duration: '2m', target: 20 },
    { duration: '12m', target: 20 },
    { duration: '1m', target: 0 },
  ],
  // SLO'lar: k6 kırmızı biterse game day hipotezi çürümüştür
  thresholds: {
    http_req_failed: ['rate<0.01'],          // %99 başarı
    http_req_duration: ['p(99)<1000'],       // p99 < 1 sn
    order_errors: ['rate<0.01'],
  },
};

export default function () {
  const payload = JSON.stringify({
    customer_id: `cust-${Math.floor(Math.random() * 1000)}`,
    product_id: `sku-${Math.floor(Math.random() * 50)}`,
    quantity: 1 + Math.floor(Math.random() * 3),
    amount: Number((10 + Math.random() * 490).toFixed(2)),
  });

  const res = http.post(`${BASE_URL}/api/orders`, payload, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '5s',
    tags: { endpoint: '/api/orders' },
  });

  const ok = check(res, {
    'status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  errorRate.add(!ok);

  sleep(0.5 + Math.random()); // Gerçek kullanıcı "düşünme süresi"
}
