#!/bin/bash
# 融合修复版 Xray + WordPress 一键安装脚本
# 基于 hijk.art 原脚本修复：
#   1. 修复 WordPress 字符集 utf8mb4mb4 错误
#   2. 升级 XTLS 流控为 xtls-rprx-vision 以兼容新版 Xray
#   3. 合并代理与建站功能

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
PLAIN='\033[0m'

colorEcho() { echo -e "${1}${@:2}${PLAIN}"; }

# 全局配置
CONFIG_FILE="/usr/local/etc/xray/config.json"
NGINX_CONF_PATH="/etc/nginx/conf.d/"
BT="false"
res=$(command -v bt)
[[ "$res" != "" ]] && { BT="true"; NGINX_CONF_PATH="/www/server/panel/vhost/nginx/"; }

VLESS="false"; TROJAN="false"; TLS="false"; WS="false"; XTLS="false"; KCP="false"
VMESS="true"

# 网站伪装列表（原脚本自带）
SITES=(
http://www.zhuizishu.com/
http://xs.56dyc.com/
http://www.ddxsku.com/
http://www.biqu6.com/
https://www.wenshulou.cc/
http://www.55shuba.com/
http://www.39shubao.com/
https://www.23xsw.cc/
https://www.jueshitangmen.info/
https://www.zhetian.org/
http://www.bequgexs.com/
http://www.tjwl.com/
)

# ------------------------------------------------------------
# 系统检查与基础函数
# ------------------------------------------------------------
checkSystem() {
    [[ $(id -u) -ne 0 ]] && { colorEcho $RED "请以root身份执行"; exit 1; }
    res=$(command -v yum)
    if [[ "$res" == "" ]]; then
        res=$(command -v apt)
        [[ "$res" == "" ]] && { colorEcho $RED "不支持的系统"; exit 1; }
        PMT="apt"
        CMD_INSTALL="apt install -y"
        CMD_REMOVE="apt remove -y"
        CMD_UPGRADE="apt update; apt upgrade -y; apt autoremove -y"
        PHP_SERVICE="php7.4-fpm"
    else
        PMT="yum"
        CMD_INSTALL="yum install -y"
        CMD_REMOVE="yum remove -y"
        CMD_UPGRADE="yum update -y"
        PHP_SERVICE="php-fpm"
        MAIN=$(grep -oE "[0-9.]+" /etc/centos-release | cut -d. -f1)
    fi
    command -v systemctl &>/dev/null || { colorEcho $RED "系统版本过低"; exit 1; }
}

archAffix() {
    case "$(uname -m)" in
        i686|i386) echo '32' ;;
        x86_64|amd64) echo '64' ;;
        armv5tel) echo 'arm32-v5' ;;
        armv6l) echo 'arm32-v6' ;;
        armv7|armv7l) echo 'arm32-v7a' ;;
        armv8|aarch64) echo 'arm64-v8a' ;;
        mips64le) echo 'mips64le' ;;
        mips64) echo 'mips64' ;;
        mipsle) echo 'mips32le' ;;
        mips) echo 'mips32' ;;
        ppc64le) echo 'ppc64le' ;;
        ppc64) echo 'ppc64' ;;
        riscv64) echo 'riscv64' ;;
        s390x) echo 's390x' ;;
        *) colorEcho $RED "不支持的CPU架构"; exit 1 ;;
    esac
}

# ------------------------------------------------------------
# Xray 状态检测（兼容新旧配置）
# ------------------------------------------------------------
status() {
    [[ ! -f /usr/local/bin/xray ]] && { echo 0; return; }
    [[ ! -f $CONFIG_FILE ]] && { echo 1; return; }
    port=$(grep port $CONFIG_FILE | head -n1 | cut -d: -f2 | tr -d \",' ')
    ss -nutlp | grep -q ":${port}.*xray" || { echo 2; return; }
    grep -q wsSettings $CONFIG_FILE || { echo 3; return; }
    ss -nutlp | grep -q nginx || { echo 4; return; }
    echo 5
}
statusText() {
    case $(status) in
        2) echo -e "${GREEN}已安装${PLAIN} ${RED}未运行${PLAIN}" ;;
        3) echo -e "${GREEN}已安装${PLAIN} ${GREEN}Xray运行中${PLAIN}" ;;
        4) echo -e "${GREEN}已安装${PLAIN} ${GREEN}Xray运行中${PLAIN}, ${RED}Nginx未运行${PLAIN}" ;;
        5) echo -e "${GREEN}已安装${PLAIN} ${GREEN}Xray/Nginx运行中${PLAIN}" ;;
        *) echo -e "${RED}未安装${PLAIN}" ;;
    esac
}

