#!/bin/bash

set -e

LOG_FILE="/var/log/setup.log"
exec > >(tee -a ${LOG_FILE})
exec 2>&1

echo "===== WordPress Setup Started: $(date) ====="

# -------- CONFIGURATION VARIABLES -------- #
# Get AWS region from instance metadata
AWS_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}')
echo "Retrieving secrets from AWS Secrets Manager in region ${AWS_REGION}..."

# Install jq if not already installed
if ! command -v jq &> /dev/null; then
  echo "jq not found, installing..."
  sudo yum install -y jq
fi

# Secret name
SECRET_NAME="wordpress/secrets"

# Retrieve secrets from AWS Secrets Manager
echo "Fetching WordPress secrets from Secrets Manager..."
SECRET_JSON=$(aws secretsmanager get-secret-value --region ${AWS_REGION} --secret-id ${SECRET_NAME} --query 'SecretString' --output text 2>/dev/null)

if [ -z "$SECRET_JSON" ]; then
    echo "Error: Failed to retrieve secret from AWS Secrets Manager."
    echo "Make sure the instance has an IAM role with permissions to access Secrets Manager."
    exit 1
fi

# Parse secrets into environment variables
MYSQL_ROOT_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.MYSQL_ROOT_PASSWORD')
WP_DB_NAME=$(echo "$SECRET_JSON" | jq -r '.WP_DB_NAME')
WP_DB_USER=$(echo "$SECRET_JSON" | jq -r '.WP_DB_USER')
WP_DB_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.WP_DB_PASSWORD')
WP_ADMIN_USER=$(echo "$SECRET_JSON" | jq -r '.WP_ADMIN_USER')
WP_ADMIN_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.WP_ADMIN_PASSWORD')
WP_ADMIN_EMAIL=$(echo "$SECRET_JSON" | jq -r '.WP_ADMIN_EMAIL')

# Check if secrets were retrieved successfully, otherwise exit with error
if [ -z "$MYSQL_ROOT_PASSWORD" ] || [ -z "$WP_DB_USER" ] || [ -z "$WP_DB_PASSWORD" ] || [ -z "$WP_ADMIN_USER" ] || [ -z "$WP_ADMIN_PASSWORD" ] || [ -z "$WP_ADMIN_EMAIL" ]; then
    echo "Error: Failed to retrieve one or more required secrets from AWS Secrets Manager."
    echo "Make sure the secret contains all required keys."
    exit 1
fi

# Non-sensitive configuration
WP_URL="http://$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)"
WP_TITLE="Richard's Site"
WP_PATH="/var/www/html"

# -------- UPDATE SYSTEM -------- #
sudo yum update -y

# -------- INSTALL PHP & EXTENSIONS -------- #
sudo amazon-linux-extras enable php7.2 -y
sudo yum clean metadata
sudo yum install -y php php-cli php-mysqlnd php-fpm php-json php-common php-devel php-mbstring unzip curl

# -------- INSTALL APACHE & MARIADB -------- #
sudo yum install -y httpd mariadb-server
sudo systemctl enable httpd
sudo systemctl start httpd
sudo systemctl enable mariadb
sudo systemctl start mariadb

# -------- CONFIGURE DIRECTORY PERMISSIONS -------- #
sudo mkdir -p /var/www
sudo usermod -a -G apache ec2-user
sudo chown -R ec2-user:apache /var/www
sudo chmod 2775 /var/www && sudo find /var/www -type d -exec chmod 2775 {} \;
sudo find /var/www -type f -exec chmod 0664 {} \;

# -------- WAIT FOR MARIADB TO FULLY START -------- #
echo "Waiting for MariaDB to be fully up..."
sleep 5

# -------- CONFIGURE MYSQL SECURELY -------- #
echo "Configuring MySQL..."
sudo systemctl stop mariadb
sudo mysqld_safe --skip-grant-tables --skip-networking &
sleep 10

sudo mysql -u root <<EOF
UPDATE mysql.user SET password = PASSWORD('${MYSQL_ROOT_PASSWORD}') WHERE User = 'root' AND Host = 'localhost';
FLUSH PRIVILEGES;

