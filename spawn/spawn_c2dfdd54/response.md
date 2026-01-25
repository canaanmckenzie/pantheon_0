I understand my assignment. I'm a BACKEND SPECIALIST subagent tasked with designing the Windows service architecture and lifecycle for the HinkyPunk VPN project.

Let me analyze the requirements and produce a comprehensive backend architecture design.

## Windows Service Architecture & Lifecycle Design

### 1. SERVICE ARCHITECTURE OVERVIEW

The Windows service will follow a privilege-separated model:

```
┌─────────────────────────────────────────────────────────┐
│         USER-MODE GUI APPLICATION (Low Privilege)       │
│  - System tray, configuration UI, status display         │
│  - IPC client using Named Pipes                          │
└────────────────────┬────────────────────────────────────┘
                     │ Named Pipe IPC
                     │ (\\.\pipe\hinkypunk_service)
                     ▼
┌─────────────────────────────────────────────────────────┐
│      WINDOWS SERVICE (SYSTEM Account - High Privilege)   │
│  - TUN device management                                 │
│  - Packet processing (encrypt/decrypt)                   │
│  - IPC server for command handling                       │
│  - Service lifecycle management                          │
└─────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│          CORE VPN ENGINE (Existing C Code)               │
│  - Cryptography (ChaCha20, Curve25519, BLAKE2s)         │
│  - Packet encryption/decryption                          │
│  - Peer management                                       │
└─────────────────────────────────────────────────────────┘
```

### 2. SERVICE LIFECYCLE STATES

```
[STOPPED]
    │
    ├─ Start Service Command
    │
    ▼
[STARTING] → Load Wintun.dll → Create TUN Adapter → Initialize Engine
    │
    ▼
[RUNNING]
    ├─ Accept IPC Connections
    ├─ Process VPN Packets
    ├─ Handle Configuration Changes
    │
    ├─ Stop/Shutdown Command
    │
    ▼
[STOPPING] → Close Connections → Cleanup TUN → Shutdown Engine
    │
    ▼
[STOPPED]

Error States:
[RUNNING] → [ERROR] → [STOPPING] (auto-recovery attempt or manual restart)
```

### 3. SERVICE ENTRY POINT & MAIN LOOP

