'use strict';

const request = require('supertest');
const app = require('../src/app');

// ── GET /health ───────────────────────────────────────────────────────────────

describe('GET /health', () => {
  it('returns 200 with status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('status', 'ok');
    expect(res.body).toHaveProperty('uptime');
    expect(typeof res.body.uptime).toBe('number');
  });
});

// ── GET /products ─────────────────────────────────────────────────────────────

describe('GET /products', () => {
  it('returns 200 with a products array', async () => {
    const res = await request(app).get('/products');
    expect(res.status).toBe(200);
    expect(res.body).toHaveProperty('products');
    expect(Array.isArray(res.body.products)).toBe(true);
  });

  it('each product has id, name, and price', async () => {
    const res = await request(app).get('/products');
    res.body.products.forEach((p) => {
      expect(p).toHaveProperty('id');
      expect(p).toHaveProperty('name');
      expect(p).toHaveProperty('price');
    });
  });
});

// ── POST /products ────────────────────────────────────────────────────────────

describe('POST /products', () => {
  it('creates a product and returns 201', async () => {
    const payload = { name: 'Test Widget', price: 4.99 };
    const res = await request(app).post('/products').send(payload);
    expect(res.status).toBe(201);
    expect(res.body).toHaveProperty('product');
    expect(res.body.product).toMatchObject(payload);
    expect(res.body.product).toHaveProperty('id');
  });

  it('returns 400 when name is missing', async () => {
    const res = await request(app).post('/products').send({ price: 5.0 });
    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  it('returns 400 when price is missing', async () => {
    const res = await request(app).post('/products').send({ name: 'No Price' });
    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  it('returns 400 when price is negative', async () => {
    const res = await request(app)
      .post('/products')
      .send({ name: 'Bad Price', price: -1 });
    expect(res.status).toBe(400);
    expect(res.body).toHaveProperty('error');
  });

  it('new product appears in GET /products', async () => {
    const payload = { name: 'Persistence Check', price: 1.0 };
    await request(app).post('/products').send(payload);
    const listRes = await request(app).get('/products');
    const names = listRes.body.products.map((p) => p.name);
    expect(names).toContain(payload.name);
  });
});

// ── GET /error ────────────────────────────────────────────────────────────────

describe('GET /error', () => {
  it('returns 500 with an error message', async () => {
    const res = await request(app).get('/error');
    expect(res.status).toBe(500);
    expect(res.body).toHaveProperty('error');
    expect(typeof res.body.error).toBe('string');
  });

  it('error message is not empty', async () => {
    const res = await request(app).get('/error');
    expect(res.body.error.length).toBeGreaterThan(0);
  });
});
