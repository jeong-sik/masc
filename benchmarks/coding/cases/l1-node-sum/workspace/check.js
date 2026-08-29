const assert = require('node:assert');
const { sumUpTo } = require('./sum.js');

assert.strictEqual(sumUpTo(1), 1);
assert.strictEqual(sumUpTo(4), 10);
assert.strictEqual(sumUpTo(10), 55);
console.log('PASS');
