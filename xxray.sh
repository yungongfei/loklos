#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}

green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Alpine")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "apk update -f")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install" "apk add -f")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "apk del -f")

[[ $EUID -ne 0 ]] && red "注意：请在root用户下运行脚本" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "不支持当前VPS系统, 请使用主流的操作系统" && exit 1

# 检测 VPS 处理器架构
archAffix() {
    case "$(uname -m)" in
        x86_64 | amd64) echo 'amd64' ;;
        armv8 | arm64 | aarch64) echo 'arm64' ;;
        s390x) echo 's390x' ;;
        *) red "不支持的CPU架构!" && exit 1 ;;
    esac
}

install_base(){
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo tar openssl
}

install_xray(){
    install_base

    if [[ $SYSTEM == "CentOS" ]]; then
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
    else
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
    fi

    if [[ -f "/etc/systemd/system/xray.service" ]]; then
        green "xray 安装成功！"
    else
        red "xray 安装失败！"
        exit 1
    fi

    # 询问用户有关 xray 端口、UUID 和回落域名
    read -p "设置 xray 端口 [1-65535]（回车则随机分配端口）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -ntlp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -ntlp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} $port ${PLAIN} 端口已经被其他程序占用，请更换端口重试！"
            read -p "设置 xray 端口 [1-65535]（回车则随机分配端口）：" port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done
    read -rp "请输入 UUID [可留空待脚本生成]: " UUID
    [[ -z $UUID ]] && UUID=$(xray uuid)
    read -rp "请输入配置回落的域名 [默认世嘉官网]: " dest_server
    [[ -z $dest_server ]] && dest_server="www.sega.com"

    # Reality short-id
    short_id=$(openssl rand -hex 8)

    # Reality 公私钥
    keys=$(xray x25519)
    private_key=$(echo ${keys} | awk '{print $3}')
    public_key=$(echo ${keys} | awk '{print $6}')

    # 将默认的配置文件删除，并写入 Reality 配置
    rm -f /usr/local/etc/xray/config.json
    cat << EOF > /usr/local/etc/xray/config.json
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [ 
    {
      "listen": "0.0.0.0",
      "port": $port, 
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID", 
            "flow": "xtls-rprx-vision" 
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false, 
          "dest": "$dest_server:$port", 
          "xver": 0, 
          "serverNames": [ 
            "$dest_server" 
          ],
          "privateKey": "$private_key", 
          "shortIds": [ 
            "$short_id"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "blocked",
        "ip": [
          "geoip:cn",
          "geoip:private"
        ] 
      }
    ]
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    },
    {
    "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ]
}
EOF

        IP=$(expr "$(curl -ks4m8 -A Mozilla https://api.ip.sb/geoip)" : '.*ip\":[ ]*\"\([^"]*\).*') || IP=$(expr "$(curl -ks6m8 -A Mozilla https://api.ip.sb/geoip)" : '.*ip\":[ ]*\"\([^"]*\).*')
    
    mkdir /root/xray >/dev/null 2>&1

    # 生成 vless 分享链接及 Clash Meta 配置文件
    share_link="vless://$UUID@$IP:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$dest_server&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#xray-Reality"
    echo ${share_link} > /root/xray/share-link.txt
    cat << EOF > /root/xray/clash-meta.yaml
mixed-port: 7890
external-controller: 127.0.0.1:9090
allow-lan: false
mode: rule
log-level: debug
ipv6: true

dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - 114.114.114.114

proxies:
- name: xray-Reality
  type: vless
  server: $IP
  port: $port
  uuid: $UUID
  network: tcp
  tls: true
  udp: true
  xudp: true
  flow: xtls-rprx-vision
  servername: $dest_server
  reality-opts:
    public-key: "$public_key"
    short-id: "$short_id"
  client-fingerprint: chrome

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - xray-Reality
      
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
    clash_link=&(cat /root/xray/clash-meta.yaml)
    systemctl stop xray >/dev/null 2>&1
    systemctl start xray >/dev/null 2>&1
    systemctl enable xray >/dev/null 2>&1

    if [[ -n $(systemctl status xray 2>/dev/null | grep -w active) && -f '/usr/local/etc/xray/config.json' ]]; then
        green "xray 服务启动成功"
    else
        red "xray 服务启动失败，请运行 systemctl status xray 查看服务状态并反馈，脚本退出" && exit 1
    fi

    yellow "Clash Meta 配置文件已保存至 /root/xray/clash-meta.yaml"
    red $clash_link
    yellow "下面是 xray Reality 的分享链接，并已保存至 /root/xray/share-link.txt"
    red $share_link
}

