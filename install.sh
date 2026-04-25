# 等待1秒, 避免curl下载脚本的打印与脚本本身的显示冲突, 吃掉了提示用户按回车继续的信息
sleep 1

echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

error() {
    echo -e "\n$red 输入错误! $none\n"
}

warn() {
    echo -e "\n$yellow $1 $none\n"
}

is_valid_uuid() {
  [[ "$1" =~ ^[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}$ ]]
}

json_escape() {
  echo -n "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

is_valid_port() {
  case "$1" in
  [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9] | 6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-3][0-5])
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

restart_xray_service() {
  echo
  echo -e "$yellow重启 Xray$none"
  echo "----------------------------------------------------------------"
  service xray restart
}

install_warp_by_stack() {
  if [[ "$1" == "4" ]]; then
    echo
    echo -e "$yellow安装 WARP IPv4 出站$none"
    echo "----------------------------------------------------------------"
    curl -LO https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh
    yes "" | bash menu.sh 4
  elif [[ "$1" == "6" ]]; then
    echo
    echo -e "$yellow安装 WARP IPv6 出站$none"
    echo "----------------------------------------------------------------"
    curl -LO https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh
    yes "" | bash menu.sh 6
  fi
}

list_nodes_overview() {
  config_file="/usr/local/etc/xray/config.json"
  if [[ ! -f "${config_file}" ]]; then
    warn "未找到 ${config_file}"
    return 1
  fi

  node_count=$(jq '.inbounds[0].settings.clients | length' "${config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || "${node_count}" == "null" || ! "${node_count}" =~ ^[0-9]+$ ]]; then
    warn "当前没有可管理的节点"
    return 1
  fi

  if [[ ${node_count} -eq 0 ]]; then
    warn "当前没有可管理的节点"
    return 1
  fi

  echo
  echo "---------- 当前节点列表 ----------"
  for ((i=0; i<node_count; i++)); do
    idx=$((i + 1))
    node_uuid=$(jq -r ".inbounds[0].settings.clients[${i}].id // \"\"" "${config_file}")
    node_email=$(jq -r ".inbounds[0].settings.clients[${i}].email // \"\"" "${config_file}")

    node_outbound="direct"
    if [[ -n "${node_email}" ]]; then
      node_outbound=$(jq -r --arg email "${node_email}" '.routing.rules[]? | select(((.user // []) | index($email)) != null) | .outboundTag' "${config_file}" | head -n 1)
      [[ -z "${node_outbound}" ]] && node_outbound="direct"
    fi

    if [[ ${i} -eq 0 ]]; then
      node_title="主节点"
    else
      node_title="额外节点${i}"
    fi

    echo -e "$yellow ${idx}. ${node_title}${none} UUID=${cyan}${node_uuid}${none} Outbound=${magenta}${node_outbound}${none}"
  done
  echo "----------------------------------"
}

delete_node_by_index() {
  delete_idx_1based="$1"
  config_file="/usr/local/etc/xray/config.json"

  if [[ -z "${delete_idx_1based}" || ! "${delete_idx_1based}" =~ ^[0-9]+$ ]]; then
    error
    return 1
  fi

  delete_idx=$((delete_idx_1based - 1))

  node_count=$(jq '.inbounds[0].settings.clients | length' "${config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || ! "${node_count}" =~ ^[0-9]+$ || ${delete_idx_1based} -lt 1 || ${delete_idx_1based} -gt ${node_count} ]]; then
    error
    return 1
  fi

  if [[ ${delete_idx_1based} -eq 1 ]]; then
    warn "主节点不可删除, 只允许删除额外节点"
    return 1
  fi

  delete_email=$(jq -r ".inbounds[0].settings.clients[${delete_idx}].email // \"\"" "${config_file}")
  delete_outbound=""
  if [[ -n "${delete_email}" ]]; then
    delete_outbound=$(jq -r --arg email "${delete_email}" '.routing.rules[]? | select(((.user // []) | index($email)) != null) | .outboundTag' "${config_file}" | head -n 1)
  fi

  tmp_file=$(mktemp)
  jq --argjson idx ${delete_idx} 'del(.inbounds[0].settings.clients[$idx])' "${config_file}" > "${tmp_file}" && mv "${tmp_file}" "${config_file}"

  if [[ -n "${delete_email}" ]]; then
    tmp_file=$(mktemp)
    jq --arg email "${delete_email}" 'if .routing and .routing.rules then .routing.rules |= map(select(((.user // []) | index($email)) == null)) else . end' "${config_file}" > "${tmp_file}" && mv "${tmp_file}" "${config_file}"
  fi

  if [[ -n "${delete_outbound}" ]]; then
    ref_count=$(jq --arg tag "${delete_outbound}" '[.routing.rules[]? | select(.outboundTag == $tag)] | length' "${config_file}")
    if [[ ${ref_count} -eq 0 ]]; then
      tmp_file=$(mktemp)
      jq --arg tag "${delete_outbound}" 'if .outbounds then .outbounds |= map(select((.tag // "") != $tag)) else . end' "${config_file}" > "${tmp_file}" && mv "${tmp_file}" "${config_file}"
    fi
  fi

  restart_xray_service
  echo -e "$green 已删除节点 ${delete_idx_1based}$none"
}

modify_node_uuid_by_index() {
  modify_idx_1based="$1"
  new_uuid="$2"
  config_file="/usr/local/etc/xray/config.json"

  if [[ -z "${modify_idx_1based}" || ! "${modify_idx_1based}" =~ ^[0-9]+$ ]]; then
    error
    return 1
  fi

  modify_idx=$((modify_idx_1based - 1))

  node_count=$(jq '.inbounds[0].settings.clients | length' "${config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || ! "${node_count}" =~ ^[0-9]+$ || ${modify_idx_1based} -lt 1 || ${modify_idx_1based} -gt ${node_count} ]]; then
    error
    return 1
  fi

  if ! is_valid_uuid "${new_uuid}"; then
    error
    return 1
  fi

  tmp_file=$(mktemp)
  jq --argjson idx ${modify_idx} --arg uuid "${new_uuid}" '.inbounds[0].settings.clients[$idx].id = $uuid' "${config_file}" > "${tmp_file}" && mv "${tmp_file}" "${config_file}"
  restart_xray_service
  echo -e "$green 已修改节点 ${modify_idx_1based} 的UUID$none"
}

node_management_menu() {
  config_file="/usr/local/etc/xray/config.json"
  if [[ ! -f "${config_file}" ]]; then
    warn "未找到 ${config_file}, 请先完成一次安装配置"
    return 1
  fi

  while :; do
    echo
    echo -e "$yellow 节点管理菜单 $none"
    echo -e "${cyan}1${none}. 查看节点列表"
    echo -e "${cyan}2${none}. 删除额外节点"
    echo -e "${cyan}3${none}. 修改节点UUID"
    echo -e "${cyan}4${none}. 退出节点管理"
    read -p "$(echo -e "请选择 [1-4] (默认Default ${cyan}1${none}):")" manage_action
    [ -z "${manage_action}" ] && manage_action=1

    case ${manage_action} in
    1)
      list_nodes_overview
      ;;
    2)
      if list_nodes_overview; then
        read -p "请输入要删除的节点编号: " delete_idx_1based
        delete_node_by_index "${delete_idx_1based}"
      fi
      ;;
    3)
      if list_nodes_overview; then
        read -p "请输入要修改的节点编号: " modify_idx_1based
        read -p "请输入新的UUID: " new_uuid
        modify_node_uuid_by_index "${modify_idx_1based}" "${new_uuid}"
      fi
      ;;
    4)
      break
      ;;
    *)
      error
      ;;
    esac
  done
}

