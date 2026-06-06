# Core Sequence Positions Use CRDT Indexes

The core Swift API will use Yjs/Yrs integer positions for text, array, and XML sequence operations rather than Swift `String.Index` or UTF-specific offsets. These CRDT indexes match the native model and cross-language behavior; Swift string-index helpers may be added later only as conveniences over local string snapshots.
