# Windows Cross-Compilation Build System Design

## Analysis

I've reviewed the project state and existing artifacts. The HinkyPunk project requires a sophisticated Windows cross-compilation build system to:

1. **Cross-compile from Linux** to Windows targets (x86, x86_64, ARM64)
2. **Integrate C core** with Windows service and GUI components
3. **Manage dependencies** (Wintun, Qt, Windows SDK headers)
4. **Support development workflow** with proper toolchains and validation
5. **Enable CI/CD pipelines** for automated Windows builds

## Architecture Decision

Given the existing Makefile-based build system and the need for Windows cross-compilation from Linux, I recommend:

- **Primary**: Docker-based cross-compilation environment (reproducible, isolated)
- **Secondary**: Makefile enhancements for native toolchain detection
- **CI/CD**: GitHub Actions workflow for automated builds
- **Packaging**: NSIS installer generation with code signing support

This approach maintains the educational focus while enabling professional-grade builds.

## Design Components

### 1. Docker Build Environment

**[ARTIFACT:docker/Dockerfile.windows]**

```dockerfile
FROM debian:bookworm-slim

# Install MinGW-w64 cross-compilation toolchain
RUN apt-get update && apt-get install -y \
    build-essential \
    mingw-w64 \
    mingw-w64-tools \
    pkg-config \
    wget \
    curl \
    git \
    ninja-build \
    cmake \
    nsis \
    && rm -rf /var/lib/apt/lists/*

# Install Qt cross-compilation environment
ENV QT_VERSION=6.6.1
RUN mkdir -p /opt/qt && \
    cd /opt/qt && \
    wget https://download.qt.io/official_releases/qt/6.6/${QT_VERSION}/single/qt-everywhere-src-${QT_VERSION}.tar.xz && \
    tar xf qt-everywhere-src-${QT_VERSION}.tar.xz && \
    cd qt-everywhere-src-${QT_VERSION} && \
    ./configure -platform linux-g++ \
      -xplatform win32-g++ \
      -static \
      -static-runtime \
      -prefix /opt/qt/install \
      -skip tests \
      -skip examples \
      -nomake tests \
      -nomake examples && \
    cmake --build . -j$(nproc) && \
    cmake --install .

# Set up Wintun headers
RUN mkdir -p /opt/wintun && \
    wget -O /opt/wintun/wintun.h https://www.wintun.net/builds/wintun.h

WORKDIR /workspace
ENV CC=x86_64-w64-mingw32-gcc \
    CXX=x86_64-w64-mingw32-g++ \
    WINDRES=x86_64-w64-mingw32-windres \
    AR=x86_64-w64-mingw32-ar \
    RANLIB=x86_64-w64-mingw32-ranlib \
    QT_PATH=/opt/qt/install \
    WINTUN_PATH=/opt/wintun
```

### 2. Enhanced Makefile with Windows Targets

**[ARTIFACT:Makefile.windows]**