pause() {
    read -rsp "$(echo -e "按 $green Enter 回车键 $none 继续....或按 $red Ctrl + C $none 取消.")" -d $'\n'
    echo
}

# 确保有 curl 和 wget
apt-get -y install curl wget jq -qq

# 说明
echo
echo -e "$yellow此脚本仅兼容于Debian 10+系统. 如果你的系统不符合,请Ctrl+C退出脚本$none"
echo -e "可以去 ${cyan}https://github.com/l1uz3/xray-vless-reality${none} 查看脚本整体思路和关键命令, 以便针对你自己的系统做出调整."
echo -e "有问题加群 ${cyan}https://t.me/+q5WPfGjtwukyZjhl${none}"
echo -e "本脚本支持带参数执行, 省略交互过程, 详见GitHub."
echo "----------------------------------------------------------------"

# 本机 IP
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))

for i in "${InFaces[@]}"; do  # 从网口循环获取IP
    # 增加超时时间, 以免在某些网络环境下请求IPv6等待太久
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    Public_IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")

    if [[ -n "$Public_IPv4" ]]; then  # 检查是否获取到IP地址
        IPv4="$Public_IPv4"
    fi
    if [[ -n "$Public_IPv6" ]]; then  # 检查是否获取到IP地址            
        IPv6="$Public_IPv6"
    fi
done

