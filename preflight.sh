#!/bin/bash
set -euo pipefail

function getHostnamectlInfo {
	local only_letters="${2:-0}"

	if [[ $only_letters -eq 1 ]]; then
		hostnamectl | grep "$1" | awk -F': ' '{print $2}' | grep -o '[a-z]*'
	else
		hostnamectl | grep "$1" | awk -F': ' '{print $2}' || true
	fi

}

function getUptime {
	current_uptime=$(awk '{print int($1)}' /proc/uptime)
	echo $((current_uptime / 60))
}

function cpu {
	local NF="${2:-0}"

	if [[ $NF -eq 1 ]]; then
		lscpu | grep "$1:" -m 1 | awk '{$1=""; print $NF}'
	else
		lscpu | grep "$1:" -m 1 | awk '{$1=""; print $0}' | cut -c 2-
	fi
}

# Возвращает имя физического диска, на котором лежит / (sda, nvme-1n1, vda...).
# Работает и для обычного раздела, и для LVM, и для RAID: идём по дереву
# устройств вверх, от того, что смонтировано в /, до устройства типа disk.
function getRootDisk {
        local root_dev
        root_dev=$(findmnt -no SOURCE /)
        lsblk -lns -o NAME,TYPE "$root_dev" | awk '$2 == "disk" {print $1}' || true
}

function printDisks {
        local root_disk name size rota type drive_type mark
        root_disk=$(getRootDisk)

        echo " - Диски:"
        while read -r name size rota type; do
                [[ $type == "disk" ]] || continue

                if [[ $rota == 1 ]]; then drive_type="HDD"; else drive_type="SSD"; fi

                mark=""
                if [[ $name == "$root_disk" ]]; then mark="[SYSTEM DRIVE]"; fi

                printf "   %-11s %-5s %8s  %s\n" "$name" "$drive_type" "$size" "$mark"
        done < <(lsblk -dn -o NAME,SIZE,ROTA,TYPE)
        echo ""
}

######################################################################################
#                                                                                    #
######################################################################################

static_hostname=$(getHostnamectlInfo 'Static hostname')
type_of_machine=$(getHostnamectlInfo 'Chassis' 1)
operating_system=$(getHostnamectlInfo 'Operating System')
kernel=$(getHostnamectlInfo 'Kernel')
architecture=$(getHostnamectlInfo 'Architecture')
hardware_vendor=$(getHostnamectlInfo 'Hardware Vendor')
hardware_model=$(getHostnamectlInfo 'Hardware Model')
hardware_serial=$(getHostnamectlInfo 'Hardware Serial')

cpu_flags=$(cpu 'Flags')
cpu_cores=$(cpu 'CPU(s)')
cpu_model=$(lscpu | sed -n "/Model name:[[:space:]]*/s/Model name:[[:space:]]*//p")
cpu_tps=$(cpu 'Thread(s) per core' 1)
cpu_cps=$(cpu 'Core(s) per socket' 1)
cpu_sockets=$(cpu 'Socket(s)')
cpu_virt=$(cpu 'Virtualization')

memory_online=$(( $(cat /proc/meminfo | awk -F':*[[:space:]]*' '{print $2}' | head -n 1) / (1048576) ))
memory_avail=$(free -h | awk '{print $NF}' | tail -n 2 | head -n 1)
swap_all=$(free -h | awk '{print $2}' | tail -n 1)
swap_used=$(free -h | awk '{print $3}' | tail -n 1)

ip_addr=$(ip route get 8.8.8.8 | awk -F'src ' '{print $2}' | awk -F' ' '{print $1}' || true)

######################################################################################
#                                                                                    #
######################################################################################

echo " - Hostname: $static_hostname"
echo " - Тип устройства: $type_of_machine"
echo " - Операционная система: $operating_system"
echo " - Ядро Linux: $kernel"
echo " - Архитектура: $architecture"

if [[ $type_of_machine == 'vm' ]]; then
	hypervisor=$(getHostnamectlInfo 'Virtualization' || true)
	echo " - Виртуализация (гипервизор): $hypervisor"
else
	hypervisor=null
fi

echo ""
echo " - Вендор оборудования: $hardware_vendor"
echo " - Модель оборудования: $hardware_model"
echo " - Серийник оборудования: $hardware_serial"
echo ""
echo " - Uptime: $(getUptime) min"
echo ""
#echo " - Флаги процессора: $cpu_flags"
echo " - Логических ядер процессора: $cpu_cores"
echo " - Модель процессора: $cpu_model"
echo " - Потоков на ядро: $cpu_tps"
echo " - Ядер на сокет: $cpu_cps"
echo " - Число сокетов: $cpu_sockets"
echo " - Виртуализация: $cpu_virt"
echo ""
echo " - RAM всего: $memory_online"
echo " - RAM доступно: $memory_avail"
echo " - SWAP всего: $swap_all"
echo " - SWAP использовано: $swap_used"
echo ""
echo " - IP-адрес машины: $ip_addr"
echo ""


######################################################################################
#                                                                                    #
######################################################################################

printDisks

######################################################################################
#                                                                                    #
######################################################################################

okSummary=0
warnSummary=0
fatalSummary=0
failSummary=0

function checkRAM {
	echo " --> Checking RAM..."
	if [[ "$1" -lt 4 ]]; then
		echo "     [FAIL] RAM less than 4"
		fatalSummary=$(($fatalSummary+1))
		failSummary=$failSummary+1
	else
		echo "     RAM OK!"
		okSummary=$okSummary+1
	fi
}

function checkVirt {

	echo " --> Checking CPU Virtualization support..."

	if ! (echo $cpu_flags | grep 'svm' -q || echo $cpu_flags | grep 'vmx' -q); then
		echo "     [FAIL] CPU doesn't support virtualiztion!"
		fatalSummary=$(($fatalSummary+2))
		failSummary=$failSummary+1
	else
		echo "     Virtualization OK!"
		okSummary=$okSummary+1
	fi
}

function checkNet {
	echo " --> Checking network..."

	if [[ $ip_addr == "" ]]; then
		echo "     [WARN] No IP address in system ($ip_addr)."
		warnSummary=$warnSummary+1
	fi

	if ! (ip -br link | grep -v "lo" | grep 'UP' -q); then
		echo "     [FAIL] No one network interface on UP state!"
		fatalSummary=$(($fatalSummary+4))
		failSummary=$failSummary+1
	else
		echo "     Network OK!"
		okSummary=$okSummary+1
	fi
}

function checkFS {
	echo " --> Checking File System..."

	local usage
    	usage=$(df --output=pcent / | tail -n 1 | tr -d '% ')

	if [[ $usage -gt 90 ]]; then
		echo "     [FAIL] FS utilization more than 90%."
		fatalSummary=$(($fatalSummary+8))
		failSummary=$failSummary+1
	elif [[ $usage -gt 80 ]]; then
		echo "     [WARN] FS utilization more than 80%."
		warnSummary=$warnSummary+1
	else
		echo "     FS OK!"
		okSummary=$okSummary+1
	fi

}


######################################################################################
#                                                                                    #
######################################################################################

checkRAM $memory_online
checkVirt
checkNet
checkFS

echo ""
echo " * FAIL:  $(($failSummary))"
echo " * WARN:  $(($warnSummary))" 
echo " * OK:    $(($okSummary))" 

if (( fatalSummary > 0 )); then exit "$fatalSummary"; fi
if (( warnSummary > 0 )); then exit 100; fi
exit 0
