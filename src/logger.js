'use strict';

const { createLogger, format, transports } = require('winston');
const path = require('path');

const { combine, timestamp, json, errors } = format;

const logger = createLogger({
  level: 'info',
  format: combine(
    timestamp({ format: 'YYYY-MM-DDTHH:mm:ss.sssZ' }),
    errors({ stack: true }),
    json()
  ),
  transports: [
    // Console transport — always on
    new transports.Console(),

    // Persistent file transports
    new transports.File({
      filename: path.join('logs', 'error.log'),
      level: 'error',
    }),
    new transports.File({
      filename: path.join('logs', 'combined.log'),
    }),
  ],
});

module.exports = logger;
