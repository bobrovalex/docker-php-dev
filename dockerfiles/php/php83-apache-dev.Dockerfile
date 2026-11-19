FROM php:8.3-apache

# persistent dependencies
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
# Ghostscript is required for rendering PDF previews
        ghostscript \
# pull in AV1 & HEVC image encoding (and not just decoding)
# https://github.com/docker-library/wordpress/issues/996
        libheif-plugin-aomenc \
        libheif-plugin-x265 \
    ; \
    rm -rf /var/lib/apt/lists/*

# install the PHP extensions we need (https://make.wordpress.org/hosting/handbook/handbook/server-environment/#php-extensions)
RUN set -ex; \
    \
    savedAptMark="$(apt-mark showmanual)"; \
    \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ssl-cert \
        libavif-dev \
        libfreetype6-dev \
        libicu-dev \
        libjpeg-dev \
        libmagickwand-dev \
        libpng-dev \
        libwebp-dev \
        libzip-dev \
    ; \
    \
    docker-php-ext-configure gd \
        --with-avif \
        --with-freetype \
        --with-jpeg \
        --with-webp \
    ; \
    docker-php-ext-install -j "$(nproc)" \
        bcmath \
        exif \
        gd \
        intl \
        mysqli \
        pdo_mysql \
        zip \
    ; \
# https://pecl.php.net/package/imagick
    pecl install imagick-3.8.1; \
# https://pecl.php.net/package/xdebug
    pecl install xdebug; \
    docker-php-ext-enable imagick; \
    docker-php-ext-enable xdebug; \
    rm -r /tmp/pear; \
    \
# some misbehaving extensions end up outputting to stdout 🙈 (https://github.com/docker-library/wordpress/issues/669#issuecomment-993945967)
    out="$(php -r 'exit(0);')"; \
    [ -z "$out" ]; \
    err="$(php -r 'exit(0);' 3>&1 1>&2 2>&3)"; \
    [ -z "$err" ]; \
    \
    extDir="$(php -r 'echo ini_get("extension_dir");')"; \
    [ -d "$extDir" ]; \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
    apt-mark auto '.*' > /dev/null; \
    apt-mark manual $savedAptMark; \
    ldd "$extDir"/*.so \
        | awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
        | sort -u \
        | xargs -r dpkg-query --search \
        | cut -d: -f1 \
        | sort -u \
        | xargs -rt apt-mark manual; \
    \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    rm -rf /var/lib/apt/lists/*; \
    \
    ! { ldd "$extDir"/*.so | grep 'not found'; }; \
# check for output like "PHP Warning:  PHP Startup: Unable to load dynamic library 'foo' (tried: ...)
    err="$(php --version 3>&1 1>&2 2>&3)"; \
    [ -z "$err" ]

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
# enabled by default in the php images: https://github.com/docker-library/php/pull/1587
RUN set -eux; \
    { \
        echo 'opcache.memory_consumption=128'; \
        echo 'opcache.interned_strings_buffer=8'; \
        echo 'opcache.max_accelerated_files=4000'; \
        echo 'opcache.revalidate_freq=2'; \
    } > "$PHP_INI_DIR/conf.d/opcache-recommended.ini"
# https://wordpress.org/support/article/editing-wp-config-php/#configure-error-logging
RUN set -eux; \
    { \
# https://www.php.net/manual/en/errorfunc.constants.php
# https://github.com/docker-library/wordpress/issues/420#issuecomment-517839670
        echo 'error_reporting = E_ALL'; \
        echo 'display_errors = On'; \
        echo 'display_startup_errors = Off'; \
        echo 'log_errors = On'; \
        echo 'error_log = /dev/stderr'; \
        echo 'log_errors_max_len = 1024'; \
        echo 'ignore_repeated_errors = Off'; \
        echo 'ignore_repeated_source = Off'; \
        echo 'report_memleaks = On'; \
        echo ';html_errors = Off'; \
    } > "$PHP_INI_DIR/conf.d/error-logging.ini"

# Configure Xdebug (optional but recommended)
RUN set -eux; \
    { \
        echo 'xdebug.mode = debug,develop'; \
        echo 'xdebug.discover_client_host = yes'; \
        echo 'xdebug.client_host = host.docker.internal'; \
        echo 'xdebug.client_port = 9003'; \
        echo 'xdebug.start_with_request = yes'; \
        echo 'xdebug.idekey = VSCODE'; \
        echo 'xdebug.max_nesting_level = 512'; \
    } >> "$PHP_INI_DIR/conf.d/docker-php-ext-xdebug.ini"

RUN set -eux; \
    a2enmod rewrite expires ssl; \
    \
# https://httpd.apache.org/docs/2.4/mod/mod_remoteip.html
    a2enmod remoteip; \
    { \
        echo 'RemoteIPHeader X-Forwarded-For'; \
# these IP ranges are reserved for "private" use and should thus *usually* be safe inside Docker
        echo 'RemoteIPInternalProxy 10.0.0.0/8'; \
        echo 'RemoteIPInternalProxy 172.16.0.0/12'; \
        echo 'RemoteIPInternalProxy 192.168.0.0/16'; \
        echo 'RemoteIPInternalProxy 169.254.0.0/16'; \
        echo 'RemoteIPInternalProxy 127.0.0.0/8'; \
    } > /etc/apache2/conf-available/remoteip.conf; \
    a2enconf remoteip; \
# https://github.com/docker-library/wordpress/issues/383#issuecomment-507886512
# (replace all instances of "%h" with "%a" in LogFormat)
    find /etc/apache2 -type f -name '*.conf' -exec sed -ri 's/([[:space:]]*LogFormat[[:space:]]+"[^"]*)%h([^"]*")/\1%a\2/g' '{}' +

RUN set -eux; \
    ls /etc/apache2/sites-enabled/ \
    | xargs -I {} a2dissite {} \
    && service apache2 restart
   
COPY --chmod=744 ./bash_scripts/createsite /usr/local/bin/
COPY --chmod=744 ./bash_scripts/make_structure /usr/local/bin/
COPY --from=composer/composer:latest /usr/bin/composer /usr/bin/composer

COPY --chmod=744  ./bash_scripts/docker-entrypoint.sh /usr/local/bin/
# https://github.com/docker-library/wordpress/issues/969
RUN ln -svfT docker-entrypoint.sh /usr/local/bin/docker-ensure-installed.sh

# Expose port 443
EXPOSE 443

ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["apache2-foreground"]