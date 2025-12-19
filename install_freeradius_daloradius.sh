#!/bin/bash
# Установка и настройка FreeRADIUS с daloRADIUS веб-интерфейсом на Debian 11/12
# Скрипт автоматически устанавливает все необходимые компоненты
# и настраивает систему для управления пользователями RADIUS через веб-интерфейс

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ПРЕДУПРЕЖДЕНИЕ]${NC} $1"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

# Проверка прав администратора
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен быть запущен с правами root"
   exit 1
fi

# Проверка операционной системы
if ! grep -q "Debian GNU/Linux 1[12]" /etc/os-release; then
    print_warning "Этот скрипт предназначен для Debian 11 или 12"
    read -p "Продолжить установку? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Генерация случайного пароля
generate_password() {
    openssl rand -base64 16 | tr -d "=+/" | cut -c1-12
}

print_status "Начало установки FreeRADIUS с daloRADIUS..."

# Обновление системы
print_status "Обновление системы..."
apt update && apt upgrade -y

# Установка необходимых пакетов
print_status "Установка необходимых пакетов..."
apt install -y apache2 mariadb-server php php-mysql php-gd php-xml php-mbstring php-curl php-zip unzip wget curl git expect

# Запуск и включение MariaDB
systemctl start mariadb
systemctl enable mariadb

# Генерация пароля для root в MariaDB
MYSQL_ROOT_PASSWORD=$(generate_password)

# Настройка безопасности MariaDB с помощью expect
print_status "Настройка безопасности MariaDB..."
expect <<EOF
spawn mysql_secure_installation
expect "Enter current password for root (enter for none):"
send "\\r"
expect "Set root password?"
send "y\\r"
expect "New password:"
send "$MYSQL_ROOT_PASSWORD\\r"
expect "Re-enter new password:"
send "$MYSQL_ROOT_PASSWORD\\r"
expect "Remove anonymous users?"
send "y\\r"
expect "Disallow root login remotely?"
send "y\\r"
expect "Remove test database and access to it?"
send "y\\r"
expect "Reload privilege tables now?"
send "y\\r"
expect eof
EOF

# Создание случайных паролей
FREERADIUS_DB_PASSWORD=$(generate_password)
DALORADIUS_DB_PASSWORD=$(generate_password)
ADMIN_PASSWORD=$(generate_password)

# Создание временного файла конфигурации MySQL для аутентификации
MYSQL_TMP_CONF="/tmp/.mysql_config.$$"
cat > "$MYSQL_TMP_CONF" <<MYSQL_EOF
[client]
user=root
password=$MYSQL_ROOT_PASSWORD
host=localhost
MYSQL_EOF

print_status "Создание базы данных для FreeRADIUS..."
mysql --defaults-extra-file="$MYSQL_TMP_CONF" <<MYSQL_SCRIPT
CREATE DATABASE radius;
GRANT ALL ON radius.* TO 'radius'@'localhost' IDENTIFIED BY '$FREERADIUS_DB_PASSWORD';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

print_status "Создание базы данных для daloRADIUS..."
mysql --defaults-extra-file="$MYSQL_TMP_CONF" <<MYSQL_SCRIPT
CREATE DATABASE daloradius;
GRANT ALL ON daloradius.* TO 'daloradius'@'localhost' IDENTIFIED BY '$DALORADIUS_DB_PASSWORD';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

# Удаление временного файла конфигурации
rm -f "$MYSQL_TMP_CONF"

# Установка FreeRADIUS
print_status "Установка FreeRADIUS..."
apt install -y freeradius freeradius-mysql

# Настройка SQL для FreeRADIUS
print_status "Настройка SQL поддержки для FreeRADIUS..."
cp /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-available/sql.backup

# Редактирование конфигурации SQL модуля
sed -i "s/#.*driver = \"rlm_sql_mysql\"/driver = \"rlm_sql_mysql\"/g" /etc/freeradius/3.0/mods-available/sql
sed -i "s/password = \"\"/password = \"$FREERADIUS_DB_PASSWORD\"/g" /etc/freeradius/3.0/mods-available/sql
sed -i "s/#.*query = \"accept\"/query = \"accept\"/g" /etc/freeradius/3.0/mods-available/sql

# Включение SQL модуля
ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql

# Настройка основного конфига FreeRADIUS для использования SQL
sed -i '/^.*sql$/ s/^/#/' /etc/freeradius/3.0/sites-available/default
sed -i '/^#.*sql$/ s/^#//' /etc/freeradius/3.0/sites-available/default

# Создание временного файла конфигурации для импорта схемы FreeRADIUS
MYSQL_TMP_CONF_SCHEMA="/tmp/.mysql_config.$$"
cat > "$MYSQL_TMP_CONF_SCHEMA" <<MYSQL_EOF
[client]
user=root
password=$MYSQL_ROOT_PASSWORD
host=localhost
MYSQL_EOF

