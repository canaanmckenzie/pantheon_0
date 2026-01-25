I understand my assignment as a DOCUMENTATION SPECIALIST subagent. I need to create a comprehensive architecture specification document for the HinkyPunk VPN Windows GUI project.

Based on the project state, existing artifacts, and requirements, I will now create a detailed architecture specification document.

[ARTIFACT:docs/ARCHITECTURE.md]

```markdown
# HinkyPunk VPN Windows GUI - Architecture Specification

**Version:** 1.0  
**Date:** 2026-01-24  
**Status:** SPECIFICATION  
**Project Phase:** Inception & Architecture Design

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Component Design](#component-design)
4. [IPC Protocol](#ipc-protocol)
5. [Windows Service Architecture](#windows-service-architecture)
6. [GUI Architecture](#gui-architecture)
7. [Deployment Model](#deployment-model)
8. [Security Considerations](#security-considerations)
9. [Development Workflow](#development-workflow)
10. [Cross-Platform Design Principles](#cross-platform-design-principles)

---

## Overview

### Purpose
HinkyPunk VPN is a lightweight, educational VPN implementation with zero external cryptographic dependencies. This document specifies the architecture for Windows GUI compatibility, including native GUI, background service, and IPC mechanisms.

### Design Philosophy
- **Educational Focus**: Code is meant to teach VPN concepts and cryptographic implementation
- **Security First**: No shortcuts in cryptography or privilege handling
- **Platform Diversity**: Support Windows, Linux, and macOS from a single codebase
- **Minimal Dependencies**: Pure C core with optional GUI frameworks (Qt for C++)
- **Cross-Compilation Ready**: Developed on Linux, targeting Windows

### Key Constraints
- C language for core VPN functionality
- Windows-specific APIs for TUN, services, and IPC
- Cross-compilation from Linux to Windows (MinGW)
- Privilege separation (GUI user-mode, service kernel-mode)
- Educational code quality with comprehensive documentation

---

## System Architecture

### High-Level Component Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    Windows System                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────┐              ┌──────────────────┐   │
│  │   GUI Process    │              │   Service Proc   │   │
│  │  (User/Admin)    │              │  (SYSTEM acct)   │   │
│  │                  │              │                  │   │
│  │ • Tray icon      │              │ • Wintun API     │   │
│  │ • Main window    │  NamedPipe   │ • Ring buffer    │   │
│  │ • Config mgmt    │◄────────────►│ • IPC handler    │   │
│  │ • Status display │ \\.\pipe\    │ • Encryption/    │   │
│  │                  │ hinkypunk    │   decryption     │   │
│  └──────────────────┘              │ • Device lifecycle   │
│                                    └──────────────────┘   │
│                                           │                │
│                                           ▼                │
│                                    ┌──────────────┐       │
│                                    │ Wintun Driver│       │
│                                    │  (TAP device)│       │
│                                    └──────────────┘       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
         │
         │ UDP packets
         ▼
    Internet/Peers
```

### Process Separation

**GUI Application (hinkypunk.exe)**
- Runs with user/admin privileges
- Handles UI rendering and user interaction
- Manages configuration files
- Communicates with service via Named Pipe IPC
- No direct access to TUN device or cryptographic operations

**Service (hinkypunk-service.exe)**
- Runs with SYSTEM privileges (Windows Service)
- Manages Wintun TUN device
- Performs encryption/decryption
- Handles UDP socket I/O
- Responds to IPC commands from GUI
- Maintains connection state and statistics

### Privilege Boundary

```
User/Admin Mode          │         SYSTEM Mode
                         │
GUI Application          │         Service
 ├─ Config mgmt         │          ├─ Wintun driver
 ├─ UI rendering        │          ├─ Packet processing
 ├─ User interaction    │          ├─ UDP I/O
 └─ IPC client          │◄────────►│ ├─ Encryption/decryption
                         │          │ └─ IPC server
                         │
```

---

## Component Design

### 1. Windows TUN Implementation (`src/net/tun.c`)

#### Responsibilities
- Wintun driver discovery and loading
- Adapter lifecycle management (create/delete)
- Ring buffer packet I/O
- MTU and tunnel configuration
- Error handling and driver interactions

#### Key Data Structures

```c
typedef struct {
    HMODULE wintun_dll;
    
    // Function pointers from wintun.dll
    WintunCreateAdapterFunc CreateAdapter;
    WintunOpenAdapterFunc OpenAdapter;
    WintunCloseAdapterFunc CloseAdapter;
    WintunDeleteAdapterFunc DeleteAdapter;
    WintunGetRunningDriverVersionFunc GetRunningDriverVersion;
    
    // Session and ring management
    WINTUN_SESSION_HANDLE session;
    WINTUN_RING_PACKET *send_ring;
    WINTUN_RING_PACKET *recv_ring;
    size_t ring_packet_capacity;
    
    // Adapter state
    WINTUN_ADAPTER_HANDLE adapter;
    char adapter_name[256];
    uint32_t ipv4_address;
    uint8_t ipv4_netmask;
    
    // Event handles for signaling
    HANDLE send_event;
    HANDLE recv_event;
} WintunDevice;
```

#### Interface Functions

