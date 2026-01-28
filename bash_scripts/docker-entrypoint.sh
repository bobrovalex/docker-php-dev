#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1-}" == apache2* ]] || [ "${1-}" = 'php-fpm' ] || { self="$(basename "$0")" && [ "$self" = 'docker-ensure-installed.sh' ]; }; then
    uid="$(id -u)"
    gid="$(id -g)"
    if [ "$uid" = '0' ]; then
        case "${1-}" in
            apache2*)
                user="${APACHE_RUN_USER:-www-data}"
                group="${APACHE_RUN_GROUP:-www-data}"

                # strip off any '#' symbol ('#1000' is valid syntax for Apache)
                pound='#'
                user="${user#$pound}"
                group="${group#$pound}"
                ;;
            *) # php-fpm
                user='www-data'
                group='www-data'
                ;;
        esac
    else
        user="$uid"
        group="$gid"
    fi

# for Ach linux users
    if [[ -n $APACHE_RUN_GROUP ]] && [[ -n $APACHE_RUN_USER ]]; then
        random_user=$(openssl rand -base64 80 | tr -dc 'a-z' | head -c 8)
        random_group=$(openssl rand -base64 80 | tr -dc 'a-z' | head -c 8)

        if getent group "${group}" > /dev/null 2>&1 && ! getent passwd "${user}" > /dev/null 2>&1; then
            useradd -u "${user}" -g "${group}" -m "${random_user}"
        elif ! getent group "${group}" > /dev/null 2>&1 && ! passwd group "${user}" > /dev/null 2>&1; then
            groupadd -g "${group}" "${random_group}"
            useradd -u "${user}" -g "${random_group}" -m "${random_user}"
        fi
    fi
# --------------------

    if [[ -n "${DOMAIN_NAME}" ]]; then
        make_structure ${DOMAIN_NAME}

        if [ "$uid" = '0' ]; then
            if [[ ! -e "/etc/ssl/private/${DOMAIN_NAME}.key" ]] || [[ ! -e "/etc/ssl/certs/${DOMAIN_NAME}.crt" ]]; then
                openssl req -x509  -nodes \
                    -days 365 \
                    -newkey rsa:2048 \
                    -keyout /etc/ssl/private/${DOMAIN_NAME}.key \
                    -out /etc/ssl/certs/${DOMAIN_NAME}.crt \
                    -subj "/C=RU/ST=YourState/L=YourCity/O=YourOrganization/OU=YourUnit/CN=localhost" &> /dev/null
            fi

            # create-certificate ${DOMAIN_NAME}

            createsite ${DOMAIN_NAME}
        fi
    fi

chown -R "${user}":"${group}" /var/www/*

fi

exec "$@"