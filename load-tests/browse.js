// Anonymous read traffic — the bulk of real storefront load: product list,
// categories, a product page and catalog search (MongoDB read model).
//
//   ./run-load.sh browse.js                 # smoke profile
//   PROFILE=load ./run-load.sh browse.js
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { GW, adminLogin, createProduct, scenarioFor } from './lib/api.js';

const PROFILE = __ENV.PROFILE || 'smoke';

export const options = {
  scenarios: {
    browse: scenarioFor(PROFILE, 50),
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:list products}': ['p(95)<500'],
    'http_req_duration{name:product by id}': ['p(95)<300'],
    'http_req_duration{name:catalog search}': ['p(95)<500'],
    checks: ['rate>0.99'],
  },
};

// One product synced into the catalog so the by-id and search reads hit real data.
export function setup() {
  const productId = createProduct(adminLogin());
  http.post(`${GW}/api/v1/catalog/sync/${productId}`, null,
    { headers: { Authorization: `Bearer ${token}` }, tags: { name: 'catalog sync' } });
  return { productId };
}

export default function ({ productId }) {
  group('browse', () => {
    const list = http.get(`${GW}/api/v1/products`, { tags: { name: 'list products' } });
    check(list, { 'list products 200': (r) => r.status === 200 });

    const cats = http.get(`${GW}/api/v1/categories`, { tags: { name: 'list categories' } });
    check(cats, { 'categories 200': (r) => r.status === 200 });

    const one = http.get(`${GW}/api/v1/products/${productId}`, { tags: { name: 'product by id' } });
    check(one, { 'product 200': (r) => r.status === 200 });

    const search = http.get(`${GW}/api/v1/catalog/search?q=Load`, { tags: { name: 'catalog search' } });
    check(search, { 'catalog search 200': (r) => r.status === 200 });
  });
  sleep(Math.random() * 2 + 0.5); // think time
}