```c
WintunDevice* wintun_device_create(
    const char *tunnel_name,
    uint32_t ipv4_address,
    uint8_t ipv4_netmask
);

int wintun_device_send_packets(
    WintunDevice *dev,
    uint8_t **packets,
    uint16_t *sizes,
    size_t num_packets
);

int wintun_device_recv_packets(
    WintunDevice *dev,
    uint8_t **packets,
    uint16_t *sizes,
    size_t *num_packets,
    unsigned timeout_ms
);

void wintun_device_destroy(WintunDevice *dev);
```

#### Implementation Notes
- Dynamic loading of wintun.dll at runtime
- Ring buffer management for zero-copy packet I/O
- Overlapped I/O with event handles for async notification
- Network interface configuration via NETSH or Windows API
- Proper error handling and driver state validation

---

### 2. Windows Service Architecture (`src/service/`)

#### Service Components

**Service Main (`service_main.c`)**
- Entry point for Windows service
- Implements `ServiceMain()` callback
- Handles service control signals (START, STOP, PAUSE)
- Manages service state transitions
- Coordinates IPC server and packet processing loops

**Service State (`service_state.h/c`)**
- Maintains service operational state
- Tracks connection status (disconnected/connecting/connected)
- Stores current configuration
- Tracks statistics (bytes sent/received, duration)
- Thread-safe state mutations with locking

**Service Installation (`service_install.c`)**
- Service registration with Windows SCM
- Privilege elevation detection
- Service path validation
- Registry configuration
- Automatic startup vs manual startup

#### Service State Machine

```
        ┌─────────────────┐
        │  DISCONNECTED   │
        └────────┬────────┘
                 │ START command (IPC)
                 ▼
        ┌─────────────────┐
        │  CONNECTING     │
        ├─────────────────┤
        │ • Load config   │
        │ • Init Wintun   │
        │ • Setup routes  │
        │ • Init threads  │
        └────────┬────────┘
                 │ Success
                 ▼
        ┌─────────────────┐
        │  CONNECTED      │
        ├─────────────────┤
        │ • Packet I/O    │
        │ • Crypto ops    │
        │ • Stats update  │
        └────────┬────────┘
                 │ STOP command or error
                 ▼
        ┌─────────────────┐
        │  DISCONNECTING  │
        ├─────────────────┤
        │ • Flush packets │
        │ • Close Wintun  │
        │ • Cleanup routes│
        └────────┬────────┘
                 │
                 └──────────────┐
                                ▼
                        ┌─────────────────┐
                        │  DISCONNECTED   │
                        └─────────────────┘
```

#### Threading Model

```
Service Main Thread
├─ Service control handler
├─ IPC server loop (Named Pipe)
└─ State management

Packet Processing Thread
├─ Wintun recv_ring monitoring
├─ Decryption
├─ Route/forward decisions
└─ UDP transmit

Crypto Worker Threads (optional)
├─ Parallel decryption
├─ Parallel encryption
└─ Statistics aggregation
```

#### Key Data Structures

```c
typedef struct {
    HANDLE service_handle;
    SERVICE_STATUS status;
    SERVICE_STATUS_HANDLE status_handle;
    
    // Operational state
    enum ServiceState current_state;
    CRITICAL_SECTION state_lock;
    
    // Configuration
    VpnConfig *config;
    
    // Device
    WintunDevice *tun_device;
    
    // IPC
    HANDLE ipc_pipe;
    volatile bool ipc_active;
    
    // Threads
    HANDLE packet_thread;
    HANDLE stats_thread;
    volatile bool shutdown_requested;
    
    // Statistics
    struct {
        uint64_t bytes_sent;
        uint64_t bytes_received;
        uint64_t packets_sent;
        uint64_t packets_received;
        uint64_t connection_time_ms;
        FILETIME connection_start;
    } stats;
} ServiceContext;
```

---

### 3. IPC Protocol Layer (`src/ipc/`)

#### Protocol Overview

**Transport**: Windows Named Pipes (`\\.\pipe\hinkypunk_service`)
**Direction**: Bidirectional (full-duplex)
**Serialization**: Binary with type tags
**Framing**: Length-prefixed messages

#### Message Types

```c
// Request messages (GUI → Service)
enum IpcMessageType {
    IPC_MSG_PING = 0x01,
    IPC_MSG_GET_STATUS = 0x02,
    IPC_MSG_GET_STATS = 0x03,
    IPC_MSG_START_VPN = 0x04,
    IPC_MSG_STOP_VPN = 0x05,
    IPC_MSG_SET_CONFIG = 0x06,
    IPC_MSG_GET_CONFIG = 0x07,
};

// Response messages (Service → GUI)
enum IpcResponseType {
    IPC_RESP_PONG = 0x81,
    IPC_RESP_STATUS = 0x82,
    IPC_RESP_STATS = 0x83,
    IPC_RESP_OK = 0x84,
    IPC_RESP_ERROR = 0xFF,
};
```

#### Message Format

```
┌─────────────────┬──────────────┬───────────────┐
│ Length (4 bytes)│ Type (1 byte)│ Payload (var) │
├─────────────────┼──────────────┼───────────────┤
│ uint32_t (LE)   │ enum type    │ Type-specific │
└─────────────────┴──────────────┴───────────────┘
```