# 通过IP, host, 时区, 生成UUID. 重装脚本不改变, 不改变节点信息, 方便个人使用
uuidSeed=${IPv4}${IPv6}$(cat /proc/sys/kernel/hostname)$(timedatectl | awk '/Time zone/ {print $3}')
default_uuid=$(curl -sL https://www.uuidtools.com/api/generate/v3/namespace/ns:dns/name/${uuidSeed} | grep -oP '[^-]{8}-[^-]{4}-[^-]{4}-[^-]{4}-[^-]{12}')

# 如果你想使用纯随机的UUID
# default_uuid=$(cat /proc/sys/kernel/random/uuid)

extra_uuid_arg=""
landing_count_arg=""
warp_mode_arg=""
quick_mode=""
quick_extra_uuid_count=0
quick_landing_count=0
entry_mode=1

# 执行脚本带参数
if [ $# -ge 1 ]; then
    # 第1个参数是搭在ipv4还是ipv6上
    case ${1} in
    4)
        netstack=4
        ip=${IPv4}
        ;;
    6)
        netstack=6
        ip=${IPv6}
        ;;
    *) # initial
        if [[ -n "$IPv4" ]]; then  # 检查是否获取到IP地址
            netstack=4
            ip=${IPv4}
        elif [[ -n "$IPv6" ]]; then  # 检查是否获取到IP地址            
            netstack=6
            ip=${IPv6}
        else
            warn "没有获取到公共IP"
        fi
        ;;
    esac

    # 第2个参数是port
    port=${2}
    if [[ -z $port ]]; then
      port=443
    fi

    # 第3个参数是域名
    domain=${3}
    if [[ -z $domain ]]; then
      domain="learn.microsoft.com"
    fi

    # 第4个参数是UUID
    uuid=${4}
    if [[ -z $uuid ]]; then
        uuid=${default_uuid}
    fi

    # 第5个参数是额外UUID, 支持两种格式:
    # 1) 纯数字: 自动生成对应数量的额外UUID
    # 2) 逗号分隔的UUID列表
    extra_uuid_arg=${5}

    # 第6个参数是落地节点数量(可选)
    landing_count_arg=${6}

    # 第7个参数是WARP模式(可选)
    # 1=跳过 2=WARP IPv4 3=WARP IPv6 4=自动
    warp_mode_arg=${7}

    echo -e "$yellow netstack = ${cyan}${netstack}${none}"
    echo -e "$yellow 本机IP = ${cyan}${ip}${none}"
    echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
    echo -e "$yellow 用户ID (User ID / UUID) = $cyan${uuid}${none}"
    echo -e "$yellow SNI = ${cyan}$domain${none}"
    if [[ -n "${extra_uuid_arg}" ]]; then
      echo -e "$yellow 额外UUID参数 (Extra UUID arg) = ${cyan}${extra_uuid_arg}${none}"
    fi
    if [[ -n "${landing_count_arg}" ]]; then
      echo -e "$yellow 落地节点数量参数 (Landing Count arg) = ${cyan}${landing_count_arg}${none}"
    fi
    if [[ -n "${warp_mode_arg}" ]]; then
      echo -e "$yellow WARP参数 (Warp arg) = ${cyan}${warp_mode_arg}${none}"
    fi
    echo "----------------------------------------------------------------"
fi

# 主菜单入口(仅交互模式)
if [[ $# -lt 1 ]]; then
  echo
  echo -e "$yellow 功能菜单 $none"
  echo -e "${cyan}1${none}. 安装/重建节点配置"
  echo -e "${cyan}2${none}. 节点管理(查看/删除/修改UUID)"

  while :; do
    read -p "$(echo -e "请选择功能 [1-2] (默认Default ${cyan}1${none}):")" entry_mode
    [ -z "${entry_mode}" ] && entry_mode=1
    case ${entry_mode} in
    1 | 2)
      break
      ;;
    *)
      error
      ;;
    esac
  done
fi

if [[ ${entry_mode} == 2 ]]; then
  node_management_menu
  exit 0
fi

pause

# 准备工作
apt update
apt install -y curl wget sudo jq qrencode net-tools lsof

# Xray官方脚本 安装最新版本
echo
echo -e "${yellow}Xray官方脚本安装最新版本$none"
echo "----------------------------------------------------------------"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# 更新 geodata
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata

# 如果脚本带参数执行的, 要在安装了xray之后再生成默认私钥公钥shortID
if [[ -n $uuid ]]; then
  # 私钥种子
  # x25519对私钥有一定要求, 不是任意随机的都满足要求, 所以下面这个字符串只能当作种子看待
  reality_key_seed=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')

  # 生成私钥公钥
  # xray x25519 如果接收一个合法的私钥, 会生成对应的公钥. 如果接收一个非法的私钥, 会先"修正"为合法的私钥. 这个"修正"的过程, 会修改其中的一些字节
  # https://github.dev/XTLS/Xray-core/blob/6830089d3c42483512842369c908f9de75da2eaa/main/commands/all/curve25519.go#L36
  tmp_key=$(echo -n ${reality_key_seed} | xargs xray x25519 -i)
  private_key=$(echo ${tmp_key} | awk '{print $2}')
  public_key=$(echo ${tmp_key} | awk '{print $4}')

  # ShortID
  shortid=$(echo -n ${uuid} | sha1sum | head -c 16)
  
  echo
  echo "私钥公钥要在安装xray之后才可以生成"
  echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}${none}"
  echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}${none}"
  echo -e "$yellow ShortId = ${cyan}${shortid}${none}"
  echo "----------------------------------------------------------------"