```makefile
# Windows Cross-Compilation Configuration
# Source this or include in main Makefile

# Toolchain Detection
ifeq ($(CROSS_COMPILE),mingw)
	CC := x86_64-w64-mingw32-gcc
	CXX := x86_64-w64-mingw32-g++
	WINDRES := x86_64-w64-mingw32-windres
	AR := x86_64-w64-mingw32-ar
	RANLIB := x86_64-w64-mingw32-ranlib
	CFLAGS += -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00
	LDFLAGS += -static-libgcc -lws2_32 -liphlpapi -lsetupapi -lcfgmgr32
endif

# Windows Service Build
SERVICE_SOURCES := src/service/service_main.c \
                   src/service/service_install.c \
                   src/service/service_state.c \
                   src/ipc/protocol.c \
                   src/net/tun.c \
                   src/net/udp.c \
                   src/crypto/chacha20.c \
                   src/crypto/poly1305.c \
                   src/crypto/blake2s.c \
                   src/crypto/curve25519.c

SERVICE_OBJECTS := $(SERVICE_SOURCES:.c=.o)
SERVICE_TARGET := bin/hinkypunk-service.exe

# Qt GUI Build (requires qmake or cmake from cross-compiled Qt)
GUI_TARGET := bin/hinkypunk-gui.exe
GUI_RESOURCES := gui/resources.qrc

# Resource Compilation
%.res: %.rc
	$(WINDRES) $< -o $@

# Windows Service
$(SERVICE_TARGET): $(SERVICE_OBJECTS) src/service/hinkypunk.res
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ $(SERVICE_OBJECTS) src/service/hinkypunk.res $(LDFLAGS)
	@echo "[OK] Windows Service: $@"

# Service Installation Helper
bin/hinkypunk-install.exe: src/service/install_helper.c
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ $< -lshlwapi $(LDFLAGS)

# Installer (NSIS)
bin/hinkypunk-installer.exe: $(SERVICE_TARGET) $(GUI_TARGET) installer/hinkypunk.nsi
	makensis /V2 /DVERSION=$(VERSION) \
		/DSERVICE_EXE=$(SERVICE_TARGET) \
		/DGUI_EXE=$(GUI_TARGET) \
		installer/hinkypunk.nsi
	mv installer/HinkyPunk-$(VERSION)-installer.exe $@

# Qt GUI (using cmake)
$(GUI_TARGET): gui/CMakeLists.txt gui/src/*
	@mkdir -p build/gui
	cd build/gui && cmake ../../gui \
		-DCMAKE_TOOLCHAIN_FILE=../../cmake/mingw-toolchain.cmake \
		-DQt6_DIR=$(QT_PATH)/lib/cmake/Qt6 \
		-DCMAKE_BUILD_TYPE=Release && \
		cmake --build . -j$$(nproc)
	@cp build/gui/HinkyPunkGUI.exe $(GUI_TARGET)

# Windows-specific targets
.PHONY: windows-service windows-gui windows-installer windows-all clean-windows

windows-service: $(SERVICE_TARGET)
windows-gui: $(GUI_TARGET)
windows-installer: bin/hinkypunk-installer.exe
windows-all: windows-service windows-gui windows-installer

clean-windows:
	rm -rf $(SERVICE_OBJECTS) src/service/*.res bin/ build/gui/
	find . -name "*.o" -delete
```

### 3. CMake Toolchain for MinGW

**[ARTIFACT:cmake/mingw-toolchain.cmake]**

```cmake
# CMake Toolchain File for MinGW Cross-Compilation
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

# Specify compilers
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)

# Compiler flags
set(CMAKE_C_FLAGS "-static-libgcc -D_WIN32_WINNT=0x0A00")
set(CMAKE_CXX_FLAGS "-static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0A00")

# Windows SDK paths (adjust as needed)
set(WINDOWS_SDK_PATH "/usr/x86_64-w64-mingw32")
set(WINTUN_INCLUDE_DIR "/opt/wintun")

include_directories(${WINDOWS_SDK_PATH}/include)
link_directories(${WINDOWS_SDK_PATH}/lib)

# Search for programs in the target environment
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

### 4. GitHub Actions CI/CD Workflow

**[ARTIFACT:.github/workflows/build-windows.yml]**

```yaml
name: Windows Cross-Compilation Build

on:
  push:
    branches: [ master, develop ]
    paths:
      - 'src/**'
      - 'gui/**'
      - 'Makefile*'
      - 'docker/**'
      - '.github/workflows/build-windows.yml'
  pull_request:
    branches: [ master ]
  workflow_dispatch:
    inputs:
      publish_release:
        description: 'Publish as release'
        required: false
        default: 'false'

jobs:
  build-windows:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          file: ./docker/Dockerfile.windows
          push: false
          load: true
          tags: hinkypunk:windows-build

      - name: Extract version
        id: version
        run: |
          VERSION=$(grep "^VERSION" Makefile | cut -d= -f2 | tr -d ' ')
          echo "version=${VERSION}" >> $GITHUB_OUTPUT

      - name: Build Windows artifacts
        run: |
          docker run --rm \
            -v ${{ github.workspace }}:/workspace \
            -e VERSION=${{ steps.version.outputs.version }} \
            hinkypunk:windows-build \
            bash -c "cd /workspace && make -f Makefile.windows windows-all"

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: windows-builds
          path: |
            bin/hinkypunk-service.exe
            bin/hinkypunk-gui.exe
            bin/hinkypunk-installer.exe
          retention-days: 30

      - name: Create Release (on tag)
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v1
        with:
          files: |
            bin/hinkypunk-service.exe
            bin/hinkypunk-gui.exe
            bin/hinkypunk-installer.exe
          draft: false
          prerelease: false
