FROM mariadb:10.11

COPY --chmod=744 ./bash_scripts/db_dump /usr/local/bin/