# ------------------------------------------------------------
# Xray 安装核心函数（修复 XTLS 流控）
# ------------------------------------------------------------
getVersion() {
    local CUR_VER=$(/usr/local/bin/xray version 2>/dev/null | head -n1 | awk '{print $2}')
    local TAG_URL="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local NEW_VER=$(curl -s "$TAG_URL" --connect-timeout 10 | grep 'tag_name' | cut -d\" -f4)
    [[ -z "$NEW_VER" ]] && { colorEcho $RED "获取版本失败"; return 3; }
    [[ -z "$CUR_VER" ]] && return 2
    [[ "$NEW_VER" != "$CUR_VER" ]] && return 1
    return 0
}

installXray() {
    rm -rf /tmp/xray; mkdir -p /tmp/xray
    local DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/download/${NEW_VER}/Xray-linux-$(archAffix).zip"
    colorEcho $BLUE "下载 Xray: $DOWNLOAD_LINK"
    curl -L -o /tmp/xray/xray.zip "$DOWNLOAD_LINK" || { colorEcho $RED "下载失败"; exit 1; }
    systemctl stop xray 2>/dev/null
    unzip -q /tmp/xray/xray.zip -d /tmp/xray
    cp /tmp/xray/xray /usr/local/bin/
    cp /tmp/xray/geo* /usr/local/share/xray/ 2>/dev/null
    chmod +x /usr/local/bin/xray
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target
[Service]
User=root
ExecStart=/usr/local/bin/xray run -config $CONFIG_FILE
Restart=on-failure
RestartPreventExitStatus=23
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
}

