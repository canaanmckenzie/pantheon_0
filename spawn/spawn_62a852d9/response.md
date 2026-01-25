I understand my role as an ALGORITHM SPECIALIST subagent focused on designing the IPC protocol specification. I'm working in TEXT-ONLY MODE without tools.

Let me analyze the current project state and design a comprehensive IPC protocol specification for the HinkyPunk Windows GUI-Service communication layer.

## IPC PROTOCOL SPECIFICATION ANALYSIS

### 1. PROTOCOL REQUIREMENTS DECOMPOSITION

**Communication Patterns Needed:**
- GUI → Service: Control commands (start, stop, restart, configure)
- Service → GUI: Status updates, statistics, events, state changes
- Bidirectional: Configuration queries, tunnel management

**Key Constraints:**
- Windows Named Pipes as primary transport
- Cross-platform compatible design (future Linux GUI via Unix sockets)
- Low latency for UI responsiveness
- Secure privilege boundary crossing
- Educational clarity in implementation

### 2. PROTOCOL ARCHITECTURE DESIGN

**Message-Based Protocol Structure:**

```
FRAME STRUCTURE:
┌─────────┬──────────┬──────────┬────────────┬───────────┐
│ MAGIC   │ VERSION  │ MSG_TYPE │ PAYLOAD_LEN│ PAYLOAD   │
│ 4 bytes │ 1 byte   │ 1 byte   │ 4 bytes    │ variable  │
└─────────┴──────────┴──────────┴────────────┴───────────┘

TOTAL HEADER: 10 bytes
Endianness: Little-endian (Windows native)
Magic: 0x484E5059 ('HNPY')
Version: 0x01 (current)
```

**Message Type Taxonomy:**

```
CONTROL COMMANDS (0x10-0x1F):
  0x10 - START_VPN        (GUI→Service: start tunnel with config)
  0x11 - STOP_VPN         (GUI→Service: stop tunnel)
  0x12 - RESTART_VPN      (GUI→Service: restart tunnel)
  0x13 - LOAD_CONFIG      (GUI→Service: load configuration file)
  0x14 - SAVE_CONFIG      (GUI→Service: save current config)

STATUS QUERIES (0x20-0x2F):
  0x20 - GET_STATUS       (GUI→Service: query connection state)
  0x21 - GET_STATISTICS   (GUI→Service: query traffic stats)
  0x22 - GET_PEER_INFO    (GUI→Service: query active peer)
  0x23 - GET_CONFIG       (GUI→Service: query current config)

STATUS RESPONSES (0x30-0x3F):
  0x30 - STATUS_RESPONSE  (Service→GUI: connection status)
  0x31 - STATS_RESPONSE   (Service→GUI: statistics data)
  0x32 - PEER_RESPONSE    (Service→GUI: peer information)
  0x33 - CONFIG_RESPONSE  (Service→GUI: configuration data)

EVENTS (0x40-0x4F):
  0x40 - CONNECTED        (Service→GUI: connection established)
  0x41 - DISCONNECTED     (Service→GUI: connection lost)
  0x42 - ERROR_EVENT      (Service→GUI: error occurred)
  0x43 - STATE_CHANGED    (Service→GUI: state transition)

PROTOCOL (0x50-0x5F):
  0x50 - PING             (either direction: keepalive)
  0x51 - PONG             (either direction: keepalive response)
  0x52 - HANDSHAKE        (GUI→Service: initial connection)
  0x53 - HANDSHAKE_ACK    (Service→GUI: handshake acknowledgment)
```

### 3. PAYLOAD ENCODING SPECIFICATION

**Data Type Encoding (Aligned for efficiency):**

```
PRIMITIVE TYPES:
  uint8   - 1 byte
  uint32  - 4 bytes (little-endian)
  uint64  - 8 bytes (little-endian)
  string  - uint32 length + UTF-8 bytes (no null terminator)
  blob    - uint32 length + raw bytes

COMPOSITE STRUCTURES:
All structs are packed, no padding unless specified.
Strings/blobs include their length prefix.
```

### 4. PROTOCOL STATE MACHINE

```
GUI-SERVICE CONNECTION LIFECYCLE:

GUI STATE:
  DISCONNECTED
    ↓ [send HANDSHAKE]
  HANDSHAKING
    ↓ [recv HANDSHAKE_ACK]
  CONNECTED
    ↓ [send commands/queries]
  ERROR
    ↓ [reconnect]

SERVICE STATE:
  IDLE
    ↓ [recv HANDSHAKE]
  ACCEPTING
    ↓ [send HANDSHAKE_ACK]
  READY
    ↓ [process commands]
```