[ARTIFACT:src/service/service_main.c]
```c
#include <windows.h>
#include <stdio.h>
#include "service.h"
#include "ipc_server.h"
#include "../vpn_engine.h"

// Global service state
static SERVICE_STATUS g_service_status = {0};
static SERVICE_STATUS_HANDLE g_status_handle = NULL;
static HANDLE g_stop_event = NULL;
static vpn_engine_t *g_vpn_engine = NULL;
static ipc_server_t *g_ipc_server = NULL;

// Forward declarations
static VOID WINAPI ServiceMain(DWORD argc, LPTSTR *argv);
static VOID WINAPI ServiceControlHandler(DWORD control);
static DWORD WINAPI ServiceWorkerThread(LPVOID param);

int main(int argc, char *argv[]) {
    // Check for install/uninstall/run flags
    if (argc > 1) {
        if (strcmp(argv[1], "--install") == 0) {
            return service_install();
        } else if (strcmp(argv[1], "--uninstall") == 0) {
            return service_uninstall();
        } else if (strcmp(argv[1], "--run") == 0) {
            // Run as console app (for debugging)
            return service_run_console();
        }
    }

    // Normal service dispatcher entry
    SERVICE_TABLE_ENTRY dispatch_table[] = {
        {TEXT("HinkyPunkService"), ServiceMain},
        {NULL, NULL}
    };

    if (!StartServiceCtrlDispatcher(dispatch_table)) {
        // Service dispatcher failed - might be running as console
        fprintf(stderr, "StartServiceCtrlDispatcher failed: %ld\n", GetLastError());
        return 1;
    }

    return 0;
}

static VOID WINAPI ServiceMain(DWORD argc, LPTSTR *argv) {
    // Register service control handler
    g_status_handle = RegisterServiceCtrlHandler(
        TEXT("HinkyPunkService"),
        ServiceControlHandler
    );

    if (!g_status_handle) {
        fprintf(stderr, "RegisterServiceCtrlHandler failed: %ld\n", GetLastError());
        return;
    }

    // Initialize service status
    g_service_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_service_status.dwCurrentState = SERVICE_START_PENDING;
    g_service_status.dwControlsAccepted = SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN;
    g_service_status.dwWin32ExitCode = 0;
    g_service_status.dwServiceSpecificExitCode = 0;
    g_service_status.dwCheckPoint = 0;
    g_service_status.dwWaitHint = 3000; // 3 seconds for startup

    SetServiceStatus(g_status_handle, &g_service_status);

    // Create stop event
    g_stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!g_stop_event) {
        g_service_status.dwCurrentState = SERVICE_STOPPED;
        g_service_status.dwWin32ExitCode = GetLastError();
        SetServiceStatus(g_status_handle, &g_service_status);
        return;
    }

    // Start service worker thread
    HANDLE worker_thread = CreateThread(
        NULL,
        0,
        ServiceWorkerThread,
        NULL,
        0,
        NULL
    );

    if (!worker_thread) {
        g_service_status.dwCurrentState = SERVICE_STOPPED;
        g_service_status.dwWin32ExitCode = GetLastError();
        SetServiceStatus(g_status_handle, &g_service_status);
        CloseHandle(g_stop_event);
        return;
    }

    // Wait for worker thread
    WaitForSingleObject(worker_thread, INFINITE);

    CloseHandle(worker_thread);
    CloseHandle(g_stop_event);

    g_service_status.dwCurrentState = SERVICE_STOPPED;
    SetServiceStatus(g_status_handle, &g_service_status);
}

static VOID WINAPI ServiceControlHandler(DWORD control) {
    switch (control) {
        case SERVICE_CONTROL_STOP:
        case SERVICE_CONTROL_SHUTDOWN:
            g_service_status.dwCurrentState = SERVICE_STOP_PENDING;
            g_service_status.dwCheckPoint = 0;
            g_service_status.dwWaitHint = 3000;
            SetServiceStatus(g_status_handle, &g_service_status);
            SetEvent(g_stop_event);
            break;

        case SERVICE_CONTROL_INTERROGATE:
            SetServiceStatus(g_status_handle, &g_service_status);
            break;

        default:
            break;
    }
}

static DWORD WINAPI ServiceWorkerThread(LPVOID param) {
    (void)param;

    // Initialize VPN engine
    g_vpn_engine = vpn_engine_create();
    if (!g_vpn_engine) {
        fprintf(stderr, "Failed to create VPN engine\n");
        return 1;
    }

    // Initialize IPC server
    g_ipc_server = ipc_server_create(TEXT("hinkypunk_service"));
    if (!g_ipc_server) {
        fprintf(stderr, "Failed to create IPC server\n");
        vpn_engine_destroy(g_vpn_engine);
        return 1;
    }

    // Signal service is running
    g_service_status.dwCurrentState = SERVICE_RUNNING;
    g_service_status.dwCheckPoint = 0;
    g_service_status.dwWaitHint = 0;
    SetServiceStatus(g_status_handle, &g_service_status);

    // Main service loop
    while (WaitForSingleObject(g_stop_event, 100) == WAIT_TIMEOUT) {
        // Process IPC messages
        ipc_server_process_messages(g_ipc_server, g_vpn_engine);
        
        // Process VPN packets
        vpn_engine_process_packets(g_vpn_engine);
    }

    // Cleanup
    ipc_server_destroy(g_ipc_server);
    vpn_engine_destroy(g_vpn_engine);

    return 0;
}

int service_run_console(void) {
    // For debugging - run service logic without service control manager
    printf("Running HinkyPunk Service in console mode...\n");
    printf("Press Ctrl+C to stop\n\n");

    g_stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    
    g_vpn_engine = vpn_engine_create();
    if (!g_vpn_engine) {
        printf("Failed to create VPN engine\n");
        return 1;
    }

    g_ipc_server = ipc_server_create(TEXT("hinkypunk_service_debug"));
    if (!g_ipc_server) {
        printf("Failed to create IPC server\n");
        vpn_engine_destroy(g_vpn_engine);
        return 1;
    }

    printf("Service initialized. Listening on named pipe...\n");

    // Main loop
    while (WaitForSingleObject(g_stop_event, 100) == WAIT_TIMEOUT) {
        ipc_server_process_messages(g_ipc_server, g_vpn_engine);
        vpn_engine_process_packets(g_vpn_engine);
    }

    ipc_server_destroy(g_ipc_server);
    vpn_engine_destroy(g_vpn_engine);
    CloseHandle(g_stop_event);

    printf("Service stopped\n");
    return 0;
}
```

### 4. SERVICE INSTALLATION/UNINSTALLATION

