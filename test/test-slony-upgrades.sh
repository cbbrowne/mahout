#!/bin/bash
set -e -u

# Let's set up a database and put some schema into it as a Base Schema
PGCMPHOME=${PGCMPHOME:-${HOME}/PostgreSQL/pgcmp}
DBCLUSTER=${DBCLUSTER:-"postgresql://postgres@localhost:7099"}
MAHOUTHOME=${MAHOUTHOME:-${HOME}/PostgreSQL/mahout}
TARGETDIR=${TARGETDIR:-"install-target"}
MAHOUTLOGDIR=${MAHOUTLOG:-"/tmp/mahout-tests"}
PGBINDIR=${PGBINDIR:-"/var/lib/postgresql/dbs/postgresql-HEAD/bin"}

PROJECTNAME=mhslonytest
TARGETMHDIR=install-target/${PROJECTNAME}
MAHOUT=${MAHOUTHOME}/mahout
SLONYCLUSTER=mhslonytest
SLONYMAINSET=10
SLONYTEMPSET=3141
SLONYOMITTABLES='()'
SLONYOMITSEQUENCES='()'
SUPERUSER=${SUPERUSER:-"postgres"}
SUPERCLUSTER=${SUPERCLUSTER:-"postgresql://${SUPERUSER}@localhost:7099"}

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
    logger -i -p "${level}" -t "test-slony-upgrades.sh" "${notice}"
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
	    echo -e "${ccode}${level} test-slony-upgrades.sh ${notice}${creset}"
	    ;;
    esac
    if [ -f ${MAHOUTLOG} ]; then
	when=`date --rfc-3339=seconds`
	echo "${when} ${level} mahout ${notice}" >> ${MAHOUTLOG}
    fi
}



kill_all_slons ()
{
    glog user.notice "Killing any extant slons based on PID files kept around"
    if [ -d ${slonydir}/pid ]; then
	for pidfile in ${slonydir}/pid/node[1-6].pid; do
	    if [ -f $pidfile ]; then
		pid=`cat $pidfile`
		glog user.notice "Shutting down slon based on $pidfile - $pid"
	    fi
	done
    fi
}

slonydir=$TARGETMHDIR/.slony
mkdir -p ${slonydir}/pid

function drop_and_recreate_databases () {
    # Drop databases and then create them
    for node in origin rep2 rep3 rep4 rep5 rep6; do
	glog user.info "Drop and recreate database ${node} on cluster ${clusterdb}"
	psql -d ${clusterdb} \
	     -c "drop database if exists ${node};"
	psql -d ${clusterdb} \
             -c "create database ${node};"
	# Create a wee table as an initialization point
	# So Slony as something to replicate from the very beginning
	psql -d ${DBCLUSTER}/${node} \
	     -c "create schema nullschema; create table nullschema.wee_table(id serial primary key, data text);"
    done
}

function set_up_preamble () {
    slonikpreamble=${slonydir}/preamble.slonik
    echo "
cluster name=${SLONYCLUSTER};
" > $slonikpreamble

    for nodeinfo in origin:1 rep2:2 rep3:3 rep4:4: rep5:5 rep6:6; do
	nodenum=`echo $nodeinfo | cut -d : -f 2` 
	nodedb=`echo $nodeinfo | cut -d : -f 1`
	conffile=${slonydir}/slon.conf.${nodenum}
	glog user.info "Set up slon.conf for node $nodenum - ${conffile}"
	echo "### Slony conf for node ${nodenum}
pid_file='${slonydir}/pid/node${nodenum}.pid'
cluster_name='${SLONYCLUSTER}'
conn_info='${DBCLUSTER}/${nodedb}'
syslog=2
syslog_facility=LOCAL0
syslog_ident=slon
" > ${conffile}
	echo "node $nodenum admin conninfo = '${DBCLUSTER}/${nodedb}';" >> $slonikpreamble
    done
}

