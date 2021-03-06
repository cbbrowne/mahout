#!/bin/bash

set -u

# Let's set up a database and put some schema into it as a Base Schema
REGUSER=${REGUSER:-"postgres"}
SUPERUSER=${SUPERUSER:-"postgres"}
PGCMPHOME=${PGCMPHOME:-${HOME}/PostgreSQL/pgcmp}
PGPORT=${PGPORT:-7099}
PGHOST=${PGHOST:-localhost}
DBCLUSTER=${DBCLUSTER:-"postgresql://${REGUSER}@${PGHOST}:${PGPORT}"}
SUPERCLUSTER=${SUPERCLUSTER:-"postgresql://${SUPERUSER}@${PGHOST}:${PGPORT}"}
MAHOUTHOME=${MAHOUTHOME:-${HOME}/PostgreSQL/mahout}
TARGETDIR=${TARGETDIR:-"install-target"}
MAHOUTLOGDIR=${MAHOUTLOG:-"/tmp/mahout-tests"}
PGBINDIR=${PGBINDIR:-"/var/lib/postgresql/dbs/postgresql-HEAD/bin"}

PROJECTNAME=mhtest
TARGETMHDIR=install-target/${PROJECTNAME}
MAHOUT=${MAHOUTHOME}/mahout

if [ -d ${MAHOUTLOGDIR} ]; then
    MAHOUTLOG=${MAHOUTLOGDIR}/mahout.log
else
    mkdir -p ${MAHOUTLOGDIR}
    MAHOUTLOG=${MAHOUTLOGDIR}/mahout.log
    echo "initialize mahout.log" > ${MAHOUTLOG}
fi

if [ -d ${PROJECTNAME} ]; then
    echo "Project directory ${PROJECTNAME} already there"
else
    mkdir -p ${PROJECTNAME}
fi

clusterdb=${DBCLUSTER}/postgres
devdb=devdb
devuri=${DBCLUSTER}/${devdb}
comparisondb=comparisondb
compuri=${DBCLUSTER}/${comparisondb}
installdb=installdb
installuri=${DBCLUSTER}/${installdb}
proddb=proddb
produri=${DBCLUSTER}/${proddb}
tempdevcopy=tempdevdb

NOTICES=0
WARNINGS=0
PROBLEMS=0
CONFIG=0

function glog () {
    local level=$1
    local notice=$2 
    local ccode
    local creset
    creset='\e[0m'
    logger -i -p "${level}" -t "test-build-stuff.sh" "${notice}"
    case ${level} in
	user.info)
	    ccode='\e[37m'
	    CONFIG=$((${CONFIG} + 1))
	    ;;
	user.notice)
	    ccode='\e[32m'
	    NOTICES=$((${NOTICES} + 1))
	    ;;
	user.warning)
	    ccode='\e[33m'
	    WARNINGS=$((${WARNINGS} + 1))
	    ;;
	user.error)
	    ccode='\e[31m'
	    PROBLEMS=$((${PROBLEMS} + 1))
	    ;;
    esac	    
    case ${level} in
	user.debug)
	    DEBUGS=$((${DEBUGS} + 1))
  	    ;;
	*)
	    echo -e "${ccode}${level} test-build-stuff.sh ${notice}${creset}"
	    ;;
    esac
    if [ -f ${MAHOUTLOG} ]; then
	when=$(date --rfc-3339=seconds)
	echo "${when} ${level} mahout ${notice}" >> ${MAHOUTLOG}
    fi
}

function drop_and_recreate_databases () {
    # Drop databases and then create them
    for i in ${devdb} ${comparisondb} ${installdb} ${proddb}; do
	glog user.info "Drop and recreate database ${i} on cluster ${clusterdb}"
	psql -d ${clusterdb} \
	     -c "drop database if exists ${i};"
	psql -d ${clusterdb} \
             -c "create database ${i};"
    done
}

function initialize_schema () {
    glog user.notice "Set up a simple schema in database $devdb"

    psql -d ${devuri} -c "
  create table if not exists t1 (id serial primary key, name text not null unique, created_on timestamptz default now());
  create schema if not exists subschema;
  create table if not exists subschema.t2 (id serial primary key, name text not null unique, created_on timestamptz default now());
"

}

