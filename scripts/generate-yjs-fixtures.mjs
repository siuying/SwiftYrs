import { writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as encoding from 'lib0/encoding'
import * as Y from 'yjs'
import * as awarenessProtocol from 'y-protocols/awareness.js'
import * as syncProtocol from 'y-protocols/sync.js'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const doc = new Y.Doc()
const fixture = {
  stateVector: Buffer.from(Y.encodeStateVector(doc)).toString('base64'),
  updateV1: Buffer.from(Y.encodeStateAsUpdate(doc)).toString('base64'),
  updateV2: Buffer.from(Y.encodeStateAsUpdateV2(doc)).toString('base64')
}

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/empty-document.json'),
  `${JSON.stringify(fixture, null, 2)}\n`
)

const richTextDoc = new Y.Doc()
richTextDoc.clientID = 1
const richText = richTextDoc.getText('body')
richText.insert(0, 'hello', { bold: true })
richText.insertEmbed(5, [1, 2, 3])

const richTextFixture = {
  stateVector: Buffer.from(Y.encodeStateVector(richTextDoc)).toString('base64'),
  updateV1: Buffer.from(Y.encodeStateAsUpdate(richTextDoc)).toString('base64'),
  updateV2: Buffer.from(Y.encodeStateAsUpdateV2(richTextDoc)).toString('base64')
}

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/rich-text-document.json'),
  `${JSON.stringify(richTextFixture, null, 2)}\n`
)

const xmlDoc = new Y.Doc()
xmlDoc.clientID = 2
const xml = xmlDoc.getXmlFragment('article')
const paragraph = new Y.XmlElement('p')
paragraph.setAttribute('class', 'lead')
const text = new Y.XmlText()
text.insert(0, 'Hello XML')
paragraph.insert(0, [text])
xml.insert(0, [paragraph])

const xmlFixture = {
  stateVector: Buffer.from(Y.encodeStateVector(xmlDoc)).toString('base64'),
  updateV1: Buffer.from(Y.encodeStateAsUpdate(xmlDoc)).toString('base64'),
  updateV2: Buffer.from(Y.encodeStateAsUpdateV2(xmlDoc)).toString('base64')
}

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/xml-document.json'),
  `${JSON.stringify(xmlFixture, null, 2)}\n`
)

const relativePositionDoc = new Y.Doc()
relativePositionDoc.clientID = 3
const relativeText = relativePositionDoc.getText('body')
// Non-ASCII before the anchor: '\u2019' is 1 UTF-16 unit but 3 UTF-8 bytes,
// so this fixture catches offset-encoding mismatches with Yjs.
relativeText.insert(0, 'he\u2019llo')
const relativePosition = Y.createRelativePositionFromTypeIndex(relativeText, 4, 0)

const relativePositionFixture = {
  stateVector: Buffer.from(Y.encodeStateVector(relativePositionDoc)).toString('base64'),
  updateV1: Buffer.from(Y.encodeStateAsUpdate(relativePositionDoc)).toString('base64'),
  updateV2: Buffer.from(Y.encodeStateAsUpdateV2(relativePositionDoc)).toString('base64'),
  relativePositionV1: Buffer.from(Y.encodeRelativePosition(relativePosition)).toString('base64'),
  relativePositionJSON: Y.relativePositionToJSON(relativePosition)
}

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/relative-position-document.json'),
  `${JSON.stringify(relativePositionFixture, null, 2)}\n`
)

const awarenessDoc = new Y.Doc()
awarenessDoc.clientID = 11
const awareness = new awarenessProtocol.Awareness(awarenessDoc)
awareness.setLocalState({
  name: 'JS',
  cursor: { index: 7 }
})

const awarenessFixture = {
  update: Buffer.from(awarenessProtocol.encodeAwarenessUpdate(awareness, [11])).toString('base64')
}

awareness.destroy()

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/awareness-update.json'),
  `${JSON.stringify(awarenessFixture, null, 2)}\n`
)

const syncDoc = new Y.Doc()
syncDoc.clientID = 21
syncDoc.getText('body').insert(0, 'from js')
const syncAwareness = new awarenessProtocol.Awareness(syncDoc)
syncAwareness.setLocalState({ name: 'sync-js' })
const syncEncoder = encoding.createEncoder()
encoding.writeVarUint(syncEncoder, 0)
syncProtocol.writeSyncStep1(syncEncoder, new Y.Doc())
encoding.writeVarUint(syncEncoder, 0)
syncProtocol.writeUpdate(syncEncoder, Y.encodeStateAsUpdate(syncDoc))
encoding.writeVarUint(syncEncoder, 1)
encoding.writeVarUint8Array(
  syncEncoder,
  awarenessProtocol.encodeAwarenessUpdate(syncAwareness, [21])
)
encoding.writeVarUint(syncEncoder, 3)

const syncFixture = {
  multiMessage: Buffer.from(encoding.toUint8Array(syncEncoder)).toString('base64')
}

syncAwareness.destroy()

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/sync-messages.json'),
  `${JSON.stringify(syncFixture, null, 2)}\n`
)

const nestedDoc = new Y.Doc()
nestedDoc.clientID = 7
const nestedMessages = nestedDoc.getArray('messages')
const nestedMessage = new Y.Map()
nestedMessage.set('sender', 'alice')
nestedMessage.set('body', 'hello')
const nestedTags = new Y.Array()
nestedTags.push(['urgent', 'demo'])
nestedMessage.set('tags', nestedTags)
nestedMessages.push([nestedMessage])

const nestedFixture = {
  stateVector: Buffer.from(Y.encodeStateVector(nestedDoc)).toString('base64'),
  updateV1: Buffer.from(Y.encodeStateAsUpdate(nestedDoc)).toString('base64'),
  updateV2: Buffer.from(Y.encodeStateAsUpdateV2(nestedDoc)).toString('base64')
}

writeFileSync(
  join(root, 'Tests/SwiftYrsTests/Fixtures/nested-container-document.json'),
  `${JSON.stringify(nestedFixture, null, 2)}\n`
)