# 以下为各协议配置函数（已修复流控）
trojanConfig() {
    cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "trojan",
    "settings": {
      "clients": [{"password": "$PASSWORD"}],
      "fallbacks": [{"alpn": "http/1.1","dest": 80},{"alpn": "h2","dest": 81}]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1","h2"],
            "certificates": [{"certificateFile": "$CERT_FILE","keyFile": "$KEY_FILE"}]
        }
    }
  }],
  "outbounds": [{"protocol": "freedom","settings": {}},{"protocol": "blackhole","tag": "blocked"}]
}
EOF
}
trojanXTLSConfig() {   # 修复：xtls -> tls, flow 固定为 xtls-rprx-vision
    cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": $PORT,
    "protocol": "trojan",
    "settings": {
      "clients": [{"password": "$PASSWORD","flow": "xtls-rprx-vision"}],
      "fallbacks": [{"alpn": "http/1.1","dest": 80},{"alpn": "h2","dest": 81}]
    },
    "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
            "serverName": "$DOMAIN",
            "alpn": ["http/1.1","h2"],
            "certificates": [{"certificateFile": "$CERT_FILE","keyFile": "$KEY_FILE"}]
        }
    }
  }],
  "outbounds": [{"protocol": "freedom"},{"protocol": "blackhole","tag": "blocked"}]
}
EOF
}
vmessConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local alterid=$((RANDOM % 31 + 50))
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vmess","settings":{"clients":[{"id":"$uuid","level":1,"alterId":$alterid}]}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vmessKCPConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    local alterid=$((RANDOM % 31 + 50))
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vmess","settings":{"clients":[{"id":"$uuid","alterId":$alterid}]},"streamSettings":{"network":"mkcp","kcpSettings":{"header":{"type":"$HEADER_TYPE"},"seed":"$SEED"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vmessTLSConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vmess","settings":{"clients":[{"id":"$uuid","alterId":0}],"disableInsecureEncryption":false},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"$DOMAIN","alpn":["http/1.1","h2"],"certificates":[{"certificateFile":"$CERT_FILE","keyFile":"$KEY_FILE"}]}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vmessWSConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$XPORT,"listen":"127.0.0.1","protocol":"vmess","settings":{"clients":[{"id":"$uuid","alterId":0}]},"streamSettings":{"network":"ws","wsSettings":{"path":"$WSPATH","headers":{"Host":"$DOMAIN"}}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vlessTLSConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vless","settings":{"clients":[{"id":"$uuid","level":0}],"decryption":"none","fallbacks":[{"alpn":"http/1.1","dest":80},{"alpn":"h2","dest":81}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"$DOMAIN","alpn":["http/1.1","h2"],"certificates":[{"certificateFile":"$CERT_FILE","keyFile":"$KEY_FILE"}]}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vlessXTLSConfig() {   # 修复：xtls -> tls, flow 固定为 xtls-rprx-vision
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vless","settings":{"clients":[{"id":"$uuid","flow":"xtls-rprx-vision","level":0}],"decryption":"none","fallbacks":[{"alpn":"http/1.1","dest":80},{"alpn":"h2","dest":81}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"serverName":"$DOMAIN","alpn":["http/1.1","h2"],"certificates":[{"certificateFile":"$CERT_FILE","keyFile":"$KEY_FILE"}]}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vlessWSConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$XPORT,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},"streamSettings":{"network":"ws","wsSettings":{"path":"$WSPATH","headers":{"Host":"$DOMAIN"}}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
vlessKCPConfig() {
    local uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > $CONFIG_FILE <<EOF
{"inbounds":[{"port":$PORT,"protocol":"vless","settings":{"clients":[{"id":"$uuid"}],"decryption":"none"},"streamSettings":{"network":"mkcp","kcpSettings":{"header":{"type":"$HEADER_TYPE"},"seed":"$SEED"}}}],"outbounds":[{"protocol":"freedom"}]}
EOF
}
configXray() {
    if [[ "$TROJAN" == "true" ]]; then
        [[ "$XTLS" == "true" ]] && trojanXTLSConfig || trojanConfig
        return
    fi
    if [[ "$VLESS" == "false" ]]; then
        [[ "$KCP" == "true" ]] && vmessKCPConfig
        [[ "$TLS" == "false" ]] && vmessConfig
        [[ "$TLS" == "true" && "$WS" == "false" ]] && vmessTLSConfig
        [[ "$WS" == "true" ]] && vmessWSConfig
    else
        [[ "$KCP" == "true" ]] && vlessKCPConfig
        [[ "$WS" == "false" && "$XTLS" == "false" ]] && vlessTLSConfig
        [[ "$XTLS" == "true" ]] && vlessXTLSConfig
        [[ "$WS" == "true" ]] && vlessWSConfig
    fi
}

# ------------------------------------------------------------
# Nginx 与 证书
# ------------------------------------------------------------
installNginx() {
    if [[ "$BT" == "false" ]]; then
        $CMD_INSTALL nginx -y
        systemctl enable nginx
    else
        command -v nginx &>/dev/null || { colorEcho $RED "请先在宝塔安装nginx"; exit 1; }
    fi
}
stopNginx() {
    if [[ "$BT" == "false" ]]; then systemctl stop nginx; else nginx -s stop 2>/dev/null; fi
}
startNginx() {
    if [[ "$BT" == "false" ]]; then systemctl start nginx; else nginx -c /www/server/nginx/conf/nginx.conf; fi
}
getCert() {
    mkdir -p /usr/local/etc/xray
    if [[ -f ~/xray.pem && -f ~/xray.key ]]; then
        cp ~/xray.pem "/usr/local/etc/xray/${DOMAIN}.pem"
        cp ~/xray.key "/usr/local/etc/xray/${DOMAIN}.key"
        CERT_FILE="/usr/local/etc/xray/${DOMAIN}.pem"
        KEY_FILE="/usr/local/etc/xray/${DOMAIN}.key"
        return
    fi
    stopNginx; systemctl stop xray 2>/dev/null
    netstat -ntlp | grep -E ':80 |:443 ' && { colorEcho $RED "端口80/443被占用"; exit 1; }
    $CMD_INSTALL socat openssl -y
    curl -sL https://get.acme.sh | sh -s email=hijk.pw@protonmail.sh
    source ~/.bashrc
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d "$DOMAIN" --keylength ec-256 --standalone
    [[ -f ~/.acme.sh/${DOMAIN}_ecc/ca.cer ]] || { colorEcho $RED "证书获取失败"; exit 1; }
    CERT_FILE="/usr/local/etc/xray/${DOMAIN}.pem"
    KEY_FILE="/usr/local/etc/xray/${DOMAIN}.key"
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --key-file "$KEY_FILE" --fullchain-file "$CERT_FILE" \
        --reloadcmd "systemctl force-reload nginx"
}
configNginx() {
    mkdir -p /usr/share/nginx/html
    [[ "$ALLOW_SPIDER" == "n" ]] && echo -e "User-Agent: *\nDisallow: /" > /usr/share/nginx/html/robots.txt
    local action=""
    [[ -n "$PROXY_URL" ]] && action="proxy_ssl_server_name on; proxy_pass $PROXY_URL; sub_filter \"$REMOTE_HOST\" \"$DOMAIN\"; sub_filter_once off;"
    if [[ "$TLS" == "true" || "$XTLS" == "true" ]]; then
        mkdir -p "$NGINX_CONF_PATH"
        if [[ "$WS" == "true" ]]; then
            cat > "${NGINX_CONF_PATH}${DOMAIN}.conf" <<EOF
server {
    listen 80; listen [::]:80; server_name $DOMAIN;
    return 301 https://\$server_name:${PORT}\$request_uri;
}
server {
    listen ${PORT} ssl http2; listen [::]:${PORT} ssl http2;
    server_name $DOMAIN;
    ssl_certificate $CERT_FILE; ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /usr/share/nginx/html;
    location / { $action }
    location ${WSPATH} {
        proxy_redirect off; proxy_pass http://127.0.0.1:${XPORT};
        proxy_http_version 1.1; proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade"; proxy_set_header Host \$host;
    }
}
EOF
        else
            cat > "${NGINX_CONF_PATH}${DOMAIN}.conf" <<EOF
server {
    listen 80; listen [::]:80; listen 81 http2;
    server_name $DOMAIN; root /usr/share/nginx/html;
    location / { $action }
}
EOF
        fi
    fi
}
setFirewall() {
    command -v firewall-cmd &>/dev/null && {
        systemctl is-active firewalld &>/dev/null && {
            firewall-cmd --permanent --add-service={http,https}
            [[ "$PORT" != "443" ]] && firewall-cmd --permanent --add-port=${PORT}/tcp --add-port=${PORT}/udp
            firewall-cmd --reload
        }
        return
    }
    command -v iptables &>/dev/null && {
        iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT -p tcp --dport 443 -j ACCEPT
        [[ "$PORT" != "443" ]] && iptables -I INPUT -p tcp --dport ${PORT} -j ACCEPT
    }
}
installBBR() {
    [[ "$NEED_BBR" != "y" ]] && return
    lsmod | grep -q bbr && { colorEcho $BLUE "BBR已启用"; return; }
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
    lsmod | grep -q bbr && { colorEcho $GREEN "BBR启用成功"; return; }
    colorEcho $RED "BBR启用失败"; INSTALL_BBR=false
}

# ------------------------------------------------------------
# Xray 安装数据收集（已移除流控选择，固定 vision）
# ------------------------------------------------------------
getData() {
    [[ "$TLS" == "true" || "$XTLS" == "true" ]] && {
        colorEcho $YELLOW "前提：域名已解析到本机IP ($IP)"
        read -p "请输入伪装域名: " DOMAIN
        DOMAIN=${DOMAIN,,}
        resolve=$(curl -sL http://ip-api.com/json/${DOMAIN} | grep -o "$IP")
        [[ -z "$resolve" && ! -f ~/xray.pem ]] && { colorEcho $RED "域名未解析到本机"; exit 1; }
    }
    if [[ "$(needNginx)" == "no" ]]; then
        read -p "请输入xray端口 [100-65535]: " PORT
        [[ -z "$PORT" ]] && PORT=$((RANDOM % 65000 + 1000))
    else
        read -p "请输入Nginx端口 [默认443]: " PORT
        [[ -z "$PORT" ]] && PORT=443
        XPORT=$((RANDOM % 55000 + 10000))
    fi
    [[ "$KCP" == "true" ]] && {
        colorEcho $BLUE "选择伪装类型: 1)无 2)BT 3)视频 4)微信 5)dtls 6)wireguard"
        read -p "请选择 [默认1]: " answer
        case $answer in 2) HEADER_TYPE="utp";;3) HEADER_TYPE="srtp";;4) HEADER_TYPE="wechat-video";;5) HEADER_TYPE="dtls";;6) HEADER_TYPE="wireguard";;*) HEADER_TYPE="none";; esac
        SEED=$(cat /proc/sys/kernel/random/uuid)
    }
    [[ "$TROJAN" == "true" ]] && {
        read -p "设置trojan密码 [随机]: " PASSWORD
        [[ -z "$PASSWORD" ]] && PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w16 | head -n1)
    }
    [[ "$WS" == "true" ]] && {
        read -p "请输入伪装路径 [/开头, 直接回车随机]: " WSPATH
        [[ -z "$WSPATH" ]] && WSPATH="/$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w8 | head -n1)"
        [[ "${WSPATH:0:1}" != "/" ]] && WSPATH="/$WSPATH"
    }
    [[ "$TLS" == "true" || "$XTLS" == "true" ]] && {
        colorEcho $BLUE "伪装站类型: 1)静态 2)小说站 3)美女站 4)高清壁纸 5)自定义"
        read -p "请选择 [默认4]: " answer
        case $answer in
            1) PROXY_URL="";;
            2) PROXY_URL=${SITES[$((RANDOM % ${#SITES[@]}))]};;
            3) PROXY_URL="https://imeizi.me";;
            5) read -p "请输入反代URL: " PROXY_URL;;
            *) PROXY_URL="https://bing.imeizi.me";;
        esac
        REMOTE_HOST=$(echo "$PROXY_URL" | cut -d/ -f3)
        read -p "允许搜索引擎爬取? [y/n, 默认n]: " answer
        ALLOW_SPIDER=$([[ "${answer,,}" == "y" ]] && echo "y" || echo "n")
    }
    read -p "安装BBR? [y/n, 默认y]: " NEED_BBR
    [[ -z "$NEED_BBR" ]] && NEED_BBR="y"
}
needNginx() { [[ "$WS" == "true" ]] && echo "yes" || echo "no"; }

