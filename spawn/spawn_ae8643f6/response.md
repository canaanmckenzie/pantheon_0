I understand my assignment. I'm the backend specialist subagent tasked with defining Windows TUN/Wintun implementation requirements.

## WINDOWS TUN/WINTUN IMPLEMENTATION REQUIREMENTS ANALYSIS

### 1. WINTUN API FUNDAMENTALS

**Core API Structure:**
- Wintun is a minimal TUN driver for Windows (MIT licensed, maintained by WireGuard project)
- DLL-based interface: `wintun.dll` (typically ~300KB)
- Requires Windows 7 SP1+ (but Windows 10+ is practical target)
- No kernel-mode installation required after initial setup

**Key API Components:**

```
WintunCreateAdapter()
  - Creates a virtual network interface
  - Parameters: adapter name, tunnel type (TUN/TAP), GUID
  - Returns: WINTUN_ADAPTER handle
  - Requires admin privileges
  - Creates persistent adapter (survives reboot if not deleted)

WintunDeleteAdapter()
  - Removes virtual interface
  - Cleans up registry entries
  - Frees driver resources
  - Requires admin privileges

WintunGetAdapterLUID()
  - Retrieves LUID (Locally Unique Identifier)
  - Required for IP configuration via SetupAPI
  - Allows integration with Windows networking stack

WintunAllocateSendPacket()
  - Allocates buffer in send ring for outgoing packets
  - Returns pointer to packet data buffer
  - Non-blocking operation

WintunReleaseSendPacket()
  - Marks packet as ready for transmission
  - Informs driver that packet is complete
  - Triggers packet delivery to network stack

WintunReceivePacket()
  - Retrieves incoming packet from receive ring
  - Returns packet pointer and size
  - Blocking or non-blocking modes

WintunReleaseReceivePacket()
  - Signals driver that packet has been processed
  - Allows driver to reuse buffer space
  - Critical for ring buffer management

WintunGetRunningDriverVersion()
  - Queries installed driver version
  - Validates compatibility
  - Important for graceful degradation
```

### 2. PACKET RING BUFFER ARCHITECTURE

**Ring Buffer Design:**

The Wintun driver uses a lockless ring buffer design for high-performance packet I/O:

```
RING_BUFFER_SIZE = 4MB (configurable, typical value)

Structure:
┌─────────────────────────────────────┐
│  Packet 1 (variable size)           │
│  [Header: Size, Padding flags]      │
│  [IP packet data]                   │
├─────────────────────────────────────┤
│  Packet 2                           │
│  [Header: Size, Padding flags]      │
│  [IP packet data]                   │
├─────────────────────────────────────┤
│  Packet N                           │
│  [Header: Size, Padding flags]      │
│  [IP packet data]                   │
├─────────────────────────────────────┤
│  Available space (wrap-around)      │
└─────────────────────────────────────┘

Head pointer: Writer's position (driver or usermode)
Tail pointer: Reader's position (usermode or driver)
Capacity: Circular buffer with wrap-around handling
```

**Key Characteristics:**

- **Lockless Operation**: Uses atomic operations instead of mutexes
  - Read pointer (consumer updates)
  - Write pointer (producer updates)
  - No synchronization primitives needed
  
- **Packet Header Format**:
  ```
  struct WINTUN_PACKET {
    uint32_t size;           // Packet payload size (typically 14-1500 bytes)
    uint32_t reserved;       // Padding/alignment field
    uint8_t data[];          // Variable-length packet data
  };
  ```

- **Alignment**: Packets aligned to 4-byte boundaries for SIMD optimization
  - Padding is automatically inserted between packets
  - Improves CPU cache efficiency

- **Wrap-Around Handling**:
  - Ring buffer is logically circular
  - Packets wrap from end to beginning
  - Reader/writer must handle boundary conditions
  - Partial packets at wrap boundary are invalid (skip)

**Buffer Management Strategy:**

1. **Send Path** (Usermode → Driver → Network):
   - Allocate buffer via `WintunAllocateSendPacket()`
   - Write IP packet data (no Ethernet frame)
   - Release via `WintunReleaseSendPacket()`
   - Driver delivers to network interface
   - Can send multiple packets per call (batch)

