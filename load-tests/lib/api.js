// Shared helpers for the k6 load tests: everything goes through the API gateway,
// exactly like smoke-test.sh, so routing, Eureka, JWT auth and the Feign/Kafka
// hops are all under load.
import http from 'k6/http';
import { check, fail } from 'k6';

export const GW = __ENV.GW || 'http://localhost:8080';
export const PASSWORD = 'Passw0rd!123';

const JSON_HEADERS = { 'Content-Type': 'application/json' };

export function authHeaders(token) {
  return { headers: { ...JSON_HEADERS, Authorization: `Bearer ${token}` } };
}

/** Registers a fresh user and returns its JWT. Fails the iteration on error. */
export function registerAndLogin(prefix) {
  const username = `${prefix}${Date.now()}${Math.floor(Math.random() * 1e6)}`;
  const reg = http.post(`${GW}/api/v1/users/register`, JSON.stringify({
    username, email: `${username}@example.com`, password: PASSWORD,
    firstName: 'Load', lastName: 'Test',
  }), { headers: JSON_HEADERS, tags: { name: 'register' } });
  check(reg, { 'register 201': (r) => r.status === 201 }) || fail(`register ${reg.status}`);

  const login = http.post(`${GW}/api/v1/users/login`, JSON.stringify({ username, password: PASSWORD }),
    { headers: JSON_HEADERS, tags: { name: 'login' } });
  check(login, { 'login 200': (r) => r.status === 200 }) || fail(`login ${login.status}`);
  return login.json('token');
}

/** Creates a product with plenty of stock so checkout iterations never run dry. */
export function createProduct(token, stock = 1000000) {
  const sku = `LOAD-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  const res = http.post(`${GW}/api/v1/products`, JSON.stringify({
    sku, name: `Load Test Widget ${sku}`, description: 'created by load-tests',
    price: 9.99, stockQuantity: stock, brand: 'ACME',
  }), { ...authHeaders(token), tags: { name: 'create product' } });
  check(res, { 'create product 201': (r) => r.status === 201 }) || fail(`create product ${res.status}`);
  return res.json('id');
}

/**
 * Load profiles shared by every script, picked with -e PROFILE=...
 *   smoke  – 1 VU for 30s: proves the script works, run before anything heavier
 *   load   – ramps to the expected peak and holds it
 *   stress – ramps well past the peak to find where latency/errors give way
 */
export function scenarioFor(profile, peak) {
  const ramping = (stages) => ({ executor: 'ramping-vus', startVUs: 0, stages, gracefulRampDown: '10s' });
  switch (profile) {
    case 'load':
      return ramping([{ duration: '1m', target: peak }, { duration: '3m', target: peak }, { duration: '30s', target: 0 }]);
    case 'stress':
      return ramping([
        { duration: '1m', target: peak }, { duration: '2m', target: peak * 2 },
        { duration: '2m', target: peak * 4 }, { duration: '1m', target: 0 },
      ]);
    default:
      return { executor: 'constant-vus', vus: 1, duration: '30s' };
  }
}