#### Specific Message Schemas

**IPC_MSG_START_VPN Request**
```
Type: 0x04
Payload:
  - config_size (uint16_t)
  - config_data (JSON or binary struct)
```

**IPC_RESP_STATUS Response**
```
Type: 0x82
Payload:
  - connection_state (uint8_t) [0=disconnected, 1=connecting, 2=connected]
  - active_peer_ip (uint32_t in network byte order)
  - active_peer_port (uint16_t in network byte order)
```

**IPC_RESP_STATS Response**
```
Type: 0x83
Payload:
  - bytes_sent (uint64_t)
  - bytes_received (uint64_t)
  - packets_sent (uint64_t)
  - packets_received (uint64_t)
  - connection_duration_ms (uint64_t)
  - current_latency_ms (uint32_t)
```

#### Connection Management

```c
// IPC Server (Service)
typedef struct {
    HANDLE listen_pipe;
    HANDLE client_pipes[MAX_CLIENTS];
    int num_clients;
    CRITICAL_SECTION clients_lock;
    volatile bool accepting;
} IpcServer;

// IPC Client (GUI)
typedef struct {
    HANDLE pipe;
    char pipe_name[256];
    volatile bool connected;
} IpcClient;
```

#### Timeout Specifications
- Connection timeout: 5 seconds
- Message read timeout: 10 seconds
- Message write timeout: 10 seconds
- Service discovery timeout: 3 seconds

---

### 4. GUI Architecture (`gui/`)

#### Framework Choice: Qt 6 (C++)

**Rationale**:
- Cross-platform (Windows, Linux, macOS from same codebase)
- Native look and feel per platform
- Signal/slot mechanism for clean event handling
- Comprehensive widget library
- Good C/C++ integration with existing C code
- Mature and well-documented

#### Application Structure

```
gui/
├── main.cpp                    # Entry point
├── mainwindow.h/cpp            # Main application window
├── trayicon.h/cpp              # System tray integration
├── connectionwidget.h/cpp      # Connection status display
├── statswidget.h/cpp           # Traffic statistics view
├── configmanager.h/cpp         # Config file handling
├── ipc_client.h/cpp            # IPC communication wrapper
├── dialogs/
│   ├── connectdialog.h/cpp     # Quick connect wizard
│   ├── configdialog.h/cpp      # Configuration editor
│   ├── settingsdialog.h/cpp    # Application settings
│   └── aboutdialog.h/cpp       # About/help
├── resources/
│   ├── resources.qrc           # Qt resource file
│   └── images/                 # Icons, images
└── CMakeLists.txt              # Qt build configuration
```

#### Main Window Hierarchy

```
MainWindow
├── MenuBar
│   ├── File (New, Open, Import, Exit)
│   ├── Edit (Preferences, Settings)
│   └── Help (About, Documentation)
├── CentralWidget
│   ├── Header (Logo, App name)
│   ├── ConnectionWidget
│   │   ├─ Status indicator (LED)
│   │   ├─ Connect/Disconnect button
│   │   └─ Active peer info
│   ├── StatsWidget
│   │   ├─ Download speed/total
│   │   ├─ Upload speed/total
│   │   ├─ Connection duration
│   │   └─ Latency display
│   ├── ConfigWidget
│   │   └─ Quick config selector
│   └─ Status bar
└── TrayIcon (System tray)
    ├─ Show main window
    ├─ Connect/Disconnect
    ├─ Settings
    └─ Exit
```

#### IPC Client Wrapper

```cpp
class IpcClient : public QObject {
    Q_OBJECT
    
public:
    IpcClient(QObject *parent = nullptr);
    ~IpcClient();
    
    bool connect();
    void disconnect();
    bool isConnected() const;
    
    // Asynchronous IPC methods
    void requestStatus();
    void requestStats();
    void startVpn(const QString &configPath);
    void stopVpn();
    void setConfig(const QByteArray &config);
    
signals:
    void statusUpdated(ServiceStatus status);
    void statsUpdated(VpnStats stats);
    void connectionStateChanged(int newState);
    void errorOccurred(QString errorMessage);
    
private:
    HANDLE m_pipe;
    QThread *m_readerThread;
    // ...
};
```

#### Configuration Storage

- **Location**: `%APPDATA%\HinkyPunk\configs\`
- **Format**: JSON for readability and future expansion
- **Encryption**: Optional encryption of private keys using Windows DPAPI
- **Sample Structure**:

```json
{
    "name": "My VPN Server",
    "interface": {
        "address": "10.0.0.2/24",
        "privateKey": "...",
        "dns": ["8.8.8.8", "8.8.4.4"]
    },
    "peer": {
        "publicKey": "...",
        "endpoint": "vpn.example.com:51820",
        "allowedIps": ["0.0.0.0/0"]
    },
    "gui": {
        "autoConnect": false,
        "minimizeToTray": true,
        "startupAction": "last"
    }
}
```

#### State Management

```cpp
class AppState : public QObject {
    Q_OBJECT
    
    enum ConnectionState {
        Disconnected,
        Connecting,
        Connected,
        Disconnecting,
        Error
    };
    
    struct VpnStats {
        quint64 bytesSent;
        quint64 bytesReceived;
        quint64 packetsSent;
        quint64 packetsReceived;
        quint64 connectionDurationMs;
        quint32 latencyMs;
    };
    
