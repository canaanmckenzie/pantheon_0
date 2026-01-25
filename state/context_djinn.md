# CRITICAL OPERATING INSTRUCTIONS
You are operating in TEXT-ONLY mode. Do NOT use any tools (Read, Bash, Task, Grep, etc.).
Instead, produce your response as structured text with markers like:
- [TASK]description[/TASK] for tasks
- [MSG:agent_name]content[/MSG] for messages
- [SPAWN]specialization:task[/SPAWN] for spawn requests (Weaver/Djinn only)
- [ARTIFACT:path]content[/ARTIFACT] for artifacts
- [COMPLETE] when done

Respond with ANALYSIS AND PLANNING ONLY. Do not attempt to execute commands or read files.

# DIRECTIVE
Implement solutions, spawn specialists as needed

# CURRENT STATE
# PROJECT STATE

## Brief
# Project Brief: HinkyPunk VPN Windows GUI Compatibility

## Objective
Add full Windows compatibility with a native GUI to the HinkyPunk VPN project, similar to WireGuard's Windows application.

## Project Location
Parent directory: `/home/grimmer/HinkyPunk/`

## Current State
- Pure C VPN implementation with zero external dependencies
- Cryptography implemented from scratch (ChaCha20-Poly1305, Curve25519, BLAKE2s, Noise IK)
- Linux support is complete and working
- Windows scaffolding exists in `src/net/tun.c` (Wintun API declarations ~70% complete)
- Windows socket support exists in `src/net/udp.c` (Winsock2)
- macOS scaffolding exists (basic structure only)
- CLI-only interface, no GUI

## Requirements

### 1. Complete Windows TUN Implementation
- Finish Wintun driver integration in `src/net/tun.c`
- Implement packet ring buffer I/O
- Handle adapter lifecycle (create/delete)
- Support dynamic wintun.dll loading

### 2. Windows Service Architecture
Create a background service that:
- Runs with elevated privileges (SYSTEM account)
- Manages TUN device operations
- Handles encryption/decryption
- Supports start/stop/restart via IPC

### 3. IPC Layer for GUI-Service Communication
- Windows: Named Pipes (`\\.\pipe\hinkypunk_service`)
- Protocol for: start/stop VPN, query status, get statistics, change config
- Keep cross-platform compatible design for future Linux GUI

### 4. Native Windows GUI Application
Design like WireGuard's Windows GUI:
- System tray icon with quick connect/disconnect
- Main window showing:
  - Connection status (connected/disconnected/connecting)
  - Active peer information
  - Traffic statistics (bytes sent/received)
  - Connection duration
- Configuration management:
  - Import/export .conf files
  - Create new tunnels with guided wizard
  - Edit existing configurations
- Settings:
  - Launch at Windows startup
  - Minimize to tray
  - Notifications

### 5. Build System Updates
- Add Windows GUI build targets to Makefile
- Support for Windows resource files (.rc)
- Application manifest for Windows 10+ compatibility
- Installer/uninstaller creation (NSIS or WiX)

### 6. Development Constraints
- Developing on Linux - create cross-compilable code
- Test Windows-specific code paths carefully
- Maintain C codebase for core (GUI can be C++ with Qt or similar)
- Document all Windows-specific APIs used

## Suggested GUI Framework
Qt is recommended for:
- Cross-platform potential (same GUI on Windows/Linux/macOS later)
- Native look on each platform
- Good C++ integration with existing C code
- Mature ecosystem

## Deliverables
1. Complete Wintun TUN implementation
2. Windows service manager code
3. IPC protocol specification and implementation
4. Qt-based GUI application
5. Updated Makefile with Windows GUI targets
6. Windows installer configuration
7. Updated documentation and README

## Priority Order
1. Complete Wintun TUN (required for everything else)
2. Service/daemon separation
3. IPC protocol
4. Basic GUI with tray icon
5. Full GUI features
6. Installer/polish

## Notes
- Maintain the educational focus of the project
- Keep code well-documented
- Security is paramount - no shortcuts in crypto or privilege handling
- Remember this is a Linux development machine - structure code for cross-compilation

## Status
INITIALIZING

## Phase
0 - INCEPTION

## Critical Path
- [ ] Requirements analysis
- [ ] Architecture design
- [ ] Implementation
- [ ] Testing
- [ ] Documentation
- [ ] Delivery

# TASK BOARD
[
  {
    "id": "task_71d65694",
    "description": "Analyze existing codebase structure",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_2fdefb49",
    "description": "Define Windows TUN implementation requirements",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_52d1ca0e",
    "description": "Design IPC protocol specification",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_ab79c8cb",
    "description": "Design Windows service architecture",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_f38acc17",
    "description": "Design Qt GUI architecture",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_8c21bfc6",
    "description": "Update Makefile strategy",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  },
  {
    "id": "task_6bd9233b",
    "description": "Phase 0 Inception - Spawn workers for parallel analysis",
    "creator": "weaver",
    "priority": "normal",
    "status": "pending",
    "created": "2026-01-24T21:32:07-05:00",
    "assigned_to": null,
    "completed": null
  }
]

# MESSAGES FOR YOU
[]

# ARTIFACTS
[]

# YOUR PREVIOUS OUTPUT
First cycle.

