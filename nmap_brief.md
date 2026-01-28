# PROJECT BRIEF: Complete nmap Clone in Rust

## CRITICAL REQUIREMENTS - READ CAREFULLY

This is NOT a proof of concept. This is NOT a skeleton. This is a FULL, WORKING IMPLEMENTATION.

**ZERO TOLERANCE FOR:**
- `unimplemented!()` macros
- `todo!()` macros
- `panic!("not implemented")` or similar
- Functions that return "not yet implemented" strings
- Placeholder code of any kind
- "Fill out later" comments
- Stub implementations

**IF ANY OF THE ABOVE EXIST IN THE FINAL PRODUCT, THE PROJECT IS NOT COMPLETE.**

## Project: rscan (Rust nmap Clone)

Build a complete, production-ready TCP/UDP port scanner in Rust that replicates nmap's core functionality.

## MANDATORY FEATURES (ALL MUST BE IMPLEMENTED)

### 1. Target Specification
- Single IP address (192.168.1.1)
- Hostname resolution (scanme.nmap.org -> IP)
- CIDR notation (192.168.1.0/24)
- IP ranges (192.168.1.1-254)
- Multiple targets (space or comma separated)
- Target file input (-iL targets.txt)

### 2. Port Scanning
- TCP Connect scan (-sT) - MUST WORK
- TCP SYN scan (-sS) - requires raw sockets, fallback to connect if no root
- UDP scan (-sU)
- Port ranges: single (80), range (1-1000), list (22,80,443)
- Common ports preset (--top-ports 100)
- All ports (-p-)

### 3. Host Discovery
- ICMP ping (-PE) when root
- TCP SYN ping (-PS)
- TCP ACK ping (-PA)
- Skip host discovery (-Pn)

### 4. Service Detection
- Banner grabbing on open ports
- Service identification (HTTP, SSH, FTP, etc.)
- Version detection (-sV)

### 5. Output Formats
- Normal human-readable (default)
- Grepable (-oG)
- XML (-oX)
- JSON (-oJ)
- All formats (-oA basename)

### 6. Timing and Performance
- Concurrent scanning with configurable thread count (-T0 to -T5)
- Connection timeout configuration
- Retry count configuration
- Rate limiting

### 7. Additional Features
- Verbose output (-v, -vv)
- Debug output (-d)
- Quiet mode (-q)
- Resume interrupted scan (--resume)

## Technical Requirements

- Language: Rust (stable)
- Async runtime: tokio
- CLI parsing: clap
- No unsafe code unless absolutely necessary
- Comprehensive error handling (no unwrap() in production paths)
- Unit tests for all core modules
- Integration tests for CLI

## Verification Criteria

The scanner MUST be able to:

1. `rscan 127.0.0.1` - Scan localhost, show open ports
2. `rscan 192.168.1.0/24 -p 22,80,443` - Scan network range
3. `rscan hostname.com -sV` - Resolve hostname and detect services
4. `rscan -iL targets.txt -oJ output.json` - Batch scan with JSON output

**If ANY of these commands fail with "not implemented", the project is INCOMPLETE.**

## Directory Structure

```
projects/rscan/
├── Cargo.toml
├── src/
│   ├── main.rs           # Entry point, CLI handling
│   ├── lib.rs            # Library root
│   ├── scanner/
│   │   ├── mod.rs
│   │   ├── tcp.rs        # TCP connect/SYN scanning
│   │   ├── udp.rs        # UDP scanning
│   │   └── service.rs    # Service/version detection
│   ├── target/
│   │   ├── mod.rs
│   │   ├── parser.rs     # Target specification parsing
│   │   ├── resolver.rs   # DNS resolution
│   │   └── range.rs      # IP/port range expansion
│   ├── output/
│   │   ├── mod.rs
│   │   ├── normal.rs     # Human readable
│   │   ├── json.rs       # JSON format
│   │   ├── xml.rs        # XML format
│   │   └── grepable.rs   # Grepable format
│   └── network/
│       ├── mod.rs
│       ├── socket.rs     # Socket operations
│       └── timeout.rs    # Timeout management
├── tests/
│   ├── cli_tests.rs
│   ├── scanner_tests.rs
│   └── integration_tests.rs
└── docs/
    └── USAGE.md
```

## Message to Agents

**LUMINARY**: Do NOT declare [COMPLETE] until the quality gate passes. Check gate_results.json.

**ARCHITECT**: Decompose this into implementable tasks. Every feature listed above needs a task.

**DJINN**: Implement EVERYTHING. No stubs. No placeholders. If you write `unimplemented!()`, you're not done.

**DOCTOR**: Your job is to CATCH incomplete work. Run the binary. If it says "not implemented" ANYWHERE, fail it. Write tests that verify actual functionality, not just compilation.

**WEAVER**: Coordinate parallel implementation. Make sure nothing gets left behind.

## Final Note

This project is complete when a user can download the binary and use it as a real port scanner. Half-finished tools are useless. Build the whole thing.