function purge_mahout_and_check_reqts () {
    glog user.notice "Purge away ./${PROJECTNAME}"
    if [ -d ./${PROJECTNAME} ]; then
	rm -rf ./${PROJECTNAME}
    else
	if [ -e ./${PROJECTNAME} ]; then
	    glog user.error "projectname directory [./${PROJECTNAME}] exists and is not a directory"
	    exit 2
	fi
    fi

    glog user.notice "Check availability of pgcmp"
    if [ -d ${PGCMPHOME} ]; then
	if [ -x ${PGCMPHOME}/pgcmp ]; then
	    glog user.notice "Ready to run pgcmp as ${PGCMPHOME}/pgcmp"
	else
	    glog user.error "pgcmp not executable as ${PGCMPHOME}/pgcmp"
	    exit 1
	fi
    else
	glog user.error "No such directory: ${PGCMPHOME}"
	exit 1
    fi

    glog user.notice "Check availability of mahout"
    if [ -d ${MAHOUTHOME} ]; then
	if [ -x ${MAHOUTHOME}/mahout ]; then
	    glog user.notice "Ready to run mahout as ${MAHOUTHOME}/mahout"
	else
	    glog user.error "mahout not executable as ${MAHOUTHOME}/mahout"
	    exit 1
	fi
    else
	glog user.error "No such directory: ${MAHOUTHOME}"
	exit 1
    fi

}

function mahout_init () {
    glog user.notice "Do mahout init to capture that base schema"

    MAHOUTSEARCHPATH=public MAHOUTSCHEMA=MaHoutSchema PGCMPHOME=${PGCMPHOME} MAINDATABASE=${devuri} SUPERUSERACCESS=${SUPERCLUSTER}/${devdb} COMPARISONDATABASE=${compuri} ${MAHOUT} init ${PROJECTNAME}

    echo "MAHOUTOMITPG=true" >> ${PROJECTNAME}/mahout.conf
}

function empty_capture () {
    glog user.notice "Do mahout capture without introducing any changes; expect no change"
    # Run mahout capture, without any change
    (
	cd ${PROJECTNAME}
	${MAHOUT} validate_control
	${MAHOUT} capture
    )
}

function common_tests () {
    glog user.notice "Add a common tests section"
    mkdir ${PROJECTNAME}/common-tests
    echo "

common tests
" >> ${PROJECTNAME}/mahout.control

    echo "select 1;" > ${PROJECTNAME}/common-tests/null-test.sql
    echo "  psqltest from 1.1 to 1.3 common-tests/null-test.sql" >> ${PROJECTNAME}/mahout.control

    echo "  psqltest from Base common-tests/pk-test.sql" >> ${PROJECTNAME}/mahout.control
    echo "
do \$\$
declare
   prec record;
   c_found boolean;
begin
   c_found := 'f';
   for prec in select nspname, relname from pg_class c, pg_namespace n where n.oid = c.relnamespace and (nspname not like 'pg_%' and nspname not in ('information_schema')) and not relhaspkey and relkind = 'r' loop
	raise warning 'table without primary key: "%"."%"', prec.nspname, prec.relname;
	c_found := 't';
  end loop;
  if c_found then
	raise exception 'Tables without primary keys found!';
  end if;
end
\$\$ language plpgsql;
" > ${PROJECTNAME}/common-tests/pk-test.sql

    echo "  psqltest common-tests/multiply-defined.sql" >> ${PROJECTNAME}/mahout.control
    echo "
do \$\$
declare
  c_found boolean;
  prec record;
  c_nsp text;
  c_table text;
  c_relname text;
begin
  c_found := 'f';

  for prec in select table_name, count(1) as count from information_schema.tables where table_schema not in ('pg_catalog', 'information_schema') group by table_name having count(1) > 1 loop
	c_found := 't';
	raise warning 'relation % found % times', prec.table_name, prec.count;
  end loop;

  if c_found then
	raise exception 'Relations found where the same table/view name was used multiple times!';
  end if;
end
\$\$ language plpgsql;

" > ${PROJECTNAME}/common-tests/multiply-defined.sql
}

function mahout_capture_target () {
    glog user.notice "Set up filesystem to use the captured mahout config for a fresh install"
    # Set up target directory for sample installation
    rm -rf ${TARGETDIR}
    mkdir ${TARGETDIR}
    cp -r ${PROJECTNAME} ${TARGETDIR}
}

