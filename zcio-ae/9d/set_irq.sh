#!/bin/bash

# 사용법: ./set_irq_v2.sh <INTERFACE> <CPU_LIST>
# 예시: ./set_irq_v2.sh ens2np0 0-3

IFACE=$1
CORES=$2

if [ -z "$IFACE" ] || [ -z "$CORES" ]; then
    echo "Usage: $0 <interface> <cpu_list>"
    exit 1
fi

# 1. ethtool이 있는지 확인
if ! command -v ethtool &> /dev/null; then
    echo "Error: 'ethtool' is required. Install it (apt install ethtool)."
    exit 1
fi

# 2. PCI Bus ID 추출 (예: 0000:c4:00.0)
BUS_INFO=$(ethtool -i $IFACE | grep bus-info | awk '{print $2}')

if [ -z "$BUS_INFO" ]; then
    echo "Error: Could not find bus-info for $IFACE. Is the interface up?"
    exit 1
fi

echo "Found PCI Device $BUS_INFO for interface $IFACE"
echo "Stopping irqbalance..."
systemctl stop irqbalance

echo "Setting affinity for $IFACE (PCI: $BUS_INFO) to CPUs $CORES..."

# 3. PCI ID를 포함하는 인터럽트 찾기
# Mellanox의 경우 보통 PCI ID가 포함된 이름으로 인터럽트가 등록됨
IRQS=$(grep "$BUS_INFO" /proc/interrupts | awk -F: '{print $1}')

# 만약 그래도 못 찾으면 드라이버 이름(mlx5 등)으로 시도 (Fallback)
if [ -z "$IRQS" ]; then
    echo "Warning: No interrupts found by PCI ID. Trying generic driver name..."
    DRIVER=$(ethtool -i $IFACE | grep driver | awk '{print $2}')
    IRQS=$(grep "$DRIVER" /proc/interrupts | awk -F: '{print $1}')
fi

if [ -z "$IRQS" ]; then
    echo "Error: Still no interrupts found. Please check 'cat /proc/interrupts' manually."
    exit 1
fi

# 4. 인터럽트 할당 (카운트 표시)
count=0
for irq in $IRQS; do
    irq=$(echo $irq | tr -d ' ') # 공백 제거
    if [ -f "/proc/irq/$irq/smp_affinity_list" ]; then
        echo $CORES > /proc/irq/$irq/smp_affinity_list
        ((count++))
    fi
done

echo "Success! Assigned $count interrupts to CPUs $CORES."
