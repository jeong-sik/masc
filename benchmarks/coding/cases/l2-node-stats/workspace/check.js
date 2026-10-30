const assert = require('node:assert');
const { minOf, maxOf, meanOf } = require('./stats.js');

assert.strictEqual(minOf([3, 1, 2]), 1);
assert.strictEqual(maxOf([3, 1, 2]), 3);
assert.strictEqual(meanOf([2, 4, 6]), 4);
assert.strictEqual(meanOf([5]), 5);
console.log('PASS');