function initialize_slony_nodes () {
    # Set up the 6 nodes as a Slony cluster
    initnodes=${slonydir}/init.slonik
    #  Initialize each node
    echo "# Initialize nodes
include <${slonikpreamble}>;
init cluster (id=1, comment='Mahout test node origin');
store node (id=2, comment='Node for mahout test', event node=1);
store node (id=3, comment='Node for mahout test', event node=1);
store node (id=4, comment='Node for mahout test', event node=1);
store node (id=5, comment='Node for mahout test', event node=1);
store node (id=6, comment='Node for mahout test', event node=1);
" > $initnodes

    glog user.notice "Initialize Slony cluster, including creating nodes"
    $PGBINDIR/slonik $initnodes
}

function store_paths () {
    #  Store paths
    storepaths=${slonydir}/storepaths.slonik
    echo "# Initialize nodes
include <${slonikpreamble}>;
" > $storepaths
    for nodeinfo in origin:1 rep2:2 rep3:3 rep4:4: rep5:5 rep6:6; do
	nodenum=`echo $nodeinfo | cut -d : -f 2` 
	nodedb=`echo $nodeinfo | cut -d : -f 1` 
	for nodeinfo2 in origin:1 rep2:2 rep3:3 rep4:4: rep5:5 rep6:6; do
	    nodenum2=`echo $nodeinfo2 | cut -d : -f 2` 
	    nodedb2=`echo $nodeinfo2 | cut -d : -f 1` 
	    if [ $nodenum -ne $nodenum2 ]; then
		echo "store path (server=$nodenum2, client=$nodenum, conninfo='${DBCLUSTER}/${nodedb2}');" >> $storepaths
	    else
		echo "Omit self-talk - $nodenum $nodenum2"
	    fi
	done
    done

    glog user.notice "Store connection paths for Slony"
    $PGBINDIR/slonik $storepaths
}

function launch_slons () {
    # Launch slons
    for i in 1 2 3 4 5 6; do
	glog user.notice "Launch slon daemon for node $i"
	$PGBINDIR/slon -f ${slonydir}/slon.conf.${i} &
    done
}

function subscribe_initial_set () {
    # Subscribe set for set 1, with the one table, nullschema.wee_table
    initset=$slonydir/initset.slonik
    echo "# Initialize nodes
include <${slonikpreamble}>;
create set (id=${SLONYMAINSET}, origin=1, comment='${SLONYCLUSTER} Tables and Sequences');
set add table (id=0, set id=${SLONYMAINSET}, origin=1, fully qualified name='nullschema.wee_table', comment='basic table');
subscribe set (id=${SLONYMAINSET}, provider=1, receiver=2, forward=yes);
wait for event (origin=all, confirmed=all, wait on=1);
subscribe set (id=${SLONYMAINSET}, provider=1, receiver=3, forward=yes);
wait for event (origin=all, confirmed=all, wait on=1);
subscribe set (id=${SLONYMAINSET}, provider=3, receiver=4, forward=yes);
wait for event (origin=all, confirmed=all, wait on=1);
subscribe set (id=${SLONYMAINSET}, provider=4, receiver=5, forward=yes);
wait for event (origin=all, confirmed=all, wait on=1);
subscribe set (id=${SLONYMAINSET}, provider=4, receiver=6, forward=yes);
wait for event (origin=all, confirmed=all, wait on=1);
" > $initset

    glog user.notice "Subscribe all nodes to simple set"
    $PGBINDIR/slonik $initset
}

function initial_mahout_schema () {
    # Set up a schema in devdb, and use mahout to extract buildable schemas
    devdb=devdb
    devuri=${DBCLUSTER}/${devdb}
    comparisondb=comparisondb
    compuri=${DBCLUSTER}/${comparisondb}

    for i in ${devdb} ${comparisondb}; do
	glog user.info "Drop and recreate database ${i} on cluster ${clusterdb}"
	psql -d ${clusterdb} \
	     -c "drop database if exists ${i};"
	psql -d ${clusterdb} \
             -c "create database ${i};"
    done

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

    glog user.notice "Do mahout init to capture the empty base schema"

    MAHOUTSCHEMA=MaHoutSchema PGCMPHOME=${PGCMPHOME} MAINDATABASE=${devuri} SUPERUSERACCESS=${SUPERCLUSTER}/${devdb} COMPARISONDATABASE=${compuri} ${MAHOUT} init ${PROJECTNAME}

}