2. **Receive Path** (Network → Driver → Usermode):
   - Driver writes packets to receive ring
   - Usermode reads via `WintunReceivePacket()`
   - Process packet (decryption, etc.)
   - Release via `WintunReleaseReceivePacket()`
   - Can receive multiple packets per call (batch)

**Performance Considerations**:
- Batch processing: Process 256-512 packets per iteration
- Reduce context switches by waiting for ring to fill
- Use larger reads/writes to amortize syscall overhead
- Monitor ring utilization to detect congestion

### 3. DRIVER LIFECYCLE MANAGEMENT

**Initialization Phase:**

```
1. Load wintun.dll Dynamically
   - Check file signature/authenticode
   - Validate version compatibility
   - Handle missing/incompatible cases gracefully

2. Enumerate Existing Adapters
   - Query WinReg for "SYSTEM\CurrentControlSet\Control\Class\{...}"
   - Filter by "Wintun" adapter class
   - Build list of existing tunnels
   - Detect stale/orphaned adapters

3. Create or Reuse Adapter
   - Check if named adapter exists
   - Reuse if compatible, create new if needed
   - Assign IP configuration (4.0.0.0/24 default)
   - Set MTU (1420 for VPN overhead)

4. Open Receive/Send Rings
   - Create handle via WintunGetAdapterLUID()
   - Map shared memory regions
   - Initialize read/write pointers
   - Spawn I/O threads
```

**Runtime Phase:**

```
1. Packet I/O Thread
   - Poll receive ring for packets from network
   - Decrypt/process packets
   - Queue for application
   - Poll for packets to send
   - Encrypt/process packets
   - Write to send ring
   - Configurable batch sizes for efficiency

2. Error Handling
   - Ring buffer full conditions
   - Packet size validation
   - Adapter removal detection
   - Driver crash/reload detection

3. Statistics Collection
   - Track packets in/out
   - Monitor bytes sent/received
   - Record packet loss
   - Measure latency
```

**Shutdown Phase:**

```
1. Stop I/O Operations
   - Signal threads to exit
   - Wait for graceful shutdown (max 5 seconds)
   - Force terminate if needed

2. Close Adapter Handles
   - Release receive/send ring handles
   - Unmap shared memory
   - Clean up event handles

3. Optional Cleanup
   - Delete adapter (for temporary sessions)
   - OR leave adapter (for persistent configs)
   - Preserve GUID for reconnection
```

**Lifecycle State Machine:**

```
┌──────────────┐
│  UNLOADED    │ (DLL not loaded, adapter doesn't exist)
└──────┬───────┘
       │ LoadDLL()
       ▼
┌──────────────┐
│  DLL_LOADED  │ (DLL loaded, querying adapters)
└──────┬───────┘
       │ CreateAdapter()
       ▼
┌──────────────┐
│  CREATED     │ (Adapter exists, not opened)
└──────┬───────┘
       │ Open()
       ▼
┌──────────────┐
│  OPENED      │ (Rings mapped, ready for I/O)
└──────┬───────┘
       │ StartIO()
       ▼
┌──────────────┐
│  RUNNING     │ (Active packet processing)
└──────┬───────┘
       │ StopIO()
       ▼
┌──────────────┐
│  STOPPED     │ (I/O halted, adapter still open)
└──────┬───────┘
       │ Close()
       ▼
┌──────────────┐
│  CLOSED      │ (Rings unmapped, handle invalid)
└──────────────┘
```

### 4. DYNAMIC DLL LOADING STRATEGY

**Rationale:**
- Wintun.dll may not be installed
- Graceful degradation required
- Allow running without VPN on systems without Wintun
- Version compatibility checking

**Implementation Approach:**