function fix_install_uri () {
# Drop alternate configuration into installation Mahout config
    glog user.info "fix up install instance to use ${installuri} rather than the URI provided in the build"
    egrep -v MAINDATABASE ${TARGETMHDIR}/mahout.conf | \
    egrep -v SUPERUSERACCESS ${TARGETMHDIR}/mahout.conf \
	> ${TARGETMHDIR}/mahout.conf.keep
    echo "
MAINDATABASE=${installuri}
SUPERUSERACCESS=${SUPERCLUSTER}/${installdb}

" >> ${TARGETMHDIR}/mahout.conf.keep
    cp ${TARGETMHDIR}/mahout.conf.keep ${TARGETMHDIR}/mahout.conf
}

function basic_schema_install () {
    glog user.notice "Install basic schema using mahout"
    (cd ${TARGETMHDIR}; ${MAHOUT} install)
}

function prepare_11_upgrade () {
    glog user.notice "Prepare upgrade for v1.1"
    # Create a couple of upgrades
    echo "

version 1.1
requires Base
ddl 1.1/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir ${PROJECTNAME}/1.1
    echo "
   alter table t1 add column deleted_on timestamptz;
" > ${PROJECTNAME}/1.1/stuff.sql

    glog user.notice "mahout capture on v1.1"
    (
	cd ${PROJECTNAME}
	${MAHOUT} validate_control
	${MAHOUT} capture
	${MAHOUT} build ${PROJECTNAME}-v1.1 tar.gz
    )
}

function upgrade_install_to_11 () {
    glog user.notice "do upgrade of the install instance to run v1.1"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    # And try to install the upgrade
    (cd ${TARGETMHDIR}; ${MAHOUT} upgrade)
}

function prepare_12_upgrade () {
    echo "

version 1.2
requires 1.1
ddl 1.2/stuff.sql

" >> ${PROJECTNAME}/mahout.control
    mkdir ${PROJECTNAME}/1.2
    echo "
   create table t3 (
     id serial primary key,
     name text not null unique,
     created_on timestamptz not null default now());

" > ${PROJECTNAME}/1.2/stuff.sql

    glog user.notice "Run mahout capture to put that into the build"

    glog user.notice "mahout capture on v1.2"
    (
	cd ${PROJECTNAME}
	${MAHOUT} validate_control
	${MAHOUT} capture
	${MAHOUT} build ${PROJECTNAME}-v1.2 tar.gz
    )
}

function apply_12_to_target () {
    glog user.notice "do upgrade of the install instance to run v1.2"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}; ${MAHOUT} upgrade)
    keep_copy_of_devdb
}

function keep_copy_of_devdb () {
    glog  user.notice "Keeping copy of devdb [${devdb}] in [${tempdevcopy}]"
    dropdb --if-exists -U $SUPERUSER -p ${PGPORT} -h ${PGHOST} ${tempdevcopy}
    createdb -p ${PGPORT} -U $SUPERUSER  -h ${PGHOST}  -T ${devdb} ${tempdevcopy}
}
function recover_devdb_from_copy () {
    glog user.notice "Recovering devdb [${devdb}] from [${tempdevcopy}]"
    dropdb -p ${PGPORT}  -h ${PGHOST}  -U $SUPERUSER ${devdb}
    createdb -p ${PGPORT}  -h ${PGHOST} -U $SUPERUSER  -T ${tempdevcopy} ${devdb} 
    glog user.notice "Recovered devdb [${devdb}] from [${tempdevcopy}]"
}

function prepare_bad_13_upgrade () {
    echo "

version 1.3
requires 1.2
ddl 1.3/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir ${PROJECTNAME}/1.3

    echo "
   alter table t3 add column deleted_on timestamptz;
   create index t3_deleted on t3(deleted_on) where (deleted_on is not null);

   create table primary_keyless (id serial);

" > ${PROJECTNAME}/1.3/stuff.sql

    glog user.notice "mahout capture on v1.3 - expecting error"
    pushd ${PROJECTNAME}
    ${MAHOUT} validate_control
    ${MAHOUT} capture
    rc=$?
    if [ $rc -eq 0 ]; then
	glog user.error "capture succeeded, it should have failed"
    else
	glog user.notice "capture of busted v1.3 failed as expected"
    fi
    popd
}

