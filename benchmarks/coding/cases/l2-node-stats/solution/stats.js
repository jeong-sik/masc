function minOf(values) {
  return Math.min(...values);
}

function maxOf(values) {
  return Math.max(...values);
}

function meanOf(values) {
  return values.reduce((a, b) => a + b, 0) / values.length;
}

module.exports = { minOf, maxOf, meanOf };