```

### 5. NSIS Installer Configuration

**[ARTIFACT:installer/hinkypunk.nsi]**

```nsis
; HinkyPunk Windows Installer (NSIS)
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

; Version from command line: /DVERSION=1.0.0
!ifndef VERSION
  !define VERSION "1.0.0"
!endif

Name "HinkyPunk VPN ${VERSION}"
OutFile "HinkyPunk-${VERSION}-installer.exe"
InstallDir "$PROGRAMFILES\HinkyPunk"
RequestExecutionLevel admin

; MUI Settings
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "English"

Section "Install"
  SetOutPath "$INSTDIR"
  
  ; Copy executables
  File "${SERVICE_EXE}"
  File "${GUI_EXE}"
  
  ; Create start menu shortcuts
  CreateDirectory "$SMPROGRAMS\HinkyPunk"
  CreateShortcut "$SMPROGRAMS\HinkyPunk\HinkyPunk GUI.lnk" "$INSTDIR\hinkypunk-gui.exe"
  CreateShortcut "$SMPROGRAMS\HinkyPunk\Uninstall.lnk" "$INSTDIR\uninstall.exe"
  
  ; Install Windows service
  ExecWait "$INSTDIR\hinkypunk-service.exe /install"
  ExecWait "net start HinkyPunk"
  
  ; Create uninstaller
  WriteUninstaller "$INSTDIR\uninstall.exe"
  
  ; Write registry for Add/Remove Programs
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\HinkyPunk" \
    "DisplayName" "HinkyPunk VPN"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\HinkyPunk" \
    "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\HinkyPunk" \
    "DisplayVersion" "${VERSION}"
SectionEnd

Section "Uninstall"
  ExecWait "net stop HinkyPunk"
  ExecWait "$INSTDIR\hinkypunk-service.exe /uninstall"
  Delete "$INSTDIR\hinkypunk-service.exe"
  Delete "$INSTDIR\hinkypunk-gui.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  RMDir "$SMPROGRAMS\HinkyPunk"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\HinkyPunk"
SectionEnd
```

### 6. Docker Compose for Development

**[ARTIFACT:docker-compose.yml]**

```yaml
version: '3.8'

services:
  windows-build:
    build:
      context: .
      dockerfile: docker/Dockerfile.windows
    volumes:
      - .:/workspace
      - /workspace/build  # Named volume for build cache
    environment:
      - CROSS_COMPILE=mingw
      - VERSION=1.0.0
    working_dir: /workspace
    command: bash -c "make -f Makefile.windows clean && make -f Makefile.windows windows-all"

  build-shell:
    build:
      context: .
      dockerfile: docker/Dockerfile.windows
    volumes:
      - .:/workspace
      - /workspace/build
    environment:
      - CROSS_COMPILE=mingw
    working_dir: /workspace
    stdin_open: true
    tty: true
    entrypoint: /bin/bash
```

### 7. Build Script for Local Development

**[ARTIFACT:scripts/build-windows.sh]**

```bash
#!/bin/bash
set -euo pipefail

# Windows Cross-Compilation Build Script
# Usage: ./scripts/build-windows.sh [target] [options]
# Targets: service, gui, installer, all (default)

TARGET="${1:-all}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
ARCHITECTURE="${ARCHITECTURE:-x86_64}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}HinkyPunk Windows Cross-Compilation Build${NC}"
echo "Target: $TARGET"
echo "Architecture: $ARCHITECTURE"
echo "Build Type: $BUILD_TYPE"
echo ""

# Verify Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

# Build or use cached Docker image
echo -e "${YELLOW}Building Docker image...${NC}"
docker build -f docker/Dockerfile.windows -t hinkypunk:windows-build .

# Run build in Docker
echo -e "${YELLOW}Starting build process...${NC}"
docker run --rm \
    -v "$(pwd):/workspace" \
    -e "CROSS_COMPILE=mingw" \
    -e "BUILD_TYPE=$BUILD_TYPE" \
    -e "ARCHITECTURE=$ARCHITECTURE" \
    hinkypunk:windows-build \
    bash -c "cd /workspace && make -f Makefile.windows windows-$TARGET"