```
1. DLL Search and Validation
   - Primary: Check %ProgramFiles%\WireGuard\wintun.dll
   - Secondary: System32\wintun.dll (if installed globally)
   - Fallback: Bundled wintun.dll in application directory
   - Verify Authenticode signature (optional but recommended)
   - Check version via GetFileVersionInfo()

2. Function Pointers Declaration
   ```
   typedef WINTUN_ADAPTER* (WINAPI *WintunCreateAdapterFunc)(
       const wchar_t *name, const wchar_t *type, const GUID *guid);
   
   typedef void (WINAPI *WintunDeleteAdapterFunc)(
       WINTUN_ADAPTER adapter, BOOL forceCloseSessions, BOOL *rebootRequired);
   
   // ... etc for all Wintun API functions
   ```

3. Runtime Loading
   ```
   HMODULE wintun_dll = LoadLibraryW(L"wintun.dll");
   if (!wintun_dll) {
       // Fallback: Try alternate paths
       // Or return error: "Wintun not available"
   }
   
   WintunCreateAdapterFunc CreateAdapter = 
       (WintunCreateAdapterFunc)GetProcAddress(wintun_dll, 
                                                "WintunCreateAdapter");
   ```

4. Version Compatibility Matrix
   ```
   Required: Wintun 0.14.0+ (as of 2025)
   Supported: 0.14.x, 0.15.x, 1.0.x
   
   Per-function availability checks:
   - Some functions added in newer versions
   - Graceful fallback for missing functions
   - Version-dependent behavior selection
   ```

5. Error Recovery
   ```
   If DLL load fails:
   - Log detailed error (path attempted, error code)
   - Disable Wintun features gracefully
   - Optionally download/install Wintun
   - Provide user-facing error message
   
   If function pointer fails:
   - Retry with alternate paths
   - Check for corrupted/partial installation
   - Suggest reinstall if necessary
   ```

### 5. WIREGUARD INTEGRATION PATTERNS

**Key Architectural Points:**

```
WireGuard Protocol Stack (Reference):
┌─────────────────────────────────────┐
│  IPC/GUI Layer                      │
│  (Named pipes, config mgmt)         │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  Service/Daemon                     │
│  (Privilege elevation, lifecycle)   │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  Crypto Engine                      │
│  (ChaCha20-Poly1305, DH exchange)   │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  Packet Processing                  │
│  (Packet framing, compression)      │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  TUN/Wintun Layer                   │
│  (Ring buffers, adapter mgmt)       │
└──────────────────┬──────────────────┘
                   │
┌──────────────────▼──────────────────┐
│  UDP Transport                      │
│  (Winsock2, socket I/O)             │
└─────────────────────────────────────┘
```

**Critical Integration Points:**

1. **Packet Flow from TUN to UDP**:
   - TUN reads: Userland IP packet (IPv4/IPv6)
   - Strip IP header, extract payload
   - Encrypt with ChaCha20-Poly1305
   - Wrap in WireGuard message format
   - Send via UDP socket
   - Track source/destination for reply routing

2. **Packet Flow from UDP to TUN**:
   - UDP receives encapsulated packet
   - Validate packet signature (Poly1305)
   - Decrypt with ChaCha20
   - Extract original IP packet
   - Write to TUN send ring
   - Network stack delivers to application

3. **Handshake Integration**:
   - WireGuard initiates via UDP
   - Exchange Noise IK messages
   - Derive session keys (Curve25519 ECDH)
   - Establish symmetric session
   - Begin packet encryption
   - Periodic re-keying (every 2 minutes)

4. **Connection State Management**:
   ```
   Per-peer state:
   - IP address / endpoint
   - Curve25519 public key
   - Session keys (current + previous for rekey)
   - Last handshake timestamp
   - Packets sent/received counters
   - Keepalive interval
   
   Per-interface state:
   - Private key (Curve25519)
   - Interface IP address (4.0.0.0/24)
   - MTU (1420)
   - Listen UDP port
   - Connected peers list
   - Statistics (total bytes, packets)
   ```

5. **Re-keying and Expiration**:
   ```
   Key rotation schedule:
   - Every 120 seconds: initiate new handshake
   - Old session keys: valid for 180 seconds after rotation
   - Session timeout: 900 seconds of no traffic
   - Auto-reconnect on session expire
   
   Keepalive messages:
   - Send empty encrypted packets every 25 seconds
   - Keeps NAT mappings alive
   - Detects peer availability
   ```

### 6. BACKEND REQUIREMENTS SUMMARY

**Data Structures Needed:**

```
TUN Adapter Management:
- tun_adapter_t: Handle to Wintun adapter
  - WINTUN_ADAPTER* wintun_handle
  - WINTUN_SESSION* send_session
  - WINTUN_SESSION* recv_session
  - HANDLE recv_event
  - uint32_t adapter_mtu
  - uint8_t adapter_address[4]