uninstall_xray(){
    systemctl stop xray >/dev/null 2>&1
    systemctl disable xray >/dev/null 2>&1
    ${PACKAGE_UNINSTALL} xray
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
    rm -rf /root/xray
    green "xray 已彻底卸载成功！"
}

start_xray(){
    systemctl start xray
    systemctl enable xray >/dev/null 2>&1
}

stop_xray(){
    systemctl stop xray
    systemctl disable xray >/dev/null 2>&1
}

changeport(){
    old_port=$(cat /usr/local/etc/xray/config.json | grep port | awk -F ": " '{print $2}' | sed "s/,//g")

    read -p "设置 xray 端口 [1-65535]（回车则随机分配端口）：" port
    [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
    until [[ -z $(ss -ntlp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -ntlp | awk '{print $4}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} $port ${PLAIN} 端口已经被其他程序占用，请更换端口重试！"
            read -p "设置 xray 端口 [1-65535]（回车则随机分配端口）：" port
            [[ -z $port ]] && port=$(shuf -i 2000-65535 -n 1)
        fi
    done

    sed -i "s/$old_port/$port/g" /usr/local/etc/xray/config.json
    sed -i "s/$old_port/$port/g" /root/xray/share-link.txt
    stop_xray && start_xray

    green "xray 端口已修改成功！"
}

changeuuid(){
    old_uuid=$(cat /usr/local/etc/xray/config.json | grep id | awk -F ": " '{print $2}' | sed "s/\"//g" | sed "s/,//g")

    read -rp "请输入 UUID [可留空待脚本生成]: " UUID
    [[ -z $UUID ]] && UUID=$(xray uuid)

    sed -i "s/$old_uuid/$UUID/g" /usr/local/etc/xray/config.json
    sed -i "s/$old_uuid/$UUID/g" /root/xray/share-link.txt
    stop_xray && start_xray

    green "xray UUID 已修改成功！"
}

changedest(){
    old_dest=$(cat /usr/local/etc/xray/config.json | grep server | sed -n 1p | awk -F ": " '{print $2}' | sed "s/\"//g" | sed "s/,//g")

    read -rp "请输入配置回落的域名 [默认微软官网]: " dest_server
    [[ -z $dest_server ]] && dest_server="www.sega.com"

    sed -i "s/$old_dest/$dest_server/g" /usr/local/etc/xray/config.json
    sed -i "s/$old_dest/$dest_server/g" /root/xray/share-link.txt
    stop_xray && start_xray

    green "xray 回落域名已修改成功！"
}

change_conf(){
    green "xray 配置变更选择如下:"
    echo -e " ${GREEN}1.${PLAIN} 修改端口"
    echo -e " ${GREEN}2.${PLAIN} 修改UUID"
    echo -e " ${GREEN}3.${PLAIN} 修改回落域名"
    echo ""
    read -p " 请选择操作 [1-3]: " confAnswer
    case $confAnswer in
        1 ) changeport ;;
        2 ) changeuuid ;;
        3 ) changedest ;;
        * ) exit 1 ;;
    esac
}

menu(){
    clear
    echo ""
    echo -e " ${GREEN}1.${PLAIN} 安装 xray Reality"
    echo -e " ${GREEN}2.${PLAIN} 卸载 xray Reality"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} 启动 xray Reality"
    echo -e " ${GREEN}4.${PLAIN} 停止 xray Reality"
    echo -e " ${GREEN}5.${PLAIN} 重载 xray Reality"
    echo " -------------"
    echo -e " ${GREEN}6.${PLAIN} 修改 xray Reality 配置"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo ""
    read -rp " 请输入选项 [0-6] ：" answer
    case $answer in
        1) install_xray ;;
        2) uninstall_xray ;;
        3) start_xray ;;
        4) stop_xray ;;
        5) stop_xray && start_xray ;;
        6) change_conf ;;
        *) red "请输入正确的选项 [0-6]！" && exit 1 ;;
    esac
}

menu