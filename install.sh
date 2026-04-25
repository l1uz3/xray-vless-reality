#!/usr/bin/env bash

sleep 1

echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'

CONFIG_FILE="${XRAY_CONFIG_FILE:-/usr/local/etc/xray/config.json}"
URL_FILE="${VLESS_URL_FILE:-${HOME}/_vless_reality_url_}"

error() {
  echo -e "\n${red}输入错误!${none}\n"
}

warn() {
  echo -e "\n${yellow}$1${none}\n"
}

info() {
  echo -e "${yellow}$1${none}"
}

is_valid_uuid() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
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

normalize_uuid() {
  echo -n "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]'
}

random_uuid() {
  cat /proc/sys/kernel/random/uuid
}

parse_x25519_private_key() {
  awk -F': ' '/^(PrivateKey|Private key):/ {print $2; exit}'
}

parse_x25519_public_key() {
  awk -F': ' '/^(Password \(PublicKey\)|PublicKey|Public key):/ {print $2; exit}'
}

ensure_x25519_keys_parsed() {
  if [[ -n "$1" && -n "$2" ]]; then
    return 0
  fi

  warn "无法解析 xray x25519 输出, 请检查 Xray 版本输出格式"
  echo "$3"
  return 1
}

read_with_default() {
  local prompt="$1"
  local default_value="$2"
  local value

  if [[ -n "${default_value}" ]]; then
    read -r -p "$(echo -e "${prompt} (默认 ${cyan}${default_value}${none}): ")" value
    echo "${value:-${default_value}}"
  else
    read -r -p "${prompt}: " value
    echo "${value}"
  fi
}