    // Properties with notification signals
    Q_PROPERTY(ConnectionState state NOTIFY stateChanged)
    Q_PROPERTY(VpnStats stats NOTIFY statsChanged)
    Q_PROPERTY(QString activeConfig NOTIFY activeConfigChanged)
    
signals:
    void stateChanged(ConnectionState newState);
    void statsChanged(const VpnStats &stats);
    void activeConfigChanged(const QString &config);
    void errorOccurred(const QString &error);
};
```

---

## IPC Protocol

Detailed specification in `docs/IPC_PROTOCOL_SPEC.md`

### Summary
- Full request/response semantics
- Binary protocol optimized for performance
- Error codes for all failure scenarios
- Keepalive mechanism for connection health
- Message ordering guarantees

---

## Windows Service Architecture

### Service Lifecycle

**Installation Phase**
```
User runs installer
    ↓
Extract service executable
    ↓
Register with SCM (Services.msc)
    ↓
Set startup type (Auto/Manual)
    ↓
Configure ACLs (SYSTEM account)
    ↓
Service ready for use
```

**Startup Phase**
```
Windows SCM starts service
    ↓
ServiceMain() called
    ↓
Register control handler
    ↓
Load configuration
    ↓
Initialize Wintun device
    ↓
Start packet processing threads
    ↓
Open IPC Named Pipe
    ↓
Report SERVICE_RUNNING to SCM
    ↓
Begin processing commands/packets
```

**Shutdown Phase**
```
SERVICE_CONTROL_STOP received
    ↓
Set shutdown_requested flag
    ↓
Signal threads to stop gracefully
    ↓
Flush pending packets
    ↓
Close Wintun device
    ↓
Close IPC pipe
    ↓
Cleanup resources
    ↓
Report SERVICE_STOPPED to SCM
```

### Resource Management

```c
// Global service context
static ServiceContext g_service = {0};

// Initialization order
void Initialize() {
    // 1. Allocate main context
    g_service.config = config_alloc();
    
    // 2. Register control handler
    g_service.status_handle = RegisterServiceCtrlHandler(...);
    
    // 3. Initialize synchronization
    InitializeCriticalSection(&g_service.state_lock);
    
    // 4. Create Wintun device
    g_service.tun_device = wintun_device_create(...);
    
    // 5. Start threads
    g_service.packet_thread = CreateThread(..., packet_worker, ...);
    g_service.stats_thread = CreateThread(..., stats_worker, ...);
    
    // 6. Open IPC pipe
    g_service.ipc_pipe = CreateNamedPipe(...);
}

// Cleanup order (reverse)
void Cleanup() {
    // 1. Stop accepting new connections
    g_service.ipc_active = false;
    CloseHandle(g_service.ipc_pipe);
    
    // 2. Signal shutdown
    g_service.shutdown_requested = true;
    
    // 3. Wait for threads
    WaitForSingleObject(g_service.packet_thread, 10000);
    WaitForSingleObject(g_service.stats_thread, 10000);
    
    // 4. Close device
    wintun_device_destroy(g_service.tun_device);
    
    // 5. Cleanup sync objects
    DeleteCriticalSection(&g_service.state_lock);
    
    // 6. Free config
    config_free(g_service.config);
}
```

---

## GUI Architecture

### Application Lifecycle

**Startup**
```
hinkypunk.exe launched
    ↓
Parse command-line arguments
    ↓
Create QApplication
    ↓
Create MainWindow
    ↓
Create TrayIcon
    ↓
Connect to IPC service
    ↓
Load configuration files
    ↓
Request current status from service
    ↓
Display UI or minimize to tray
```

**Event Loop**
```
UI Events (user clicks, input)
    │
    ├─→ Window interactions (drag, resize, etc)
    │
    ├─→ Button/menu actions
    │   └─→ Queue IPC request to service
    │
    ├─→ Timer events
    │   └─→ Periodic status/stats requests
    │
    └─→ IPC responses from service
        └─→ Update UI state and display
```

**Shutdown**
```
User closes application or clicks exit
    ↓
MainWindow::closeEvent()
    ↓