fi

# 打开BBR
echo
echo -e "$yellow打开BBR$none"
echo "----------------------------------------------------------------"
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
sysctl -p >/dev/null 2>&1

# 配置 VLESS_Reality 模式, 需要:端口, UUID, x25519公私钥, 目标网站
echo
echo -e "$yellow配置 VLESS_Reality 模式$none"
echo "----------------------------------------------------------------"

# 网络栈
if [[ -z $netstack ]]; then
  echo
  echo -e "如果你的小鸡是${magenta}双栈(同时有IPv4和IPv6的IP)${none}，请选择你把Xray搭在哪个'网口'上"
  echo "如果你不懂这段话是什么意思, 请直接回车"
  read -p "$(echo -e "Input ${cyan}4${none} for IPv4, ${cyan}6${none} for IPv6:") " netstack

  if [[ $netstack == "4" ]]; then
    ip=${IPv4}
  elif [[ $netstack == "6" ]]; then
    ip=${IPv6}
  else
    if [[ -n "$IPv4" ]]; then
      ip=${IPv4}
      netstack=4
    elif [[ -n "$IPv6" ]]; then
      ip=${IPv6}
      netstack=6
    else
      warn "没有获取到公共IP"
    fi
  fi
fi

# 端口
if [[ -z $port ]]; then
  default_port=443
  while :; do
    read -p "$(echo -e "请输入端口 [${magenta}1-65535${none}] Input port (默认Default ${cyan}${default_port}$none):")" port
    [ -z "$port" ] && port=$default_port
    case $port in
    [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9] | 6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-3][0-5])
      echo
      echo
      echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
      echo "----------------------------------------------------------------"
      echo
      break
      ;;
    *)
      error
      ;;
    esac
  done
fi

# Xray UUID
if [[ -z $uuid ]]; then
  while :; do
    echo -e "请输入 "$yellow"UUID"$none" "
    read -p "$(echo -e "(默认ID: ${cyan}${default_uuid}$none):")" uuid
    [ -z "$uuid" ] && uuid=$default_uuid
    case $(echo -n $uuid | sed -E 's/[a-z0-9]{8}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{12}//g') in
    "")
        echo
        echo
        echo -e "$yellow UUID = $cyan$uuid$none"
        echo "----------------------------------------------------------------"
        echo
        break
        ;;
    *)
        error
        ;;
    esac
  done
fi

# 快捷菜单(仅交互模式)
if [[ $# -lt 1 ]]; then
  echo
  echo -e "$yellow 快捷模式选择 $none"
  echo -e "${cyan}1${none}. 基础模式: 主UUID直连"
  echo -e "${cyan}2${none}. 落地模式: 主UUID直连 + 额外UUID + ss/socks5落地"

  while :; do
    read -p "$(echo -e "请选择模式 [1-2] (默认Default ${cyan}1${none}):")" quick_mode
    [ -z "${quick_mode}" ] && quick_mode=1
    case ${quick_mode} in
    1 | 2)
      break
      ;;
    *)
      error
      ;;
    esac
  done

  if [[ ${quick_mode} == "2" ]]; then
    while :; do
      read -p "$(echo -e "请输入额外UUID数量(默认Default ${cyan}1${none}):")" quick_extra_uuid_count
      [ -z "${quick_extra_uuid_count}" ] && quick_extra_uuid_count=1
      case ${quick_extra_uuid_count} in
      '' | *[!0-9]*)
        error
        ;;
      0)
        warn "落地模式下额外UUID数量建议大于0"
        ;;
      *)
        break
        ;;
      esac
    done
  fi

  if [[ ${quick_mode} == "2" ]]; then
    while :; do
      read -p "$(echo -e "请输入落地节点数量(默认Default ${cyan}${quick_extra_uuid_count}${none}):")" quick_landing_count
      [ -z "${quick_landing_count}" ] && quick_landing_count=${quick_extra_uuid_count}
      case ${quick_landing_count} in
      '' | *[!0-9]*)
        error
        ;;
      0)
        warn "落地模式下落地节点数量建议大于0"
        ;;
      *)
        break
        ;;
      esac
    done
  fi
fi

# WARP菜单
if [[ -n "${warp_mode_arg}" ]]; then
  warp_mode="${warp_mode_arg}"
