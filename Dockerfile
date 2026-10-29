ARG WORDPRESS_VERSION=latest
ARG PHP_VERSION=8.4
ARG USER=www-data
ARG DNS_PROVIDERS="cloudflare route53 digitalocean godaddy namecheap googleclouddns easydns dnsmadeeasy"

# ---------- 1. Build the custom FrankenPHP binary ----------
FROM dunglas/frankenphp:builder-php$PHP_VERSION AS builder
ARG DNS_PROVIDERS

COPY --from=caddy:builder /usr/bin/xcaddy /usr/bin/xcaddy
COPY ./sidekick/middleware/cache ./cache

RUN set -eux; \
    dns_args=""; \
    for p in $DNS_PROVIDERS; do dns_args="$dns_args --with github.com/caddy-dns/$p"; done; \
    CGO_ENABLED=1 \
    XCADDY_GO_BUILD_FLAGS="-ldflags='-w -s' -tags=nobadger,nomysql,nopgx" \
    CGO_CFLAGS=$(php-config --includes) \
    CGO_LDFLAGS="$(php-config --ldflags) $(php-config --libs)" \
    xcaddy build \
      --output /usr/local/bin/frankenphp \
      --with github.com/dunglas/frankenphp=./ \
      --with github.com/dunglas/frankenphp/caddy=./caddy/ \
      --with github.com/dunglas/caddy-cbrotli \
      --with github.com/clutchlabsapp/frankenwplite/sidekick/middleware/cache=./cache \
      $dns_args; \
    # Set the port-80 capability HERE, so the final image doesn't store the binary twice
    command -v setcap || (apt-get update && apt-get install -y --no-install-recommends libcap2-bin); \
    setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp

# ---------- 2. Downloads (tools used here never reach the final image) ----------
FROM alpine:3 AS downloads
RUN apk add --no-cache curl unzip
WORKDIR /out
RUN set -eux; \
    curl -fsSL -o wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar; \
    chmod +x wp-cli.phar; \
    curl -fsSL -o sqlite.zip https://downloads.wordpress.org/plugin/sqlite-database-integration.zip; \
    unzip -q sqlite.zip -d mu-plugins; \
    rm sqlite.zip; \
    cp mu-plugins/sqlite-database-integration/db.copy db.php; \
    sed -i \
      -e 's#{SQLITE_IMPLEMENTATION_FOLDER_PATH}#/usr/src/wordpress/wp-content/mu-plugins/sqlite-database-integration#g' \
      -e 's#{SQLITE_PLUGIN}#WP_PLUGIN_DIR/SQLITE_MAIN_FILE#g' \
      db.php

# ---------- 3. Patch WordPress files before copying them ----------
FROM wordpress:$WORDPRESS_VERSION AS wp
RUN sed -i \
      -e 's/\[ "$1" = '\''php-fpm'\'' \]/\[\[ "$1" == frankenphp* \]\]/g' \
      -e 's/php-fpm/frankenphp/g' \
      /usr/local/bin/docker-entrypoint.sh && \
    sed -i 's/<?php/<?php if (!!getenv("FORCE_HTTPS")) { \$_SERVER["HTTPS"] = "on"; } define( "FS_METHOD", "direct" ); set_time_limit(300); /g' \
      /usr/src/wordpress/wp-config-docker.php

# ---------- 4. Final image ----------
FROM dunglas/frankenphp:php$PHP_VERSION AS base
ARG USER
ARG DEBUG

LABEL org.opencontainers.image.title=FrankenWPlite
LABEL org.opencontainers.image.description="Optimized WordPress containers to run everywhere. Built with FrankenPHP, SQLite & Caddy."
LABEL org.opencontainers.image.url=https://clutchlabs.app
LABEL org.opencontainers.image.source=https://github.com/clutchlabs/frankenwplite
LABEL org.opencontainers.image.licenses=MIT
LABEL org.opencontainers.image.vendor="Danny Summerlin"

ENV WP_DEBUG=${DEBUG:+1}
ENV FORCE_HTTPS=0
ENV PHP_INI_SCAN_DIR=$PHP_INI_DIR/conf.d

# No apt-get needed: the base already has curl + ca-certificates, and
# install-php-extensions pulls in (and cleans up) whatever it needs to compile.
# PDO SQLite is already built into the official PHP images.
RUN install-php-extensions \
    bcmath \
    exif \
    gd \
    intl \
    mysqli \
    zip \
    opcache

# All php.ini tweaks in one layer
RUN set -eux; \
    cp $PHP_INI_DIR/php.ini-production $PHP_INI_DIR/php.ini; \
    { \
    echo '[php]'; \
    echo 'upload_max_filesize = 512M'; \
    echo 'post_max_size = 512M'; \
    } > $PHP_INI_DIR/conf.d/wp.ini; \
    { \
    echo 'opcache.memory_consumption=128'; \
    echo 'opcache.interned_strings_buffer=8'; \
    echo 'opcache.max_accelerated_files=4000'; \
    echo 'opcache.revalidate_freq=2'; \
    } > $PHP_INI_DIR/conf.d/opcache-recommended.ini; \
    { \
    echo 'error_reporting = E_ERROR | E_WARNING | E_PARSE | E_CORE_ERROR | E_CORE_WARNING | E_COMPILE_ERROR | E_COMPILE_WARNING | E_RECOVERABLE_ERROR'; \
    echo 'display_errors = Off'; \
    echo 'display_startup_errors = Off'; \
    echo 'log_errors = On'; \
    echo 'error_log = /dev/stderr'; \
    echo 'log_errors_max_len = 1024'; \
    echo 'ignore_repeated_errors = On'; \
    echo 'ignore_repeated_source = Off'; \
    echo 'html_errors = Off'; \
    } > $PHP_INI_DIR/conf.d/error-logging.ini

# Copy files with the right owner up front (a later `chown -R` would duplicate them)
COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
COPY --from=wp /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d/
COPY --from=wp --chown=$USER:$USER /usr/local/bin/docker-entrypoint.sh /usr/local/bin/
COPY --from=wp --chown=$USER:$USER /usr/src/wordpress /usr/src/wordpress
COPY --chown=$USER:$USER wp-content/mu-plugins /usr/src/wordpress/wp-content/mu-plugins
COPY --from=downloads --chown=$USER:$USER /out/mu-plugins/ /usr/src/wordpress/wp-content/mu-plugins/
COPY --from=downloads --chown=$USER:$USER /out/db.php /usr/src/wordpress/wp-content/db.php
COPY --from=downloads /out/wp-cli.phar /usr/local/bin/wp
COPY Caddyfile /etc/caddy/Caddyfile

# Only small/empty folders are chowned here.
# The WordPress image's conf.d includes an imagick loader; remove it since Imagick isn't installed.
RUN rm -f /usr/local/etc/php/conf.d/docker-php-ext-imagick.ini && \
    mkdir -p /usr/src/wordpress/wp-content/cache && \
    chown -R $USER:$USER \
      /usr/src/wordpress/wp-content/cache \
      /data/caddy \
      /config/caddy \
      /var/www/html

WORKDIR /var/www/html
VOLUME /var/www/html/wp-content

USER $USER

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
