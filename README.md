```
                            _   _
 _ __   __ _  __ _  ___| |_| |
| '_ \ / _` |/ _` |/ __| __| |
| |_) | (_| | (_| | (__| |_| |
| .__/ \__,_|\__, |\___|\__|_|
|_|             |_|
```

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/SamNet-dev/paqctl/releases)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Server](https://img.shields.io/badge/server-Linux-lightgrey.svg)](https://github.com/SamNet-dev/paqctl)
[![Client](https://img.shields.io/badge/client-Windows%20%7C%20macOS%20%7C%20Linux-green.svg)](https://github.com/SamNet-dev/paqctl)

**Bypass firewall restrictions and access the free internet**

[نسخه فارسی](#نسخه-فارسی)

---

## What is this?

paqctl is a unified management tool for bypass proxies. It helps you connect to a server outside restricted networks (like behind the Great Firewall) and access the internet freely. You run the **server** component on a VPS, and the **client** on your Windows/Mac/Linux machine.

---

## Two Methods

This tool supports **two different bypass methods**. Choose based on your situation:

| | **Paqet** | **GFW-Knocker (GFK)** |
|---|---|---|
| **Difficulty** | Easy ⭐ | Advanced ⭐⭐⭐ |
| **Best for** | Most situations | Heavy censorship (GFW) |
| **Your proxy** | `127.0.0.1:1080` | `127.0.0.1:14000` |
| **Technology** | KCP over raw sockets | Violated TCP + QUIC tunnel |
| **Server needs** | Just paqet | GFK + Xray |

### Which should I use?

```
START HERE
     |
     v
+----------------------------------+
| Is your network heavily censored |
| (like Iran or China's GFW)?      |
+----------------------------------+
     |                |
    YES               NO
     |                |
     v                v
+-----------+    +-----------+
| Try GFK   |    | Use Paqet |
| first     |    |           |
+-----------+    +-----------+
```

> **Tip:** You can install BOTH and have a backup! They use different ports.

---

## How It Works

### Paqet (Simple)

```
YOUR COMPUTER                YOUR VPS                   INTERNET
+--------------+            +--------------+           +----------+
|  Browser     |            |    Paqet     |           |  Google  |
|      |       |            |    Server    |           |  YouTube |
|      v       |  ---KCP--> |      |       |  -------> |  etc.    |
|  Paqet       | (random    |      v       |           |          |
|  Client      |    UDP)    |    SOCKS5    |           |          |
+--------------+            +--------------+           +----------+
  127.0.0.1:1080              your.vps.ip
```

**How Paqet bypasses firewalls:**
1. Uses KCP protocol over raw TCP packets with custom TCP flags
2. Sends packets via raw sockets, making them hard to fingerprint
3. DPI systems can't easily identify it as proxy traffic

---

### GFW-Knocker (Advanced)

```
YOUR COMPUTER                YOUR VPS                   INTERNET
+--------------+            +--------------+           +----------+
|  Browser     |            |  GFK Server  |           |  Google  |
|      |       | "Violated  |      |       |           |  YouTube |
|      v       |    TCP"    |      v       |           |  etc.    |
|  GFK Client  | ---------> | QUIC Tunnel  |  -------> |          |
|  (VIO+QUIC)  | (malformed |      |       |           |          |
|      |       |  +QUIC)    |      v       |           |          |
|  Port 14000  |            |    Xray      |           |          |
+--------------+            +--------------+           +----------+
  127.0.0.1:14000             your.vps.ip
```

**How GFK bypasses firewalls:**
1. **Violated TCP**: Sends TCP packets that are intentionally "broken" - they have wrong flags, no proper handshake. Firewalls expect normal TCP and often pass these through.
2. **QUIC Tunnel**: Inside these violated packets, there's a QUIC connection carrying your actual data.
3. **Xray Backend**: On the server, Xray provides the actual SOCKS5 proxy service.

---

<details>
<summary><strong>Using GFK with an Existing Xray Panel (3x-ui, Marzban, etc.)</strong></summary>

If you already have an Xray panel on your server, GFK works alongside it without conflicts. GFK is a raw TCP forwarder — it tunnels traffic to whatever service is running on your target port.

**How paqctl handles existing Xray:**

| Scenario | What happens |
|---|---|
| **No Xray installed** | paqctl installs Xray with a SOCKS5 proxy automatically |
| **Xray panel running, target port is listening** | paqctl skips Xray setup, GFK forwards to your panel's inbound |
| **Xray running, target port NOT listening** | paqctl warns you — configure your panel to listen on that port |
| **Xray installed but not running** | paqctl installs its own SOCKS5 (same as fresh install) |

**Step-by-step setup (panel on both servers):**

Assume your **foreign server** has a panel with vmess/vless inbound on port `443`, and your **Iran server** has a panel with outbound to the foreign server.

**1. Install paqctl on the foreign server (server role):**
```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```
- Choose **server** role
- Set port mapping: `14000:443` (where `443` is your panel's inbound port)
- paqctl detects Xray is running and skips SOCKS5 — your panel stays untouched

**2. Install paqctl on the Iran server (client role):**
```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```
- Choose **client** role
- Set the **same** port mapping: `14000:443`
- Use the same auth code from the server setup

**3. Update your Iran panel outbound to route through GFK:**

In your Iran panel (3x-ui, Marzban, etc.), change the outbound that connects to the foreign server:

**Before** (direct connection — blocked by DPI):
```json
{
  "tag": "vmess_out",
  "protocol": "vmess",
  "settings": {
    "vnext": [{
      "address": "FOREIGN_SERVER_IP",
      "port": 443,
      "users": [{"id": "your-uuid", "security": "auto"}]
    }]
  }
}
```

**After** (routed through GFK tunnel):
```json
{
  "tag": "vmess_out",
  "protocol": "vmess",
  "settings": {
    "vnext": [{
      "address": "127.0.0.1",
      "port": 14000,
      "users": [{"id": "your-uuid", "security": "auto"}]
    }]
  }
}
```

The key changes:
- `address`: from `FOREIGN_SERVER_IP` to `127.0.0.1`
- `port`: from `443` to `14000` (the VIO port from your mapping)

**4. Traffic flow:**
```
End user --> Iran panel inbound --> Iran panel outbound (127.0.0.1:14000)
  --> GFK client (VIO port) --> QUIC tunnel over violated TCP
  --> Foreign GFK server --> 127.0.0.1:443 (foreign panel inbound) --> Internet
```

**Multiple ports:** If your panel uses multiple ports, map them all:
```
14000:443,14001:8080,14002:2020
```
Then create separate outbounds in your Iran panel for each port (14000, 14001, 14002).

> **Note:** The "Firewall: VIO port blocked" status message (shown in green) is **normal and correct**. It means the firewall is properly configured for GFK's raw socket to work.

</details>

---

## Quick Start

### 1. Server Setup (Linux VPS)

Run this on your VPS (requires root):

```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```

Then open the interactive menu:

```bash
sudo paqctl menu
```

After setup, get your connection info:

```bash
sudo paqctl info
```

This will show you the **Server IP**, **Port**, and **Key/Auth Code** you need for the client.

---

### 2. Client Setup

<details>
<summary><h3>🪟 Windows Client Setup (Click to expand)</h3></summary>

## Windows Client - Complete Guide

### Prerequisites

- Windows 10 or 11
- Administrator access
- Your server's connection info (from `paqctl info` on server)

---

## 🚀 Easy Method (Recommended) - Using .bat Files

The simplest way to get started - just download, double-click, and connect!

### Step 1: Download

1. Go to: https://github.com/SamNet-dev/paqctl
2. Click the green **"Code"** button → **"Download ZIP"**
3. Extract the ZIP file anywhere (e.g., Desktop)
4. Open the `windows` folder inside

### Step 2: Install Protocol

You'll see two `.bat` files:
- `Paqet-Client.bat` - For Paqet protocol (simple, recommended)
- `GFK-Client.bat` - For GFW-knocker protocol (advanced)

**Right-click** your chosen `.bat` file → **"Run as administrator"**

First run will install Npcap (required for raw sockets). Follow the installer prompts.

### Step 3: Configure & Connect

After installation, the script will ask for your server info:
- **Paqet:** Server address (e.g., `1.2.3.4:8443`) and encryption key
- **GFK:** Server IP and auth code

Enter the values from your server (shown after server setup or via `paqctl info`).

Once configured, press **Connect** and you're done!

### Step 4: Use the Proxy

Configure your browser to use SOCKS5 proxy:
- **Paqet:** `127.0.0.1:1080`
- **GFK:** `127.0.0.1:14000`

To disconnect, press `Ctrl+C` in the window.

---

## 💻 Advanced Method - PowerShell Script

For more control, use the interactive PowerShell menu.

### Step 1: Open PowerShell as Administrator

1. Press `Win + S`, type `PowerShell`
2. Right-click "Windows PowerShell" → **"Run as administrator"**
3. Click "Yes" on the UAC prompt

### Step 2: Run the Script

**Option A: One-liner (downloads and runs automatically)**
```powershell
irm https://raw.githubusercontent.com/SamNet-dev/paqctl/main/windows/paqet-client.ps1 | iex
```

**Option B: Download first, then run**
```powershell
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl\windows
.\paqet-client.ps1
```

### Step 3: Use the Menu

The interactive menu lets you:
1. Install paqet or GFK
2. Configure connection
3. Start/stop client
4. Check status

---

### Step 4: Allow Script Execution

Windows blocks scripts by default. Run this once:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

Type `Y` and press Enter when prompted.

---

### Step 5: Run the Client

**Option 1: Double-click (Easiest)**
- Double-click `Paqet-Client.bat`
- It will automatically run as Administrator

**Option 2: From PowerShell**
```powershell
.\paqet-client.ps1
```

You'll see an interactive menu:

```
===============================================
  PAQET/GFK CLIENT MANAGER
===============================================

  No backend installed yet

  1. Install paqet        (simple, all-in-one SOCKS5)
  2. Install GFW-knocker  (advanced, for heavy DPI)
  3. Configure connection
  4. Start client
  5. Stop client
  6. Show status
  7. About (how it works)
  0. Exit

  Select option:
```

---

### Step 6: Install Your Chosen Backend

> **Tip:** For a smoother experience, download and install [Npcap](https://npcap.com/#download) separately first.

#### For Paqet (Recommended for most users):

1. Press `1` and Enter
2. The script will:
   - Download and install **Npcap** (network capture driver)
   - Download the **paqet binary**
3. When Npcap installer opens:
   - Click "I Agree"
   - Keep default options checked
   - Click "Install"
   - Click "Finish"

#### For GFK (If Paqet is blocked):

1. Press `2` and Enter
2. The script will:
   - Install **Npcap**
   - Install **Python 3.10+** (if not present)
   - Install Python packages: `scapy`, `aioquic`
   - Copy GFK client scripts

---

### Step 7: Configure Connection

1. Press `3` and Enter
2. Enter the info from your server:

**For Paqet:**
```
Server address (e.g., 1.2.3.4:8443): <your server IP:port>
Encryption key (16+ chars): <your key from server>
```

**For GFK:**
```
Server IP (e.g., 1.2.3.4): <your server IP>
Auth code (from server setup): <your auth code from server>
```

---

### Step 8: Start the Client

1. Press `4` and Enter
2. The client will start and show logs
3. Keep this window open while using the proxy

---

### Step 9: Configure Your Browser

Now you need to tell your browser to use the proxy.

**Your proxy address is:**
- **Paqet:** `127.0.0.1:1080` (SOCKS5)
- **GFK:** `127.0.0.1:14000` (SOCKS5)

#### Firefox (Recommended):
1. Open Firefox
2. Go to Settings → General → Network Settings → Settings...
3. Select "Manual proxy configuration"
4. In "SOCKS Host": `127.0.0.1`
5. Port: `1080` (for Paqet) or `14000` (for GFK)
6. Select "SOCKS v5"
7. Check "Proxy DNS when using SOCKS v5" ← **Important!**
8. Click OK

#### Chrome (via extension):
Chrome uses Windows proxy settings. Use a browser extension instead:
1. Install "SwitchyOmega" extension
2. Create a new profile
3. Set SOCKS5 proxy: `127.0.0.1:1080` or `127.0.0.1:14000`
4. Activate the profile

---

### Step 10: Test Your Connection

1. Open your browser (with proxy configured)
2. Go to: https://whatismyipaddress.com
3. Your IP should show your **VPS IP**, not your real IP
4. Try accessing blocked sites

---

### Stopping the Client

- Press `Ctrl+C` in the PowerShell window, OR
- Run the script again and choose option `5` (Stop client)

---

### Troubleshooting Windows

<details>
<summary><strong>"Running scripts is disabled" error</strong></summary>

Run this command first:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
</details>

<details>
<summary><strong>"Administrator privileges required"</strong></summary>

You must run PowerShell as Administrator. Right-click PowerShell and select "Run as administrator".
</details>

<details>
<summary><strong>Npcap installation fails</strong></summary>

1. Download manually from https://npcap.com
2. Run the installer as Administrator
3. Make sure "WinPcap API-compatible Mode" is checked
4. Restart your computer after installation
</details>

<details>
<summary><strong>Connection times out</strong></summary>

1. Make sure your server is running (`paqctl status` on server)
2. Check if your VPS firewall allows the port (8443 for Paqet, 45000 for GFK)
3. Try the other method (if Paqet fails, try GFK)
</details>

<details>
<summary><strong>GFK: "Gateway MAC not found"</strong></summary>

The script couldn't detect your router's MAC address. You'll need to enter it manually:

1. Open Command Prompt
2. Run: `arp -a`
3. Find your gateway IP (usually 192.168.1.1 or 192.168.0.1)
4. Copy the MAC address next to it (format: aa-bb-cc-dd-ee-ff)
5. Enter it when the script asks
</details>

</details>

---

<details>
<summary><h3>🍎 macOS Client Setup (Click to expand)</h3></summary>

## macOS Client - Complete Guide

macOS requires manual setup since there's no automated script yet.

### Prerequisites

- macOS 10.15 (Catalina) or newer
- Administrator access (for sudo)
- Homebrew (recommended)
- Your server's connection info

---

### Option A: Paqet on macOS

#### Step 1: Install Homebrew (if not installed)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### Step 2: Download Paqet Binary

```bash
# Create directory
mkdir -p ~/paqet && cd ~/paqet

# Download latest release (Intel Mac)
curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz
tar -xzf paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz

# For Apple Silicon (M1/M2/M3):
# curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz
# tar -xzf paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz

# Make executable
chmod +x paqet_darwin_amd64
```

#### Step 3: Create Config File

```bash
cat > ~/paqet/config.yaml << 'EOF'
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "en0"  # Your network interface (en0 for macOS, eth0 for Linux)
  ipv4:
    addr: "YOUR_LOCAL_IP:0"  # Your local IP, e.g., 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC"  # Gateway MAC, e.g., aa:bb:cc:dd:ee:ff

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
EOF
```

Replace the placeholders:
- `YOUR_LOCAL_IP`: Run `ifconfig en0 | grep inet` to find your IP
- `YOUR_ROUTER_MAC`: Run `arp -n | grep gateway` or check your router
- `YOUR_SERVER_IP` and `YOUR_SECRET_KEY`: Get from your server admin

> **Tip:** Use `paqctl` for automatic configuration - it detects these values for you.

#### Step 4: Run Paqet

```bash
# Requires sudo for raw socket access
sudo ~/paqet/paqet_darwin_amd64 run -c ~/paqet/config.yaml
```

For Apple Silicon:
```bash
sudo ~/paqet/paqet_darwin_arm64 run -c ~/paqet/config.yaml
```

Your SOCKS5 proxy is now at `127.0.0.1:1080`

---

### Option B: GFK on macOS

GFK requires Python and some setup:

#### Step 1: Install Python 3.10+

```bash
brew install python@3.11
```

#### Step 2: Clone the Repository

```bash
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl/gfk/client
```

#### Step 3: Install Python Dependencies

```bash
pip3 install scapy aioquic
```

#### Step 4: Create parameters.py

```bash
cat > parameters.py << 'EOF'
# GFW-knocker client configuration
from scapy.all import conf

# Server settings
vps_ip = "YOUR_SERVER_IP"
xray_server_ip = "127.0.0.1"

# Port mappings (local_port: remote_port)
tcp_port_mapping = {14000: 443}
udp_port_mapping = {}

# VIO (raw socket) ports
vio_tcp_server_port = 45000
vio_tcp_client_port = 40000
vio_udp_server_port = 35000
vio_udp_client_port = 30000

# QUIC tunnel ports
quic_server_port = 25000
quic_client_port = 20000
quic_local_ip = "127.0.0.1"

# QUIC settings
quic_verify_cert = False
quic_idle_timeout = 86400
udp_timeout = 300
quic_mtu = 1420
quic_max_data = 1073741824
quic_max_stream_data = 1073741824
quic_auth_code = "YOUR_AUTH_CODE"
quic_certificate = "cert.pem"
quic_private_key = "key.pem"

# SOCKS proxy
socks_port = 14000
EOF
```

Replace `YOUR_SERVER_IP` and `YOUR_AUTH_CODE` with your actual values.

#### Step 5: Run GFK Client

```bash
# Requires sudo for raw socket access
sudo python3 mainclient.py
```

Your SOCKS5 proxy is now at `127.0.0.1:14000`

---

### Configure macOS to Use Proxy

#### System-wide (all apps):

1. Open **System Preferences** → **Network**
2. Select your connection (Wi-Fi or Ethernet)
3. Click **Advanced** → **Proxies**
4. Check **SOCKS Proxy**
5. Server: `127.0.0.1`
6. Port: `1080` (Paqet) or `14000` (GFK)
7. Click **OK** → **Apply**

#### Firefox only:

Same as Windows - go to Firefox Settings → Network Settings → Manual proxy.

---

### Troubleshooting macOS

<details>
<summary><strong>"Operation not permitted" error</strong></summary>

macOS requires special permissions for raw sockets:

1. Run with `sudo`
2. If still failing, you may need to disable SIP (not recommended) or use a different method
</details>

<details>
<summary><strong>Python package installation fails</strong></summary>

Try using a virtual environment:

```bash
python3 -m venv ~/paqet-venv
source ~/paqet-venv/bin/activate
pip install scapy aioquic
```

Then run GFK from within the venv.
</details>

</details>

---

<details>
<summary><h3>🐧 Linux Client Setup (Click to expand)</h3></summary>

## Linux Client - Complete Guide

### Option A: Paqet

```bash
# Download paqet
mkdir -p ~/paqet && cd ~/paqet
curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
tar -xzf paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
chmod +x paqet_linux_amd64

# Create config
cat > config.yaml << 'EOF'
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"  # Your network interface (ip link show)
  ipv4:
    addr: "YOUR_LOCAL_IP:0"  # Your local IP, e.g., 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC"  # Gateway MAC (ip neigh | grep default)

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
EOF

# Run (requires root for raw sockets)
sudo ./paqet_linux_amd64 run -c config.yaml
```

> **Tip:** Use `paqctl` for automatic configuration - it detects network values for you.

### Option B: GFK

```bash
# Install dependencies
sudo apt install python3 python3-pip  # Debian/Ubuntu
# or: sudo dnf install python3 python3-pip  # Fedora

pip3 install scapy aioquic

# Clone and configure
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl/gfk/client

# Create parameters.py (same as macOS section above)
# Then run:
sudo python3 mainclient.py
```

### Configure Browser

Firefox: Settings → Network Settings → Manual proxy → SOCKS5 `127.0.0.1:1080` or `127.0.0.1:14000`

Or use system-wide proxy via environment variables:

```bash
export ALL_PROXY=socks5://127.0.0.1:1080
```

</details>

---

<details>
<summary><h3>📦 Offline/Manual Installation - If GitHub is Blocked (Click to expand)</h3></summary>

## Offline/Manual Installation

Can't download from GitHub? (e.g., behind DPI/firewall in Iran, China, etc.)

No problem! Paqet is just **one small file** (~8MB). Download it somewhere else and copy it over.

---

### Step 1: Get your server info first

On your **server** (VPS), run:
```bash
sudo paqctl info
```

Write down these 3 things:
```
Server IP:    _______________  (e.g., 185.1.2.3)
Port:         _______________  (e.g., 8443)
Key:          _______________  (e.g., mySecretKey123)
```

---

### Step 2: Download paqet binary

Do this on a machine that CAN access GitHub (your VPS, a friend's computer, VPN, etc.)

**Go to:** https://github.com/hanselime/paqet/releases

> **Note:** Check for the latest version. Examples below use v1.0.0-alpha.14 - use newer if available.

**Click to download the right file for your CLIENT machine:**

| Your Client OS | Download this file |
|----------------|-------------------|
| Windows | `paqet-windows-amd64-v1.0.0-alpha.14.zip` |
| Linux (most computers) | `paqet-linux-amd64-v1.0.0-alpha.14.tar.gz` |
| Linux (Raspberry Pi 3/4/5, ARM 64-bit) | `paqet-linux-arm64-v1.0.0-alpha.14.tar.gz` |
| Linux (Raspberry Pi 2, ARM 32-bit) | `paqet-linux-arm32-v1.0.0-alpha.14.tar.gz` |
| macOS (Intel) | `paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz` |
| macOS (M1/M2/M3) | `paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz` |

---

### Step 3: Extract the binary

**On Linux/macOS:**
```bash
tar -xzf paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
mv paqet_linux_amd64 paqet
chmod +x paqet
```

**On Windows:**
- Right-click the ZIP file → "Extract All"
- You'll get `paqet.exe`

---

### Step 4: Transfer to your client machine

Pick ONE method:

**Method A - SCP (if you downloaded on your VPS):**
```bash
# Run this FROM your VPS
scp paqet user@CLIENT_IP:/home/user/paqet
```

**Method B - USB Drive:**
1. Copy `paqet` (or `paqet.exe`) to USB
2. Plug USB into client machine
3. Copy file to a folder (e.g., `C:\paqet\` on Windows or `~/paqet/` on Linux)

**Method C - SFTP/FileZilla:**
1. Connect to your client machine
2. Upload the `paqet` file

---

### Step 5: Create config file

On your **client machine**, create a file called `config.yaml` in the same folder as paqet.

**First, find your network info:**

| OS | Find Local IP | Find Router MAC |
|----|---------------|-----------------|
| Linux | `ip addr` or `hostname -I` | `ip neigh \| grep default` |
| macOS | `ifconfig en0 \| grep inet` | `arp -a \| grep gateway` |
| Windows | `ipconfig` | `arp -a` (look for your gateway IP) |

**Copy this and fill in your values:**

```yaml
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"  # Linux: eth0/wlan0, macOS: en0, Windows: see note below
  ipv4:
    addr: "YOUR_LOCAL_IP:0"       # e.g., 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC" # e.g., aa:bb:cc:dd:ee:ff

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
```

> **Windows note:** Leave `interface: ""` empty - paqet will auto-detect. Or find your interface name in Network Connections.

**Example with real values:**
```yaml
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"
  ipv4:
    addr: "192.168.1.100:0"
    router_mac: "aa:bb:cc:dd:ee:ff"

server:
  addr: "185.1.2.3:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "mySecretKey123"
```

---

### Step 6: Run paqet

**Linux/macOS:**
```bash
cd ~/paqet              # Go to the folder with paqet
sudo ./paqet run -c config.yaml
```

**Windows (must run as Administrator):**
1. Open Command Prompt as Administrator
2. Run:
```cmd
cd C:\paqet
paqet.exe run -c config.yaml
```

You should see:
```
[INFO] Starting paqet client...
[INFO] Connecting to server...
[INFO] SOCKS5 proxy listening on 127.0.0.1:1080
```

---

### Step 7: Configure your browser

**Firefox:**
1. Settings → Network Settings → Settings...
2. Select "Manual proxy configuration"
3. SOCKS Host: `127.0.0.1`  Port: `1080`
4. Select "SOCKS v5"
5. Check "Proxy DNS when using SOCKS v5"
6. Click OK

**Chrome (use system proxy or extension like SwitchyOmega)**

---

### Step 8: Test it!

1. Go to https://whatismyipaddress.com
2. Your IP should show your **VPS IP**, not your real IP
3. Try accessing blocked sites

---

### Troubleshooting

**"Connection refused" or timeout:**
- Check server is running: `sudo paqctl status` on VPS
- Check IP/port/key are correct in config.yaml
- Check firewall allows the port on VPS

**"Permission denied":**
- Linux/macOS: Must run with `sudo`
- Windows: Must run as Administrator

**To stop paqet:**
- Press `Ctrl+C` in the terminal

### Notes

- You don't need `paqctl` script for basic usage - paqet runs standalone
- Server and client versions should match
- For GFK, the process is more complex (needs Python) - use paqet if possible

</details>

---

## Server Management

After installing on your VPS, use these commands:

```bash
# Show interactive menu
sudo paqctl menu

# Quick commands
sudo paqctl status      # Check if running
sudo paqctl start       # Start the service
sudo paqctl stop        # Stop the service
sudo paqctl restart     # Restart the service
sudo paqctl info        # Show connection info for clients
sudo paqctl logs        # View recent logs
```

---

## Security Notes

- **Change default keys/auth codes** - Never use example values in production
- **Keep your VPS IP private** - Don't share it publicly
- **Use strong encryption keys** - At least 16 characters for Paqet
- **Keep software updated** - Run `sudo paqctl update` periodically

---

## FAQ

<details>
<summary><strong>Can I run both Paqet and GFK at the same time?</strong></summary>

**Yes!** They use different ports:
- Paqet: `127.0.0.1:1080`
- GFK: `127.0.0.1:14000`

This is useful as a backup - if one method gets blocked, switch to the other.
</details>

<details>
<summary><strong>Which VPS provider should I use?</strong></summary>

Any VPS outside your restricted region works. Popular choices:
- DigitalOcean
- Vultr
- Linode
- AWS Lightsail
- Hetzner

Choose a location close to you for better speed (but outside the firewall).
</details>

<details>
<summary><strong>Is this legal?</strong></summary>

This tool is for legitimate privacy and access needs. Laws vary by country. Use responsibly and check your local regulations.
</details>

<details>
<summary><strong>My connection is slow. How can I improve it?</strong></summary>

1. Choose a VPS closer to your location
2. Try the other method (Paqet vs GFK)
3. Check your VPS isn't overloaded
4. Make sure your local network is stable
</details>

<details>
<summary><strong>The server keeps disconnecting</strong></summary>

1. Check server logs: `sudo paqctl logs`
2. Make sure your VPS has enough resources
3. Check if the port is blocked by your ISP
4. Try switching between Paqet and GFK
</details>

---

## Contributing

Issues and pull requests are welcome at:
https://github.com/SamNet-dev/paqctl

---

## License

MIT License - See [LICENSE](LICENSE) file.

---

## Acknowledgments

- [paqet](https://github.com/hanselime/paqet) - KCP over raw TCP packets with custom flags (original source)
- [paqetNG](https://github.com/AliRezaBeigy/paqetNG) - Android client for paqet
- [GFW-knocker](https://github.com/GFW-knocker/gfw_resist_tcp_proxy) - Violated TCP technique
- [aioquic](https://github.com/aiortc/aioquic) - QUIC protocol implementation
- [scapy](https://scapy.net/) - Packet manipulation library
- [kcptun](https://github.com/xtaci/kcptun) - KCP protocol inspiration

---

---

# نسخه فارسی

## این چیست؟

پاکت‌کنترل یک ابزار مدیریت پروکسی برای دور زدن فایروال است. این ابزار به شما کمک می‌کند تا به سروری خارج از شبکه‌های محدود (مثل پشت فایروال بزرگ) متصل شوید و آزادانه به اینترنت دسترسی داشته باشید.

شما کامپوننت **سرور** را روی VPS و **کلاینت** را روی ویندوز/مک/لینوکس خود اجرا می‌کنید.

---

## دو روش

این ابزار از **دو روش مختلف** پشتیبانی می‌کند:

| | **Paqet** | **GFW-Knocker (GFK)** |
|---|---|---|
| **سختی** | آسان ⭐ | پیشرفته ⭐⭐⭐ |
| **مناسب برای** | اکثر شرایط | سانسور سنگین (GFW) |
| **پروکسی شما** | `127.0.0.1:1080` | `127.0.0.1:14000` |
| **تکنولوژی** | KCP روی raw socket | TCP نقض‌شده + تونل QUIC |
| **نیاز سرور** | فقط paqet | GFK + Xray |

### کدام را استفاده کنم؟

- اگر شبکه شما سانسور سنگین دارد (مثل ایران یا GFW چین): **ابتدا GFK را امتحان کنید**
- در غیر این صورت: **از Paqet استفاده کنید**

> **نکته:** می‌توانید هر دو را نصب کنید و یک بکاپ داشته باشید! از پورت‌های مختلف استفاده می‌کنند.

---

## نحوه کار

### Paqet (ساده)

```
[Browser] --> [Paqet Client] --KCP/Raw TCP--> [Paqet Server] --SOCKS5--> [Internet]
                 127.0.0.1:1080              your.vps.ip
```

**نحوه دور زدن فایروال:**
1. از پروتکل KCP روی پکت‌های TCP خام با فلگ‌های سفارشی استفاده می‌کند
2. بسته‌ها را از طریق raw socket ارسال می‌کند که شناسایی آن‌ها سخت است
3. سیستم‌های DPI نمی‌توانند به راحتی آن را شناسایی کنند

### GFW-Knocker (پیشرفته)

```
[Browser] --> [GFK Client] --Violated TCP--> [GFK Server] --> [Xray] --> [Internet]
              (VIO+QUIC)                      (QUIC Tunnel)    (SOCKS5)
               127.0.0.1:14000                 your.vps.ip
```

**نحوه دور زدن فایروال:**
1. **TCP نقض‌شده**: بسته‌های TCP ارسال می‌کند که عمداً "خراب" هستند
2. **تونل QUIC**: درون این بسته‌ها، یک اتصال QUIC داده‌های واقعی را حمل می‌کند
3. **بکند Xray**: روی سرور، Xray سرویس SOCKS5 را ارائه می‌دهد

---

<details>
<summary><strong>استفاده از GFK با پنل Xray موجود (3x-ui، Marzban و غیره)</strong></summary>

اگر از قبل پنل Xray روی سرور خود دارید، GFK بدون تداخل در کنار آن کار می‌کند. GFK یک فورواردر خام TCP است — ترافیک را به هر سرویسی که روی پورت مقصد شما اجرا می‌شود تونل می‌کند.

**رفتار paqctl با Xray موجود:**

| سناریو | چه اتفاقی می‌افتد |
|---|---|
| **Xray نصب نیست** | paqctl به صورت خودکار Xray با پروکسی SOCKS5 نصب می‌کند |
| **پنل Xray در حال اجراست، پورت مقصد فعال است** | paqctl نصب Xray را رد می‌کند، GFK به اینباند پنل شما فوروارد می‌کند |
| **Xray در حال اجراست، پورت مقصد فعال نیست** | paqctl هشدار می‌دهد — پنل خود را روی آن پورت تنظیم کنید |
| **Xray نصب شده ولی اجرا نمی‌شود** | paqctl SOCKS5 خودش را نصب می‌کند (مثل نصب جدید) |

**راهنمای گام به گام (پنل روی هر دو سرور):**

فرض کنید **سرور خارج** پنلی با اینباند vmess/vless روی پورت `443` دارد و **سرور ایران** پنلی با اوتباند به سرور خارج دارد.

**۱. نصب paqctl روی سرور خارج (نقش server):**
```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```
- نقش **server** را انتخاب کنید
- مپینگ پورت: `14000:443` (که `443` پورت اینباند پنل شماست)
- paqctl تشخیص می‌دهد Xray در حال اجراست و نصب SOCKS5 را رد می‌کند — پنل شما دست نخورده می‌ماند

**۲. نصب paqctl روی سرور ایران (نقش client):**
```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```
- نقش **client** را انتخاب کنید
- **همان** مپینگ پورت: `14000:443`
- همان کد احراز هویت سرور را استفاده کنید

**۳. اوتباند پنل ایران را به‌روزرسانی کنید تا از GFK عبور کند:**

در پنل ایران (3x-ui، Marzban و غیره)، اوتباندی که به سرور خارج متصل می‌شود را تغییر دهید:

**قبل** (اتصال مستقیم — توسط DPI مسدود می‌شود):
```json
{
  "tag": "vmess_out",
  "protocol": "vmess",
  "settings": {
    "vnext": [{
      "address": "IP_SERVER_KHAREJ",
      "port": 443,
      "users": [{"id": "your-uuid", "security": "auto"}]
    }]
  }
}
```

**بعد** (از طریق تونل GFK):
```json
{
  "tag": "vmess_out",
  "protocol": "vmess",
  "settings": {
    "vnext": [{
      "address": "127.0.0.1",
      "port": 14000,
      "users": [{"id": "your-uuid", "security": "auto"}]
    }]
  }
}
```

تغییرات کلیدی:
- `address`: از `IP_SERVER_KHAREJ` به `127.0.0.1`
- `port`: از `443` به `14000` (پورت VIO از مپینگ شما)

**۴. مسیر ترافیک:**
```
کاربر --> اینباند پنل ایران --> اوتباند پنل ایران (127.0.0.1:14000)
  --> GFK client (پورت VIO) --> تونل QUIC روی TCP نقض‌شده
  --> GFK server خارج --> 127.0.0.1:443 (اینباند پنل خارج) --> اینترنت
```

**چند پورت:** اگر پنل شما از چند پورت استفاده می‌کند، همه را مپ کنید:
```
14000:443,14001:8080,14002:2020
```
سپس برای هر پورت (14000، 14001، 14002) اوتباند جداگانه در پنل ایران بسازید.

> **توجه:** پیام وضعیت "Firewall: VIO port blocked" (که با رنگ سبز نمایش داده می‌شود) **عادی و صحیح** است. این به معنای آن است که فایروال به درستی برای کار raw socket در GFK تنظیم شده است.

</details>

---

## شروع سریع

### ۱. راه‌اندازی سرور (VPS لینوکس)

این دستور را روی VPS خود اجرا کنید (نیاز به root دارد):

```bash
curl -fsSL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
```

سپس منوی تعاملی را باز کنید:

```bash
sudo paqctl menu
```

بعد از راه‌اندازی، اطلاعات اتصال را دریافت کنید:

```bash
sudo paqctl info
```

این دستور **آی‌پی سرور**، **پورت** و **کلید/کد احراز هویت** را نشان می‌دهد.

---

### ۲. راه‌اندازی کلاینت

<details>
<summary><h3>🪟 راه‌اندازی کلاینت ویندوز (کلیک کنید)</h3></summary>

## راهنمای کامل کلاینت ویندوز

### پیش‌نیازها

- ویندوز ۱۰ یا ۱۱
- دسترسی Administrator
- اطلاعات اتصال سرور (از دستور `paqctl info` روی سرور)

---

## 🚀 روش آسان (پیشنهادی) - استفاده از فایل‌های .bat

ساده‌ترین روش - فقط دانلود کنید، دوبار کلیک کنید و وصل شوید!

### مرحله ۱: دانلود

1. بروید به: https://github.com/SamNet-dev/paqctl
2. روی دکمه سبز **"Code"** کلیک کنید → **"Download ZIP"**
3. فایل ZIP را در هر جایی استخراج کنید (مثلاً دسکتاپ)
4. وارد پوشه `windows` شوید

### مرحله ۲: نصب پروتکل

دو تا فایل `.bat` می‌بینید:
- `Paqet-Client.bat` - برای پروتکل Paqet (ساده، پیشنهادی)
- `GFK-Client.bat` - برای پروتکل GFW-knocker (پیشرفته)

روی فایل `.bat` مورد نظر **راست‌کلیک** کنید → **"Run as administrator"**

اجرای اول Npcap را نصب می‌کند (برای raw socket لازم است). مراحل نصب را دنبال کنید.

### مرحله ۳: پیکربندی و اتصال

بعد از نصب، اسکریپت اطلاعات سرور را می‌خواهد:
- **Paqet:** آدرس سرور (مثلاً `1.2.3.4:8443`) و کلید رمزنگاری
- **GFK:** آی‌پی سرور و کد احراز هویت

مقادیر را از سرور وارد کنید (بعد از نصب سرور نشان داده می‌شود یا با `paqctl info`).

وقتی تنظیم شد، **Connect** را بزنید و تمام!

### مرحله ۴: استفاده از پروکسی

مرورگر را روی پروکسی SOCKS5 تنظیم کنید:
- **Paqet:** `127.0.0.1:1080`
- **GFK:** `127.0.0.1:14000`

برای قطع اتصال، `Ctrl+C` را در پنجره فشار دهید.

---

## 💻 روش پیشرفته - اسکریپت PowerShell

برای کنترل بیشتر، از منوی تعاملی PowerShell استفاده کنید.

### مرحله ۱: باز کردن PowerShell با دسترسی Administrator

1. کلید `Win + S` را فشار دهید، تایپ کنید `PowerShell`
2. روی "Windows PowerShell" راست‌کلیک → **"Run as administrator"**
3. روی "Yes" در پنجره UAC کلیک کنید

### مرحله ۲: اجرای اسکریپت

**گزینه A: یک خطی (خودکار دانلود و اجرا می‌کند)**
```powershell
irm https://raw.githubusercontent.com/SamNet-dev/paqctl/main/windows/paqet-client.ps1 | iex
```

**گزینه B: اول دانلود، بعد اجرا**
```powershell
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl\windows
.\paqet-client.ps1
```

### مرحله ۳: استفاده از منو

منوی تعاملی امکان این کارها را می‌دهد:
1. نصب paqet یا GFK
2. پیکربندی اتصال
3. شروع/توقف کلاینت
4. بررسی وضعیت

> **نکته:** اگر خطای "Running scripts is disabled" دیدید، این را یک بار اجرا کنید:
> ```powershell
> Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```

---

### مرحله ۵: اجرای کلاینت

**روش ۱: دوبار کلیک (آسان‌تر)**
- روی فایل `Paqet-Client.bat` دوبار کلیک کنید
- به صورت خودکار با دسترسی Administrator اجرا می‌شود

**روش ۲: از PowerShell**
```powershell
.\paqet-client.ps1
```

یک منوی تعاملی خواهید دید:

```
===============================================
  PAQET/GFK CLIENT MANAGER
===============================================

  1. Install paqet        (ساده، SOCKS5 همه‌کاره)
  2. Install GFW-knocker  (پیشرفته، برای DPI سنگین)
  3. Configure connection
  4. Start client
  5. Stop client
  6. Show status
  0. Exit

  Select option:
```

---

### مرحله ۶: نصب بکند انتخابی

> **نکته:** برای تجربه روان‌تر، ابتدا [Npcap](https://npcap.com/#download) را جداگانه دانلود و نصب کنید.

#### برای Paqet (توصیه‌شده):

1. کلید `1` را بزنید و Enter
2. اسکریپت موارد زیر را انجام می‌دهد:
   - دانلود و نصب **Npcap**
   - دانلود **باینری paqet**
3. وقتی نصب‌کننده Npcap باز شد:
   - روی "I Agree" کلیک کنید
   - روی "Install" کلیک کنید
   - روی "Finish" کلیک کنید

#### برای GFK (اگر Paqet مسدود است):

1. کلید `2` را بزنید و Enter
2. اسکریپت موارد زیر را انجام می‌دهد:
   - نصب **Npcap**
   - نصب **Python 3.10+**
   - نصب پکیج‌های Python

---

### مرحله ۷: پیکربندی اتصال

1. کلید `3` را بزنید و Enter
2. اطلاعات سرور خود را وارد کنید:

**برای Paqet:**
```
Server address: <آی‌پی:پورت سرور>
Encryption key: <کلید از سرور>
```

**برای GFK:**
```
Server IP: <آی‌پی سرور>
Auth code: <کد احراز هویت از سرور>
```

---

### مرحله ۸: شروع کلاینت

1. کلید `4` را بزنید و Enter
2. کلاینت شروع به کار می‌کند
3. این پنجره را باز نگه دارید

---

### مرحله ۹: پیکربندی مرورگر

**آدرس پروکسی شما:**
- **Paqet:** `127.0.0.1:1080` (SOCKS5)
- **GFK:** `127.0.0.1:14000` (SOCKS5)

#### Firefox (توصیه‌شده):
1. Firefox را باز کنید
2. بروید به Settings → General → Network Settings → Settings...
3. "Manual proxy configuration" را انتخاب کنید
4. در "SOCKS Host": `127.0.0.1`
5. Port: `1080` (برای Paqet) یا `14000` (برای GFK)
6. "SOCKS v5" را انتخاب کنید
7. "Proxy DNS when using SOCKS v5" را تیک بزنید ← **مهم!**
8. روی OK کلیک کنید

#### Chrome:
1. افزونه "SwitchyOmega" را نصب کنید
2. یک پروفایل جدید بسازید
3. پروکسی SOCKS5 را تنظیم کنید: `127.0.0.1:1080` یا `127.0.0.1:14000`
4. پروفایل را فعال کنید

---

### مرحله ۱۰: تست اتصال

1. مرورگر خود را باز کنید
2. بروید به: https://whatismyipaddress.com
3. آی‌پی شما باید **آی‌پی VPS** را نشان دهد
4. سایت‌های مسدود را امتحان کنید

---

### متوقف کردن کلاینت

- در پنجره PowerShell کلید `Ctrl+C` را بزنید، یا
- اسکریپت را دوباره اجرا کنید و گزینه `5` را انتخاب کنید

---

### رفع مشکلات

<details>
<summary><strong>خطای "اجرای اسکریپت غیرفعال است"</strong></summary>

ابتدا این دستور را اجرا کنید:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```
</details>

<details>
<summary><strong>"نیاز به دسترسی Administrator"</strong></summary>

باید PowerShell را به عنوان Administrator اجرا کنید. روی PowerShell راست‌کلیک کنید و "Run as administrator" را انتخاب کنید.
</details>

<details>
<summary><strong>نصب Npcap ناموفق است</strong></summary>

1. به صورت دستی از https://npcap.com دانلود کنید
2. نصب‌کننده را به عنوان Administrator اجرا کنید
3. مطمئن شوید "WinPcap API-compatible Mode" تیک خورده است
4. کامپیوتر را ریستارت کنید
</details>

<details>
<summary><strong>اتصال timeout می‌شود</strong></summary>

1. مطمئن شوید سرور در حال اجرا است
2. بررسی کنید که فایروال VPS پورت را اجازه می‌دهد
3. روش دیگر را امتحان کنید
</details>

<details>
<summary><strong>GFK: "MAC گیت‌وی پیدا نشد"</strong></summary>

1. Command Prompt را باز کنید
2. اجرا کنید: `arp -a`
3. آی‌پی گیت‌وی خود را پیدا کنید (معمولاً 192.168.1.1)
4. آدرس MAC کنار آن را کپی کنید
5. وقتی اسکریپت پرسید آن را وارد کنید
</details>

</details>

---

<details>
<summary><h3>🍎 راه‌اندازی کلاینت مک (کلیک کنید)</h3></summary>

## راهنمای کامل کلاینت macOS

macOS نیاز به راه‌اندازی دستی دارد.

### پیش‌نیازها

- macOS 10.15 یا جدیدتر
- دسترسی Administrator (برای sudo)
- Homebrew (توصیه‌شده)
- اطلاعات اتصال سرور

---

### گزینه A: Paqet روی macOS

#### مرحله ۱: نصب Homebrew

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

#### مرحله ۲: دانلود باینری Paqet

```bash
mkdir -p ~/paqet && cd ~/paqet

# برای Intel Mac:
curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz
tar -xzf paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz

# برای Apple Silicon (M1/M2/M3):
# curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz
# tar -xzf paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz

chmod +x paqet_darwin_amd64
```

#### مرحله ۳: ایجاد فایل پیکربندی

```bash
cat > ~/paqet/config.yaml << 'EOF'
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "en0"  # اینترفیس شبکه (ifconfig برای پیدا کردن)
  ipv4:
    addr: "YOUR_LOCAL_IP:0"  # IP محلی شما، مثلا 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC"  # MAC روتر (arp -a | grep gateway)

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
EOF
```

مقادیر زیر را جایگزین کنید:
- `YOUR_LOCAL_IP`: با `ifconfig en0 | grep inet` پیدا کنید
- `YOUR_ROUTER_MAC`: با `arp -a | grep gateway` پیدا کنید
- `YOUR_SERVER_IP` و `YOUR_SECRET_KEY`: از ادمین سرور بگیرید

> **نکته:** از `paqctl` برای تنظیم خودکار استفاده کنید - مقادیر شبکه را خودش تشخیص می‌دهد.

#### مرحله ۴: اجرای Paqet

```bash
sudo ~/paqet/paqet_darwin_amd64 run -c ~/paqet/config.yaml
# یا برای Apple Silicon:
sudo ~/paqet/paqet_darwin_arm64 run -c ~/paqet/config.yaml
```

پروکسی SOCKS5 شما اکنون در `127.0.0.1:1080` است.

---

### گزینه B: GFK روی macOS

#### مرحله ۱: نصب Python

```bash
brew install python@3.11
```

#### مرحله ۲: کلون مخزن

```bash
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl/gfk/client
```

#### مرحله ۳: نصب وابستگی‌ها

```bash
pip3 install scapy aioquic
```

#### مرحله ۴: ایجاد parameters.py

فایل `parameters.py` را با اطلاعات سرور خود بسازید (مشابه بخش انگلیسی بالا).

#### مرحله ۵: اجرا

```bash
sudo python3 mainclient.py
```

پروکسی در `127.0.0.1:14000` است.

---

### پیکربندی macOS برای استفاده از پروکسی

1. **System Preferences** → **Network** را باز کنید
2. اتصال خود را انتخاب کنید
3. **Advanced** → **Proxies** را کلیک کنید
4. **SOCKS Proxy** را تیک بزنید
5. Server: `127.0.0.1`
6. Port: `1080` یا `14000`
7. **OK** → **Apply**

</details>

---

<details>
<summary><h3>🐧 راه‌اندازی کلاینت لینوکس (کلیک کنید)</h3></summary>

## راهنمای کامل کلاینت لینوکس

### گزینه A: Paqet

```bash
# دانلود paqet
mkdir -p ~/paqet && cd ~/paqet
curl -LO https://github.com/hanselime/paqet/releases/download/v1.0.0-alpha.14/paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
tar -xzf paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
chmod +x paqet_linux_amd64

# ایجاد config
cat > config.yaml << 'EOF'
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"  # اینترفیس شبکه (ip link show)
  ipv4:
    addr: "YOUR_LOCAL_IP:0"  # IP محلی شما، مثلا 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC"  # MAC روتر (ip neigh | grep default)

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
EOF

# اجرا (نیاز به root)
sudo ./paqet_linux_amd64 run -c config.yaml
```

> **نکته:** از `paqctl` برای تنظیم خودکار استفاده کنید - مقادیر شبکه را خودش تشخیص می‌دهد.

### گزینه B: GFK

```bash
# نصب وابستگی‌ها
sudo apt install python3 python3-pip  # Debian/Ubuntu
pip3 install scapy aioquic

# کلون و پیکربندی
git clone https://github.com/SamNet-dev/paqctl.git
cd paqctl/gfk/client

# ایجاد parameters.py (مشابه بخش macOS)
# سپس اجرا:
sudo python3 mainclient.py
```

### پیکربندی مرورگر

Firefox: Settings → Network Settings → Manual proxy → SOCKS5 `127.0.0.1:1080` یا `127.0.0.1:14000`

</details>

---

<details>
<summary><h3>📦 نصب آفلاین/دستی - اگر GitHub مسدود است (کلیک کنید)</h3></summary>

## نصب آفلاین/دستی

نمی‌توانید از GitHub دانلود کنید؟ (مثلاً پشت فایروال در ایران، چین و غیره)

مشکلی نیست! Paqet فقط **یک فایل کوچک** (~۸ مگابایت) است. از جای دیگر دانلود کنید و کپی کنید.

---

### مرحله ۱: اول اطلاعات سرور را بگیرید

روی **سرور** (VPS)، این دستور را بزنید:
```bash
sudo paqctl info
```

این ۳ چیز را یادداشت کنید:
```
آی‌پی سرور:    _______________  (مثلاً 185.1.2.3)
پورت:         _______________  (مثلاً 8443)
کلید:          _______________  (مثلاً mySecretKey123)
```

---

### مرحله ۲: دانلود باینری paqet

این کار را روی دستگاهی انجام دهید که به GitHub دسترسی دارد (VPS شما، کامپیوتر دوست، VPN و غیره)

**بروید به:** https://github.com/hanselime/paqet/releases

> **نکته:** آخرین نسخه را چک کنید. مثال‌های زیر از v1.0.0-alpha.14 استفاده می‌کنند - اگر جدیدتر موجود است آن را بگیرید.

**فایل مناسب سیستم کلاینت خود را دانلود کنید:**

| سیستم کلاینت شما | این فایل را دانلود کنید |
|-----------------|----------------------|
| ویندوز | `paqet-windows-amd64-v1.0.0-alpha.14.zip` |
| لینوکس (اکثر کامپیوترها) | `paqet-linux-amd64-v1.0.0-alpha.14.tar.gz` |
| لینوکس (Raspberry Pi 3/4/5, ARM 64-bit) | `paqet-linux-arm64-v1.0.0-alpha.14.tar.gz` |
| لینوکس (Raspberry Pi 2, ARM 32-bit) | `paqet-linux-arm32-v1.0.0-alpha.14.tar.gz` |
| مک (Intel) | `paqet-darwin-amd64-v1.0.0-alpha.14.tar.gz` |
| مک (M1/M2/M3) | `paqet-darwin-arm64-v1.0.0-alpha.14.tar.gz` |

---

### مرحله ۳: استخراج باینری

**در لینوکس/مک:**
```bash
tar -xzf paqet-linux-amd64-v1.0.0-alpha.14.tar.gz
mv paqet_linux_amd64 paqet
chmod +x paqet
```

**در ویندوز:**
- روی فایل ZIP راست‌کلیک کنید ← "Extract All"
- فایل `paqet.exe` را خواهید داشت

---

### مرحله ۴: انتقال به دستگاه کلاینت

یک روش را انتخاب کنید:

**روش A - SCP (اگر روی VPS دانلود کردید):**
```bash
# این را روی VPS خود اجرا کنید
scp paqet user@CLIENT_IP:/home/user/paqet
```

**روش B - فلش USB:**
1. فایل `paqet` (یا `paqet.exe`) را به USB کپی کنید
2. USB را به دستگاه کلاینت وصل کنید
3. فایل را به یک پوشه کپی کنید (مثلاً `C:\paqet\` در ویندوز یا `~/paqet/` در لینوکس)

**روش C - SFTP/FileZilla:**
1. به دستگاه کلاینت متصل شوید
2. فایل `paqet` را آپلود کنید

---

### مرحله ۵: ساخت فایل کانفیگ

روی **دستگاه کلاینت**، یک فایل به نام `config.yaml` در همان پوشه‌ای که paqet است بسازید.

**اول اطلاعات شبکه خود را پیدا کنید:**

| سیستم‌عامل | پیدا کردن IP محلی | پیدا کردن MAC روتر |
|-----------|------------------|-------------------|
| لینوکس | `ip addr` یا `hostname -I` | `ip neigh \| grep default` |
| مک | `ifconfig en0 \| grep inet` | `arp -a \| grep gateway` |
| ویندوز | `ipconfig` | `arp -a` (دنبال IP گیت‌وی بگردید) |

**این را کپی کنید و مقادیر خود را بگذارید:**

```yaml
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"  # لینوکس: eth0/wlan0، مک: en0، ویندوز: نکته پایین را ببینید
  ipv4:
    addr: "YOUR_LOCAL_IP:0"       # مثلاً 192.168.1.100:0
    router_mac: "YOUR_ROUTER_MAC" # مثلاً aa:bb:cc:dd:ee:ff

server:
  addr: "YOUR_SERVER_IP:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "YOUR_SECRET_KEY"
```

> **نکته ویندوز:** مقدار `interface: ""` را خالی بگذارید - paqet خودش تشخیص می‌دهد. یا نام اینترفیس را در Network Connections پیدا کنید.

**مثال با مقادیر واقعی:**
```yaml
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:1080"

network:
  interface: "eth0"
  ipv4:
    addr: "192.168.1.100:0"
    router_mac: "aa:bb:cc:dd:ee:ff"

server:
  addr: "185.1.2.3:8443"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "mySecretKey123"
```

---

### مرحله ۶: اجرای paqet

**لینوکس/مک:**
```bash
cd ~/paqet              # به پوشه paqet بروید
sudo ./paqet run -c config.yaml
```

**ویندوز (باید به عنوان Administrator اجرا شود):**
1. Command Prompt را به عنوان Administrator باز کنید
2. اجرا کنید:
```cmd
cd C:\paqet
paqet.exe run -c config.yaml
```

باید این را ببینید:
```
[INFO] Starting paqet client...
[INFO] Connecting to server...
[INFO] SOCKS5 proxy listening on 127.0.0.1:1080
```

---

### مرحله ۷: پیکربندی مرورگر

**فایرفاکس:**
1. Settings ← Network Settings ← Settings...
2. "Manual proxy configuration" را انتخاب کنید
3. SOCKS Host: `127.0.0.1`  Port: `1080`
4. "SOCKS v5" را انتخاب کنید
5. تیک "Proxy DNS when using SOCKS v5" را بزنید
6. OK کنید

**کروم (از system proxy یا افزونه SwitchyOmega استفاده کنید)**

---

### مرحله ۸: تست کنید!

1. بروید به https://whatismyipaddress.com
2. آی‌پی شما باید **آی‌پی VPS** باشد، نه آی‌پی واقعی شما
3. سایت‌های مسدود را امتحان کنید

---

### عیب‌یابی

**"Connection refused" یا تایم‌اوت:**
- چک کنید سرور اجرا باشد: `sudo paqctl status` روی VPS
- چک کنید IP/پورت/کلید در config.yaml درست باشد
- چک کنید فایروال VPS پورت را اجازه دهد

**"Permission denied":**
- لینوکس/مک: باید با `sudo` اجرا شود
- ویندوز: باید به عنوان Administrator اجرا شود

**برای توقف paqet:**
- در ترمینال `Ctrl+C` بزنید

</details>

---

## مدیریت سرور

بعد از نصب روی VPS:

```bash
sudo paqctl menu      # منوی تعاملی
sudo paqctl status    # بررسی وضعیت
sudo paqctl start     # شروع سرویس
sudo paqctl stop      # توقف سرویس
sudo paqctl restart   # ریستارت
sudo paqctl info      # اطلاعات اتصال
sudo paqctl logs      # مشاهده لاگ‌ها
```

---

## نکات امنیتی

- **کلیدها را تغییر دهید** - هرگز از مقادیر نمونه استفاده نکنید
- **آی‌پی VPS را خصوصی نگه دارید**
- **از کلیدهای قوی استفاده کنید** - حداقل ۱۶ کاراکتر
- **به‌روز نگه دارید** - `sudo paqctl update`

---

## سوالات متداول

<details>
<summary><strong>آیا می‌توانم Paqet و GFK را همزمان اجرا کنم؟</strong></summary>

**بله!** از پورت‌های مختلف استفاده می‌کنند:
- Paqet: `127.0.0.1:1080`
- GFK: `127.0.0.1:14000`

اگر یکی مسدود شد، به دیگری سوییچ کنید.
</details>

<details>
<summary><strong>از کدام VPS استفاده کنم؟</strong></summary>

هر VPS خارج از منطقه محدود:
- DigitalOcean
- Vultr
- Linode
- AWS Lightsail
- Hetzner

مکانی نزدیک انتخاب کنید (اما خارج از فایروال).
</details>

<details>
<summary><strong>اتصال کند است</strong></summary>

1. VPS نزدیک‌تر انتخاب کنید
2. روش دیگر را امتحان کنید
3. VPS را بررسی کنید
4. شبکه محلی را بررسی کنید
</details>

<details>
<summary><strong>سرور مدام قطع می‌شود</strong></summary>

1. لاگ‌ها را بررسی کنید: `sudo paqctl logs`
2. منابع VPS را بررسی کنید
3. پورت توسط ISP مسدود نشده باشد
4. بین Paqet و GFK سوییچ کنید
</details>

---

## مشارکت

مشکلات و pull request در گیت‌هاب:
https://github.com/SamNet-dev/paqctl

---

## قدردانی

- [paqet](https://github.com/hanselime/paqet) - پروکسی مبتنی بر KCP با SOCKS5 داخلی (سورس اصلی)
- [GFW-knocker](https://github.com/GFW-knocker/gfw_resist_tcp_proxy) - تکنیک TCP نقض‌شده
- [aioquic](https://github.com/aiortc/aioquic) - پیاده‌سازی QUIC
- [scapy](https://scapy.net/) - کتابخانه دستکاری بسته
- [kcptun](https://github.com/xtaci/kcptun) - الهام‌بخش پروتکل KCP