# ------------------------------------------------------------
# Xray 安装主流程
# ------------------------------------------------------------
installXrayMain() {
    getData
    $CMD_UPGRADE
    $CMD_INSTALL wget curl unzip tar gcc openssl net-tools -y
    installNginx
    setFirewall
    [[ "$TLS" == "true" || "$XTLS" == "true" ]] && getCert
    configNginx
    getVersion; RETVAL=$?
    if [[ $RETVAL -eq 0 ]]; then
        colorEcho $BLUE "Xray已是最新版"
    elif [[ $RETVAL -eq 3 ]]; then
        exit 1
    else
        NEW_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d\" -f4)
        installXray
    fi
    configXray
    installBBR
    systemctl restart xray nginx 2>/dev/null
    showXrayInfo
    [[ "$INSTALL_BBR" == "true" ]] && { colorEcho $YELLOW "系统将重启以启用BBR"; sleep 3; reboot; }
}

# ------------------------------------------------------------
# WordPress 相关函数（修复字符集错误）
# ------------------------------------------------------------
installPHP() {
    [[ "$PMT" == "apt" ]] && $PMT update
    $CMD_INSTALL curl wget ca-certificates -y
    if [[ "$PMT" == "yum" ]]; then
        $CMD_INSTALL epel-release -y
        [[ $MAIN -eq 7 ]] && rpm -iUh https://rpms.remirepo.net/enterprise/remi-release-7.rpm
        [[ $MAIN -eq 8 ]] && dnf install https://rpms.remirepo.net/enterprise/remi-release-8.rpm
        sed -i '0,/enabled=0/{s/enabled=0/enabled=1/}' /etc/yum.repos.d/remi*.repo
        $CMD_INSTALL php-cli php-fpm php-bcmath php-gd php-mbstring php-mysqlnd php-pdo php-xml php-pecl-zip -y
    else
        $CMD_INSTALL lsb-release gnupg2 -y
        wget -q https://packages.sury.org/php/apt.gpg -O- | apt-key add -
        echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list
        $PMT update
        $CMD_INSTALL php7.4-cli php7.4-fpm php7.4-bcmath php7.4-gd php7.4-mbstring php7.4-mysql php7.4-xml php7.4-zip -y
        update-alternatives --set php /usr/bin/php7.4
    fi
    systemctl enable $PHP_SERVICE
}
installMysql() {
    if [[ "$PMT" == "yum" ]]; then
        yum remove -y MariaDB-server
        [[ ! -f /etc/yum.repos.d/mariadb.repo ]] && {
            cat > /etc/yum.repos.d/mariadb.repo <<EOF
[mariadb]
name=MariaDB
baseurl=http://yum.mariadb.org/10.5/centos${MAIN}-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
        }
        yum install -y MariaDB-server
    else
        $CMD_INSTALL mariadb-server -y
    fi
    systemctl enable mariadb
}
installWordPress() {
    mkdir -p /var/www
    wget https://cn.wordpress.org/latest-zh_CN.tar.gz || { colorEcho $RED "下载失败"; exit 1; }
    tar -zxf latest-zh_CN.tar.gz
    rm -rf "/var/www/$DOMAIN"
    mv wordpress "/var/www/$DOMAIN"
    rm -f latest-zh_CN.tar.gz
}
configWordPress() {
    systemctl start mariadb
    DBNAME="wordpress"
    DBUSER="wordpress"
    DBPASS=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w16 | head -n1)
    mysql -uroot <<EOF