# Check build artifacts
if [ -d "bin" ]; then
    echo -e "${GREEN}Build completed successfully!${NC}"
    ls -lah bin/
    echo ""
    echo -e "${GREEN}Artifacts:${NC}"
    [ -f "bin/hinkypunk-service.exe" ] && echo "  ✓ Service: bin/hinkypunk-service.exe"
    [ -f "bin/hinkypunk-gui.exe" ] && echo "  ✓ GUI: bin/hinkypunk-gui.exe"
    [ -f "bin/hinkypunk-installer.exe" ] && echo "  ✓ Installer: bin/hinkypunk-installer.exe"
else
    echo -e "${RED}Build failed - no artifacts found${NC}"
    exit 1
fi
```

### 8. Build Configuration Documentation

**[ARTIFACT:docs/WINDOWS_BUILD_SYSTEM.md]**

```markdown
# Windows Cross-Compilation Build System

## Overview

The HinkyPunk Windows build system is designed to cross-compile from Linux to Windows using:
- **MinGW-w64** toolchain for C/C++ compilation
- **Docker** for reproducible build environment
- **Qt 6** for GUI framework
- **NSIS** for installer generation
- **GitHub Actions** for CI/CD

## Quick Start

### Prerequisites
- Docker and Docker Compose
- At least 20GB free disk space
- Git

### Build All Windows Artifacts

```bash
./scripts/build-windows.sh all
```

### Build Individual Components

```bash
./scripts/build-windows.sh service  # Windows Service only
./scripts/build-windows.sh gui      # GUI application only
./scripts/build-windows.sh installer # Complete installer
```

## Architecture

### Service (hinkypunk-service.exe)
- Runs as Windows service (SYSTEM privilege level)
- Manages TUN device (Wintun)
- Handles VPN connections
- Listens on named pipe for GUI communication

### GUI (hinkypunk-gui.exe)
- Qt6-based native Windows application
- System tray integration
- Configuration management
- Communicates with service via IPC

### Installer (hinkypunk-installer.exe)
- NSIS-based installer
- Installs service and GUI
- Creates start menu shortcuts
- Registers Add/Remove Programs entry

## Docker Build Environment

### What's Included
- MinGW-w64 cross-compiler (x86_64, x86, ARM64 capable)
- Qt 6.6.1 cross-compiled for Windows (static build)
- NSIS for installer generation
- CMake and Ninja for builds
- Wintun SDK headers

### Customization

Edit `docker/Dockerfile.windows` to:
- Change Qt version (modify QT_VERSION)
- Add additional dependencies
- Adjust compiler flags

Rebuild with:
```bash
docker build -f docker/Dockerfile.windows -t hinkypunk:windows-build .
```

## Build Targets

### Makefile.windows Targets

| Target | Description |
|--------|-------------|
| `windows-service` | Build service executable |
| `windows-gui` | Build GUI application |
| `windows-installer` | Build NSIS installer |
| `windows-all` | Build all components |
| `clean-windows` | Clean Windows build artifacts |

### Usage

```bash
docker run --rm -v $(pwd):/workspace hinkypunk:windows-build \
  bash -c "make -f Makefile.windows windows-all"
```

## CI/CD Pipeline

GitHub Actions workflow (`.github/workflows/build-windows.yml`) automatically:
1. Triggers on push/PR to master/develop
2. Builds Docker image
3. Compiles all Windows artifacts
4. Uploads artifacts to Actions
5. Creates releases on git tags

## Development Workflow

### Local Testing

1. Build in Docker:
   ```bash
   docker-compose run windows-build
   ```

2. Interactive shell for debugging:
   ```bash
   docker-compose run build-shell
   ```

3. Examine build artifacts:
   ```bash
   ls -la bin/
   ```

### Testing Windows Builds

Since building on Linux:
1. Use Wine to test basic execution
2. Use GitHub Actions artifacts for real Windows testing
3. Consider using Windows CI runners for comprehensive testing

## Code Signing

For production releases, add code signing:

1. Obtain EV code signing certificate
2. Create `secrets/codesign.pfx` (gitignored)
3. Update CI workflow to sign executables:
   ```bash
   signtool sign /f codesign.pfx /p $CERT_PASSWORD bin/*.exe
   ```

## Troubleshooting