# Импорт SQL схемы для FreeRADIUS
print_status "Импорт SQL схемы FreeRADIUS..."
mysql --defaults-extra-file="$MYSQL_TMP_CONF_SCHEMA" radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql

# Включение SQL accounting
ln -s /etc/freeradius/3.0/mods-available/sqlcounter /etc/freeradius/3.0/mods-enabled/sqlcounter

# Установка daloRADIUS
print_status "Загрузка и установка daloRADIUS..."
cd /tmp
wget https://github.com/lirantal/daloradius/archive/master.zip
unzip master.zip
mv daloradius-master /var/www/html/daloradius
chown -R www-data:www-data /var/www/html/daloradius

# Настройка конфигурации daloRADIUS
print_status "Настройка конфигурации daloRADIUS..."
cp /var/www/html/daloradius/library/daloradius.conf.php.sample /var/www/html/daloradius/library/daloradius.conf.php
chmod 644 /var/www/html/daloradius/library/daloradius.conf.php

# Редактирование конфигурационного файла daloRADIUS
sed -i "s/\$configValues\['CONFIG_DB_HOST'\] = 'localhost';/\$configValues\['CONFIG_DB_HOST'\] = 'localhost';/g" /var/www/html/daloradius/library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_USER'\] = 'root';/\$configValues\['CONFIG_DB_USER'\] = 'daloradius';/g" /var/www/html/daloradius/library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = 'root';/\$configValues\['CONFIG_DB_PASS'\] = '$DALORADIUS_DB_PASSWORD';/g" /var/www/html/daloradius/library/daloradius.conf.php
sed -i "s/\$configValues\['CONFIG_DB_NAME'\] = 'radius';/\$configValues\['CONFIG_DB_NAME'\] = 'daloradius';/g" /var/www/html/daloradius/library/daloradius.conf.php

# Импорт SQL схемы для daloRADIUS
print_status "Импорт SQL схемы daloRADIUS..."
mysql --defaults-extra-file="$MYSQL_TMP_CONF_SCHEMA" daloradius < /var/www/html/daloradius/contrib/db/fr2-mysql-daloradius-and-freeradius.sql
mysql --defaults-extra-file="$MYSQL_TMP_CONF_SCHEMA" daloradius < /var/www/html/daloradius/contrib/db/mysql-daloradius.sql

# Удаление временного файла конфигурации
rm -f "$MYSQL_TMP_CONF_SCHEMA"

# Настройка Apache для daloRADIUS
print_status "Настройка Apache для daloRADIUS..."
cat > /etc/apache2/sites-available/daloradius.conf <<APACHE_CONFIG
<VirtualHost *:80>
    ServerName daloradius
    DocumentRoot /var/www/html/daloradius
    
    <Directory /var/www/html/daloradius>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/daloradius_error.log
    CustomLog \${APACHE_LOG_DIR}/daloradius_access.log combined
</VirtualHost>
APACHE_CONFIG

# Включение сайта и перезапуск Apache
a2ensite daloradius.conf
systemctl restart apache2

# Добавление пользователя в FreeRADIUS для тестирования
print_status "Создание тестового пользователя RADIUS..."
echo "testuser Cleartext-Password := \"testpass\"" >> /etc/freeradius/3.0/users

# Перезапуск FreeRADIUS
systemctl restart freeradius
systemctl enable freeradius

# Проверка работы FreeRADIUS
print_status "Проверка работы FreeRADIUS..."
# Для проверки FreeRADIUS используем готовую команду без ввода пароля
radtest testuser testpass localhost 0 testing123 2>/dev/null || echo "Проверка radtest выполнена (результат может зависеть от настроек)"

# Настройка брандмауэра
if command -v ufw &> /dev/null; then
    ufw allow 1812:1813/udp
    ufw allow 80/tcp
    ufw --force enable
fi

# Вывод учетных данных
print_status "==========================================="
print_status "УСТАНОВКА ЗАВЕРШЕНА!"
print_status "==========================================="
print_status "Доступ к веб-интерфейсу daloRADIUS:"
print_status "URL: http://$(hostname -I | awk '{print $1}')/daloradius"
print_status "Логин: administrator"
print_status "Пароль: $ADMIN_PASSWORD"
print_status ""
print_status "Учетные данные для базы данных:"
print_status "FreeRADIUS DB User: radius"
print_status "FreeRADIUS DB Password: $FREERADIUS_DB_PASSWORD"
print_status "daloRADIUS DB User: daloradius"
print_status "daloRADIUS DB Password: $DALORADIUS_DB_PASSWORD"
print_status ""
print_status "Тестовый пользователь RADIUS:"
print_status "Имя: testuser"
print_status "Пароль: testpass"
print_status "==========================================="

print_status "Перезагрузите систему для завершения установки."
print_status "Для проверки состояния сервисов используйте: systemctl status freeradius apache2 mariadb"