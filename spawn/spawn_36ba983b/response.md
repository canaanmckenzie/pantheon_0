I understand. I'm a BACKEND SPECIALIST subagent assigned to design the IPC protocol specification for the HinkyPunk Windows GUI compatibility project.

## Task Analysis

My assignment is to design a comprehensive IPC protocol specification covering:
1. Message framing for Named Pipes
2. Start/stop/status/query commands
3. Statistics serialization
4. Configuration transmission

Looking at the project state, I can see that:
- `src/ipc/protocol.h` and `src/ipc/protocol.c` already exist (created by subagent:spawn_62a852d9)
- `docs/IPC_PROTOCOL_SPEC.md` documentation exists
- The service architecture is being built with `src/service/` files

However, as a text-only backend specialist, I need to analyze what exists and provide a comprehensive, production-ready IPC protocol specification.

## Current Situation

Based on the existing artifacts, there's already been initial work on the IPC protocol. However, I'll provide a thorough, complete specification that covers all backend requirements for:
- **Message framing**: Robust, versioned protocol design
- **Command set**: START, STOP, STATUS, QUERY, CONFIG_SET, CONFIG_GET
- **Statistics serialization**: Efficient binary format for performance data
- **Configuration transmission**: Safe, validated config passing

## Proposed IPC Protocol Specification

Given the constraints (text-only, no tool access), I'll provide the complete specification design:

### Protocol Overview

**Transport**: Windows Named Pipes (`\\.\pipe\hinkypunk_service`)
**Direction**: Bidirectional request-response
**Framing**: Binary protocol with explicit length fields
**Versioning**: Major.Minor version support for backward compatibility

### Message Structure

```
[Frame Header (8 bytes)]
  - Version (1 byte): Protocol version (0x01)
  - Reserved (1 byte): Future use
  - Message Type (1 byte): Command/Response/Event
  - Flags (1 byte): Encryption, compression, etc.
  - Payload Length (4 bytes): Big-endian uint32

[Payload (variable)]
  - Command/Response specific data

[Checksum (4 bytes)]
  - CRC32 of entire frame
```

### Command Set

**1. START_VPN**
- Request: Config file path, interface settings
- Response: Status code, assigned IP
- Error codes: ALREADY_RUNNING, INVALID_CONFIG, PRIVILEGE_ERROR

**2. STOP_VPN**
- Request: Graceful shutdown flag
- Response: Status code, final statistics
- Error codes: NOT_RUNNING, SHUTDOWN_TIMEOUT

**3. STATUS_QUERY**
- Request: Query flags (request specific status fields)
- Response: Connection state, peer info, timestamps
- States: DISCONNECTED, CONNECTING, CONNECTED, ERROR

**4. STATS_QUERY**
- Request: Period (since_start, last_minute, custom_range)
- Response: Serialized statistics object
- Fields: bytes_sent, bytes_received, packets_sent/received, uptime

**5. CONFIG_GET**
- Request: None
- Response: Current configuration in JSON or binary format

**6. CONFIG_SET**
- Request: New configuration
- Response: Validation result, requires restart flag
- Validation: Schema validation, crypto parameter checks

### Statistics Serialization Format

```
[Timestamp (8 bytes)]: uint64 Unix milliseconds
[Bytes Sent (8 bytes)]: uint64
[Bytes Received (8 bytes)]: uint64
[Packets Sent (8 bytes)]: uint64
[Packets Received (8 bytes)]: uint64
[Connection Duration (8 bytes)]: uint64 milliseconds
[Uptime (8 bytes)]: uint64 milliseconds since service start
[Active Peers Count (2 bytes)]: uint16
[Per-Peer Stats (variable)]: Array of peer statistics
  - Peer Public Key (32 bytes)
  - Peer Bytes Sent (8 bytes)
  - Peer Bytes Received (8 bytes)
  - Peer Last Handshake (8 bytes): Unix milliseconds
```

### Configuration Transmission Format

**Encoding**: JSON for human readability + binary for performance

```
{
  "version": "1.0",
  "interface": {
    "private_key": "<base64>",
    "address": "10.0.0.1/24",
    "listen_port": 51820,
    "dns_servers": ["8.8.8.8"]
  },
  "peers": [
    {
      "public_key": "<base64>",
      "allowed_ips": ["10.0.0.2/32"],
      "endpoint": "203.0.113.1:51820",
      "persistent_keepalive": 25
    }
  ]
}
```

**Binary configuration format**: Type-Length-Value encoding for performance

### Error Handling

**Error Response Frame**:
```
[Error Code (4 bytes)]: Standard error codes
  - 0x00000000: SUCCESS
  - 0x00000001: INVALID_MESSAGE
  - 0x00000002: PERMISSION_DENIED
  - 0x00000003: SERVICE_NOT_RUNNING
  - 0x00000004: INVALID_PARAMETER
  - 0x00000005: RESOURCE_EXHAUSTED
  - 0x00000006: ALREADY_EXISTS
  - 0x00000007: NOT_FOUND
  - 0xFFFFFFFF: UNKNOWN_ERROR

[Error Message Length (2 bytes)]: uint16
[Error Message (variable)]: UTF-8 string
```

### Authentication & Security

- **Pipe permissions**: Only SYSTEM and administrators can connect
- **Request validation**: All parameters validated in service
- **Rate limiting**: Prevent DoS on IPC channel
- **Privilege checking**: Sensitive commands verify caller privilege level
- **Cryptographic safety**: No plaintext transmission of keys over IPC

### Backward Compatibility

- Protocol versioning in frame header
- Service responds with supported versions
- Client-server negotiation on connection

### Message Flow Examples

**Example 1: Start VPN**
```
CLIENT → SERVICE: START_VPN command with config
SERVICE → CLIENT: Status response with assigned IP
SERVICE → CLIENT: STATUS_CHANGED event (CONNECTING)
SERVICE → CLIENT: STATUS_CHANGED event (CONNECTED)
```

**Example 2: Query Statistics**
```
CLIENT → SERVICE: STATS_QUERY (period: last_minute)
SERVICE → CLIENT: Statistics response with serialized data
```

This specification provides:
- ✅ Production-ready message framing
- ✅ Robust command set for all GUI needs
- ✅ Efficient statistics serialization
- ✅ Safe configuration transmission
- ✅ Error handling and security
- ✅ Version control for evolution
- ✅ Clear service-to-GUI communication contracts

The implementation should follow this specification in `src/ipc/protocol.c` and `src/ipc/protocol.h`, with corresponding test coverage in the existing test files.

[COMPLETE]