read_required() {
  local prompt="$1"
  local default_value="$2"
  local value

  while :; do
    value=$(read_with_default "${prompt}" "${default_value}")
    value=$(echo -n "${value}" | tr -d '[:space:]')
    if [[ -n "${value}" ]]; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_nonempty_value() {
  local prompt="$1"
  local default_value="$2"
  local value

  while :; do
    value=$(read_with_default "${prompt}" "${default_value}")
    if [[ -n "${value}" ]]; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_choice() {
  local prompt="$1"
  local default_value="$2"
  local min_value="$3"
  local max_value="$4"
  local value

  while :; do
    value=$(read_with_default "${prompt} [${min_value}-${max_value}]" "${default_value}")
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge "${min_value}" && "${value}" -le "${max_value}" ]]; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_count() {
  local prompt="$1"
  local default_value="$2"
  local min_value="$3"
  local value

  while :; do
    value=$(read_with_default "${prompt}" "${default_value}")
    if [[ "${value}" =~ ^[0-9]+$ && "${value}" -ge "${min_value}" ]]; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_port() {
  local prompt="$1"
  local default_value="$2"
  local value

  while :; do
    value=$(read_with_default "${prompt} [1-65535]" "${default_value}")
    if is_valid_port "${value}"; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_uuid() {
  local prompt="$1"
  local default_value="$2"
  local value

  while :; do
    value=$(read_with_default "${prompt}" "${default_value}")
    value=$(normalize_uuid "${value}")
    if is_valid_uuid "${value}"; then
      echo "${value}"
      return 0
    fi
    error
  done
}

read_short_id() {
  local default_value="$1"
  local value

  while :; do
    value=$(read_with_default "请输入 Reality ShortId, 可为空, 偶数长度十六进制, 最长16位" "${default_value}")
    value=$(echo -n "${value}" | tr 'A-F' 'a-f' | tr -d '[:space:]')
    if [[ "${#value}" -le 16 && $(( ${#value} % 2 )) -eq 0 && "${value}" =~ ^[0-9a-f]*$ ]]; then
      echo "${value}"
      return 0
    fi
    error
  done
}

uuid_exists_in_list() {
  local needle="$1"
  shift
  local existing

  for existing in "$@"; do
    if [[ "${existing}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

require_command() {
  local command_name="$1"
  local hint="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return 0
  fi

  warn "未检测到 ${command_name}. ${hint}"
  return 1
}

strip_json_comments() {
  local src_config="$1"
  local tmp_config
  tmp_config=$(mktemp)
  sed -E 's@[[:space:]]+//.*$@@; /^[[:space:]]*\/\//d' "${src_config}" > "${tmp_config}"
  echo "${tmp_config}"
}

load_config_for_jq() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return 1
  fi
  strip_json_comments "${CONFIG_FILE}"
}

make_config_tmp() {
  local config_dir
  local config_base

  config_dir=$(dirname "${CONFIG_FILE}")
  config_base=$(basename "${CONFIG_FILE}")
  mkdir -p "${config_dir}"
  mktemp "${config_dir}/.${config_base}.tmp.XXXXXX"
}

prepare_xray_log_files() {
  mkdir -p /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  if id nobody >/dev/null 2>&1; then
    chown nobody:nogroup /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
  fi
  chmod 600 /var/log/xray/access.log /var/log/xray/error.log 2>/dev/null || true
}

replace_xray_config() {
  local new_config_file="$1"
  local validation_output

  prepare_xray_log_files
  validation_output=$(xray run -test -format json -config "${new_config_file}" 2>&1)
  if [[ $? -ne 0 ]]; then
    warn "新配置未通过 Xray 校验, 已取消写入"
    echo "${validation_output}"
    rm -f "${new_config_file}"
    return 1
  fi

  if [[ -f "${CONFIG_FILE}" ]]; then
    chmod --reference="${CONFIG_FILE}" "${new_config_file}" 2>/dev/null || chmod 0644 "${new_config_file}"
    chown --reference="${CONFIG_FILE}" "${new_config_file}" 2>/dev/null || true
  else
    chmod 0644 "${new_config_file}"
  fi

  mv "${new_config_file}" "${CONFIG_FILE}"
}

restart_xray_service() {
  echo
  info "重启 Xray"
  echo "----------------------------------------------------------------"
  service xray restart
}

detect_public_address() {
  local ip

  if command -v curl >/dev/null 2>&1; then
    ip=$(curl -4s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2; exit}')
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi

    ip=$(curl -6s -m 2 https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/{print $2; exit}')
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
  fi

  return 1
}

extract_saved_address() {
  if [[ ! -f "${URL_FILE}" ]]; then
    return 1
  fi

  sed -n 's#.*vless://[^@]*@\(\[[^]]*\]\|[^:?]*\):[0-9][0-9]*?.*#\1#p' "${URL_FILE}" | head -n 1
}

normalize_url_address() {
  local address="$1"

  address=$(echo -n "${address}" | tr -d '[:space:]')
  if [[ "${address}" == \[*\] ]]; then
    echo "${address}"
  elif [[ "${address}" == *:* ]]; then
    echo "[${address}]"
  else
    echo "${address}"
  fi
}

current_config_value() {
  local filter="$1"
  local default_value="$2"
  local jq_config_file
  local value

  jq_config_file=$(load_config_for_jq) || {
    echo "${default_value}"
    return 0
  }

  value=$(jq -r "${filter} // empty" "${jq_config_file}" 2>/dev/null)
  rm -f "${jq_config_file}"

  if [[ -n "${value}" && "${value}" != "null" ]]; then
    echo "${value}"
  else
    echo "${default_value}"
  fi
}

derive_x25519_keys() {
  local private_key_seed="$1"
  xray x25519 -i "${private_key_seed}"
}

default_private_key_for_uuid() {
  local uuid="$1"
  local seed
  local key_output

  seed=$(echo -n "${uuid}" | md5sum | head -c 32 | base64 -w 0 | tr '+/' '-_' | tr -d '=')
  key_output=$(derive_x25519_keys "${seed}")
  printf '%s\n' "${key_output}" | parse_x25519_private_key
}

public_key_for_private_key() {
  local private_key="$1"
  local key_output
  local parsed_private_key
  local public_key

  key_output=$(derive_x25519_keys "${private_key}")
  parsed_private_key=$(printf '%s\n' "${key_output}" | parse_x25519_private_key)
  public_key=$(printf '%s\n' "${key_output}" | parse_x25519_public_key)
  ensure_x25519_keys_parsed "${parsed_private_key}" "${public_key}" "${key_output}" || return 1
  echo "${public_key}"
}

read_private_key() {
  local default_private_key="$1"
  local private_key
  local key_output
  local parsed_private_key
  local public_key

  while :; do
    private_key=$(read_with_default "请输入 Reality PrivateKey" "${default_private_key}")
    private_key=$(echo -n "${private_key}" | tr -d '[:space:]')

    key_output=$(derive_x25519_keys "${private_key}")
    parsed_private_key=$(printf '%s\n' "${key_output}" | parse_x25519_private_key)
    public_key=$(printf '%s\n' "${key_output}" | parse_x25519_public_key)
    if ensure_x25519_keys_parsed "${parsed_private_key}" "${public_key}" "${key_output}"; then
      PRIVATE_KEY_RESULT="${parsed_private_key}"
      PUBLIC_KEY_RESULT="${public_key}"
      return 0
    fi
  done
}

append_json_item() {
  local array_json="$1"
  local item_json="$2"

  jq -c --argjson item "${item_json}" '. + [$item]' <<< "${array_json}"
}

landing_tag_for_uuid() {
  echo "landing-$1"
}

node_email_for_uuid() {
  echo "node-$1"
}

build_socks_outbound_json() {
  local tag="$1"
  local address="$2"
  local port="$3"
  local user="$4"
  local pass="$5"

  if [[ -n "${user}" ]]; then
    jq -n -c \
      --arg tag "${tag}" \
      --arg address "${address}" \
      --argjson port "${port}" \
      --arg user "${user}" \
      --arg pass "${pass}" \
      '{protocol:"socks",settings:{servers:[{address:$address,port:$port,users:[{user:$user,pass:$pass}]}]},tag:$tag}'
  else
    jq -n -c \
      --arg tag "${tag}" \
      --arg address "${address}" \
      --argjson port "${port}" \
      '{protocol:"socks",settings:{servers:[{address:$address,port:$port}]},tag:$tag}'
  fi
}

build_shadowsocks_outbound_json() {
  local tag="$1"
  local address="$2"
  local port="$3"
  local method="$4"
  local password="$5"

  jq -n -c \
    --arg tag "${tag}" \
    --arg address "${address}" \
    --argjson port "${port}" \
    --arg method "${method}" \
    --arg password "${password}" \
    '{protocol:"shadowsocks",settings:{servers:[{address:$address,port:$port,method:$method,password:$password}]},tag:$tag}'
}

build_landing_outbound_json() {
  local outbound_type="$1"
  local tag="$2"
  local address="$3"
  local port="$4"
  local user="$5"
  local pass="$6"
  local method="$7"

  if [[ "${outbound_type}" == "socks5" ]]; then
    build_socks_outbound_json "${tag}" "${address}" "${port}" "${user}" "${pass}"
  else
    build_shadowsocks_outbound_json "${tag}" "${address}" "${port}" "${method}" "${pass}"
  fi
}

read_landing_outbound() {
  local default_type="$1"
  local default_address="$2"
  local default_port="$3"
  local default_user="$4"
  local default_pass="$5"
  local default_method="$6"
  local choice
  local address
  local port
  local user
  local pass
  local method

  echo -e "${cyan}1${none}. socks5"
  echo -e "${cyan}2${none}. shadowsocks"
  if [[ "${default_type}" == "shadowsocks" ]]; then
    choice=$(read_choice "请选择落地类型" "2" 1 2)
  else
    choice=$(read_choice "请选择落地类型" "1" 1 2)
  fi

  address=$(read_required "请输入落地地址" "${default_address}")
  port=$(read_port "请输入落地端口" "${default_port:-443}")

  if [[ "${choice}" == "1" ]]; then
    while :; do
      user=$(read_with_default "请输入 Socks5 用户名, 可留空" "${default_user}")
      pass=$(read_with_default "请输入 Socks5 密码, 可留空" "${default_pass}")
      if [[ -z "${user}" && -z "${pass}" ]]; then
        LANDING_TYPE_RESULT="socks5"
        LANDING_ADDRESS_RESULT="${address}"
        LANDING_PORT_RESULT="${port}"
        LANDING_USER_RESULT=""
        LANDING_PASS_RESULT=""
        LANDING_METHOD_RESULT=""
        return 0
      fi
      if [[ -n "${user}" && -n "${pass}" ]]; then
        LANDING_TYPE_RESULT="socks5"
        LANDING_ADDRESS_RESULT="${address}"
        LANDING_PORT_RESULT="${port}"
        LANDING_USER_RESULT="${user}"
        LANDING_PASS_RESULT="${pass}"
        LANDING_METHOD_RESULT=""
        return 0
      fi
      warn "Socks5 用户名和密码需要同时填写或同时留空"
    done
  fi

  method=$(read_required "请输入 Shadowsocks 加密方式" "${default_method:-aes-128-gcm}")
  pass=$(read_nonempty_value "请输入 Shadowsocks 密码" "${default_pass}")
  LANDING_TYPE_RESULT="shadowsocks"
  LANDING_ADDRESS_RESULT="${address}"
  LANDING_PORT_RESULT="${port}"
  LANDING_USER_RESULT=""
  LANDING_PASS_RESULT="${pass}"
  LANDING_METHOD_RESULT="${method}"
}

build_config_file() {
  local output_file="$1"
  local port="$2"
  local domain="$3"
  local private_key="$4"
  local short_id="$5"
  local clients_json="$6"
  local landing_outbounds_json="$7"
  local routing_rules_json="$8"
  local outbounds_json
  local rules_json
  local item

  outbounds_json='[]'
  item=$(jq -n -c '{protocol:"freedom",tag:"direct"}')
  outbounds_json=$(append_json_item "${outbounds_json}" "${item}")

  while IFS= read -r item; do
    [[ -z "${item}" ]] && continue
    outbounds_json=$(append_json_item "${outbounds_json}" "${item}")
  done <<< "${landing_outbounds_json}"

  item=$(jq -n -c '{protocol:"blackhole",tag:"block"}')
  outbounds_json=$(append_json_item "${outbounds_json}" "${item}")

  rules_json="${routing_rules_json}"
  item=$(jq -n -c '{type:"field",ip:["geoip:private"],outboundTag:"block"}')
  rules_json=$(append_json_item "${rules_json}" "${item}")

  jq -n \
    --argjson port "${port}" \
    --arg domain "${domain}" \
    --arg privateKey "${private_key}" \
    --arg shortId "${short_id}" \
    --argjson clients "${clients_json}" \
    --argjson outbounds "${outbounds_json}" \
    --argjson rules "${rules_json}" \
    '{
      log: {
        access: "/var/log/xray/access.log",
        error: "/var/log/xray/error.log",
        loglevel: "warning"
      },
      inbounds: [
        {
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {
            clients: $clients,
            decryption: "none"
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: ($domain + ":443"),
              xver: 0,
              serverNames: [$domain],
              privateKey: $privateKey,
              shortIds: [$shortId]
            }
          },
          sniffing: {
            enabled: true,
            destOverride: ["http", "tls", "quic"]
          }
        }
      ],
      outbounds: $outbounds,
      dns: {
        servers: [
          "8.8.8.8",
          "1.1.1.1",
          "2001:4860:4860::8888",
          "2606:4700:4700::1111",
          "localhost"
        ]
      },
      routing: {
        domainStrategy: "IPIfNonMatch",
        rules: $rules
      }
    }' > "${output_file}"
}

node_outbound_tag() {
  local jq_config_file="$1"
  local node_idx="$2"
  local node_email
  local tag

  node_email=$(jq -r ".inbounds[0].settings.clients[${node_idx}].email // \"\"" "${jq_config_file}")
  if [[ -z "${node_email}" ]]; then
    echo "direct"
    return 0
  fi

  tag=$(jq -r --arg email "${node_email}" 'first(.routing.rules[]? | select(((.user // []) | index($email)) != null) | .outboundTag) // "direct"' "${jq_config_file}")
  echo "${tag}"
}

describe_outbound() {
  local jq_config_file="$1"
  local tag="$2"
  local protocol
  local address
  local port
  local method

  if [[ -z "${tag}" || "${tag}" == "direct" ]]; then
    echo "direct"
    return 0
  fi

  protocol=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .protocol) // empty' "${jq_config_file}")
  address=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].address) // empty' "${jq_config_file}")
  port=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].port) // empty' "${jq_config_file}")

  if [[ "${protocol}" == "socks" ]]; then
    echo "socks5 ${address}:${port}"
  elif [[ "${protocol}" == "shadowsocks" ]]; then
    method=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].method) // empty' "${jq_config_file}")
    echo "shadowsocks ${address}:${port} ${method}"
  else
    echo "${tag}"
  fi
}

list_nodes_overview() {
  local jq_config_file
  local node_count
  local idx
  local node_uuid
  local tag
  local outbound_desc

  jq_config_file=$(load_config_for_jq) || {
    warn "未找到 ${CONFIG_FILE}, 请先安装节点"
    return 1
  }

  node_count=$(jq '.inbounds[0].settings.clients | length' "${jq_config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || "${node_count}" == "null" || ! "${node_count}" =~ ^[0-9]+$ || "${node_count}" -eq 0 ]]; then
    rm -f "${jq_config_file}"
    warn "当前没有可管理的节点"
    return 1
  fi

  echo
  echo "---------- 当前节点列表 ----------"
  for ((idx=0; idx<node_count; idx++)); do
    node_uuid=$(jq -r ".inbounds[0].settings.clients[${idx}].id // \"\"" "${jq_config_file}")
    tag=$(node_outbound_tag "${jq_config_file}" "${idx}")
    outbound_desc=$(describe_outbound "${jq_config_file}" "${tag}")
    echo -e "${yellow}$((idx + 1)). 节点$((idx + 1))${none} UUID=${cyan}${node_uuid}${none} Outbound=${magenta}${outbound_desc}${none}"
  done
  echo "----------------------------------"

  rm -f "${jq_config_file}"
  print_vless_urls "" || true
}

refresh_vless_url_file() {
  local address="$1"
  local jq_config_file
  local node_count
  local port
  local domain
  local private_key
  local short_id
  local public_key
  local idx
  local current_uuid
  local tag
  local outbound_desc
  local current_url
  local tmp_url_file

  jq_config_file=$(load_config_for_jq) || {
    warn "未找到 ${CONFIG_FILE}, 跳过刷新节点链接"
    return 1
  }

  node_count=$(jq '.inbounds[0].settings.clients | length' "${jq_config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || "${node_count}" == "null" || ! "${node_count}" =~ ^[0-9]+$ || "${node_count}" -eq 0 ]]; then
    : > "${URL_FILE}"
    rm -f "${jq_config_file}"
    info "当前没有节点, 已清空 ${URL_FILE}"
    return 0
  fi

  if [[ -z "${address}" ]]; then
    address=$(extract_saved_address)
  fi
  if [[ -z "${address}" ]]; then
    address=$(detect_public_address)
  fi
  if [[ -z "${address}" ]]; then
    rm -f "${jq_config_file}"
    warn "无法确定客户端连接地址, 跳过刷新 ${URL_FILE}"
    return 1
  fi
  address=$(normalize_url_address "${address}")

  port=$(jq -r '.inbounds[0].port // empty' "${jq_config_file}")
  domain=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0] // ((.inbounds[0].streamSettings.realitySettings.dest // "") | sub(":[0-9]+$"; "")) // empty' "${jq_config_file}")
  private_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey // empty' "${jq_config_file}")
  short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "${jq_config_file}")
  public_key=$(public_key_for_private_key "${private_key}") || {
    rm -f "${jq_config_file}"
    return 1
  }

  tmp_url_file=$(mktemp)
  : > "${tmp_url_file}"

  for ((idx=0; idx<node_count; idx++)); do
    current_uuid=$(jq -r ".inbounds[0].settings.clients[${idx}].id // \"\"" "${jq_config_file}")
    [[ -z "${current_uuid}" ]] && continue

    tag=$(node_outbound_tag "${jq_config_file}" "${idx}")
    outbound_desc=$(describe_outbound "${jq_config_file}" "${tag}")
    current_url="vless://${current_uuid}@${address}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=random&pbk=${public_key}&sid=${short_id}&spx=#NODE_$((idx + 1))_${address}"
    echo "节点$((idx + 1)) (${outbound_desc}):" >> "${tmp_url_file}"
    echo "${current_url}" >> "${tmp_url_file}"
    echo >> "${tmp_url_file}"
  done

  mv "${tmp_url_file}" "${URL_FILE}"
  rm -f "${jq_config_file}"
}

print_vless_urls() {
  local address="$1"

  if refresh_vless_url_file "${address}"; then
    echo
    echo "---------- VLESS 节点链接 ----------"
    cat "${URL_FILE}"
  fi
}

collect_node_uuid() {
  local prompt="$1"
  local default_uuid="$2"
  local uuid

  while :; do
    uuid=$(read_uuid "${prompt}" "${default_uuid}")
    if uuid_exists_in_list "${uuid}" "${NODE_UUIDS[@]}"; then
      warn "UUID 已存在, 请换一个"
      continue
    fi
    echo "${uuid}"
    return 0
  done
}

install_nodes() {
  local mode
  local default_address
  local address
  local port
  local domain
  local direct_count
  local landing_count
  local total_count
  local idx
  local uuid
  local email
  local tag
  local outbound_json
  local client_json
  local rule_json
  local clients_json='[]'
  local landing_outbounds_text=""
  local routing_rules_json='[]'
  local default_private_key
  local private_key
  local public_key
  local short_id
  local tmp_config

  require_command xray "请先使用主菜单 3 安装/更新 Xray; 安装节点流程不会自动安装 Xray。" || return 1
  require_command jq "请先安装 jq: apt install -y jq" || return 1

  echo
  info "安装节点"
  echo -e "${cyan}1${none}. 仅直连"
  echo -e "${cyan}2${none}. 直连加落地"
  mode=$(read_choice "请选择安装模式" "1" 1 2)

  default_address=$(extract_saved_address)
  [[ -z "${default_address}" ]] && default_address=$(detect_public_address)
  address=$(read_required "请输入客户端连接地址(IP或域名)" "${default_address}")
  address=$(normalize_url_address "${address}")

  port=$(read_port "请输入 Xray 入站端口" "$(current_config_value '.inbounds[0].port' '443')")
  domain=$(read_required "请输入 Reality SNI 域名" "$(current_config_value '.inbounds[0].streamSettings.realitySettings.serverNames[0]' 'learn.microsoft.com')")

  direct_count=$(read_count "请输入直连节点数量" "1" 1)
  if [[ "${mode}" == "2" ]]; then
    landing_count=$(read_count "请输入落地节点数量" "1" 1)
  else
    landing_count=0
  fi
  total_count=$((direct_count + landing_count))

  NODE_UUIDS=()
  for ((idx=1; idx<=direct_count; idx++)); do
    uuid=$(collect_node_uuid "请输入节点${idx} UUID" "$(random_uuid)")
    NODE_UUIDS+=("${uuid}")
    client_json=$(jq -n -c --arg id "${uuid}" '{id:$id,flow:"xtls-rprx-vision"}')
    clients_json=$(append_json_item "${clients_json}" "${client_json}")
  done

  for ((idx=direct_count + 1; idx<=total_count; idx++)); do
    uuid=$(collect_node_uuid "请输入节点${idx} UUID" "$(random_uuid)")
    NODE_UUIDS+=("${uuid}")
    email=$(node_email_for_uuid "${uuid}")
    tag=$(landing_tag_for_uuid "${uuid}")

    echo
    info "配置节点${idx}的落地出站"
    read_landing_outbound "socks5" "" "443" "" "" "aes-128-gcm"
    outbound_json=$(build_landing_outbound_json "${LANDING_TYPE_RESULT}" "${tag}" "${LANDING_ADDRESS_RESULT}" "${LANDING_PORT_RESULT}" "${LANDING_USER_RESULT}" "${LANDING_PASS_RESULT}" "${LANDING_METHOD_RESULT}")
    landing_outbounds_text="${landing_outbounds_text}${outbound_json}"$'\n'

    client_json=$(jq -n -c --arg id "${uuid}" --arg email "${email}" '{id:$id,flow:"xtls-rprx-vision",email:$email}')
    clients_json=$(append_json_item "${clients_json}" "${client_json}")
    rule_json=$(jq -n -c --arg email "${email}" --arg tag "${tag}" '{type:"field",user:[$email],outboundTag:$tag}')
    routing_rules_json=$(append_json_item "${routing_rules_json}" "${rule_json}")
  done

  default_private_key=$(default_private_key_for_uuid "${NODE_UUIDS[0]}")
  read_private_key "${default_private_key}" || return 1
  private_key="${PRIVATE_KEY_RESULT}"
  public_key="${PUBLIC_KEY_RESULT}"
  short_id=$(read_short_id "$(echo -n "${NODE_UUIDS[0]}" | sha1sum | head -c 16)")

  tmp_config=$(make_config_tmp)
  build_config_file "${tmp_config}" "${port}" "${domain}" "${private_key}" "${short_id}" "${clients_json}" "${landing_outbounds_text}" "${routing_rules_json}"

  if replace_xray_config "${tmp_config}"; then
    refresh_vless_url_file "${address}"
    restart_xray_service
    echo
    echo "---------- 节点信息 ----------"
    echo -e "${yellow}地址${none}: ${cyan}${address}${none}"
    echo -e "${yellow}端口${none}: ${cyan}${port}${none}"
    echo -e "${yellow}SNI${none}: ${cyan}${domain}${none}"
    echo -e "${yellow}PublicKey${none}: ${cyan}${public_key}${none}"
    echo -e "${yellow}ShortId${none}: ${cyan}${short_id}${none}"
    echo
    echo "---------- VLESS 节点链接 ----------"
    cat "${URL_FILE}"
    echo "节点链接保存在 ${URL_FILE}"
  fi
}

node_current_details() {
  local jq_config_file="$1"
  local idx="$2"
  local tag="$3"
  local protocol

  CURRENT_UUID=$(jq -r ".inbounds[0].settings.clients[${idx}].id // \"\"" "${jq_config_file}")
  CURRENT_EMAIL=$(jq -r ".inbounds[0].settings.clients[${idx}].email // \"\"" "${jq_config_file}")
  CURRENT_TAG="${tag}"
  CURRENT_OUTBOUND_TYPE="direct"
  CURRENT_ADDRESS=""
  CURRENT_PORT=""
  CURRENT_USER=""
  CURRENT_PASS=""
  CURRENT_METHOD=""

  [[ "${tag}" == "direct" ]] && return 0

  protocol=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .protocol) // empty' "${jq_config_file}")
  CURRENT_ADDRESS=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].address) // empty' "${jq_config_file}")
  CURRENT_PORT=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].port) // empty' "${jq_config_file}")

  if [[ "${protocol}" == "socks" ]]; then
    CURRENT_OUTBOUND_TYPE="socks5"
    CURRENT_USER=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].users[0].user) // empty' "${jq_config_file}")
    CURRENT_PASS=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].users[0].pass) // empty' "${jq_config_file}")
  elif [[ "${protocol}" == "shadowsocks" ]]; then
    CURRENT_OUTBOUND_TYPE="shadowsocks"
    CURRENT_METHOD=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].method) // empty' "${jq_config_file}")
    CURRENT_PASS=$(jq -r --arg tag "${tag}" 'first(.outbounds[]? | select((.tag // "") == $tag) | .settings.servers[0].password) // empty' "${jq_config_file}")
  fi
}