DELETE FROM mysql.user WHERE User='';
CREATE DATABASE $DBNAME default charset utf8mb4;
CREATE USER '${DBUSER}'@'%' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'%';
FLUSH PRIVILEGES;
EOF
    cd "/var/www/$DOMAIN"
    cp wp-config-sample.php wp-config.php
    sed -i "s/database_name_here/$DBNAME/; s/username_here/$DBUSER/; s/password_here/$DBPASS/" wp-config.php
    # 修复字符集错误：使用精确替换，避免 utf8 -> utf8mb4 -> utf8mb4mb4
    perl -pi -e "s/utf8/utf8mb4/ if /DB_CHARSET/" wp-config.php
    # 生成随机密钥
    perl -i -pe '
        BEGIN { @chars = ("a".."z","A".."Z",0..9,"!","@","#","$","%","^","&","*","(",")","-","_","=","+","[","]","{","}","|",";",":",",",".","/","?","<",">","~"); sub salt { join "", map $chars[rand @chars], 1..64 } }
        s/put your unique phrase here/salt()/ge
    ' wp-config.php
    local user="www-data"
    [[ "$PMT" == "yum" ]] && user="apache"
    chown -R "$user":"$user" "/var/www/$DOMAIN"
    # 配置 nginx 虚拟主机（如果尚未配置）
    if [[ ! -f "${NGINX_CONF_PATH}${DOMAIN}.conf" ]]; then
        local upstream="unix:/run/php/php7.4-fpm.sock"
        [[ "$PMT" == "yum" && $MAIN -eq 7 ]] && upstream="127.0.0.1:9000"
        [[ "$PMT" == "yum" && $MAIN -eq 8 ]] && upstream="php-fpm"
        cat > "${NGINX_CONF_PATH}${DOMAIN}.conf" <<EOF