elif [[ $# -lt 1 ]]; then
  echo
  echo -e "$yellow WARP 选项 $none"
  echo -e "${cyan}1${none}. 跳过WARP"
  echo -e "${cyan}2${none}. 安装WARP IPv4出站"
  echo -e "${cyan}3${none}. 安装WARP IPv6出站"
  echo -e "${cyan}4${none}. 自动(IPv6入站->WARP4, IPv4入站->WARP6)"

  while :; do
    read -p "$(echo -e "请选择 [1-4] (默认Default ${cyan}1${none}):")" warp_mode
    [ -z "${warp_mode}" ] && warp_mode=1
    case ${warp_mode} in
    1 | 2 | 3 | 4)
      break
      ;;
    *)
      error
      ;;
    esac
  done
else
  # 带参数模式默认保持历史行为: 自动按入站栈推荐WARP方向
  warp_mode=4
fi

# 额外UUID(多入口): 同一个端口, 不同UUID
extra_uuids=()
if [[ -n "${extra_uuid_arg}" ]]; then
  if [[ "${extra_uuid_arg}" =~ ^[0-9]+$ ]]; then
    for ((i=1; i<=extra_uuid_arg; i++)); do
      extra_uuids+=("$(cat /proc/sys/kernel/random/uuid)")
    done
  else
    IFS=',' read -r -a parsed_extra_uuids <<< "${extra_uuid_arg}"
    for one_uuid in "${parsed_extra_uuids[@]}"; do
      one_uuid=$(echo -n "${one_uuid}" | tr 'A-Z' 'a-z' | tr -d '[:space:]')
      [[ -z "${one_uuid}" ]] && continue
      if is_valid_uuid "${one_uuid}"; then
        extra_uuids+=("${one_uuid}")
      else
        warn "跳过无效的额外UUID: ${one_uuid}"
      fi
    done
  fi
elif [[ $# -lt 1 ]]; then
  for ((i=1; i<=quick_extra_uuid_count; i++)); do
    extra_uuids+=("$(cat /proc/sys/kernel/random/uuid)")
  done
fi

# 合并主UUID与额外UUID, 并去重
all_uuids=("${uuid}")
for one_uuid in "${extra_uuids[@]}"; do
  if [[ "${one_uuid}" == "${uuid}" ]]; then
    warn "跳过与主UUID重复的额外UUID: ${one_uuid}"
    continue
  fi

  duplicated=0
  for existing_uuid in "${all_uuids[@]}"; do
    if [[ "${existing_uuid}" == "${one_uuid}" ]]; then
      duplicated=1
      break
    fi
  done

  if [[ ${duplicated} -eq 0 ]]; then
    all_uuids+=("${one_uuid}")
  fi
done

# 落地节点配置: 支持 socks5 / shadowsocks
landing_count=0
landing_outbound_entries=()
landing_rule_entries=()
landing_map_notes=()

if [[ -n "${landing_count_arg}" ]]; then
  if [[ "${landing_count_arg}" =~ ^[0-9]+$ ]]; then
    landing_count=${landing_count_arg}
  else
    warn "落地节点数量参数无效, 已按0处理: ${landing_count_arg}"
  fi
elif [[ $# -lt 1 ]]; then
  landing_count=${quick_landing_count}
fi

if [[ ${landing_count} -gt 0 ]]; then
  while [[ $((${#all_uuids[@]} - 1)) -lt ${landing_count} ]]; do
    all_uuids+=("$(cat /proc/sys/kernel/random/uuid)")
  done

  for ((landing_idx=1; landing_idx<=landing_count; landing_idx++)); do
    bind_uuid=${all_uuids[$landing_idx]}
    landing_tag="landing-${landing_idx}"
    landing_email="landing-user-${landing_idx}"

    echo
    echo -e "$yellow 配置落地节点 ${cyan}${landing_idx}${yellow} (绑定UUID: ${cyan}${bind_uuid}${yellow})$none"
    echo "----------------------------------------------------------------"

    while :; do
      echo -e "${cyan}1${none}. socks5"
      echo -e "${cyan}2${none}. shadowsocks"
      read -p "$(echo -e "请选择落地类型 [1-2] (默认Default ${cyan}1${none}):")" landing_type_choose
      [ -z "${landing_type_choose}" ] && landing_type_choose=1
      case ${landing_type_choose} in
      1)
        landing_type="socks5"
        break
        ;;
      2)
        landing_type="ss"
        break
        ;;
      *)
        error
        ;;
      esac
    done

    while :; do
      read -p "请输入落地地址 (address): " landing_address
      landing_address=$(echo -n "${landing_address}" | tr -d '[:space:]')
      if [[ -n "${landing_address}" ]]; then
        break
      fi
      error
    done

    while :; do
      read -p "$(echo -e "请输入落地端口 [${magenta}1-65535${none}] (默认Default ${cyan}443${none}):")" landing_port
      [ -z "${landing_port}" ] && landing_port=443
      if is_valid_port "${landing_port}"; then
        break
      fi
      error
    done

    escaped_address=$(json_escape "${landing_address}")
    if [[ "${landing_type}" == "socks5" ]]; then
      while :; do
        read -p "请输入Socks5用户名 (可留空): " landing_user
        read -p "请输入Socks5密码 (可留空): " landing_pass
        if [[ -z "${landing_user}" && -z "${landing_pass}" ]]; then
          break
        fi
        if [[ -n "${landing_user}" && -n "${landing_pass}" ]]; then
          break
        fi
        warn "用户名和密码需要同时填写或同时留空"
      done

      if [[ -n "${landing_user}" ]]; then
        escaped_user=$(json_escape "${landing_user}")
        escaped_pass=$(json_escape "${landing_pass}")
        landing_outbound_entry=$(cat <<EOF
    {
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "${escaped_address}",
          "port": ${landing_port},
          "users": [{
            "user": "${escaped_user}",
            "pass": "${escaped_pass}"
          }]
        }]
      },
      "tag": "${landing_tag}"
    }
EOF
)
        landing_map_notes+=("落地节点${landing_idx}: UUID=${bind_uuid} -> socks5://${landing_address}:${landing_port} (auth)")
      else
        landing_outbound_entry=$(cat <<EOF
    {
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": "${escaped_address}",
          "port": ${landing_port}
        }]
      },
      "tag": "${landing_tag}"
    }
EOF
)
        landing_map_notes+=("落地节点${landing_idx}: UUID=${bind_uuid} -> socks5://${landing_address}:${landing_port}")
      fi
    else
      while :; do
        read -p "$(echo -e "请输入SS加密方式 (默认Default ${cyan}aes-128-gcm${none}):")" landing_method
        [ -z "${landing_method}" ] && landing_method="aes-128-gcm"
        landing_method=$(echo -n "${landing_method}" | tr -d '[:space:]')
        if [[ -n "${landing_method}" ]]; then
          break
        fi
        error
      done

      while :; do
        read -p "请输入SS密码: " landing_pass
        if [[ -n "${landing_pass}" ]]; then
          break
        fi
        error
      done

      escaped_method=$(json_escape "${landing_method}")
      escaped_pass=$(json_escape "${landing_pass}")
      landing_outbound_entry=$(cat <<EOF
    {
      "protocol": "shadowsocks",
      "settings": {
        "servers": [{
          "address": "${escaped_address}",
          "port": ${landing_port},
          "method": "${escaped_method}",
          "password": "${escaped_pass}"
        }]
      },
      "tag": "${landing_tag}"
    }
EOF
)
      landing_map_notes+=("落地节点${landing_idx}: UUID=${bind_uuid} -> ss://${landing_address}:${landing_port} (${landing_method})")
    fi

    landing_rule_entry=$(cat <<EOF
      {
        "type": "field",
        "user": ["${landing_email}"],
        "outboundTag": "${landing_tag}"
      }
EOF
)
    landing_outbound_entries+=("${landing_outbound_entry}")
    landing_rule_entries+=("${landing_rule_entry}")
  done
