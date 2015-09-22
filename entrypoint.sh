#!/bin/bash

# removing the database cluster if it exists and prepping everything for postgresql operation
# be careful, Will Robinson!

set -e

# we need to be root for this
if [[ `whoami` != 'root' ]]; then
  echo "We need to be root for this, quitting"
  exit 1
fi

#
# make sure the directories exist and that we have access to them
#
# yes, this has already been done in the Dockerfile, but we might have those
# volume-mounted from somewhere
#

# TODO what if the user *wants* config and data to reside in a single directory?
# TODO make it all configurable via env-vars

mkdir -p /var/lib/postgresql/ /var/run/postgresql/ /etc/postgresql/ /tmp/pgstats
chown -R postgres:postgres /var/lib/postgresql/ /var/run/postgresql/ /tmp/pgstats
chmod -R 0700 /var/lib/postgresql/ 
chmod g+s /var/run/postgresql


# do we have the cluster data?
if [ -s /var/lib/postgresql/PG_VERSION ]; then
    echo "Cluster found!"
    
    if [ ! -z ${POSTGRES_PASSWORD+x} ]; then
        echo "...POSTGRESS_PASSWORD ignored, cluster exists"
    fi
    
    if [ ! -z ${POSTGRES_USER+x} ]; then
        echo "...POSTGRESS_USER ignored, cluster exists"
    fi
    
    if [ ! -z ${POSTGRES_DB+x} ]; then
        echo "...POSTGRESS_DB ignored, cluster exists"
    fi

    # do we have config?
    if [ ! -s /etc/postgresql/postgresql.conf ]; then
        echo "No config found... attempting to get config from the cluster"
        
        # no, we don't; let's try to get it from the cluster
        if pg_createcluster -l /var/log/postgresql/ -s /var/run/postgresql/ -d /var/lib/postgresql 9.4 main >/dev/null 2>&1; then
            echo "...success."
            # it worked! let's move the config in place
            mv /etc/postgresql/9.4/main/* /etc/postgresql/
            # and doing minor cleanup
            rmdir /etc/postgresql/9.4/main/
            rmdir /etc/postgresql/9.4/
            # set the settings
            sed -i -r\
                -e "s/^#?data_directory = 'ConfigDir'/data_directory = '\/var\/lib\/postgresql'/" \
                -e "s/^#?log_directory = 'pg_log'/log_directory = '\/var\/log\/postgresql'/" \
                -e "s/^#?unix_socket_directories = '\/tmp'/unix_socket_directories = '\/var\/run\/postgresql'/" \
                -e "s/^#?stats_temp_directory = '.+'/stats_temp_directory = '\/tmp\/pgstats'/" \
                /etc/postgresql/postgresql.conf
        else
            echo "...fail; auto-generating config from templates"
            # that's a bummer. we do have a cluster, but we do not have a valid config for it
            # if only there were some kind of templates we could use there...
            mv /usr/share/postgresql/9.4/{pg_hba,pg_ident,postgresql}.conf.sample /etc/postgresql
            rename 's/\.sample//' /etc/postgresql/*.sample
            
            # make sure pg_hba.conf is usable
            sed -i -r \
                -e 's/@authcomment@/# GENERATED BY docker-postgresql/' \
                -e 's/@remove-line-for-nolocal@//' \
                -e 's/@authmethodlocal@/trust/' \
                -e 's/@authmethodhost@/md5/' \
                -e 's/@default_username@/postgres/' \
                /etc/postgresql/pg_hba.conf
                
            # set the settings
            sed -i -r\
                -e "s/^#data_directory = 'ConfigDir'/data_directory = '\/var\/lib\/postgresql'/" \
                -e "s/^#log_directory = 'pg_log'/#log_directory = '\/var\/log\/postgresql'/" \
                -e "s/^#unix_socket_directories = '\/tmp'/#unix_socket_directories = '\/var\/run\/postgresql'/" \
                -e "s/^stats_temp_directory = '.+'/stats_temp_directory = '\/tmp\/pgstats'/" \
                /etc/postgresql/postgresql.conf
        fi
    fi

# no cluster, need to create one
else

    echo "No database cluster found, setting one up!"

    #
    # thank FSM for pg_createcluster!
    # https://www.cs.drexel.edu/cgi-bin/manServer.pl/usr/share/man/man8/pg_createcluster.8
    # 
    # this will create the cluster in the /var/lib/postgresql config files in
    # /etc/postgresql/9.4/main
    # 
    # if the cluster data exist in /var/lib/postgresql, along with conf files
    # therein, the conf files will be moved to /etc/postgresql/9.4/main/ and
    # appropriate config changes (data_directory) will be made to them
    # 
    # if the cluster exists but there are no conf files therein, pg_createcluster
    # will exit with an error
    pg_createcluster -l /var/log/postgresql/ -s /var/run/postgresql/ -d /var/lib/postgresql 9.4 main
    
    # do we have the config?
    if [ -s /etc/postgresql/postgresql.conf ]; then
        echo "Config found, no need to retain auto-generated one!"
        # we do, deleting the autogenerated config, then
        rm -rf /etc/postgresql/9.4
    else
        echo "Config not found, retaining the auto-generated one!"
        # we don't, moving the autogenerated config in place
        mv /etc/postgresql/9.4/main/* /etc/postgresql/
        # and doing minor cleanup
        rmdir /etc/postgresql/9.4/main/
        rmdir /etc/postgresql/9.4/
        # fixing some paths
        sed -i -r \
            -e "s/^hba_file = '.+'/#hba_file = 'pg_hba.conf'/" \
            -e "s/^ident_file = '.+'/#ident_file = 'pg_ident.conf'/" \
            -e "s/^#?stats_temp_directory = '.+'/stats_temp_directory = '\/tmp\/pgstats'/" \
            /etc/postgresql/postgresql.conf
    fi
    
    # just for setting thins up
    su -c "/usr/lib/postgresql/9.4/bin/pg_ctl -D '/etc/postgresql' -o \"-c listen_addresses=''\" -w start" postgres
    
    # user
    if [ -z ${POSTGRES_USER+x} ]; then
        echo "...POSTGRES_USER not set, using 'postgres'"
        POSTGRES_USER="postgres"
    fi
    export POSTGRES_USER
    
    # pw
    if [ -z ${POSTGRES_PASSWORD+x} ]; then
        POSTGRES_PASSWORD="$( dd status=none bs=1 count=16 if=/dev/random  | sha256sum | cut -d ' ' -f 1 )"
        echo "...POSTGRESS_PASSWORD not set, using '$POSTGRES_PASSWORD' (change immediately!)"
    fi
    
    # create/modify the user
    if [ "$POSTGRES_USER" = "postgres" ]; then
        su -c "psql --username postgres -c \"ALTER USER $POSTGRES_USER WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';\"" postgres
    else
        su -c "psql --username postgres -c \"CREATE USER $POSTGRES_USER WITH SUPERUSER PASSWORD '$POSTGRES_PASSWORD';\"" postgres
    fi
    
    # db -- set it up?
    if [ -z ${POSTGRES_DB+x} ] || [ "$POSTGRES_DB" = "postgres" ]; then
        echo "...no database will be set-up, remember to set one up before usage!"
    
    # actually, yes, set it up
    else
        export POSTGRES_DB
        echo "...POSTGRESS_DB set, setting up a database: '$POSTGRES_DB'"
        su -c "psql --username postgres -c \"CREATE DATABASE $POSTGRES_DB;\"" postgres
    fi
    
    su -c "/usr/lib/postgresql/9.4/bin/pg_ctl -D \"/etc/postgresql\" -m fast -w stop" postgres
fi

# run the configured CMD
exec su -p -c "env PATH=\"$PATH\" $*" postgres