[ARTIFACT:src/service/service_install.c]
```c
#include <windows.h>
#include <winsvc.h>
#include <stdio.h>
#include <tchar.h>

#define SERVICE_NAME TEXT("HinkyPunkService")
#define SERVICE_DISPLAY_NAME TEXT("HinkyPunk VPN Service")
#define SERVICE_DESCRIPTION TEXT("Windows VPN service for HinkyPunk")

int service_install(void) {
    SC_HANDLE scm_handle = NULL;
    SC_HANDLE service_handle = NULL;
    TCHAR binary_path[MAX_PATH];
    int result = 1;

    // Get the path to the service executable
    if (!GetModuleFileName(NULL, binary_path, MAX_PATH)) {
        fprintf(stderr, "GetModuleFileName failed: %ld\n", GetLastError());
        return 1;
    }

    // Open service control manager
    scm_handle = OpenSCManager(NULL, NULL, SC_MANAGER_CREATE_SERVICE);
    if (!scm_handle) {
        fprintf(stderr, "OpenSCManager failed: %ld\n", GetLastError());
        return 1;
    }

    // Create service
    service_handle = CreateService(
        scm_handle,
        SERVICE_NAME,
        SERVICE_DISPLAY_NAME,
        SERVICE_ALL_ACCESS,
        SERVICE_WIN32_OWN_PROCESS,
        SERVICE_AUTO_START,
        SERVICE_ERROR_NORMAL,
        binary_path,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    );

    if (!service_handle) {
        DWORD error = GetLastError();
        if (error == ERROR_SERVICE_EXISTS) {
            printf("Service already installed\n");
            result = 0;
        } else {
            fprintf(stderr, "CreateService failed: %ld\n", error);
        }
        goto cleanup;
    }

    // Set service description
    SERVICE_DESCRIPTION desc;
    desc.lpDescription = SERVICE_DESCRIPTION;
    if (!ChangeServiceConfig2(service_handle, SERVICE_CONFIG_DESCRIPTION, &desc)) {
        fprintf(stderr, "ChangeServiceConfig2 failed: %ld\n", GetLastError());
        goto cleanup;
    }

    printf("Service installed successfully\n");
    result = 0;

cleanup:
    if (service_handle) CloseServiceHandle(service_handle);
    if (scm_handle) CloseServiceHandle(scm_handle);
    return result;
}

int service_uninstall(void) {
    SC_HANDLE scm_handle = NULL;
    SC_HANDLE service_handle = NULL;
    SERVICE_STATUS status;
    int result = 1;

    // Open service control manager
    scm_handle = OpenSCManager(NULL, NULL, SC_MANAGER_ALL_ACCESS);
    if (!scm_handle) {
        fprintf(stderr, "OpenSCManager failed: %ld\n", GetLastError());
        return 1;
    }

    // Open service
    service_handle = OpenService(scm_handle, SERVICE_NAME, DELETE | SERVICE_STOP);
    if (!service_handle) {
        fprintf(stderr, "OpenService failed: %ld\n", GetLastError());
        goto cleanup;
    }

    // Stop service if running
    if (!ControlService(service_handle, SERVICE_CONTROL_STOP, &status)) {
        DWORD error = GetLastError();
        if (error != ERROR_SERVICE_NOT_ACTIVE) {
            fprintf(stderr, "ControlService failed: %ld\n", error);
            goto cleanup;
        }
    }

    // Wait for service to stop
    for (int i = 0; i < 10; i++) {
        if (QueryServiceStatus(service_handle, &status)) {
            if (status.dwCurrentState == SERVICE_STOPPED) break;
        }
        Sleep(100);
    }

    // Delete service
    if (!DeleteService(service_handle)) {
        fprintf(stderr, "DeleteService failed: %ld\n", GetLastError());
        goto cleanup;
    }

    printf("Service uninstalled successfully\n");
    result = 0;

cleanup:
    if (service_handle) CloseServiceHandle(service_handle);
    if (scm_handle) CloseServiceHandle(scm_handle);
    return result;
}
```

### 5. SERVICE STATE MANAGER