Ring Buffer State:
- tun_ring_t: Shared memory ring state
  - uint8_t* buffer_ptr
  - size_t buffer_size
  - volatile uint32_t* head
  - volatile uint32_t* tail
  - uint32_t packet_count

Packet I/O:
- tun_packet_t: Single packet
  - uint8_t* data
  - uint16_t size
  - uint32_t flags
```

**Function Interfaces Required:**

```
Adapter Lifecycle:
int tun_adapter_create(const char* name, tun_adapter_t** adapter)
int tun_adapter_open(tun_adapter_t* adapter)
int tun_adapter_close(tun_adapter_t* adapter)
int tun_adapter_delete(tun_adapter_t* adapter)

Packet I/O:
int tun_read_packets(tun_adapter_t* adapter, tun_packet_t** packets, 
                     size_t* count, size_t max_packets)
int tun_write_packets(tun_adapter_t* adapter, tun_packet_t* packets, 
                      size_t count)
void tun_packet_release(tun_adapter_t* adapter, tun_packet_t* packet)

Configuration:
int tun_set_address(tun_adapter_t* adapter, const char* address, 
                    const char* netmask)
int tun_set_mtu(tun_adapter_t* adapter, uint32_t mtu)
int tun_get_stats(tun_adapter_t* adapter, tun_stats_t* stats)
```

**Thread Safety Requirements:**

- Receive ring: Read thread safe (single reader expected)
- Send ring: Write thread safe (may have multiple writers)
- Statistics: Atomic counters for thread-safe updates
- Configuration: Copy-on-write for config changes
- No blocking operations in I/O critical path

**Performance Targets:**

- Throughput: >900 Mbps (limited by encryption, not Wintun)
- Latency: <2ms per packet (measured at TUN layer)
- CPU usage: <5% per Gbps of throughput
- Memory: <50MB resident for adapter + buffers
- Packet loss: <0.001% under normal load

**Error Handling Requirements:**

```
Critical errors (should abort):
- Ring buffer corruption
- Adapter removal during operation
- Unrecoverable DLL load failure

Recoverable errors:
- Temporary ring full (backpressure)
- Packet too large (fragment)
- Configuration changes during operation

Graceful degradation:
- No Wintun available: Disable VPN
- Adapter busy: Wait and retry
- Network down: Reconnect on link restore
```

### 7. CROSS-COMPILATION CONSIDERATIONS (Linux → Windows)

**MinGW Toolchain Requirements:**

```
Headers needed:
- <wintun.h> (Wintun API declarations)
- <winsock2.h> (Winsock2 for UDP)
- <ws2ipdef.h> (IP definitions)
- <iphlpapi.h> (IPHLPAPI for adapter config)
- <setupapi.h> (SetupAPI for device management)

Libraries to link:
- wintun.lib (imported from wintun.dll)
- ws2_32.lib (Winsock2)
- iphlpapi.lib (IP helper)
- setupapi.lib (Setup API)
- advapi32.lib (Registry, privileges)
```

**Platform Abstraction Layer:**

```
#ifdef _WIN32
  #include "platform/windows/tun_wintun.c"
  #include "platform/windows/ipc_namedpipe.c"
#elif __linux__
  #include "platform/linux/tun_netlink.c"
  #include "platform/linux/ipc_unix.c"
#elif __APPLE__
  #include "platform/macos/tun_utun.c"
  #include "platform/macos/ipc_mach.c"
#endif
```

[COMPLETE]

This comprehensive requirements document provides the backend specialist perspective on Windows TUN/Wintun implementation, covering all critical aspects: API design, data structures, performance characteristics, error handling, and integration patterns with the existing HinkyPunk VPN system.