Disconnect from IPC (don't stop service)
    ↓
Save window geometry and state
    ↓
Close all dialogs
    ↓
Quit QApplication
```

---

## Deployment Model

### Windows Installer (NSIS)

**Components**:
- Service executable (`hinkypunk-service.exe`)
- GUI application (`hinkypunk.exe`)
- Wintun DLL (if not already installed)
- Configuration directories
- Start menu shortcuts
- Uninstall support

**Installation Steps**:
1. Elevate to admin (if needed)
2. Extract files to Program Files
3. Register service with Windows SCM
4. Create shortcuts and start menu items
5. Launch GUI application
6. Prompt user to import first configuration

### Registry Configuration

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\HinkyPunk
├─ ImagePath: REG_SZ = "C:\Program Files\HinkyPunk\hinkypunk-service.exe"
├─ DisplayName: REG_SZ = "HinkyPunk VPN Service"
├─ Description: REG_SZ = "Manages VPN tunnel and encryption"
├─ Start: REG_DWORD = 3 (Manual) or 2 (Auto)
├─ Type: REG_DWORD = 0x00000010 (Win32 Service)
└─ (SecurityDescriptor): Service ACLs

HKEY_CURRENT_USER\Software\HinkyPunk
├─ ConfigPath: REG_SZ = "%APPDATA%\HinkyPunk\configs"
├─ LastUsedConfig: REG_SZ = "config_name"
├─ MinimizeToTray: REG_DWORD = 1
├─ StartupBehavior: REG_SZ = "last" | "manual" | "disabled"
└─ ...
```

---

## Security Considerations

### Privilege Separation

**Design Principle**: Least privilege
- GUI runs as current user (may be non-admin)
- Service runs as SYSTEM only when needed
- IPC enforces strict message validation
- No privileged code in GUI process

### Named Pipe Security

```c
// IPC server (service) setup
SECURITY_ATTRIBUTES sa = {0};
sa.nLength = sizeof(SECURITY_ATTRIBUTES);
sa.lpSecurityDescriptor = CreateServicePipeSD();
sa.bInheritHandle = FALSE;

HANDLE hPipe = CreateNamedPipe(
    L"\\\\.\\pipe\\hinkypunk_service",
    PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
    PIPE_UNLIMITED_INSTANCES,
    4096,  // output buffer
    4096,  // input buffer
    0,     // timeout
    &sa    // security attributes
);

// Client connection with impersonation check
if (ImpersonateNamedPipeClient(hPipe)) {
    // Verify client identity
    HANDLE hClientToken;
    if (!OpenThreadToken(GetCurrentThread(), 
                         TOKEN_QUERY, 
                         FALSE, 
                         &hClientToken)) {
        // Deny - client not properly authenticated
        return IPC_RESP_ERROR;
    }
    RevertToSelf();
}
```

### Input Validation

All IPC messages are strictly validated:
- Message length bounds
- Field type checking
- String null-termination verification
- Configuration file validation before use
- No buffer overflows or format string attacks

### Cryptographic Security

- Private keys stored in application data directory
- Optional Windows DPAPI encryption
- No unencrypted key transmission
- Secure memory handling (zero-fill before free)
- No logging of sensitive data

### Service Elevation

```c
// Detect if running with admin/SYSTEM privileges
bool IsServiceRunningElevated() {
    HANDLE hToken;
    if (!OpenProcessToken(GetCurrentProcess(), 
                          TOKEN_QUERY, 
                          &hToken)) {
        return false;
    }
    
    TOKEN_ELEVATION elevation;
    DWORD dwSize = sizeof(TOKEN_ELEVATION);
    
    bool bElevated = false;
    if (GetTokenInformation(hToken, 
                            TokenElevation, 
                            &elevation, 
                            dwSize, 
                            &dwSize)) {
        bElevated = (elevation.TokenIsElevated != 0);
    }
    
    CloseHandle(hToken);
    return bElevated;
}
```

---

## Development Workflow

### Cross-Compilation from Linux

**Target**: Windows x86-64 via MinGW-w64

**Build Environment**:
```bash
# On Linux host
apt-get install mingw-w64 mingw-w64-tools

# Compiler chain
x86_64-w64-mingw32-gcc   # C compiler
x86_64-w64-mingw32-g++   # C++ compiler
x86_64-w64-mingw32-windres # Resource compiler
```

**Build Targets**:
```makefile
# Build service
make -f Makefile.windows service

# Build GUI
make -f Makefile.windows gui

# Build installer
make -f Makefile.windows installer

# Build all
make -f Makefile.windows all
```

### Testing Strategy

**Unit Tests** (`tests/`)
- TUN adapter lifecycle (`test_tun_adapter.c`)
- Service state machine (`test_service_lifecycle.c`)
- IPC protocol (`test_ipc_protocol.c`)
- Privilege boundaries (`test_privilege_boundary.c`)

**Integration Tests**
- Service start/stop cycles
- IPC message round-trips
- GUI to service communication
- Configuration loading and persistence

**System Tests**
- Installation and uninstallation
- Service autostart behavior
- Multiple GUI instances connecting to service
- Error recovery scenarios

### Code Organization

```
src/
├── core/           # Shared VPN logic (Linux/Windows)
│   ├── config.h/c
│   ├── peer.h/c
│   └── crypto.h/c
├── net/            # Network layer
│   ├── tun.h/c     # TUN device (platform-specific)
│   ├── udp.h/c     # UDP socket layer
│   └── packet.h/c  # Packet structure definitions
├── service/        # Windows service only
│   ├── service.h
│   ├── service_main.c
│   ├── service_install.c
│   └── service_state.h/c
├── ipc/            # IPC protocol
│   ├── protocol.h
│   └── protocol.c
└── main_service.c  # Service entry point (Windows)

gui/
├── main.cpp
├── mainwindow.h/cpp
├── trayicon.h/cpp
├── ipc_client.h/cpp
├── dialogs/
└── CMakeLists.txt

tests/
├── CMakeLists.txt
├── test_tun_adapter.c
├── test_service_lifecycle.c
├── test_ipc_protocol.c
└── test_privilege_boundary.c
```

---

## Cross-Platform Design Principles

### Platform Abstraction Layer

**Platform-specific implementations**:
```c
// src/net/tun.c - platform-specific
#ifdef _WIN32
    // Windows: Wintun API implementation
#elif __linux__
    // Linux: netlink/tap device implementation
#elif __APPLE__
    // macOS: utun device implementation
#endif

// src/net/udp.c - platform-specific
#ifdef _WIN32
    // Windows: Winsock2
#elif __linux__ || __APPLE__
    // Unix: BSD sockets
#endif

// src/ipc/protocol.c - platform-specific
#ifdef _WIN32
    // Windows: Named Pipes implementation
#elif __linux__
    // Linux: Unix domain sockets implementation
#endif
```

### Shared Interfaces

All platform implementations follow common interfaces:

```c
// Unified TUN interface
typedef struct TunDevice {
    int fd;  // Platform-specific file descriptor or handle
    char name[256];
    // ...
} TunDevice;

TunDevice* tun_create(const char *name);
int tun_send(TunDevice *dev, const uint8_t *pkt, size_t len);
int tun_recv(TunDevice *dev, uint8_t *pkt, size_t max_len);
void tun_destroy(TunDevice *dev);
```

### Configuration Portability

Configuration files (JSON) are identical across platforms:
```json
{
    "interface": { /* platform-independent */ },
    "peer": { /* platform-independent */ },
    "routing": { /* platform-independent */ }
}
```

---

## Implementation Roadmap

### Phase 1: Foundation (Current)
- [x] Architecture specification
- [ ] Wintun TUN implementation completion
- [ ] Service lifecycle framework

### Phase 2: IPC & Plumbing
- [ ] Named Pipe IPC implementation
- [ ] Service state management
- [ ] Statistics collection

### Phase 3: GUI (Basic)
- [ ] Qt project setup and build
- [ ] Main window with status display
- [ ] System tray icon
- [ ] Connect/disconnect functionality

### Phase 4: GUI (Advanced)
- [ ] Configuration wizard
- [ ] Configuration file editor
- [ ] Settings dialog
- [ ] Statistics visualization

### Phase 5: Installer & Polish
- [ ] NSIS installer configuration
- [ ] Service auto-start options
- [ ] Documentation and help
- [ ] Error messages and logging

### Phase 6: Testing & Hardening
- [ ] Comprehensive testing
- [ ] Security audit
- [ ] Performance optimization
- [ ] Release build process

---

## References

### Windows API Documentation
- Windows Service Control Manager (SCM)
- Named Pipes API
- Wintun Driver Guide
- Windows Cryptography API (CNG)
- Registry API

### Qt Documentation
- Qt Core (threading, signals/slots)
- Qt GUI (windows, dialogs)
- Qt Network (optional for future features)

### Related Standards
- Noise Protocol Framework (VPN key exchange)
- ChaCha20-Poly1305 (encryption/authentication)
- Curve25519 (key agreement)

---

## Document Control

**Version History**:
| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-01-24 | Documentation Specialist | Initial architecture specification |

**Next Review**: Phase 2 completion or significant design changes

**Approval**:
- [ ] Project Lead
- [ ] Security Lead
- [ ] Implementation Team Lead

```

---

[ARTIFACT:docs/ARCHITECTURE_DIAGRAMS.md]

```markdown
# HinkyPunk Windows GUI - Architecture Diagrams

## Detailed System Architecture

### Complete System Interaction Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        User Interaction                              │
│                      (GUI Application)                               │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  Main Window                                                  │  │
│  ├───────────────────────────────────────────────────────────────┤  │
│  │                                                                │  │
│  │  ┌─────────────────┐  ┌──────────────────┐                   │  │
│  │  │ Connect Button  │  │ Disconnect Button│                   │  │
│  │  └────────┬────────┘  └────────┬─────────┘                   │  │
│  │           │                    │                              │  │
│  │           └────────┬───────────┘                              │  │
│  │                    │                                           │  │
│  │           ┌────────▼───────┐                                 │  │
│  │           │ Status Display │ (Connected/Disconnected)        │  │
│  │           └────────┬───────┘                                 │  │
│  │                    │                                           │  │
│  │  ┌─────────────────┴─────────────────┐                       │  │
│  │  │ Statistics                        │                       │  │
│  │  │ • Download: XXX Mbps              │                       │  │
│  │  │ • Upload: XXX Mbps                │                       │  │
│  │  │ • Duration: XX:XX:XX              │                       │  │
│  │  │ • Latency: XX ms                  │                       │  │
│  │  └───────────────────────────────────┘                       │  │
│  │                                                                │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  Tray Icon (Minimize to system tray)                                │
│  Quick access context menu                                           │
└─────────────────────┬───────────────────────────────────────────────┘
                      │ IPC Named Pipe
                      │ \\.\pipe\hinkypunk_service
                      ▼
        ┌─────────────────────────────────────────┐
        │   Windows Service (SYSTEM privilege)    │
        │   hinkypunk-service.exe                 │
        ├─────────────────────────────────────────┤
        │                                         │
        │  IPC Server                             │
        │  ├─ Receive START/STOP/STATUS commands │
        │  └─ Send responses and status updates   │
        │                                         │
        │  State Manager                          │
        │  ├─ Connection state                   │
        │  ├─ Statistics tracking                │
        │  └─ Configuration management            │
        │                                         │
        │  Packet Processing                      │
        │  ├─ Decrypt inbound packets            │
        │  ├─ Encrypt outbound packets           │
        │  └─ Route decisions                     │
        │                                         │
        └────────┬────────────────────────────────┘
                 │
        ┌────────┴──────────────────────────────┐
        │                                        │
        ▼                                        ▼
    ┌────────────────┐             ┌────────────────────┐
    │ Wintun Device  │             │  UDP Socket        │
    │  (TAP adapter) │             │ (51820 or custom)  │
    │                │             │                    │
    │ • TUN packet   │             │ • Send encrypted   │
    │   ring buffer  │             │   packets to peers │
    │ • Receive IPs  │             │ • Receive packets  │
    │ • Send IPs to  │             │   from peers       │
    │   tunnels      │             │                    │
    └────────┬───────┘             └─────────┬──────────┘
             │                                │
             └────────────┬───────────────────┘
                          │
                    ┌─────▼─────┐
                    │  Network  │
                    │ Interface │
                    └───────────┘
                          │
                          ▼
                   Internet / Peers
```

### IPC Communication Sequence

```
GUI (Client)                          Service (Server)
     │                                     │
     │ 1. Connect to Named Pipe            │
     ├────────────────────────────────────►│
     │                                     │
     │ 2. Send START_VPN message           │
     ├────────────────────────────────────►│
     │                                     │
     │                     3. Initialize Wintun
     │                     4. Start packet threads
     │                                     │
     │ 5. Poll for status (GET_STATUS)     │
     ├────────────────────────────────────►│
     │                                     │
     │◄─────────────────────────────────────│ 6. Response (CONNECTING)
     │                                     │
     │ 7. Poll for stats (GET_STATS)       │
     ├────────────────────────────────────►│
     │                                     │
     │◄─────────────────────────────────────│ 8. Response (bytes, pkts)
     │                                     │
     │ [Packets flowing through tunnel]    │
     │                                     │
     │ 9. Poll for status                  │
     ├────────────────────────────────────►│
     │                                     │
     │◄─────────────────────────────────────│ 10. Response (CONNECTED)
     │                                     │
     │ 11. Send STOP_VPN message           │
     ├────────────────────────────────────►│
     │                                     │
     │                     12. Flush packets
     │                     13. Close Wintun
     │                     14. Stop threads
     │                                     │
     │◄─────────────────────────────────────│ 15. Response (OK)
     │                                     │
     │ 16. Disconnect from Named Pipe      │
     ├────────────────────────────────────►│
     │                                     │
```

### Packet Processing Flow

```
Outbound (User → Internet)
━━━━━━━━━━━━━━━━━━━━━━━━━━

User Application sends packet
         │
         ▼
    ┌────────────────┐
    │ Wintun Device  │ (TAP interface receives IP packet)
    │  Send Ring     │
    └────────┬───────┘
             │
             ▼
    ┌────────────────────────────┐
    │ Packet Processing Thread   │
    ├────────────────────────────┤
    │ 1. Read from send_ring     │
    │ 2. Parse IP header         │
    │ 3. Match routing rules     │
    │ 4. Extract destination IP  │
    └────────┬───────────────────┘
             │
             ▼
    ┌────────────────────────────┐
    │ Encryption                 │
    ├────────────────────────────┤
    │ 1. Build Noise header      │
    │ 2. ChaCha20-Poly1305 AEAD  │
    │ 3. Create transport packet │
    └────────┬───────────────────┘
             │
             ▼
    ┌────────────────────────────┐
    │ UDP Send                   │
    ├────────────────────────────┤
    │ 1. UDP socket sendto()     │
    │ 2. Send to peer endpoint   │
    │ 3. Update TX statistics    │
    └────────┬───────────────────┘
             │
             ▼
        Internet / Peer


Inbound (Internet → User)
━━━━━━━━━━━━━━━━━━━━━━━━

        Internet / Peer
             │
             ▼
    ┌────────────────────────────┐
    │ UDP Receive                │
    ├────────────────────────────┤
    │ 1. UDP socket recvfrom()   │
    │ 2. Receive from any peer   │
    │ 3. Update RX statistics    │
    └────────┬───────────────────┘
             │
             ▼
    ┌────────────────────────────┐
    │ Decryption                 │
    ├────────────────────────────┤
    │ 1. Parse Noise header      │
    │ 2. ChaCha20-Poly1305 AEAD  │
    │ 3. Extract inner IP packet │
    └────────┬───────────────────┘
             │
             ▼
    ┌────────────────────────────┐
    │ Packet Processing Thread   │
    ├────────────────────────────┤
    │ 1. Parse IP header         │
    │ 2. Verify source address   │
    │ 3. Route to TUN            │
    └────────┬───────────────────┘
             │
             ▼
    ┌────────────────────────────┐
    │ Wintun Device              │
    │  Receive Ring              │
    └────────┬───────────────────┘
             │
             ▼
    User Application receives packet
```

### Service State Transitions with Timeouts

```
                    [DISCONNECTED]
                           │
                           │ START command
                           │
                           ▼
                    [CONNECTING]
                           │
                  ┌────────┴────────┐
                  │                 │
         Wintun init         IPC timeout
            error?           (5 seconds)?
         │         │             │
         │ No      │ Yes         │ Yes
         │         │             │
         │         ▼             │
         │    [ERROR]            │
         │         │             ▼
         │         │         [TIMEOUT]
         │         │             │
         │         │             │ Retry or STOP
         │         │             │
         │         └─────┬───────┘
         │               │
         │               ▼
         │          [DISCONNECTED]
         │
         ▼
    [CONNECTED]
         │
     ┌───┴───┐
     │       │
  STOP    Crash
     │       │
     ▼       ▼
[DISCONNECTING]
     │
     └──►[DISCONNECTED]

Legend:
[STATE] = Service operational state
  │     = State transition
  ►     = Command/event
  ?     = Decision point
```

### Thread Communication and Synchronization

```
Service Main Thread
├─ SCM Control Handler (async)
│  └─ Sets g_service.shutdown_requested
│
├─ IPC Server Loop
│  ├─ Listen on Named Pipe
│  ├─ Read commands (START, STOP, STATUS, STATS)
│  ├─ Validate message
│  ├─ Acquire state_lock
│  ├─ Execute command
│  ├─ Release state_lock
│  └─ Write response
│
└─ Synchronized via:
   ├─ CRITICAL_SECTION state_lock
   ├─ Event handles for thread signaling
   └─ Atomic flags (volatile)

Packet Processing Thread
├─ Main loop:
│  ├─ Check shutdown_requested
│  ├─ Poll Wintun recv_ring
│  │  ├─ Read packets
│  │  ├─ Decrypt each packet
│  │  ├─ Route decision
│  │  └─ Queue for sending
│  ├─ Write send_ring
│  ├─ Poll UDP socket
│  │  ├─ Read packets from peer
│  │  ├─ Decrypt
│  │  └─ Write to Wintun recv_ring
│  └─ Acquire state_lock for stats update
│
└─ Synchronized via:
   ├─ WaitForMultipleObjects on events
   ├─ CRITICAL_SECTION state_lock (stats)
   └─ Ring buffer signaling

Statistics Thread
├─ Periodic timer (1 second)
├─ Calculate rates:
│  ├─ bytes_per_second
│  ├─ packets_per_second
│  └─ latency estimates
├─ Acquire state_lock
├─ Update stats structure
├─ Release state_lock
└─ Synchronized via:
   └─ CRITICAL_SECTION state_lock
```

### GUI State Management Flow

```
QApplication Start
        │
        ▼
Create MainWindow
        │
        ▼
Create AppState (singleton)
        │
        ▼
Create IpcClient
        │
        ├─► Connect to service
        │
        ▼
Load Configuration Files
        │
        ▼
Request Initial Status
        │
        └─► Display UI / Minimize to tray
                │
                ▼
    [Event Loop Running]
                │
        ┌───────┼────────┐
        │       │        │
        │       │        ▼
        │       │   Timer Event (1 sec)
        │       │   - Request stats
        │       │   - Request status
        │       │
        │       ▼
        │   User Action
        │   - Click Connect
        │   - Click Disconnect
        │   - Open config dialog
        │   - Change settings
        │
        ▼
    IPC Response Received
        │
        ├─► Status update
        │   └─► AppState::stateChanged(signal)
        │       └─► UI updated
        │
        ├─► Stats update
        │   └─► AppState::statsChanged(signal)
        │       └─► UI updated (speeds, totals)
        │
        └─► Error
            └─► AppState::errorOccurred(signal)
                └─► Show error dialog
```

---

[COMPLETE]
```

---

## Documentation Artifacts Created

I have successfully created comprehensive architecture specification documentation for the HinkyPunk VPN Windows GUI project:

### Deliverables:

1. **[ARTIFACT:docs/ARCHITECTURE.md]** - Complete 40+ section architecture specification covering:
   - System overview and design philosophy
   - High-level component architecture with process separation
   - Detailed Windows TUN implementation design
   - Service architecture with state machine and threading model
   - IPC protocol specifications with message schemas
   - Qt GUI architecture and component structure
   - Deployment model with Windows installer guidance
   - Comprehensive security considerations
   - Development workflow and cross-compilation strategy
   - Implementation roadmap with 6 phases

2. **[ARTIFACT:docs/ARCHITECTURE_DIAGRAMS.md]** - Visual architecture reference with:
   - Complete system interaction diagram
   - IPC communication sequence
   - Outbound/inbound packet processing flows
   - Service state transition diagrams with timeouts
   - Thread communication and synchronization model
   - GUI state management flow

### Key Specifications Documented:

- **Privilege Separation**: GUI runs as user, service as SYSTEM
- **IPC Protocol**: Binary, length-prefixed messages over Windows Named Pipes
- **Service Lifecycle**: Complete initialization, startup, and shutdown sequences
- **GUI Framework**: Qt 6 with C++ for cross-platform capability
- **Thread Model**: Main service thread, packet processor thread, stats thread with CRITICAL_SECTION synchronization
- **Configuration**: JSON-based format with optional DPAPI encryption
- **Security**: Input validation, privilege elevation detection, secure memory handling

The documentation is comprehensive, includes implementation details (function signatures, data structures, code examples), and provides clear guidance for the implementation team.

[COMPLETE]
