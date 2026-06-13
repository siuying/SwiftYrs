import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Y from 'yjs'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const b64 = (bytes) => Buffer.from(bytes).toString('base64')

// Two writers contribute to one document. The CloudKit provider captures a
// *client-scoped* diff: only the updates authored by a single client since a
// marker clock. We model that in Yjs with a synthetic state vector that claims
// the target already holds every other client's state but nothing from the
// scoped client below `fromClock`.
const clientID = 1
const fromClock = 0

const clientOne = new Y.Doc()
clientOne.clientID = clientID
clientOne.getText('body').insert(0, 'one')
const clientOneUpdate = Y.encodeStateAsUpdate(clientOne)

const clientTwo = new Y.Doc()
clientTwo.clientID = 2
clientTwo.getText('body').insert(0, 'two')
const clientTwoUpdate = Y.encodeStateAsUpdate(clientTwo)

const merged = new Y.Doc()
Y.applyUpdate(merged, clientOneUpdate)
Y.applyUpdate(merged, clientTwoUpdate)

const fullStateVector = Y.encodeStateVectorFromUpdate(Y.encodeStateAsUpdate(merged))
const decodedSV = Y.decodeStateVector(fullStateVector)
const expectedClock = decodedSV.get(clientID)

// Scoped state vector: pretend the target has everything except the scoped
// client's writes past `fromClock`, so the diff carries only this client's data.
// Yjs has no public Map->state-vector encoder, so build the lib0 bytes directly.
const scopedSV = new Map(decodedSV)
scopedSV.set(clientID, fromClock)
const encodedScopedSV = encodeStateVectorFromMap(scopedSV)
const clientOneDiff = Y.encodeStateAsUpdate(merged, encodedScopedSV)

const fixture = {
  clientID,
  fromClock,
  expectedClock,
  clientOneUpdate: b64(clientOneUpdate),
  clientTwoUpdate: b64(clientTwoUpdate),
  scopedStateVector: b64(encodedScopedSV),
  clientOneDiff: b64(clientOneDiff),
}

writeFileSync(
  join(root, 'Tests/SwiftYrsCloudKitTests/Fixtures/client-scoped-diff.json'),
  `${JSON.stringify(fixture, null, 2)}\n`
)

// lib0 varint-encoded state vector: count, then (client, clock) pairs.
function encodeStateVectorFromMap(sv) {
  const bytes = []
  const writeVarUint = (num) => {
    let n = num
    while (n > 0b0111_1111) {
      bytes.push(0b1000_0000 | (n & 0b0111_1111))
      n = Math.floor(n / 128)
    }
    bytes.push(n & 0b0111_1111)
  }
  const pairs = [...sv].sort(([a], [b]) => a - b)
  writeVarUint(pairs.length)
  for (const [client, clock] of pairs) {
    writeVarUint(client)
    writeVarUint(clock)
  }
  return new Uint8Array(bytes)
}
