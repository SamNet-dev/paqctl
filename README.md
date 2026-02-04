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
1. Uses KCP protocol (reliable UDP) instead of TCP
2. Sends packets via raw sockets, making them look like random UDP traffic
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
curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-darwin-amd64-v1.0.0-alpha.12.tar.gz
tar -xzf paqet-darwin-amd64-v1.0.0-alpha.12.tar.gz

# For Apple Silicon (M1/M2/M3):
# curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-darwin-arm64-v1.0.0-alpha.12.tar.gz
# tar -xzf paqet-darwin-arm64-v1.0.0-alpha.12.tar.gz

# Make executable
chmod +x paqet_darwin_amd64
```

#### Step 3: Create Config File

```bash
cat > ~/paqet/config.yaml << 'EOF'
mode: client
listen: 127.0.0.1:1080
remote: YOUR_SERVER_IP:8443
key: YOUR_SECRET_KEY
EOF
```

Replace `YOUR_SERVER_IP` and `YOUR_SECRET_KEY` with your actual values.

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
curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-linux-amd64-v1.0.0-alpha.12.tar.gz
tar -xzf paqet-linux-amd64-v1.0.0-alpha.12.tar.gz
chmod +x paqet_linux_amd64

# Create config
cat > config.yaml << 'EOF'
mode: client
listen: 127.0.0.1:1080
remote: YOUR_SERVER_IP:8443
key: YOUR_SECRET_KEY
EOF

# Run (requires root for raw sockets)
sudo ./paqet_linux_amd64 run -c config.yaml
```

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

- [paqet](https://github.com/hanselime/paqet) - KCP-based proxy with built-in SOCKS5 (original source)
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
[Browser] --> [Paqet Client] --KCP/UDP--> [Paqet Server] --SOCKS5--> [Internet]
                 127.0.0.1:1080              your.vps.ip
```

**نحوه دور زدن فایروال:**
1. از پروتکل KCP (UDP قابل اطمینان) به جای TCP استفاده می‌کند
2. بسته‌ها را از طریق raw socket ارسال می‌کند که شبیه ترافیک UDP تصادفی به نظر می‌رسند
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
curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-darwin-amd64-v1.0.0-alpha.12.tar.gz
tar -xzf paqet-darwin-amd64-v1.0.0-alpha.12.tar.gz

# برای Apple Silicon (M1/M2/M3):
# curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-darwin-arm64-v1.0.0-alpha.12.tar.gz
# tar -xzf paqet-darwin-arm64-v1.0.0-alpha.12.tar.gz

chmod +x paqet_darwin_amd64
```

#### مرحله ۳: ایجاد فایل پیکربندی

```bash
cat > ~/paqet/config.yaml << 'EOF'
mode: client
listen: 127.0.0.1:1080
remote: YOUR_SERVER_IP:8443
key: YOUR_SECRET_KEY
EOF
```

`YOUR_SERVER_IP` و `YOUR_SECRET_KEY` را با مقادیر واقعی جایگزین کنید.

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
curl -LO https://github.com/SamNet-dev/paqctl/releases/download/v1.0.0-alpha.12/paqet-linux-amd64-v1.0.0-alpha.12.tar.gz
tar -xzf paqet-linux-amd64-v1.0.0-alpha.12.tar.gz
chmod +x paqet_linux_amd64

# ایجاد config
cat > config.yaml << 'EOF'
mode: client
listen: 127.0.0.1:1080
remote: YOUR_SERVER_IP:8443
key: YOUR_SECRET_KEY
EOF

# اجرا (نیاز به root)
sudo ./paqet_linux_amd64 run -c config.yaml
```

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