function repair_13 () {
    # Get the 12 database back
    recover_devdb_from_copy
    # Now, repair the table definitions, which was the problem
    echo "
   alter table t3 add column deleted_on timestamptz;
   create index t3_deleted on t3(deleted_on) where (deleted_on is not null);
" > ${PROJECTNAME}/1.3/stuff.sql

    # Expect the build to go well
    (
	cd ${PROJECTNAME}
	${MAHOUT} validate_control
	${MAHOUT} capture
	${MAHOUT} build ${PROJECTNAME}-v1.3 tar.gz
    )
}

function prepare_14_broken () {
    # Preparing for expected failure
    cp ${PROJECTNAME}/mahout.control ${PROJECTNAME}/mahout.control-keep
    keep_copy_of_devdb
    
    echo "

version 1.4
requires 1.3
ddl 1.4/stuff.sql
psqltest common-tests/failing-test.sql

" >> ${PROJECTNAME}/mahout.control

    echo "
select 1/0;
" > ${PROJECTNAME}/common-tests/failing-test.sql

    mkdir ${PROJECTNAME}/1.4

    echo "
   alter table t3 drop column deleted_on;
   alter table t3 add column updated_on timestamptz default now();
" > ${PROJECTNAME}/1.4/stuff.sql

    glog user.notice "Attempt capture on bad v1.4, this is expected to fail"

    (   # all in a common subprocess
	cd ${PROJECTNAME}
	${MAHOUT} validate_control
	${MAHOUT} capture
	rc=$?
	if [ $rc -eq 0 ]; then
	    glog user.error "capture succeeded, it should have failed"
	    exit 1
	fi
    )
}

function repair_14 () {
    # Now, redo version 1.4, without the failing bits
    mv ${PROJECTNAME}/mahout.control-keep ${PROJECTNAME}/mahout.control 
    recover_devdb_from_copy
    
    rm -f common-tests/failing-test.sql
    echo "

version 1.4
requires 1.3
ddl 1.4/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    (cd ${PROJECTNAME}
     ${MAHOUT} validate_control
     ${MAHOUT} capture
    )
}

function upgrade_install_1314 () {
    glog user.notice "do upgrade of the install instance to run v1.3, v1.4"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}; ${MAHOUT} upgrade)

    glog user.notice "Completed upgrade to v1.4"
}

function attach_to_mahout () {
    ### Create a database and use "mahout attach" to attach a database to
    ### it

    psql -d ${clusterdb} \
	 -c "drop database if exists ${proddb};"
    psql -d ${clusterdb} \
	 -c "create database ${proddb} template ${devdb};"

    # It's a clone of the dev schema, so we need to drop the MAHOUT schema
    psql -d ${produri} \
	 -c "drop schema \"MaHoutSchema\" cascade;"

    # modify control file to indicate the production DB
    cp ${TARGETMHDIR}/mahout.conf ${TARGETMHDIR}/mahout.conf-production
    echo "
MAINDATABASE=${DBCLUSTER}/${proddb}
SUPERUSERACCESS=${SUPERCLUSTER}/${proddb}

" >> ${TARGETMHDIR}/mahout.conf-production
    (cd ${TARGETMHDIR}; 
     MAHOUTCONFIG=mahout.conf-production ${MAHOUT} attach 1.4)
}

function mix_ddl_dml_badly () {
    cp ${PROJECTNAME}/mahout.control ${PROJECTNAME}/mahout.control-keep

    mkdir -p ${PROJECTNAME}/badmix
    echo "-- DDL noop
create table mix_ddl_dml (id serial primary key, data text not null unique);" > $PROJECTNAME/badmix/ddl-for-mix.sql
    echo "-- DML also
insert into mix_ddl_dml (data) values ('a'), ('b'), ('c');" > $PROJECTNAME/badmix/dml-for-mix.sql
    
    echo "

version busteddmlddl
requires 1.4
  ddl badmix/ddl-for-mix.sql
  dml badmix/dml-for-mix.sql
" >> $PROJECTNAME/mahout.control
    
    glog user.notice "mahout capture on vbusteddmlddl - expecting error"
    pushd ${PROJECTNAME}
    ${MAHOUT} validate_control
    rc=$?
    if [ $rc -eq 0 ]; then
	glog user.error "capture succeeded, it should have failed"
	exit 1
    else
	glog user.notice "capture of busteddmlddl failed as expected"
    fi
    popd
}

function cleanup_after_dmlddl () {
    # Now, restore control...
    rm -f $PROJECTNAME/badmix/dml-for-mix.sql $PROJECTNAME/badmix/ddl-for-mix.sql
    rmdir $PROJECTNAME/badmix
    mv ${PROJECTNAME}/mahout.control-keep $PROJECTNAME/mahout.control
}