CREATE DATABASE IF NOT EXISTS \`${WP_DB_NAME}\`;

DELETE FROM mysql.user WHERE User = '${WP_DB_USER}' AND Host = 'localhost';
FLUSH PRIVILEGES;

CREATE USER '${WP_DB_USER}'@'localhost' IDENTIFIED BY '${WP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${WP_DB_NAME}\`.* TO '${WP_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

sleep 3
sudo mysqladmin -u root --password="${MYSQL_ROOT_PASSWORD}" shutdown
sleep 5
sudo systemctl start mariadb

# -------- TEST DB CONNECTION FROM PHP -------- #
php -r "mysqli_connect('localhost', '${WP_DB_USER}', '${WP_DB_PASSWORD}', '${WP_DB_NAME}') ? print(\"PHP: DB connection works\n\") : print(\"PHP: DB connection failed\n\");"

# -------- INSTALL PHPMYADMIN -------- #
cd ${WP_PATH}
sudo wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz
sudo mkdir phpMyAdmin && sudo tar -xvzf phpMyAdmin-latest-all-languages.tar.gz -C phpMyAdmin --strip-components 1
sudo rm phpMyAdmin-latest-all-languages.tar.gz

# -------- INSTALL WORDPRESS -------- #
sudo wget https://wordpress.org/latest.tar.gz
sudo tar -xzf latest.tar.gz
sudo cp wordpress/wp-config-sample.php wordpress/wp-config.php
sudo sed -i "s/database_name_here/${WP_DB_NAME}/" wordpress/wp-config.php
sudo sed -i "s/username_here/${WP_DB_USER}/" wordpress/wp-config.php
sudo sed -i "s/password_here/${WP_DB_PASSWORD}/" wordpress/wp-config.php
sudo cp -r wordpress/* ${WP_PATH}/
sudo mkdir -p ${WP_PATH}/blog
sudo cp -r wordpress/* ${WP_PATH}/blog/
sudo rm -rf wordpress latest.tar.gz

# -------- INSTALL WP-CLI -------- #
cd /tmp
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar
sudo mv wp-cli.phar /usr/local/bin/wp

# -------- COMPLETE WORDPRESS INSTALL -------- #
cd ${WP_PATH}
sudo -u apache /usr/local/bin/wp core install \
  --url="${WP_URL}" \
  --title="${WP_TITLE}" \
  --admin_user="${WP_ADMIN_USER}" \
  --admin_password="${WP_ADMIN_PASSWORD}" \
  --admin_email="${WP_ADMIN_EMAIL}" \
  --skip-email \
  --path="${WP_PATH}"

# -------- INSTALL THEME FROM GITHUB ZIP AND ACTIVATE -------- #
echo "Downloading 'twentyseventeen' theme as ZIP from GitHub..."

cd /tmp
curl -L -o theme.zip https://github.com/WordPress/twentyseventeen/archive/refs/heads/master.zip
unzip theme.zip
sudo mv twentyseventeen-master ${WP_PATH}/wp-content/themes/twentyseventeen
sudo chown -R apache:apache ${WP_PATH}/wp-content/themes/twentyseventeen

echo "Activating 'twentyseventeen' theme..."
sudo -u apache /usr/local/bin/wp theme activate twentyseventeen --path="${WP_PATH}"

# -------- FIX THEME DIRECTORY PERMISSIONS -------- #
sudo chown -R apache:apache ${WP_PATH}/wp-content/themes
sudo chmod -R 755 ${WP_PATH}/wp-content/themes

# -------- FINAL PERMISSIONS -------- #
sudo chown -R apache:apache /var/www
sudo chmod 2775 /var/www && sudo find /var/www -type d -exec chmod 2775 {} \;
sudo find /var/www -type f -exec chmod 0664 {} \;

# -------- RESTART SERVICES -------- #
sudo systemctl restart httpd
sudo systemctl restart mariadb

# -------- CONFIGURE URL -------- #
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
sudo -u apache /usr/local/bin/wp option update siteurl "http://$PUBLIC_IP" --path=/var/www/html
sudo -u apache /usr/local/bin/wp option update home "http://$PUBLIC_IP" --path=/var/www/html
sudo -u apache /usr/local/bin/wp theme activate twentyseventeen --path=/var/www/html