server {
    listen 80; listen [::]:80;
    server_name $DOMAIN;
    root /var/www/$DOMAIN;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ { include fastcgi_params; fastcgi_pass $upstream; fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name; }
}
EOF
        systemctl restart nginx
    fi
    systemctl restart $PHP_SERVICE mariadb nginx
}
showWordPressInfo() {
    local wpconfig="/var/www/${DOMAIN}/wp-config.php"
    [[ ! -f "$wpconfig" ]] && { colorEcho $RED "WordPress未安装"; return; }
    local DBUSER=$(grep DB_USER "$wpconfig" | cut -d, -f2 | tr -d "\"', " )
    local DBNAME=$(grep DB_NAME "$wpconfig" | cut -d, -f2 | tr -d "\"', " )
    local DBPASS=$(grep DB_PASSWORD "$wpconfig" | cut -d, -f2 | tr -d "\"', " )
    local url="http://$DOMAIN"
    [[ -f "${NGINX_CONF_PATH}${DOMAIN}.conf" ]] && grep -q ssl "${NGINX_CONF_PATH}${DOMAIN}.conf" && url="https://$DOMAIN"
    colorEcho $BLUE "WordPress配置信息："
    echo "==============================="
    echo -e "  安装路径: /var/www/${DOMAIN}"
    echo -e "  数据库: ${DBNAME}"
    echo -e "  用户名: ${DBUSER}"
    echo -e "  密码: ${DBPASS}"
    echo -e "  网址: $url"
    echo "==============================="
}
uninstallWordPress() {
    read -p "确认卸载WordPress? [y/n]: " ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit
    systemctl stop mariadb $PHP_SERVICE
    systemctl disable mariadb $PHP_SERVICE
    $CMD_REMOVE mariadb* php* -y
    rm -rf /var/lib/mysql /var/www/${DOMAIN} 2>/dev/null
    colorEcho $GREEN "WordPress卸载完成"
}