function capture_null () {
    glog user.notice "Do mahout capture without introducing any changes; expect no change"
    # Run mahout capture, without any change
    (cd ${PROJECTNAME}; ${MAHOUT} capture)
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
	raise notice 'table without primary key: "%"."%"', prec.nspname, prec.relname;
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
	raise notice 'relation % found % times', prec.table_name, prec.count;
  end loop;

  if c_found then
	raise exception 'Relations found where the same table/view name was used multiple times!';
  end if;
end
\$\$ language plpgsql;

" > ${PROJECTNAME}/common-tests/multiply-defined.sql
}

function install_target () {
    glog user.notice "Set up filesystem to use the captured mahout config for a fresh install"
    # Set up target directory for sample installation
    rm -rf ${TARGETDIR}
    mkdir ${TARGETDIR}
    cp -r ${PROJECTNAME} ${TARGETDIR}
}

function fix_install_uri () {
    # Drop alternate configuration into installation Mahout config
    local installuri
    installuri=${DBCLUSTER}/origin
    glog user.info "Change install instance to use ${installuri} rather than the URI provided in the build"
    egrep -v MAINDATABASE ${TARGETMHDIR}/mahout.conf | \
    egrep -v SUPERUSERACCESS ${TARGETMHDIR}/mahout.conf \
	> ${TARGETMHDIR}/mahout.conf.keep
    echo "
MAINDATABASE=${installuri}
SUPERUSERACCESS=${SUPERCLUSTER}/origin
SLONYCLUSTER=${SLONYCLUSTER}
SLONYMAINSET=${SLONYMAINSET}
SLONYTEMPSET=${SLONYTEMPSET}
SLONYOMITSEQUENCES=${SLONYOMITSEQUENCES}
SLONYOMITTABLES=${SLONYOMITTABLES}
MAHOUTOMITSCHEMAS=\"('_${SLONYCLUSTER}', 'nullschema', 'pg_catalog', 'information_schema', '\\\"MaHoutSchema\\\"')\"

" >> ${TARGETMHDIR}/mahout.conf.keep
    cp ${TARGETMHDIR}/mahout.conf.keep ${TARGETMHDIR}/mahout.conf
}

function attach_base_to_replicas () {
    glog user.notice "Attach base schema to Slony replicas"
    (cd ${TARGETMHDIR}; ${MAHOUT} slony_attach Base)
}

function prep_v11 () {
    glog user.notice "Prepare upgrade for v1.1"
    # Create a couple of upgrades
    echo "

version 1.1
requires Base
ddl 1.1/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir -p ${PROJECTNAME}/1.1
    echo "
   create table if not exists t1 (id serial primary key, name text not null unique, created_on timestamptz default now());
   create schema if not exists subschema;
   create table if not exists subschema.t2 (id serial primary key, name text not null unique, created_on timestamptz default now());
   alter table t1 add column if not exists \"Deleted_On\" timestamptz;
   create schema if not exists \"StudlySchema\";
   create table if not exists \"StudlySchema\".\"StudlyTable\" (id serial primary key, name text not null unique);
" > ${PROJECTNAME}/1.1/stuff.sql
} 

function capture_v11 () {
    glog user.notice "mahout capture on v1.1"
    (cd ${PROJECTNAME}; ${MAHOUT} capture; ${MAHOUT} build ${PROJECTNAME}-v1.1 tar.gz)
}

function install_v11_on_cluster () {
    glog user.notice "do upgrade of the install instance to run v1.1"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    # And try to install the upgrade
    (cd ${TARGETMHDIR}
     ${MAHOUT} slonik
     glog user.notice "Prepped slonik: .mahout-temp/mahout-ddl-script-1.1.slonik"
     ${PGBINDIR}/slonik .mahout-temp/mahout-ddl-script-1.1.slonik
     glog user.notice "Completed slonik for v1.1"
    )
    glog user.notice "Upgrade to v1.1 completed"
}

function prep_v12 () {
    echo "

version 1.2
requires 1.1
ddl 1.2/stuff.sql

" >> ${PROJECTNAME}/mahout.control
    mkdir -p ${PROJECTNAME}/1.2
    echo "
   create table t3 (
     id serial primary key,
     name text not null unique,
     created_on timestamptz not null default now());

" > ${PROJECTNAME}/1.2/stuff.sql
}

