#!/bin/bash

# --- Configuration Variables ---
NGINX_DOMAIN="storage.luveedu.cloud"
WEB_ROOT="/var/www/html"
FTP_USER="luveeduftp" # Dedicated FTP user
FTP_USER_PASS="U#_S8fvRGdyjR4C" # Password for the FTP user
FTP_PASSIVE_PORTS_MIN=40000
FTP_PASSIVE_PORTS_MAX=40005

# --- Script Start ---
echo "Starting Nginx and FTP server setup for ${NGINX_DOMAIN}..."

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Please use 'sudo bash $(basename "$0")'"
    exit 1
fi

# --- 1. Update System and Install Dependencies ---
echo -e "\n--- Updating system and installing necessary packages ---"
apt update -y
apt upgrade -y
apt install -y nginx vsftpd ufw

# --- 2. Configure Nginx ---
echo -e "\n--- Configuring Nginx for ${NGINX_DOMAIN} ---"

# Create Nginx server block configuration
NGINX_CONF_PATH="/etc/nginx/sites-available/${NGINX_DOMAIN}"
cat <<EOF > "${NGINX_CONF_PATH}"
server {
    listen 80;
    listen [::]:80;

    server_name ${NGINX_DOMAIN};

    root ${WEB_ROOT};
    index index.html index.htm index.nginx-debian.html;

    # Disable directory indexing
    autoindex off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Optional: Add basic logging for debugging
    access_log /var/log/nginx/${NGINX_DOMAIN}.access.log;
    error_log /var/log/nginx/${NGINX_DOMAIN}.error.log;
}
EOF

# Remove default Nginx site and enable the new one
echo "Disabling default Nginx site and enabling ${NGINX_DOMAIN}..."
rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_CONF_PATH}" "/etc/nginx/sites-enabled/${NGINX_DOMAIN}"

# Apply Nginx global optimizations (edit nginx.conf directly)
echo -e "\n--- Applying Nginx global performance optimizations ---"
# Backup original nginx.conf
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak

# Use sed to add optimization directives to the http block
# This is a bit fragile if nginx.conf structure changes significantly
sed -i '/http {/a \
    worker_processes auto;\
    worker_connections 1024;\
\
    sendfile on;\
    tcp_nopush on;\
    tcp_nodelay on;\
    keepalive_timeout 65;\
    types_hash_max_size 2048;\
\
    gzip on;\
    gzip_vary on;\
    gzip_proxied any;\
    gzip_comp_level 6;\
    gzip_buffers 16 8k;\
    gzip_http_version 1.1;\
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;\
' /etc/nginx/nginx.conf

# Test Nginx configuration
echo "Testing Nginx configuration..."
nginx -t
if [ $? -ne 0 ]; then
    echo "Nginx configuration test failed. Please check the output above."
    exit 1
fi

# --- 3. Configure vsftpd ---
echo -e "\n--- Configuring vsftpd ---"

# Backup original vsftpd.conf
cp /etc/vsftpd.conf /etc/vsftpd.conf.bak

# Create vsftpd.conf
cat <<EOF > /etc/vsftpd.conf
listen=NO
listen_ipv6=YES
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
chroot_local_user=YES
allow_writeable_chroot=YES # Necessary if the chroot directory is writable by the user
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
rsa_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem
rsa_private_key_file=/etc/ssl/private/ssl-cert-snakeoil.key
ssl_enable=NO # Set to YES for FTPS (requires certificates)
pasv_enable=YES
pasv_min_port=${FTP_PASSIVE_PORTS_MIN}
pasv_max_port=${FTP_PASSIVE_PORTS_MAX}
local_root=${WEB_ROOT} # Chroot users to the web root
userlist_enable=YES
userlist_deny=NO # userlist_file contains users allowed to log in
userlist_file=/etc/vsftpd.userlist
EOF

# Create the userlist file and add the FTP user
touch /etc/vsftpd.userlist
echo "${FTP_USER}" | tee -a /etc/vsftpd.userlist > /dev/null

# --- 4. Create FTP User and Set Permissions ---
echo -e "\n--- Creating FTP user '${FTP_USER}' and setting permissions ---"

# Create the user if they don't exist, and add to www-data group
if id "${FTP_USER}" &>/dev/null; then
    echo "User '${FTP_USER}' already exists. Setting new password."
    echo "${FTP_USER}:${FTP_USER_PASS}" | chpasswd
else
    adduser --home "${WEB_ROOT}" --no-create-home --shell /bin/false "${FTP_USER}"
    echo "${FTP_USER}:${FTP_USER_PASS}" | chpasswd
    echo "FTP user '${FTP_USER}' created with the provided password."
fi

# Add FTP user to www-data group to allow write access to web root
usermod -aG www-data "${FTP_USER}"

# Set permissions for the web root
# Nginx needs read access, FTP user needs write access
# This sets ownership to www-data and allows group write
chown -R www-data:www-data "${WEB_ROOT}"
chmod -R 775 "${WEB_ROOT}" # Group (www-data) gets write permission
chmod g+s "${WEB_ROOT}" # Setgid bit ensures new files inherit group ownership

# Create a test file for Nginx to serve
echo "<h1>Welcome to ${NGINX_DOMAIN}</h1><p>This is a test page.</p><p>You can upload files via FTP to this directory.</p>" > "${WEB_ROOT}/index.html"

# --- 5. Configure Firewall (UFW) ---
echo -e "\n--- Configuring UFW Firewall ---"
ufw allow OpenSSH # Ensure SSH access is not blocked
ufw allow 'Nginx HTTP'
ufw allow 'Nginx HTTPS' # Good practice to allow HTTPS
ufw allow 20/tcp # FTP data port
ufw allow 21/tcp # FTP control port
ufw allow "${FTP_PASSIVE_PORTS_MIN}:${FTP_PASSIVE_PORTS_MAX}/tcp" # FTP passive ports
ufw --force enable # Enable UFW without prompt

echo "UFW status:"
ufw status verbose

# --- 6. Restart Services ---
echo -e "\n--- Restarting Nginx and vsftpd services ---"
systemctl restart nginx
systemctl enable nginx
systemctl restart vsftpd
systemctl enable vsftpd

# --- 7. Verification ---
echo -e "\n--- Verification ---"
echo "Nginx status:"
systemctl status nginx | grep Active

echo "vsftpd status:"
systemctl status vsftpd | grep Active

echo -e "\nSetup complete! Please verify the following:"
echo "1. Point your domain '${NGINX_DOMAIN}' to this server's IP address in your DNS settings."
echo "2. Access your website at http://${NGINX_DOMAIN} to see the test page."
echo "3. Connect via FTP using the user '${FTP_USER}' and the password you set, to upload files to ${WEB_ROOT}."
echo "   FTP Host: Your_VPS_IP_Address or ${NGINX_DOMAIN}"
echo "   FTP Username: ${FTP_USER}"
echo "   FTP Password: ${FTP_USER_PASS}" # Display the password for convenience
echo -e "\nRemember to use SFTP for more secure file transfers if possible."
