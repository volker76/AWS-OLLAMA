#!/bin/bash

# Komplettes Setup-Script für AWS g6.2xlarge mit Ollama
# Debian 13 - NVIDIA aus Debian Repos (automatische Versionswahl) + Docker + Ollama
# Version: 2.0

set -e  # Bei Fehler abbrechen

# Non-interactive Mode für apt
export DEBIAN_FRONTEND=noninteractive

echo "=========================================="
echo "AWS g6.2xlarge Ollama Setup"
echo "=========================================="
echo ""

# Konfiguriere deutsche Tastatur vorab
echo "=== Konfiguriere deutsche Tastatur ==="
sudo debconf-set-selections <<< 'keyboard-configuration keyboard-configuration/layoutcode string de'
sudo debconf-set-selections <<< 'keyboard-configuration keyboard-configuration/model select Generic 105-key PC (intl.)'
sudo debconf-set-selections <<< 'keyboard-configuration keyboard-configuration/variant select German'
sudo debconf-set-selections <<< 'keyboard-configuration keyboard-configuration/xkb-keymap select de'

echo ""
echo "=== Aktiviere non-free Repositories ==="
# Backup der debian.sources
sudo cp /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/debian.sources.backup 2>/dev/null || true

# Prüfe ob non-free bereits aktiviert ist
if ! grep -q "non-free-firmware" /etc/apt/sources.list.d/debian.sources; then
    sudo sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources
    echo "non-free Repositories aktiviert"
fi

echo ""
echo "=== System Update ==="
sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo ""
echo "=== Installiere grundlegende Tools ==="
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    mc curl wget git htop gnupg lsb-release ca-certificates \
    htop xfsprogs pciutils kmod build-essential mc

echo ""
echo "=== Erstelle Partition auf /dev/nvme1n1 ==="
if [ ! -b /dev/nvme1n1 ]; then
    echo "WARNUNG: /dev/nvme1n1 nicht gefunden - überspringe Partitionierung"
else
    if ! mountpoint -q /var/lib/docker 2>/dev/null; then
        DEVICE=/dev/nvme1n1
        MOUNT=/var/lib/docker        
        mkfs.xfs -f $DEVICE
        mkdir -p $MOUNT
        mount $DEVICE $MOUNT
        
        echo "$DEVICE $MOUNT xfs defaults,nofail 0 2" >> /etc/fstab
        
        echo "Mounte die Partition..."
        sudo mount -a
        df -h /var/lib/docker
     else
        echo "/var/lib/docker ist bereits gemountet"
     fi
 fi

# Swap-File auf /var/lib/docker erstellen (NVMe) mit vollständiger Prüfung
SWAP_SIZE=10G
SWAP_FILE=/var/lib/docker/swapfile

echo "=== Erstelle 10GB Swap-File auf NVMe ==="
echo ""

# Prüfe ob Swap-File bereits existiert und aktiviert ist
if [ -f "$SWAP_FILE" ]; then
    echo "Swap-File existiert bereits: $SWAP_FILE"
    
    # Prüfe ob es bereits aktiviert ist
    if sudo swapon --show | grep -q "$SWAP_FILE"; then
        echo "✓ Swap-File ist bereits aktiv"
    else
        echo "⚠ Swap-File existiert, aber ist nicht aktiv. Aktiviere..."
        sudo swapon $SWAP_FILE
        echo "✓ Swap aktiviert"
    fi
else
    echo "Erstelle Swap-File ($SWAP_SIZE)..."
    sudo fallocate -l $SWAP_SIZE $SWAP_FILE
    
    echo "Setze Berechtigungen..."
    sudo chmod 600 $SWAP_FILE
    
    echo "Erstelle Swap-Space..."
    sudo mkswap $SWAP_FILE
    
    echo "Aktiviere Swap..."
    sudo swapon $SWAP_FILE
    echo "✓ Swap-File erstellt und aktiviert"
fi

echo ""
echo "Prüfe /etc/fstab Eintrag..."
if grep -q "$SWAP_FILE" /etc/fstab; then
    echo "✓ Eintrag in /etc/fstab bereits vorhanden"
else
    echo "Füge zu /etc/fstab hinzu (permanent)..."
    echo "$SWAP_FILE none swap sw 0 0" | sudo tee -a /etc/fstab
    echo "✓ Eintrag zu /etc/fstab hinzugefügt"
fi

echo ""
echo "Prüfe Swappiness-Einstellung..."
CURRENT_SWAPPINESS=$(cat /proc/sys/vm/swappiness)
echo "Aktuelle Swappiness: $CURRENT_SWAPPINESS"

