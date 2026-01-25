I understand. I'm a FRONTEND SPECIALIST subagent focused on **designing Qt GUI component architecture** for the HinkyPunk Windows VPN GUI.

Based on the project state, I need to design a native Windows GUI similar to WireGuard that:
- Connects to the service via IPC (named pipes)
- Displays connection status, peer info, and traffic statistics
- Provides configuration management
- Integrates with system tray

## Qt GUI Component Architecture Design

### 1. **Application Structure**

```
gui/
├── CMakeLists.txt
├── src/
│   ├── main.cpp
│   ├── application.h
│   ├── application.cpp
│   ├── windows/
│   │   ├── main_window.h
│   │   ├── main_window.cpp
│   │   ├── settings_dialog.h
│   │   ├── settings_dialog.cpp
│   │   ├── tunnel_wizard.h
│   │   └── tunnel_wizard.cpp
│   ├── widgets/
│   │   ├── status_panel.h
│   │   ├── status_panel.cpp
│   │   ├── peer_list.h
│   │   ├── peer_list.cpp
│   │   ├── statistics_panel.h
│   │   └── statistics_panel.cpp
│   ├── tray/
│   │   ├── tray_icon.h
│   │   └── tray_icon.cpp
│   ├── ipc/
│   │   ├── service_client.h
│   │   ├── service_client.cpp
│   │   └── ipc_connection.h
│   ├── models/
│   │   ├── tunnel_model.h
│   │   ├── tunnel_model.cpp
│   │   ├── peer_model.h
│   │   └── peer_model.cpp
│   └── resources/
│       └── resources.qrc
└── forms/
    ├── main_window.ui
    ├── settings_dialog.ui
    └── tunnel_wizard.ui
```

### 2. **Core Components**

#### **Application (application.h/cpp)**
- Manages Qt application lifecycle
- Initializes system tray
- Handles startup/shutdown
- Registry integration for auto-launch
- Singleton pattern for service client access

#### **MainWindow (main_window.h/cpp)**
Central UI container with:
- Header: Connection status indicator (LED), tunnel name
- Status panel: Connection state, duration, peer info
- Statistics panel: Real-time traffic graphs
- Action buttons: Connect/Disconnect, Settings
- Menu bar: File, Edit, View, Help
- Status bar: Service connection status

#### **StatusPanel (status_panel.h/cpp)**
Displays:
- Large circular status indicator (green/red/yellow)
- Connection state text ("Connected", "Disconnected", "Connecting")
- Active peer information (IP, endpoint, last handshake)
- Connection duration timer
- Allowed IPs list

#### **StatisticsPanel (statistics_panel.h/cpp)**
Shows:
- Real-time traffic graphs (sent/received bytes)
- Data transferred counters
- Refresh interval controls (1s, 5s, 10s)
- Uses QChart for visualization

#### **PeerListWidget (peer_list.h/cpp)**
- Displays configured tunnels/peers
- Double-click to connect
- Right-click context menu: Edit, Delete, Duplicate, Export
- Drag-drop for reordering
- Search/filter functionality

#### **TrayIcon (tray_icon.h/cpp)**
System tray integration:
- Context menu: Show/Hide, Connect/Disconnect, Settings, Exit
- Double-click to show main window
- Status tooltip showing connection state
- Icon changes based on connection status

#### **ServiceClient (service_client.h/cpp)**
IPC communication layer:
- Wraps `src/ipc/protocol.c` functionality
- Async message handling with Qt signals/slots
- Connection status monitoring
- Automatic reconnection on service restart
- Thread-safe queue for requests

#### **SettingsDialog (settings_dialog.h/cpp)**
Configuration UI:
- Launch at startup toggle
- Minimize to tray toggle
- Theme selection (light/dark)
- Notification preferences
- Advanced: Log level, service restart button

#### **TunnelWizard (tunnel_wizard.h/cpp)**
Multi-step configuration:
- Step 1: Import file or new tunnel
- Step 2: Edit config (keys, endpoint, allowed IPs)
- Step 3: Review and save
- Validation at each step

### 3. **Data Models**

#### **TunnelModel (tunnel_model.h/cpp)**
- Qt abstract model for tunnel list
- Manages tunnel configuration data
- Signals for add/remove/update
- Persistence to config files

#### **PeerModel (peer_model.h/cpp)**
- Represents active peer statistics
- Updates from service via IPC
- Handles real-time data refresh

### 4. **IPC Integration Layer (ipc/)**

#### **IPCConnection (ipc_connection.h)**
```cpp
class IPCConnection : public QObject {
    Q_OBJECT
public:
    bool connect_to_service();
    void disconnect_from_service();
    
    void send_request(const ipc_message_t* msg);
    
signals:
    void connected();
    void disconnected();
    void message_received(const ipc_message_t* msg);
    void error(const QString& error_msg);
    
private slots:
    void on_data_ready();
    
private:
    QLocalSocket* socket;
};
```

#### **ServiceClient (service_client.h/cpp)**
```cpp
class ServiceClient : public QObject {
    Q_OBJECT
public:
    static ServiceClient* instance();
    
    void start_vpn(const QString& tunnel_name);
    void stop_vpn();
    void query_status();
    
signals:
    void status_changed(const ipc_status_response_t* status);
    void connected_to_service();
    void disconnected_from_service();
    void error(const QString& error);
    
private:
    IPCConnection* ipc;
};
```

### 5. **State Management**

- **Application State**: Using Qt's model-view architecture
- **Service State**: Cached locally, updated via IPC
- **UI State**: Managed by individual widgets with QAction/QSignalMapper

### 6. **Threading Model**

- **Main (GUI) Thread**: All UI operations
- **IPC Thread**: Service communication via QThread
- **Signal/Slot mechanism**: Thread-safe IPC updates

### 7. **Resource Architecture (resources.qrc)**

```xml
<RCC>
    <qresource prefix="/">
        <file>images/connected.png</file>
        <file>images/disconnected.png</file>
        <file>images/connecting.png</file>
        <file>styles/dark.qss</file>
        <file>styles/light.qss</file>
    </qresource>
</RCC>
```

### 8. **Key Design Patterns**

- **Singleton**: ServiceClient, Application
- **Model-View**: Qt's MVC for lists
- **Observer**: Qt signals/slots for state changes
- **Factory**: Dialog creation for settings/wizards
- **Strategy**: Different IPC transports (named pipes on Windows, Unix sockets on Linux)

### 9. **Build Integration**

- Qt 6.x (or 5.15 for compatibility)
- CMake with Qt toolchain
- Cross-compilation support via CMake variables
- Resource compilation (.ui → .h)

### 10. **Dependencies**

- Qt Core, Gui, Widgets, Network, Concurrent
- OpenSSL (Qt's crypto support, optional)
- No external GUI libraries beyond Qt

### 11. **Security Considerations**

- IPC client validates service responses
- No hardcoded credentials in UI
- Configuration files stored in `%APPDATA%\HinkyPunk\`
- Registry writes limited to HKCU for auto-launch
- UI runs with user privileges, service runs as SYSTEM

[COMPLETE]