function ddl_and_dml_in_proper_harmony () {
    glog user.notice "Upgrade that combines DDL and DML properly"
    mkdir ${PROJECTNAME}/v1.5ddl
    mkdir ${PROJECTNAME}/v1.5dml
    mkdir -p ${PROJECTNAME}/unix    
    echo "-- DDL noop
create table mix_ddl_dml (id serial primary key, data text not null unique);" > $PROJECTNAME/v1.5ddl/ddl-for-mix.sql
    echo "-- DML also
insert into mix_ddl_dml (data) values ('a'), ('b'), ('c');" > $PROJECTNAME/v1.5dml/dml-for-mix.sql
    echo "\!/bin/bash
local parms=\$1
source \$parms
for i in d e f; do
   \${PGBINDIR}/psql -d \${MAINDATABASE} -c \"insert into mix_ddl_unix(data) values ('\${i}')\"
done
" > $PROJECTNAME/unix/script
    chmod a+x $PROJECTNAME/unix/script
    
    echo "

version v1.5ddl
requires 1.4
  ddl v1.5ddl/ddl-for-mix.sql

version v1.5dml
requires v1.5ddl
  dml v1.5dml/dml-for-mix.sql

version v1.5unix
requires v1.5dml
  unix unix/script mahout.conf

" >> $PROJECTNAME/mahout.control
    
    glog user.notice "mahout capture of versions for DDL and DML"
    pushd ${PROJECTNAME}
    ${MAHOUT} capture
    popd

}

function mess_with_production () {
    glog user.notice "Now, muss with the production schema, and see that mahout diff notices this"
    psql -d ${DBCLUSTER}/${proddb} -c "create table extra_table (id serial primary key, description text not null unique);" 
    (cd ${TARGETMHDIR};
     MAHOUTCONFIG=mahout.conf-production ${MAHOUT} diff)
    if [ $? -eq 0 ]; then
	glog user.notice "Problem: mahout diff did not notice induced changes"
    else
	glog user.error "Found differences, as expected"
    fi
}

function mix_ddl_unix_badly () {
    cp ${PROJECTNAME}/mahout.control ${PROJECTNAME}/mahout.control-keep
    mkdir -p ${PROJECTNAME}/badmix
    mkdir -p ${PROJECTNAME}/unix    
    echo "-- DDL noop
create table mix_ddl_unix (id serial primary key, data text not null unique);" > $PROJECTNAME/badmix/ddl-for-mix.sql
    echo "\!/bin/bash
local parms=\$1
source \$parms
for i in d e f; do
   \${PGBINDIR}/psql -d \${MAINDATABASE} -c \"insert into mix_ddl_unix(data) values ('\${i}')\"
done
" > $PROJECTNAME/unix/script
    chmod a+x $PROJECTNAME/unix/script
    echo "

version busteddmlddl
requires 1.4
  ddl badmix/ddl-for-mix.sql
  unix unix/script mahout.conf
" >> $PROJECTNAME/mahout.control
    
    glog user.notice "mahout capture on vbusteddmlddl - expecting error"
    pushd ${PROJECTNAME}
    ${MAHOUT} validate_control
    rc=$?
    if [ $rc -eq 0 ]; then
	glog user.error "capture succeeded, it should have failed"
	exit 1
    else
	glog user.notice "capture of busteddmlddl failed as expected"
    fi
    popd
}

function cleanup_after_ddlunix () {
    # Now, restore control...
    rm -f $PROJECTNAME/badmix/ddl-for-mix.sql
    rmdir $PROJECTNAME/badmix
    mv ${PROJECTNAME}/mahout.control-keep $PROJECTNAME/mahout.control
}

drop_and_recreate_databases
initialize_schema
purge_mahout_and_check_reqts
mahout_init
empty_capture
common_tests
mahout_capture_target
fix_install_uri
basic_schema_install
prepare_11_upgrade
upgrade_install_to_11
prepare_12_upgrade
apply_12_to_target
prepare_bad_13_upgrade
repair_13
prepare_14_broken
repair_14
#mix_ddl_dml_badly
#cleanup_after_dmlddl
ddl_and_dml_in_proper_harmony
mix_ddl_unix_badly

#cleanup_after_ddlunix
#upgrade_install_1314
#attach_to_mahout
#mess_with_production

