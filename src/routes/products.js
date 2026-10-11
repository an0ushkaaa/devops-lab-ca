'use strict';

const { Router } = require('express');
const logger = require('../logger');

const router = Router();

// In-memory product store (resets on restart — fine for a lab)
const products = [
  { id: 1, name: 'Widget A', price: 9.99 },
  { id: 2, name: 'Widget B', price: 19.99 },
];
let nextId = products.length + 1;

/**
 * GET /products
 * Returns the full list of products.
 */
router.get('/', (req, res) => {
  logger.info('Fetching all products', { count: products.length });
  res.json({ products });
});

/**
 * POST /products
 * Creates a new product.
 * Body: { name: string, price: number }
 */
router.post('/', (req, res) => {
  const { name, price } = req.body;

  if (!name || price === undefined) {
    logger.warn('POST /products — missing required fields', { body: req.body });
    return res.status(400).json({ error: 'name and price are required' });
  }

  if (typeof price !== 'number' || price < 0) {
    logger.warn('POST /products — invalid price', { price });
    return res.status(400).json({ error: 'price must be a non-negative number' });
  }

  const product = { id: nextId++, name: String(name).trim(), price };
  products.push(product);

  logger.info('Product created', { product });
  res.status(201).json({ product });
});

module.exports = router;