function capture_v12 () {
    glog user.notice "mahout capture on v1.2"
    (cd ${PROJECTNAME}
     ${MAHOUT} capture
     ${MAHOUT} build ${PROJECTNAME}-v1.2 tar.gz
    )
}

function install_v12_on_cluster () {
    glog user.notice "do upgrade of the install instance to run v1.2"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}
     ${MAHOUT} slonik
     ${PGBINDIR}/slonik .mahout-temp/mahout-ddl-script-1.2.slonik
    )
}

function prep_v13 () {
    echo "

version 1.3
requires 1.2
ddl 1.3/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir -p ${PROJECTNAME}/1.3

    echo "
   alter table t3 add column deleted_on timestamptz;
   create index t3_deleted on t3(deleted_on) where (deleted_on is not null);

" > ${PROJECTNAME}/1.3/stuff.sql
}

function capture_v13 () {
    glog user.notice "mahout capture on v1.3"
    (cd ${PROJECTNAME}
     ${MAHOUT} capture
     ${MAHOUT} build ${PROJECTNAME}-v1.3 tar.gz
    )
}

function install_v13_on_cluster () {
    glog user.notice "do upgrade of the install instance to run v1.3"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}
     ${MAHOUT} slonik
     ${PGBINDIR}/slonik .mahout-temp/mahout-ddl-script-1.3.slonik
    )
}

function prep_v14 () {
    echo "

version 1.4
requires 1.3
ddl 1.4/stuff.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir -p ${PROJECTNAME}/1.4

    echo "
   alter table t3 drop column deleted_on;
   alter table t3 add column updated_on timestamptz default now();
" > ${PROJECTNAME}/1.4/stuff.sql
}

function capture_v14 () {
    glog user.notice "mahout capture on v1.4"
    (cd ${PROJECTNAME}
     ${MAHOUT} capture
     ${MAHOUT} build ${PROJECTNAME}-v1.4 tar.gz
    )
}

function install_v14_on_cluster () {
    glog user.notice "do upgrade of the install instance to run v1.3, v1.4"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}
     ${MAHOUT} slonik
     ${PGBINDIR}/slonik .mahout-temp/mahout-ddl-script-1.4.slonik
    )
    glog user.notice "Completed upgrade to v1.4"
}

function prep_v15 () {
    echo "

version 1.5
requires 1.4
ddl 1.5/drop-t3.sql

" >> ${PROJECTNAME}/mahout.control

    mkdir -p ${PROJECTNAME}/1.5

    echo "
   drop table t3;
   create table t4 (id serial primary key, name text not null unique);
" > ${PROJECTNAME}/1.5/drop-t3.sql
}

function capture_v15 () {
    glog user.notice "mahout capture on v1.5"
    (cd ${PROJECTNAME}
     ${MAHOUT} capture
     ${MAHOUT} build ${PROJECTNAME}-v1.5 tar.gz
    )
}

function install_v15_on_cluster () {
    glog user.notice "do upgrade of the install instance to run v1.5"
    cp -r ${PROJECTNAME} ${TARGETDIR}
    fix_install_uri
    (cd ${TARGETMHDIR}
     ${MAHOUT} slonik
     ${PGBINDIR}/slonik .mahout-temp/mahout-ddl-script-1.5.slonik
    )
    glog user.notice "Completed upgrade to v1.5"
}
 
# Start...
kill_all_slons
drop_and_recreate_databases
set_up_preamble
initialize_slony_nodes
store_paths
launch_slons
subscribe_initial_set
initial_mahout_schema
capture_null
common_tests
install_target
fix_install_uri
attach_base_to_replicas
prep_v11
capture_v11
install_v11_on_cluster
prep_v12
capture_v12
install_v12_on_cluster
prep_v13
capture_v13
install_v13_on_cluster
prep_v14
capture_v14
install_v14_on_cluster
prep_v15
capture_v15
install_v15_on_cluster
kill_all_slons

# Test scenarios still needed...
# - set drop table fails!!!!
# - Use DML action
# - Use UNIX action