if [ "$CURRENT_SWAPPINESS" -ne 10 ]; then
    echo "Setze Swappiness auf 10 (temporär)..."
    sudo sysctl vm.swappiness=10
    echo "✓ Swappiness temporär gesetzt"
else
    echo "✓ Swappiness ist bereits auf 10 gesetzt"
fi

if grep -q "^vm.swappiness" /etc/sysctl.conf; then
    CONF_SWAPPINESS=$(grep "^vm.swappiness" /etc/sysctl.conf | cut -d'=' -f2 | tr -d ' ')
    if [ "$CONF_SWAPPINESS" = "10" ]; then
        echo "✓ Swappiness in /etc/sysctl.conf bereits auf 10 gesetzt"
    else
        echo "⚠ Swappiness in /etc/sysctl.conf ist $CONF_SWAPPINESS (nicht 10)"
        echo "Aktualisiere /etc/sysctl.conf..."
        sudo sed -i 's/^vm.swappiness=.*/vm.swappiness=10/' /etc/sysctl.conf
        echo "✓ Swappiness in /etc/sysctl.conf aktualisiert"
    fi
else
    echo "Füge Swappiness zu /etc/sysctl.conf hinzu (permanent)..."
    echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
    echo "✓ Swappiness permanent gesetzt"
fi


# Erstelle das Zielverzeichnis falls nicht vorhanden
sudo mkdir -p /var/lib/docker/containerd

# Entferne altes /var/lib/containerd falls es existiert und kein Symlink ist
if [ -d /var/lib/containerd ] && [ ! -L /var/lib/containerd ]; then
    echo "Verschiebe existierendes /var/lib/containerd nach /var/lib/docker/containerd..."
    sudo rsync -av /var/lib/containerd/ /var/lib/docker/containerd/ 2>/dev/null || true
    sudo rm -rf /var/lib/containerd
fi

# Erstelle Symlink falls nicht vorhanden
if [ ! -L /var/lib/containerd ]; then
    echo "Erstelle Symlink: /var/lib/containerd -> /var/lib/docker/containerd"
    sudo ln -s /var/lib/docker/containerd /var/lib/containerd
    ls -la /var/lib/containerd
else
    echo "Symlink existiert bereits: /var/lib/containerd -> $(readlink /var/lib/containerd)"
fi

echo ""
echo "=== Prüfe GPU ==="
lspci | grep -i nvidia || echo "Keine NVIDIA GPU gefunden"

echo ""
echo "=== Installiere NVIDIA Treiber ==="

# Kernel Headers installieren
sudo DEBIAN_FRONTEND=noninteractive apt install -y \
    linux-headers-$(uname -r) dkms

# Installiere NVIDIA Treiber - Debian wählt automatisch die passende Version
echo "Installiere NVIDIA Driver (Debian wählt Version automatisch)..."
sudo DEBIAN_FRONTEND=noninteractive apt install -y nvidia-driver

echo ""
echo "=== Prüfe NVIDIA Installation ==="
dpkg -l | grep nvidia | grep ^ii
echo ""
echo "Installierte NVIDIA Version:"
dpkg -l | grep nvidia-driver | grep ^ii | awk '{print $2, $3}'

# Finde installierte NVIDIA Version für DKMS
NVIDIA_VERSION=$(dpkg -l | grep nvidia-kernel-dkms | awk '{print $3}' | cut -d'-' -f1 | head -1)
echo "NVIDIA DKMS Version: $NVIDIA_VERSION"

# Update module dependencies
sudo depmod -a

echo ""
echo "=== Prüfe NVIDIA Module ==="
find /lib/modules/$(uname -r) -name "nvidia*.ko" 2>/dev/null || echo "Keine Kernel-Module gefunden (Reboot erforderlich)"

echo ""
echo "=== Installiere Docker ==="

if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo rm -f /etc/apt/keyrings/docker.gpg

    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      bookworm stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install -y \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker $USER

    echo "Docker erfolgreich installiert"
else
    echo "Docker ist bereits installiert"
fi

echo ""
echo "=== Installiere NVIDIA Container Toolkit ==="

if ! dpkg -l | grep -q nvidia-container-toolkit; then
    sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
      sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
      sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

    sudo apt update
    sudo DEBIAN_FRONTEND=noninteractive apt install -y nvidia-container-toolkit nvtop

    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker

    echo "NVIDIA Container Toolkit erfolgreich installiert"
else
    echo "NVIDIA Container Toolkit ist bereits installiert"
fi

echo ""
echo "=== Wende Tastatur-Konfiguration an ==="
sudo dpkg-reconfigure -f noninteractive keyboard-configuration

sudo docker run --rm --gpus all nvidia/cuda:latest nvidia-smi

docker pull ollama/ollama:latest