# ------------------------------------------------------------
# Xray 管理功能
# ------------------------------------------------------------
updateXray() {
    getVersion; case $? in 0) colorEcho $BLUE "已是最新";;2) colorEcho $RED "未安装";;3) exit 1;;*) installXray;;
    esac
}
uninstallXray() {
    read -p "卸载Xray? [y/n]: " ans; [[ "$ans" != "y" ]] && exit
    systemctl stop xray nginx; systemctl disable xray nginx
    rm -rf /usr/local/bin/xray /usr/local/etc/xray /etc/systemd/system/xray.service /etc/nginx /usr/share/nginx/html/*
    colorEcho $GREEN "卸载完成"
}
startXray() { systemctl start xray nginx; }
stopXray()  { systemctl stop xray nginx; }
restartXray(){ systemctl restart xray nginx; }
showXrayInfo() {
    grep -q wsSettings $CONFIG_FILE && WS_MODE="WS" || WS_MODE="TCP"
    colorEcho $BLUE "Xray配置信息："
    echo "==============================="
    grep -q '"protocol": "vmess"' $CONFIG_FILE && echo "协议: VMess"
    grep -q '"protocol": "vless"' $CONFIG_FILE && echo "协议: VLESS"
    grep -q '"protocol": "trojan"' $CONFIG_FILE && echo "协议: Trojan"
    grep -q '"security": "tls"' $CONFIG_FILE && echo "加密: TLS"
    grep -q '"flow": "xtls-rprx-vision"' $CONFIG_FILE && echo "流控: xtls-rprx-vision"
    echo "端口: $(grep port $CONFIG_FILE | head -n1 | cut -d: -f2 | tr -d ,' ')"
    [[ -n "$DOMAIN" ]] && echo "域名: $DOMAIN"
    echo "==============================="
}
showXrayLog() { journalctl -u xray -n 50 --no-pager; }

# ------------------------------------------------------------
# 主菜单（融合）
# ------------------------------------------------------------
menu() {
    clear
    echo "#############################################################"
    echo -e "#          ${RED}Xray + WordPress 一键安装脚本（修复版）${PLAIN}          #"
    echo -e "# ${GREEN}作者: 网络跳越 (修复 by AI)${PLAIN}                              #"
    echo "#############################################################"
    echo -e "  ${GREEN}1.${PLAIN}   Xray-VMESS"
    echo -e "  ${GREEN}2.${PLAIN}   Xray-VMESS+mKCP"
    echo -e "  ${GREEN}3.${PLAIN}   Xray-VMESS+TCP+TLS"
    echo -e "  ${GREEN}4.${PLAIN}   Xray-VMESS+WS+TLS ${RED}(推荐)${PLAIN}"
    echo -e "  ${GREEN}5.${PLAIN}   Xray-VLESS+mKCP"
    echo -e "  ${GREEN}6.${PLAIN}   Xray-VLESS+TCP+TLS"
    echo -e "  ${GREEN}7.${PLAIN}   Xray-VLESS+WS+TLS ${RED}(可过CDN)${PLAIN}"
    echo -e "  ${GREEN}8.${PLAIN}   Xray-VLESS+TCP+XTLS ${RED}(推荐，已修复流控)${PLAIN}"
    echo -e "  ${GREEN}9.${PLAIN}   Trojan ${RED}(推荐)${PLAIN}"
    echo -e "  ${GREEN}10.${PLAIN}  Trojan+XTLS ${RED}(推荐，已修复流控)${PLAIN}"
    echo " -------------"
    echo -e "  ${GREEN}11.${PLAIN}  安装 WordPress（需先安装 Xray 并获得域名）"
    echo -e "  ${GREEN}12.${PLAIN}  卸载 WordPress"
    echo -e "  ${GREEN}13.${PLAIN}  查看 WordPress 配置"
    echo -e "  ${GREEN}14.${PLAIN}  查看操作帮助（Nginx/PHP/MySQL）"
    echo " -------------"
    echo -e "  ${GREEN}15.${PLAIN}  更新 Xray"
    echo -e "  ${GREEN}16.${PLAIN}  卸载 Xray"
    echo -e "  ${GREEN}17.${PLAIN}  启动 Xray"
    echo -e "  ${GREEN}18.${PLAIN}  重启 Xray"
    echo -e "  ${GREEN}19.${PLAIN}  停止 Xray"
    echo -e "  ${GREEN}20.${PLAIN}  查看 Xray 配置"
    echo -e "  ${GREEN}21.${PLAIN}  查看 Xray 日志"
    echo " -------------"
    echo -e "  ${GREEN}0.${PLAIN}   退出"
    echo -n "当前状态: "; statusText
    echo
    read -p "请选择操作 [0-21]: " answer
    case $answer in
        0) exit 0 ;;
        1) installXrayMain ;;
        2) KCP="true"; installXrayMain ;;
        3) TLS="true"; installXrayMain ;;
        4) TLS="true"; WS="true"; installXrayMain ;;
        5) VLESS="true"; KCP="true"; installXrayMain ;;
        6) VLESS="true"; TLS="true"; installXrayMain ;;
        7) VLESS="true"; TLS="true"; WS="true"; installXrayMain ;;
        8) VLESS="true"; TLS="true"; XTLS="true"; installXrayMain ;;
        9) TROJAN="true"; TLS="true"; installXrayMain ;;
        10) TROJAN="true"; TLS="true"; XTLS="true"; installXrayMain ;;
        11)
            [[ $(status) -lt 2 ]] && { colorEcho $RED "请先安装 Xray 并获得域名"; exit 1; }
            DOMAIN=$(grep -oE 'serverName": "[^"]+' $CONFIG_FILE | head -n1 | cut -d'"' -f3)
            [[ -z "$DOMAIN" ]] && DOMAIN=$(grep -oE 'Host": "[^"]+' $CONFIG_FILE | head -n1 | cut -d'"' -f3)
            [[ -z "$DOMAIN" ]] && { colorEcho $RED "无法获取域名"; exit 1; }
            installPHP; installMysql; installWordPress; configWordPress
            colorEcho $GREEN "WordPress 安装完成！"; showWordPressInfo
            ;;
        12) uninstallWordPress ;;
        13) showWordPressInfo ;;
        14)
            echo "Nginx: systemctl start/stop/restart nginx"
            echo "PHP:   systemctl start/stop/restart $PHP_SERVICE"
            echo "MySQL: systemctl start/stop/restart mariadb"
            ;;
        15) updateXray ;;
        16) uninstallXray ;;
        17) startXray ;;
        18) restartXray ;;
        19) stopXray ;;
        20) showXrayInfo ;;
        21) showXrayLog ;;
        *) colorEcho $RED "无效选项" ;;
    esac
}

# ------------------------------------------------------------
# 启动
# ------------------------------------------------------------
checkSystem
[[ -z "$1" ]] && menu || { case $1 in menu|update|uninstall|start|restart|stop|showInfo|showLog) ${1};; *) echo "参数错误";; esac; }