fi

extra_uuid_count=$((${#all_uuids[@]} - 1))
if [[ ${extra_uuid_count} -gt 0 ]]; then
  echo
  echo -e "$yellow 已增加 ${cyan}${extra_uuid_count}${yellow} 个额外UUID(同端口)$none"
  echo "----------------------------------------------------------------"
fi

if [[ ${landing_count} -gt 0 ]]; then
  echo
  echo -e "$yellow 已配置 ${cyan}${landing_count}${yellow} 个落地节点(支持ss/socks5)$none"
  for landing_note in "${landing_map_notes[@]}"; do
    echo -e "$yellow ${landing_note}${none}"
  done
  echo "----------------------------------------------------------------"
fi

# x25519公私钥
if [[ -z $private_key ]]; then
  # 私钥种子
  # x25519对私钥有一定要求, 不是任意随机的都满足要求, 所以下面这个字符串只能当作种子看待
  reality_key_seed=$(echo -n ${uuid} | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')

  # 生成私钥公钥
  # xray x25519 如果接收一个合法的私钥, 会生成对应的公钥. 如果接收一个非法的私钥, 会先"修正"为合法的私钥. 这个"修正"的过程, 会修改其中的一些字节
  # https://github.dev/XTLS/Xray-core/blob/6830089d3c42483512842369c908f9de75da2eaa/main/commands/all/curve25519.go#L36
  tmp_key=$(echo -n ${reality_key_seed} | xargs xray x25519 -i)
  default_private_key=$(echo ${tmp_key} | awk '{print $2}')
  default_public_key=$(echo ${tmp_key} | awk '{print $4}')
  
  echo -e "请输入 "$yellow"x25519 Private Key"$none" x25519私钥 :"
  read -p "$(echo -e "(默认私钥 Private Key: ${cyan}${default_private_key}$none):")" private_key
  if [[ -z "$private_key" ]]; then 
    private_key=$default_private_key
    public_key=$default_public_key
  else
    tmp_key=$(echo -n ${private_key} | xargs xray x25519 -i)
    private_key=$(echo ${tmp_key} | awk '{print $2}')
    public_key=$(echo ${tmp_key} | awk '{print $4}')
  fi

  echo
  echo 
  echo -e "$yellow 私钥 (PrivateKey) = ${cyan}${private_key}$none"
  echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}$none"
  echo "----------------------------------------------------------------"
  echo
fi

# ShortID
if [[ -z $shortid ]]; then
  default_shortid=$(echo -n ${uuid} | sha1sum | head -c 16)
  while :; do
    echo -e "请输入 "$yellow"ShortID"$none" :"
    read -p "$(echo -e "(默认ShortID: ${cyan}${default_shortid}$none):")" shortid
    [ -z "$shortid" ] && shortid=$default_shortid
    if [[ ${#shortid} -gt 16 ]]; then
      error
      continue
    elif [[ $(( ${#shortid} % 2 )) -ne 0 ]]; then
      # 字符串包含奇数个字符
      error
      continue
    else
      # 字符串包含偶数个字符
      echo
      echo
      echo -e "$yellow ShortID = ${cyan}${shortid}$none"
      echo "----------------------------------------------------------------"
      echo
      break
    fi
  done
fi

# 目标网站
if [[ -z $domain ]]; then
  echo -e "请输入一个 ${magenta}合适的域名${none} Input the domain"
  read -p "(例如: learn.microsoft.com): " domain
  [ -z "$domain" ] && domain="learn.microsoft.com"

  echo
  echo
  echo -e "$yellow SNI = ${cyan}$domain$none"
  echo "----------------------------------------------------------------"
  echo
fi

# 配置config.json
echo
echo -e "$yellow 配置 /usr/local/etc/xray/config.json $none"
echo "----------------------------------------------------------------"

clients_json=$(for idx in "${!all_uuids[@]}"; do
  client_uuid="${all_uuids[$idx]}"
  if [[ $idx -gt 0 ]]; then
    printf ",\n"
  fi
  printf "          {\n"
  printf '            "id": "%s",\n' "${client_uuid}"
  printf '            "flow": "xtls-rprx-vision"'
  if [[ $idx -ge 1 && $idx -le $landing_count ]]; then
    printf ",\n"
    printf '            "email": "landing-user-%s"\n' "${idx}"
  else
    printf "\n"
  fi
  printf "          }"
done)

landing_outbounds_json=""
for idx in "${!landing_outbound_entries[@]}"; do
  if [[ $idx -gt 0 ]]; then
    landing_outbounds_json+=$',\n'
  fi
  landing_outbounds_json+="${landing_outbound_entries[$idx]}"
done
if [[ -n "${landing_outbounds_json}" ]]; then
  landing_outbounds_json+=$',\n'
fi

landing_routing_rules_json=""
for idx in "${!landing_rule_entries[@]}"; do
  if [[ $idx -gt 0 ]]; then
    landing_routing_rules_json+=$',\n'
  fi
  landing_routing_rules_json+="${landing_rule_entries[$idx]}"
done

cat > /usr/local/etc/xray/config.json <<-EOF
{ // VLESS + Reality
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    // [inbound] 如果你想使用其它翻墙服务端如(HY2或者NaiveProxy)对接v2ray的分流规则, 那么取消下面一段的注释, 并让其它翻墙服务端接到下面这个socks 1080端口
    // {
    //   "listen":"127.0.0.1",
    //   "port":1080,
    //   "protocol":"socks",
    //   "sniffing":{
    //     "enabled":true,
    //     "destOverride":[
    //       "http",
    //       "tls"
    //     ]
    //   },
    //   "settings":{
    //     "auth":"noauth",
    //     "udp":false
    //   }
    // },
    {
      "listen": "0.0.0.0",
      "port": ${port},    // ***
      "protocol": "vless",
      "settings": {
        "clients": [
${clients_json}
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${domain}:443",    // ***
          "xver": 0,
          "serverNames": ["${domain}"],    // ***
          "privateKey": "${private_key}",    // ***私钥
          "shortIds": ["${shortid}"]    // ***
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
// [outbound]
{
    "protocol": "freedom",
    "settings": {
        "domainStrategy": "UseIPv4"
    },
    "tag": "force-ipv4"
},
{
    "protocol": "freedom",
    "settings": {
        "domainStrategy": "UseIPv6"
    },
    "tag": "force-ipv6"
},
{
    "protocol": "socks",
    "settings": {
        "servers": [{
            "address": "127.0.0.1",
            "port": 40000 //warp socks5 port
        }]
     },
    "tag": "socks5-warp"
},
${landing_outbounds_json}
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      "2001:4860:4860::8888",
      "2606:4700:4700::1111",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
${landing_routing_rules_json}
    ]
  }
}
EOF

# 重启 Xray
echo
echo -e "$yellow重启 Xray$none"
echo "----------------------------------------------------------------"
service xray restart

# 指纹FingerPrint
fingerprint="random"

# SpiderX
spiderx=""

echo
echo "---------- Xray 配置信息 -------------"
echo -e "$green ---提示..这是 VLESS Reality 服务器配置--- $none"
echo -e "$yellow 地址 (Address) = $cyan${ip}$none"
echo -e "$yellow 端口 (Port) = ${cyan}${port}${none}"
echo -e "$yellow 主用户ID (Primary UUID) = $cyan${uuid}$none"
if [[ ${extra_uuid_count} -gt 0 ]]; then
  echo -e "$yellow 额外UUID数量 (Extra UUID Count) = ${cyan}${extra_uuid_count}${none}"
fi
echo -e "$yellow 流控 (Flow) = ${cyan}xtls-rprx-vision${none}"
echo -e "$yellow 加密 (Encryption) = ${cyan}none${none}"
echo -e "$yellow 传输协议 (Network) = ${cyan}tcp$none"
echo -e "$yellow 伪装类型 (header type) = ${cyan}none$none"
echo -e "$yellow 底层传输安全 (TLS) = ${cyan}reality$none"
echo -e "$yellow SNI = ${cyan}${domain}$none"
echo -e "$yellow 指纹 (Fingerprint) = ${cyan}${fingerprint}$none"
echo -e "$yellow 公钥 (PublicKey) = ${cyan}${public_key}$none"
echo -e "$yellow ShortId = ${cyan}${shortid}$none"
echo -e "$yellow SpiderX = ${cyan}${spiderx}$none"
echo
echo "---------- VLESS Reality URL ----------"
url_ip=${ip}
if [[ $netstack == "6" ]]; then
  url_ip=[${ip}]
fi

# 节点信息保存到文件中
: > ~/_vless_reality_url_

for idx in "${!all_uuids[@]}"; do
  current_uuid=${all_uuids[$idx]}
  if [[ $idx -eq 0 ]]; then
    node_title="主节点"
    node_tag="PRIMARY"
  else
    node_title="额外节点${idx}"
    node_tag="EXTRA_${idx}"
  fi

  node_outbound="direct"
  if [[ $idx -ge 1 && $idx -le $landing_count ]]; then
    node_outbound="landing-${idx}"
  fi

  current_url="vless://${current_uuid}@${url_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${shortid}&spx=${spiderx}#${node_tag}_${url_ip}"

  echo -e "$yellow ${node_title} UUID = ${cyan}${current_uuid}${none}"
  echo -e "$yellow ${node_title} 出站 (Outbound) = ${cyan}${node_outbound}${none}"
  echo -e "${cyan}${current_url}${none}"
  echo
  echo "以下两个二维码完全一样的内容 (${node_title})"
  qrencode -t UTF8 "${current_url}"
  qrencode -t ANSI "${current_url}"
  echo

  echo "${node_title} (${node_outbound}): ${current_url}" >> ~/_vless_reality_url_
  echo "以下两个二维码完全一样的内容 (${node_title})" >> ~/_vless_reality_url_
  qrencode -t UTF8 "${current_url}" >> ~/_vless_reality_url_
  qrencode -t ANSI "${current_url}" >> ~/_vless_reality_url_
  echo >> ~/_vless_reality_url_
done

echo "---------- END -------------"
echo "以上节点信息保存在 ~/_vless_reality_url_ 中"

# WARP处理
warp_install_target="none"
case ${warp_mode} in
1)
  warp_install_target="none"
  ;;
2)
  warp_install_target="4"
  ;;
3)
  warp_install_target="6"
  ;;
4)
  if [[ $netstack == "6" ]]; then
    warp_install_target="4"
  elif [[ $netstack == "4" ]]; then
    warp_install_target="6"
  fi
  ;;
*)
  warn "WARP选项无效, 已跳过WARP安装"
  warp_install_target="none"
  ;;
esac

if [[ ${warp_install_target} == "4" ]]; then
  echo
  echo -e "$yellow将安装 WARP IPv4 出站$none"
  echo "----------------------------------------------------------------"
  if [[ $# -lt 1 ]]; then
    pause
  fi
  install_warp_by_stack 4
  restart_xray_service
elif [[ ${warp_install_target} == "6" ]]; then
  echo
  echo -e "$yellow将安装 WARP IPv6 出站$none"
  echo "----------------------------------------------------------------"
  if [[ $# -lt 1 ]]; then
    pause
  fi
  install_warp_by_stack 6
  restart_xray_service
else
  echo
  echo -e "$yellow已跳过WARP安装$none"
fi

echo
echo "节点信息保存在 ~/_vless_reality_url_ 中"
