// Authenticated write path under load: create order → add item (order-service
// PATCHes product-service stock over Feign) → confirm (publishes order.placed
// to Kafka). Every VU logs in once and reuses its token, like a real session.
//
// Writes real rows: point it at a disposable stack, not shared data.
//
//   PROFILE=load ./run-load.sh checkout.js
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { GW, authHeaders, registerAndLogin, createProduct, scenarioFor } from './lib/api.js';

const PROFILE = __ENV.PROFILE || 'smoke';

export const options = {
  scenarios: {
    checkout: scenarioFor(PROFILE, 10),
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:create order}': ['p(95)<800'],
    'http_req_duration{name:add item}': ['p(95)<1500'], // includes the Feign hop
    'http_req_duration{name:confirm order}': ['p(95)<1000'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  const token = registerAndLogin('loadadmin');
  return { productId: createProduct(token) };
}

let token; // per-VU, survives iterations

export default function ({ productId }) {
  if (!token) token = registerAndLogin('loadvu');
  const auth = authHeaders(token);

  group('checkout', () => {
    const order = http.post(`${GW}/api/v1/orders?customerId=${__VU}`, null, { ...auth, tags: { name: 'create order' } });
    if (!check(order, { 'create order 201': (r) => r.status === 201 })) return;
    const orderId = order.json('orderId');

    const item = http.post(`${GW}/api/v1/orders/${orderId}/items`,
      JSON.stringify({ productId, quantity: 1 }), { ...auth, tags: { name: 'add item' } });
    check(item, { 'add item 200': (r) => r.status === 200 });

    const confirm = http.post(`${GW}/api/v1/orders/${orderId}/confirm`, null, { ...auth, tags: { name: 'confirm order' } });
    check(confirm, { 'confirm 200': (r) => r.status === 200 });
  });
  sleep(Math.random() * 3 + 1);
}