update_node_by_index() {
  local idx_1based="$1"
  local jq_config_file
  local node_count
  local idx
  local tag
  local new_uuid
  local duplicate_count
  local outbound_choice
  local new_type
  local new_email=""
  local new_tag=""
  local new_outbound_json='{}'
  local tmp_config

  jq_config_file=$(load_config_for_jq) || {
    warn "未找到 ${CONFIG_FILE}"
    return 1
  }

  node_count=$(jq '.inbounds[0].settings.clients | length' "${jq_config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || ! "${node_count}" =~ ^[0-9]+$ || "${idx_1based}" -lt 1 || "${idx_1based}" -gt "${node_count}" ]]; then
    rm -f "${jq_config_file}"
    error
    return 1
  fi

  idx=$((idx_1based - 1))
  tag=$(node_outbound_tag "${jq_config_file}" "${idx}")
  node_current_details "${jq_config_file}" "${idx}" "${tag}"

  echo
  info "修改节点${idx_1based}; 每项直接回车表示保留当前值"
  new_uuid=$(read_uuid "UUID" "${CURRENT_UUID}")
  duplicate_count=$(jq --argjson idx "${idx}" --arg uuid "${new_uuid}" '[.inbounds[0].settings.clients | to_entries[] | select(.key != $idx and .value.id == $uuid)] | length' "${jq_config_file}" 2>/dev/null)
  if [[ "${duplicate_count}" -gt 0 ]]; then
    rm -f "${jq_config_file}"
    warn "UUID已存在, 不允许生成重复节点"
    return 1
  fi

  echo -e "${cyan}1${none}. direct"
  echo -e "${cyan}2${none}. socks5"
  echo -e "${cyan}3${none}. shadowsocks"
  if [[ "${CURRENT_OUTBOUND_TYPE}" == "socks5" ]]; then
    outbound_choice=$(read_choice "请选择出站类型" "2" 1 3)
  elif [[ "${CURRENT_OUTBOUND_TYPE}" == "shadowsocks" ]]; then
    outbound_choice=$(read_choice "请选择出站类型" "3" 1 3)
  else
    outbound_choice=$(read_choice "请选择出站类型" "1" 1 3)
  fi

  case "${outbound_choice}" in
  1)
    new_type="direct"
    ;;
  2)
    new_type="socks5"
    read_landing_outbound "socks5" "${CURRENT_ADDRESS}" "${CURRENT_PORT:-443}" "${CURRENT_USER}" "${CURRENT_PASS}" "aes-128-gcm"
    ;;
  3)
    new_type="shadowsocks"
    read_landing_outbound "shadowsocks" "${CURRENT_ADDRESS}" "${CURRENT_PORT:-443}" "" "${CURRENT_PASS}" "${CURRENT_METHOD:-aes-128-gcm}"
    ;;
  esac

  if [[ "${new_type}" != "direct" ]]; then
    if [[ -n "${CURRENT_EMAIL}" && "${CURRENT_TAG}" != "direct" ]]; then
      new_email="${CURRENT_EMAIL}"
      new_tag="${CURRENT_TAG}"
    else
      new_email=$(node_email_for_uuid "${new_uuid}")
      new_tag=$(landing_tag_for_uuid "${new_uuid}")
    fi
    new_outbound_json=$(build_landing_outbound_json "${LANDING_TYPE_RESULT}" "${new_tag}" "${LANDING_ADDRESS_RESULT}" "${LANDING_PORT_RESULT}" "${LANDING_USER_RESULT}" "${LANDING_PASS_RESULT}" "${LANDING_METHOD_RESULT}")
  fi

  tmp_config=$(make_config_tmp)
  if [[ "${new_type}" == "direct" ]]; then
    jq \
      --argjson idx "${idx}" \
      --arg uuid "${new_uuid}" \
      --arg old_email "${CURRENT_EMAIL}" \
      --arg old_tag "${CURRENT_TAG}" '
        (.routing.rules //= [])
        | (.outbounds //= [])
        | if $old_email != "" then
            .routing.rules |= map(select(((.user // []) | index($old_email)) == null))
          else
            .
          end
        | .inbounds[0].settings.clients[$idx] = {id:$uuid,flow:"xtls-rprx-vision"}
        | if ($old_tag | test("^landing-")) and (([.routing.rules[]? | select(.outboundTag == $old_tag)] | length) == 0) then
            .outbounds |= map(select((.tag // "") != $old_tag))
          else
            .
          end
      ' "${jq_config_file}" > "${tmp_config}"
  else
    jq \
      --argjson idx "${idx}" \
      --arg uuid "${new_uuid}" \
      --arg old_email "${CURRENT_EMAIL}" \
      --arg old_tag "${CURRENT_TAG}" \
      --arg email "${new_email}" \
      --arg tag "${new_tag}" \
      --argjson outbound "${new_outbound_json}" '
        (.routing.rules //= [])
        | (.outbounds //= [])
        | if $old_email != "" then
            .routing.rules |= map(select(((.user // []) | index($old_email)) == null))
          else
            .
          end
        | .inbounds[0].settings.clients[$idx] = {id:$uuid,flow:"xtls-rprx-vision",email:$email}
        | .routing.rules += [{type:"field",user:[$email],outboundTag:$tag}]
        | .outbounds |= map(select((.tag // "") != $tag))
        | .outbounds += [$outbound]
        | if ($old_tag | test("^landing-")) and ($old_tag != $tag) and (([.routing.rules[]? | select(.outboundTag == $old_tag)] | length) == 0) then
            .outbounds |= map(select((.tag // "") != $old_tag))
          else
            .
          end
      ' "${jq_config_file}" > "${tmp_config}"
  fi

  rm -f "${jq_config_file}"
  if replace_xray_config "${tmp_config}"; then
    refresh_vless_url_file ""
    restart_xray_service
    echo -e "${green}已修改节点 ${idx_1based}${none}"
  fi
}

delete_node_by_index() {
  local idx_1based="$1"
  local jq_config_file
  local node_count
  local idx
  local old_email
  local old_tag
  local tmp_config

  jq_config_file=$(load_config_for_jq) || {
    warn "未找到 ${CONFIG_FILE}"
    return 1
  }

  node_count=$(jq '.inbounds[0].settings.clients | length' "${jq_config_file}" 2>/dev/null)
  if [[ -z "${node_count}" || ! "${node_count}" =~ ^[0-9]+$ || "${idx_1based}" -lt 1 || "${idx_1based}" -gt "${node_count}" ]]; then
    rm -f "${jq_config_file}"
    error
    return 1
  fi

  idx=$((idx_1based - 1))
  old_email=$(jq -r ".inbounds[0].settings.clients[${idx}].email // \"\"" "${jq_config_file}")
  old_tag=$(node_outbound_tag "${jq_config_file}" "${idx}")

  tmp_config=$(make_config_tmp)
  jq \
    --argjson idx "${idx}" \
    --arg old_email "${old_email}" \
    --arg old_tag "${old_tag}" '
      (.routing.rules //= [])
      | (.outbounds //= [])
      | del(.inbounds[0].settings.clients[$idx])
      | if $old_email != "" then
          .routing.rules |= map(select(((.user // []) | index($old_email)) == null))
        else
          .
        end
      | if ($old_tag | test("^landing-")) and (([.routing.rules[]? | select(.outboundTag == $old_tag)] | length) == 0) then
          .outbounds |= map(select((.tag // "") != $old_tag))
        else
          .
        end
    ' "${jq_config_file}" > "${tmp_config}"

  rm -f "${jq_config_file}"
  if replace_xray_config "${tmp_config}"; then
    refresh_vless_url_file ""
    restart_xray_service
    echo -e "${green}已删除节点 ${idx_1based}${none}"
  fi
}

node_management_menu() {
  require_command jq "请先安装 jq: apt install -y jq" || return 1

  while :; do
    echo
    info "节点管理"
    echo -e "${cyan}1${none}. 查看节点"
    echo -e "${cyan}2${none}. 修改节点"
    echo -e "${cyan}3${none}. 删除节点"
    echo -e "${cyan}4${none}. 返回"

    case "$(read_choice "请选择" "1" 1 4)" in
    1)
      list_nodes_overview
      ;;
    2)
      if list_nodes_overview; then
        update_node_by_index "$(read_required "请输入要修改的节点编号" "")"
      fi
      ;;
    3)
      if list_nodes_overview; then
        delete_node_by_index "$(read_required "请输入要删除的节点编号" "")"
      fi
      ;;
    4)
      return 0
      ;;
    esac
  done
}

install_base_dependencies() {
  echo
  info "安装基础依赖"
  echo "----------------------------------------------------------------"
  apt update
  apt install -y curl wget sudo jq net-tools lsof
}

install_or_update_xray() {
  install_base_dependencies

  echo
  info "安装/更新 Xray"
  echo "----------------------------------------------------------------"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

  echo
  info "更新 geodata"
  echo "----------------------------------------------------------------"
  bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install-geodata
}

uninstall_all() {
  local confirm

  warn "此操作会卸载 Xray, 删除 ${CONFIG_FILE}, ${URL_FILE}, Xray 日志目录, 并移除脚本写入的 BBR sysctl 行。"
  read -r -p "确认卸载请输入 YES: " confirm
  if [[ "${confirm}" != "YES" ]]; then
    warn "已取消卸载"
    return 1
  fi

  if command -v curl >/dev/null 2>&1; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge
  else
    warn "未检测到 curl, 跳过官方 Xray 卸载脚本"
  fi

  rm -f "${URL_FILE}"
  rm -f "${HOME}/_vless_reality_url_"
  rm -f "/root/_vless_reality_url_" 2>/dev/null || true
  rm -rf /usr/local/etc/xray /var/log/xray /run/xray
  rm -f menu.sh

  if [[ -f /etc/sysctl.conf ]]; then
    sed -i '/net.ipv4.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr/d' /etc/sysctl.conf
    sed -i '/net.core.default_qdisc[[:space:]]*=[[:space:]]*fq/d' /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
  fi

  echo -e "${green}卸载完成${none}"
}

main_menu() {
  while :; do
    echo
    info "主页"
    echo -e "${cyan}1${none}. 安装节点"
    echo -e "${cyan}2${none}. 节点管理"
    echo -e "${cyan}3${none}. 安装/更新 Xray"
    echo -e "${cyan}4${none}. 卸载"
    echo -e "${cyan}5${none}. 退出"

    case "$(read_choice "请选择" "1" 1 5)" in
    1)
      install_nodes
      ;;
    2)
      node_management_menu
      ;;
    3)
      install_or_update_xray
      ;;
    4)
      uninstall_all
      ;;
    5)
      exit 0
      ;;
    esac
  done
}

if [[ "${XRAY_SCRIPT_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main_menu
