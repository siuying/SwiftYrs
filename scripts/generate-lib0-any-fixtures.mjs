import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as encoding from 'lib0/encoding'

const root = dirname(dirname(fileURLToPath(import.meta.url)))

// Canonical lib0 `writeAny` encodings. Restricted to values with a single,
// deterministic byte representation (scalars, arrays, single-key maps) so the
// Swift side can assert byte-exact wire parity. Multi-key maps have undefined
// key order across implementations and are covered by value-level round-trips.
const values = [
  { name: 'string', value: 'hello' },
  { name: 'emptyString', value: '' },
  { name: 'integer', value: 42 },
  { name: 'zero', value: 0 },
  { name: 'negativeInteger', value: -7 },
  { name: 'float', value: 3.5 },
  { name: 'boolTrue', value: true },
  { name: 'boolFalse', value: false },
  { name: 'null', value: null },
  { name: 'array', value: [1, 2, 3] },
  { name: 'singleKeyMap', value: { type: 'offer' } },
]

const cases = values.map(({ name, value }) => {
  const encoder = encoding.createEncoder()
  encoding.writeAny(encoder, value)
  return {
    name,
    value,
    bytes: Buffer.from(encoding.toUint8Array(encoder)).toString('base64'),
  }
})

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/lib0-any.json'),
  `${JSON.stringify({ cases }, null, 2)}\n`
)
