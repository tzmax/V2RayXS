#!/bin/bash
# supported by @xuxucode, related links: https://github.com/Cenmrev/V2RayX/issues/320
# related issue: https://github.com/tzmax/V2RayXS/issues/37

PAC_DIR_PATH="${HOME}/Library/Application Support/V2RayXS/pac/"
OUT_FILE="${PAC_DIR_PATH}gfwlist.js"
if [ ! -d "${PAC_DIR_PATH}" ]; then
  echo -e "V2RayXS is not installed or the pac directory is corrupted\n"
  exit 2
fi

# 从 gfwlist 更新 gfwlist.js
readonly GFWLIST_PATH="https://gitlab.com/gfwlist/gfwlist/raw/master/gfwlist.txt"

# 扩展域名，添加额外需要代理的域名
declare -a EXTEND_DOMAINS
EXTEND_DOMAINS=( github.com githubusercontent.com )

echo -e "下载 gfwlist.txt..."

# 开头
cat << 'EOF' > "$OUT_FILE"
var V2Ray = "SOCKS5 127.0.0.1:1081; SOCKS 127.0.0.1:1081; DIRECT;";

var domains = [
EOF

# 域名
for line in "${EXTEND_DOMAINS[@]}"; do
  echo "  \"${line}\"," >> "$OUT_FILE"
done;

while IFS= read -r line; do
  if [[ "${line}" == .* ]]; then
    echo "  \"${line:1}\"," >> "$OUT_FILE"
  fi
  if [[ "${line}" == \|\|* ]]; then
    echo "  \"${line:2}\"," >> "$OUT_FILE"
  fi
done < <(curl -sSfL "${GFWLIST_PATH}" | tr -d '\n' | base64 --decode | sort | uniq)

# 结尾
cat << 'EOF' >> "$OUT_FILE"
];

function FindProxyForURL(url, host) {
    for (var i = domains.length - 1; i >= 0; i--) {
    	if (dnsDomainIs(host, domains[i])) {
            return V2Ray;
    	}
    }
    return "DIRECT";
}
EOF

echo -e "\n\033[32m更新完成 ${OUT_FILE} \033[0m\n"