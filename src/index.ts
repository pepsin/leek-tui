#!/usr/bin/env node
import { run } from './main.js';

run().catch((err) => {
  console.error(err);
  process.exit(1);
});