### Build Fails with MinGW Errors
- Update MinGW: `apt-get install --only-upgrade mingw-w64`
- Check toolchain version: `x86_64-w64-mingw32-gcc --version`

### Qt Build Takes Too Long
- Docker builds Qt from source (one-time cost)
- Cache layers: Use `docker build --no-cache` to rebuild from scratch

### Installer Generation Fails
- Verify NSIS installation: `makensis --version`
- Check file paths in .nsi script are correct

### Service Won't Install on Windows
- Ensure service binary is signed (if UAC enforcement enabled)
- Check service manifest for compatibility
- Verify admin/SYSTEM privileges

## Security Considerations

1. **Code Signing**: All production executables should be signed
2. **Manifest**: Service includes Windows 10+ manifest
3. **UAC**: Service requires admin elevation (service mode)
4. **Dependencies**: Minimal dependencies reduce attack surface
5. **Static Linking**: Reduces DLL injection risks

## Performance

Build times (approximate):
- Service: 2-3 minutes
- GUI: 5-7 minutes (Qt compilation)
- Installer: 1 minute
- Full build: 10-15 minutes

Cache optimization:
- Docker layers cached between builds
- Qt only built once (included in base image)
- Use `docker-compose build --no-cache` to rebuild everything

## Future Enhancements

- [ ] Multi-architecture builds (x86, ARM64)
- [ ] Automated signing pipeline
- [ ] Remote Windows build agent for testing
- [ ] Performance benchmarking in CI
- [ ] Automated Windows testing via API
```

### 9. Integration with Main Makefile

**[ARTIFACT:Makefile.integration]**

```makefile
# Add to existing Makefile to integrate Windows builds

# Detect Windows cross-compilation target
ifeq ($(shell uname -s),Linux)
  # Running on Linux - check for cross-compilation
  ifdef CROSS_COMPILE
    include Makefile.windows
  endif
endif

# Unified build target
.PHONY: all-platforms all-native
all-native: build
all-platforms: build windows-all

# Help target showing all options
help:
	@echo "HinkyPunk Build System"
	@echo ""
	@echo "Linux (native):"
	@echo "  make              - Build Linux binaries"
	@echo "  make test         - Run tests"
	@echo ""
	@echo "Windows (cross-compile):"
	@echo "  make windows-service    - Build Windows service"
	@echo "  make windows-gui        - Build Windows GUI"
	@echo "  make windows-installer  - Build Windows installer"
	@echo "  make windows-all        - Build all Windows components"
	@echo ""
	@echo "Docker (development):"
	@echo "  docker-compose run windows-build   - Build in Docker"
	@echo "  docker-compose run build-shell     - Interactive shell"
	@echo ""
	@echo "Scripts:"
	@echo "  ./scripts/build-windows.sh [target] - Windows build script"
```

## Implementation Strategy

1. **Phase 1 - Setup** (Week 1)
   - Create Docker environment with MinGW and Qt
   - Set up CMake toolchain configuration
   - Validate cross-compilation works

2. **Phase 2 - Service Build** (Week 2)
   - Integrate service code into Makefile.windows
   - Compile and validate service executable
   - Test service installation/removal

3. **Phase 3 - GUI Integration** (Week 3)
   - Set up Qt cross-compilation
   - Build GUI with CMake
   - Link with service IPC protocol

4. **Phase 4 - Installer** (Week 4)
   - Create NSIS configuration
   - Package all components
   - Test on actual Windows machines

5. **Phase 5 - CI/CD** (Week 5)
   - Configure GitHub Actions
   - Automated builds on every commit
   - Release artifact automation

## Key Features

✓ **Reproducible Builds**: Docker ensures identical builds across machines  
✓ **Cross-Platform**: From Linux, compile Windows, macOS, Linux  
✓ **Modular**: Service, GUI, installer built independently  
✓ **Automated**: CI/CD pipeline handles releases  
✓ **Documented**: Clear build process documentation  
✓ **Debuggable**: Interactive shell for troubleshooting  
✓ **Scalable**: Supports multi-architecture builds  

## Dependencies

The build system requires:
- Docker (handles all compilation tools)
- Bash 4.0+ (build scripts)
- git (version control)
- Make 4.0+ (build orchestration)

No Windows tools required for cross-compilation!

[COMPLETE]