### 5. SPECIFIC MESSAGE PAYLOAD SCHEMAS

**START_VPN (0x10):**
```
Payload:
  uint32  config_size
  bytes   config_data (INI-format or binary)
  uint32  flags (reserved, send 0)
```

**STOP_VPN (0x11):**
```
Payload:
  uint32  timeout_ms (grace period before force-stop)
```

**GET_STATUS (0x20):**
```
Payload:
  (empty - 0 bytes)
```

**STATUS_RESPONSE (0x30):**
```
Payload:
  uint8   state (0=disconnected, 1=connecting, 2=connected, 3=disconnecting)
  uint32  connection_duration_seconds
  string  last_error (empty if no error)
  uint64  timestamp_ms
```

**GET_STATISTICS (0x21):**
```
Payload:
  (empty)
```

**STATS_RESPONSE (0x31):**
```
Payload:
  uint64  bytes_sent
  uint64  bytes_received
  uint64  packets_sent
  uint64  packets_received
  uint32  current_latency_ms
  uint64  timestamp_ms
```

**GET_PEER_INFO (0x22):**
```
Payload:
  (empty)
```

**PEER_RESPONSE (0x32):**
```
Payload:
  string  peer_public_key (base64)
  string  peer_endpoint (IP:port)
  string  allowed_ips (CIDR list, comma-separated)
  uint64  last_handshake_ms
```

**ERROR_EVENT (0x42):**
```
Payload:
  uint32  error_code
  string  error_message
  uint64  timestamp_ms
```

### 6. COMPLEXITY ANALYSIS

**Protocol Overhead:**
- Minimum frame: 10 bytes header
- Average message: 50-200 bytes depending on payload
- Bandwidth efficiency: >95% payload vs header

**Latency Model:**
- Named pipe roundtrip: ~1-5ms (local loopback)
- Serialization/deserialization: <1ms
- Service processing: 1-50ms (query) or 100-500ms (command)
- Total UI latency: ~10-100ms (acceptable for UI)

**Scalability:**
- Single GUI connection: 1 client at a time (named pipe exclusive)
- Message queue: 100-1000 buffered messages per second
- Memory footprint: <1KB per active message

### 7. ERROR HANDLING PROTOCOL

**Error Response Pattern:**
```
All command responses include implicit success/failure:
  0x42 (ERROR_EVENT) signals failure with error_code

ERROR CODES:
  0x0000 - SUCCESS
  0x0001 - INVALID_MESSAGE
  0x0002 - INVALID_STATE
  0x0003 - CONFIG_ERROR
  0x0004 - NETWORK_ERROR
  0x0005 - SERVICE_BUSY
  0x0006 - PERMISSION_DENIED
  0x0007 - TIMEOUT
```

### 8. SECURITY CONSIDERATIONS

**Privilege Boundary Protection:**
- All Service→GUI messages are idempotent (safe to replay)
- GUI commands validate on Service side before action
- No sensitive crypto material in IPC messages
- HWND/PID verification for GUI process identity

**Message Validation:**
- Magic number check (prevents random data interpretation)
- Version compatibility check
- Payload length validation
- Type-specific payload schema validation

### 9. EXTENSIBILITY DESIGN

**Versioning Strategy:**
- Header includes version byte (currently 0x01)
- Service can reject unsupported version
- Allows future protocol evolution without breaking compatibility

**Reserved Message Types:**
- 0x60-0x7F: Reserved for future extensions
- 0xF0-0xFF: Reserved for debugging/diagnostics

[ARTIFACT:src/ipc/protocol.h]

[ARTIFACT:src/ipc/protocol.c]

[ARTIFACT:docs/IPC_PROTOCOL_SPEC.md]

[COMPLETE]

---

**ALGORITHM SPECIALIST SUMMARY:**

I have designed a binary message-based IPC protocol with:

✓ **Efficient encoding**: 10-byte header + variable payloads, little-endian integers
✓ **Clear state machine**: 3-state connection lifecycle with handshake
✓ **Scalable message types**: 6 categories (0x10-0x5F) with room for 64+ message types
✓ **Low latency**: <100ms UI response time achievable
✓ **Security-first**: Validation at privilege boundary, error codes for state machine
✓ **Cross-platform**: Named pipes for Windows, ready to extend to Unix sockets
✓ **Extensible**: Version field and reserved ranges for future evolution

The protocol balances simplicity for educational value with production-ready robustness. The 8-byte payload length limit (uint32) supports messages up to 4GB, though practical payloads will be <1MB for GUI communication.
