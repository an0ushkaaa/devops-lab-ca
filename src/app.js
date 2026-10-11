'use strict';

const express = require('express');
const logger = require('./logger');
const productsRouter = require('./routes/products');

const app = express();

// ── Middleware ────────────────────────────────────────────────────────────────

app.use(express.json());

/**
 * Request-logging middleware.
 * Attaches a high-resolution start time to each request, then logs
 * timestamp, method, route, status code, and response time on finish.
 */
app.use((req, res, next) => {
  const startHr = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startHr) / 1e6;

    const logData = {
      timestamp: new Date().toISOString(),
      method: req.method,
      route: req.originalUrl,
      statusCode: res.statusCode,
      responseTimeMs: parseFloat(durationMs.toFixed(3)),
    };

    if (res.statusCode >= 500) {
      logger.error('Request completed', logData);
    } else if (res.statusCode >= 400) {
      logger.warn('Request completed', logData);
    } else {
      logger.info('Request completed', logData);
    }
  });

  next();
});

// ── Routes ────────────────────────────────────────────────────────────────────

/**
 * GET /health
 * Liveness check — always returns 200.
 */
app.get('/health', (req, res) => {
  res.json({ status: 'ok', uptime: process.uptime() });
});

/**
 * GET /error
 * Intentionally throws to exercise the error-handling middleware.
 */
app.get('/error', (req, res, next) => {
  const err = new Error('Intentional error for demonstration');
  err.status = 500;
  next(err);
});

app.use('/products', productsRouter);

// ── Global error handler ──────────────────────────────────────────────────────

// Must have exactly four parameters so Express treats it as an error handler.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = err.status || 500;

  logger.error('Unhandled error', {
    message: err.message,
    stack: err.stack,
    route: req.originalUrl,
    method: req.method,
    statusCode: status,
  });

  res.status(status).json({
    error: err.message || 'Internal Server Error',
  });
});

// ── Server bootstrap ──────────────────────────────────────────────────────────

const PORT = process.env.PORT || 3000;

// Only start listening when this file is run directly (not during tests).
if (require.main === module) {
  app.listen(PORT, () => {
    logger.info(`Server listening on port ${PORT}`);
  });
}

module.exports = app;