[ARTIFACT:src/service/service_state.h]
```c
#ifndef SERVICE_STATE_H
#define SERVICE_STATE_H

#include <windows.h>
#include <time.h>

typedef enum {
    SERVICE_STATE_STOPPED = 0,
    SERVICE_STATE_STARTING = 1,
    SERVICE_STATE_RUNNING = 2,
    SERVICE_STATE_STOPPING = 3,
    SERVICE_STATE_ERROR = 4
} service_state_t;

typedef struct {
    service_state_t state;
    DWORD error_code;
    char error_message[256];
    time_t start_time;
    DWORD packet_count;
    uint64_t bytes_sent;
    uint64_t bytes_received;
} service_status_t;

typedef struct {
    CRITICAL_SECTION lock;
    service_status_t status;
} service_state_manager_t;

service_state_manager_t *service_state_create(void);
void service_state_destroy(service_state_manager_t *mgr);

void service_state_set(service_state_manager_t *mgr, service_state_t state);
void service_state_set_error(service_state_manager_t *mgr, DWORD error, const char *message);
service_status_t service_state_get(service_state_manager_t *mgr);

void service_state_update_stats(
    service_state_manager_t *mgr,
    uint64_t bytes_sent,
    uint64_t bytes_received
);

#endif
```

[ARTIFACT:src/service/service_state.c]
```c
#include "service_state.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

service_state_manager_t *service_state_create(void) {
    service_state_manager_t *mgr = malloc(sizeof(service_state_manager_t));
    if (!mgr) return NULL;

    InitializeCriticalSection(&mgr->lock);
    
    mgr->status.state = SERVICE_STATE_STOPPED;
    mgr->status.error_code = 0;
    mgr->status.error_message[0] = '\0';
    mgr->status.start_time = 0;
    mgr->status.packet_count = 0;
    mgr->status.bytes_sent = 0;
    mgr->status.bytes_received = 0;

    return mgr;
}

void service_state_destroy(service_state_manager_t *mgr) {
    if (!mgr) return;
    DeleteCriticalSection(&mgr->lock);
    free(mgr);
}

void service_state_set(service_state_manager_t *mgr, service_state_t state) {
    if (!mgr) return;

    EnterCriticalSection(&mgr->lock);
    mgr->status.state = state;
    if (state == SERVICE_STATE_RUNNING) {
        mgr->status.start_time = time(NULL);
    }
    LeaveCriticalSection(&mgr->lock);
}

void service_state_set_error(service_state_manager_t *mgr, DWORD error, const char *message) {
    if (!mgr) return;

    EnterCriticalSection(&mgr->lock);
    mgr->status.state = SERVICE_STATE_ERROR;
    mgr->status.error_code = error;
    if (message) {
        strncpy_s(mgr->status.error_message, sizeof(mgr->status.error_message), message, _TRUNCATE);
    }
    LeaveCriticalSection(&mgr->lock);
}

service_status_t service_state_get(service_state_manager_t *mgr) {
    service_status_t result = {0};
    if (!mgr) return result;

    EnterCriticalSection(&mgr->lock);
    result = mgr->status;
    LeaveCriticalSection(&mgr->lock);

    return result;
}

void service_state_update_stats(
    service_state_manager_t *mgr,
    uint64_t bytes_sent,
    uint64_t bytes_received
) {
    if (!mgr) return;

    EnterCriticalSection(&mgr->lock);
    mgr->status.bytes_sent = bytes_sent;
    mgr->status.bytes_received = bytes_received;
    mgr->status.packet_count++;
    LeaveCriticalSection(&mgr->lock);
}
```

### 6. SERVICE HEADER

[ARTIFACT:src/service/service.h]
```c
#ifndef SERVICE_H
#define SERVICE_H

int service_install(void);
int service_uninstall(void);
int service_run_console(void);

#endif
```

### 7. KEY ARCHITECTURAL PRINCIPLES

**Privilege Boundary:**
- Service runs as SYSTEM (high privilege)
- GUI runs as user (low privilege)
- All communication through Named Pipes (mediated)
- No direct file access from GUI to service state

**Thread Safety:**
- CRITICAL_SECTION for state protection
- IPC queue for command processing
- Non-blocking packet processing loop

**Error Handling:**
- Graceful shutdown on initialization failure
- Service continues running on individual command failures
- Detailed error logging for debugging
- Automatic state recovery on specific errors

**Resource Lifecycle:**
- Clean startup sequence: Engine → IPC Server
- Clean shutdown sequence: Stop accepting → Close connections → Cleanup
- Handle unexpected termination gracefully

### 8. INTEGRATION POINTS

The service architecture integrates with:
1. **Existing VPN Engine** (`vpn_engine_t`) - Packet processing, peer management
2. **Wintun TUN Implementation** - Called by VPN engine
3. **IPC Server** - Handles GUI commands and state queries
4. **Windows Service Manager** - Service lifecycle control

[COMPLETE]
